import https from 'node:https';
import { fail, hash, verifyFreeProtection } from './models.mjs';

const endpoints = new Set([
  'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
  'https://openrouter.ai/api/v1/chat/completions',
  'https://open.bigmodel.cn/api/paas/v4/chat/completions'
]);
export class HTTPSTransport {
  async open(request, credential, signal) {
    if (!request.real || !endpoints.has(request.model.endpoint)) throw fail('transport_not_authorized');
    if (typeof credential.secret !== 'string' || !credential.secret || /[\r\n]/.test(credential.secret)) throw fail('invalid_credential');
    return await new Promise((resolve, reject) => {
      const req = https.request(request.model.endpoint, {
        method: 'POST', signal, headers: {'Authorization': `Bearer ${credential.secret}`,
          'Content-Type': 'application/json', 'Accept': 'text/event-stream'}
      }, response => resolve({status: response.statusCode, headers: response.headers, body: response}));
      req.on('error', reject);
      req.end(request.payloadJSON); // Exact frozen bytes. Never redirect or resend.
    });
  }
}

export async function* sseData(body, {maxFrameBytes = 1024 * 1024} = {}) {
  const decoder = new TextDecoder('utf-8', {fatal: true});
  let buffer = '', data = [];
  function line(value) {
    if (value === '') { const out = data.length ? data.join('\n') : null; data = []; return out; }
    if (value.startsWith('data:')) data.push(value.slice(5).replace(/^ /, ''));
    if (Buffer.byteLength(data.join('\n')) > maxFrameBytes) throw fail('sse_frame_too_large');
    return null;
  }
  for await (const chunk of body) {
    buffer += typeof chunk === 'string' ? chunk : decoder.decode(chunk, {stream: true});
    let match;
    while ((match = /\r\n|\n|\r(?!$)/.exec(buffer))) {
      const out = line(buffer.slice(0, match.index));
      buffer = buffer.slice(match.index + match[0].length);
      if (out !== null) yield out;
    }
    if (Buffer.byteLength(buffer) > maxFrameBytes) throw fail('sse_frame_too_large');
  }
  buffer += decoder.decode();
  // An unterminated SSE frame is incomplete and must not invent a terminal event.
  if (buffer || data.length) throw fail('incomplete_sse');
}

function failureFor(status, code, headers = {}) {
  if (code === 'AllocationQuota.FreeTierOnly' || status === 402) return {code: 'quota_denied', retryable: false};
  if (status === 429 || code === 429) {
    const seconds = Number(headers['retry-after']);
    return {code: 'rate_limited', retryable: true, retry_after_seconds: Number.isFinite(seconds) && seconds >= 0 ? Math.ceil(seconds) : null};
  }
  return {code: status === 401 ? 'unauthorized' : status === 403 ? 'forbidden' : 'provider_failed', retryable: false};
}

export class ModelGateway {
  constructor({transport, credentials, realEnabled = false, clock = () => Date.now()}) {
    this.transport = transport; this.credentials = credentials; this.realEnabled = realEnabled; this.clock = clock;
  }
  async *stream(request, {signal, timeoutMs = 30000, operationID, runtimeEpoch = 1} = {}) {
    let sequence = 0, text = '', accepted = false, response;
    const event = (type, fields = {}) => ({operation_id: operationID, runtime_epoch: runtimeEpoch,
      sequence: ++sequence, reality: request.real ? (accepted ? 'remote_accepted' : 'unknown') : 'simulated', type, ...fields});
    const controller = new AbortController();
    let timedOut = false;
    const cancelled = () => controller.abort();
    signal?.addEventListener('abort', cancelled, {once: true});
    if (signal?.aborted) controller.abort();
    const timer = setTimeout(() => {timedOut = true; controller.abort();}, timeoutMs);
    // Also races injected transports; cancellation is a transport contract, not a timeout promise that hangs.
    const abort = new Promise((_, reject) => {
      const stop = () => reject(fail(timedOut ? 'timeout' : 'cancelled'));
      if (controller.signal.aborted) stop(); else controller.signal.addEventListener('abort', stop, {once: true});
    });
    abort.catch(() => {});
    try {
      if (controller.signal.aborted) throw fail('cancelled');
      if (hash(request.payloadJSON) !== request.payloadHash) throw fail('payload_tampered');
      if (request.real) {
        if (!this.realEnabled) throw fail('real_calls_disabled');
        verifyFreeProtection(request.model, request.protection, this.clock());
      }
      const credential = request.real ? await Promise.race([this.credentials.credentialFor(request), abort]) : {secret: 'MOCK_ONLY'};
      if (request.real && credential.accountReference !== request.protection.account_reference) throw fail('credential_account_mismatch');
      response = await Promise.race([this.transport.open(request, credential, controller.signal), abort]);
      if (response.status !== 200) {
        let body = '';
        const it = response.body[Symbol.asyncIterator]();
        for (;;) { const next = await Promise.race([it.next(), abort]); if (next.done) break; body += Buffer.from(next.value).toString('utf8'); if (body.length > 8192) break; }
        let code; try { const parsed = JSON.parse(body); code = parsed.code ?? parsed.error?.code; } catch {}
        yield event('failed', failureFor(response.status, code, response.headers)); return;
      }
      accepted = true;
      yield event('accepted', {provider_operation_id: response.headers?.['x-generation-id'] ?? 'unreported'});
      const tools = new Map(); let finish, done = false, providerID;
      const it = sseData(response.body)[Symbol.asyncIterator]();
      for (;;) {
        const next = await Promise.race([it.next(), abort]);
        if (next.done) break;
        if (next.value === '[DONE]') { done = true; break; }
        let chunk; try {chunk = JSON.parse(next.value);} catch {throw fail('malformed_sse_json');}
        if (chunk.error) {yield event('failed', failureFor(Number(chunk.error.code), chunk.error.code)); return;}
        providerID = chunk.id ?? providerID;
        if (!Array.isArray(chunk.choices)) throw fail('invalid_chunk');
        const c = chunk.choices.find(x => x.index === 0);
        if (!c) continue; // usage-only chunks
        if (finish && (c.delta?.content || c.delta?.tool_calls?.length)) throw fail('delta_after_finish');
        if (typeof c.delta?.content === 'string' && c.delta.content) {
          text += c.delta.content;
          if (Buffer.byteLength(text) > 1024 * 1024) throw fail('text_too_large');
          yield event('text_delta', {text: c.delta.content});
        }
        for (const part of c.delta?.tool_calls ?? []) {
          if (!Number.isInteger(part.index) || part.index < 0 || part.index > 31) throw fail('invalid_tool_index');
          const tool = tools.get(part.index) ?? {id: '', name: '', arguments: ''};
          if (part.id) { if (tool.id && tool.id !== part.id) throw fail('tool_id_changed'); tool.id = part.id; }
          tool.name += part.function?.name ?? ''; tool.arguments += part.function?.arguments ?? '';
          if (tool.arguments.length > 65536 || tool.name.length > 128) throw fail('tool_too_large');
          tools.set(part.index, tool);
          yield event('tool_call_delta', {index: part.index, id: part.id ?? null,
            name: part.function?.name ?? '', arguments: part.function?.arguments ?? ''});
        }
        if (c.finish_reason) {
          if (finish && finish !== c.finish_reason) throw fail('finish_changed');
          finish = c.finish_reason;
        }
      }
      if (!done || !finish) throw fail('missing_terminal');
      if (finish === 'length') {yield event('failed', {code: 'output_truncated', retryable: false}); return;}
      if (!['stop', 'tool_calls'].includes(finish)) throw fail('unsupported_finish');
      for (const [index, tool] of tools) {
        const defined = JSON.parse(request.payloadJSON).tools?.find(t => t.function.name === tool.name);
        if (!tool.id || !defined || !tool.arguments) throw fail('invalid_tool_call');
        let args; try {args = JSON.parse(tool.arguments);} catch {throw fail('invalid_tool_arguments');}
        if (!args || typeof args !== 'object' || Array.isArray(args)) throw fail('invalid_tool_arguments');
        yield event('tool_call_complete', {index, ...tool});
      }
      if ((finish === 'tool_calls') !== (tools.size > 0)) throw fail('tool_finish_mismatch');
      yield event('message_completed', {final_text_hash: hash(text), finish_reason: tools.size ? 'tool_work_continues' : 'stop'});
      if (tools.size) {
        // Parsing a model proposal never grants execution permission. No automatic tool or model fallback.
        yield event('failed', {code: 'tool_requires_policy', retryable: false});
      } else {
        yield event('task_completed', {receipt_reference: `${request.real ? 'provider-response' : 'mock-response'}:${providerID ?? request.payloadHash}`});
      }
    } catch (error) {
      const code = timedOut ? 'timeout' : controller.signal.aborted ? 'cancelled' : error.code ?? 'transport_failed';
      yield event(code === 'cancelled' ? 'cancelled' : 'failed', code === 'cancelled' ? {} :
        {code, retryable: false, transport_outcome: accepted ? 'response_incomplete' : 'unconfirmed'});
    } finally {
      clearTimeout(timer); signal?.removeEventListener('abort', cancelled);
      controller.abort();
      response?.body?.destroy?.();
    }
  }
}
