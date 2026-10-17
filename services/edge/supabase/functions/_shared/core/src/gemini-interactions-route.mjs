// Google Gemini Interactions API route (POST /v1beta/interactions, stream=true, store=false).
// Docs read 2026-10-16: ai.google.dev/gemini-api/docs/interactions, /interactions/streaming,
// /function-calling?api=interactions, /image-understanding?api=interactions, /rate-limits, /pricing.
// Stateless: full history is sent each turn (store=false → nothing kept server-side, no previous_interaction_id).
// Free tier: "Used to improve our products: Yes" (pricing page) and limits are per project (RPM/TPM/RPD, RPD resets
// at midnight Pacific). This adapter adds a per-instance RPM guard and a cooldown after 429/RESOURCE_EXHAUSTED so a
// busy Gemini fails over to the next chain route (OpenRouter/Agnes) immediately instead of burning the turn budget.
// The key is read by the composition root from env (CATPAW_GEMINI_API_KEY) and is only ever sent as x-goog-api-key.
import { Buffer } from 'node:buffer';
import { ApiError, check, clone } from '../facade-r2/src/common.mjs';
import { safeProviderFailure } from './provider-errors.mjs';
import { sseData } from './openrouter-provider.mjs';

export const GEMINI_INTERACTIONS_ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse';
const MAX_CALLS = 4, MAX_OVERFLOW_CALLS = 12, STREAM_MAX_BYTES = 4_000_000, THOUGHT_MAX_BYTES = 16000, TEXT_MAX_BYTES = 64000;

/** Per-instance limiter shared by all Gemini routes of this isolate: sliding 60 s window + cooldown after 429. */
export class GeminiRateGuard {
  constructor({ rpm = 10, now = () => Date.now() } = {}) { this.rpm = rpm; this.now = now; this.sent = []; this.coolUntil = 0; }
  /** Throws rate_limited (a failover code) without calling Google when over budget or cooling down. */
  admit() {
    const t = this.now(); this.sent = this.sent.filter(x => t - x < 60000);
    if (t < this.coolUntil) throw Object.assign(new ApiError(429, 'rate_limited'), { retryAfterSeconds: Math.ceil((this.coolUntil - t) / 1000), localGuard: 'cooldown' });
    if (this.sent.length >= this.rpm) throw Object.assign(new ApiError(429, 'rate_limited'), { retryAfterSeconds: Math.ceil((60000 - (t - this.sent[0])) / 1000), localGuard: 'rpm' });
    this.sent.push(t);
  }
  /** Back off: honour Retry-After / RetryInfo when given, else exponential (15 s → 30 s → … ≤ 10 min); daily quota → 1 h. */
  backoff({ retryAfterSeconds = null, daily = false } = {}) {
    this.strikes = Math.min((this.strikes ?? 0) + 1, 6);
    const s = daily ? 3600 : Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0 ? Math.min(retryAfterSeconds, 3600) : Math.min(15 * 2 ** (this.strikes - 1), 600);
    this.coolUntil = Math.max(this.coolUntil, this.now() + s * 1000); return s;
  }
  ok() { this.strikes = 0; }
}

// Thought signatures: Gemini 3 function calling needs the model's own steps (incl. thought signatures) replayed in
// stateless mode. Our conversation store keeps OpenAI-style tool_calls only, so the raw thought steps are cached per
// call id in this isolate (TTL 30 min). A miss (other isolate / restart) is sent without them; if Google rejects that
// history (400) before any output, the chain fails over to the next route.
const signatureCache = new Map();
const remember = (id, steps) => { if (!id || !steps.length) return; signatureCache.set(id, { steps: clone(steps), at: Date.now() }); if (signatureCache.size > 500) signatureCache.delete(signatureCache.keys().next().value); };
const recall = id => { const e = signatureCache.get(id); if (!e) return []; if (Date.now() - e.at > 1800000) { signatureCache.delete(id); return []; } return clone(e.steps); };
export const _signatureCacheForTests = signatureCache;

const textOf = c => typeof c === 'string' ? c : Array.isArray(c) ? c.filter(p => p?.type === 'text').map(p => p.text).join('') : c == null ? '' : JSON.stringify(c);
/** OpenAI chat content → Interactions content blocks (text + inline base64 images). */
export function toContent(content) {
  if (typeof content === 'string') return [{ type: 'text', text: content }];
  const out = [];
  for (const p of Array.isArray(content) ? content : []) {
    if (p?.type === 'text' && typeof p.text === 'string') out.push({ type: 'text', text: p.text });
    else if (p?.type === 'image_url' || p?.type === 'image') {
      const url = typeof p.image_url === 'string' ? p.image_url : p.image_url?.url ?? p.url;
      const m = typeof url === 'string' && /^data:(image\/(?:png|jpeg|webp|heic|heif|gif));base64,([A-Za-z0-9+/=]+)$/.exec(url);
      check(m || (typeof p.data === 'string' && /^image\//.test(p.mime_type ?? '')), 422, 'image_input_unsupported'); // only inline data; no remote fetch
      out.push(m ? { type: 'image', mime_type: m[1], data: m[2] } : { type: 'image', mime_type: p.mime_type, data: p.data });
    }
  }
  return out.length ? out : [{ type: 'text', text: '' }];
}
/** OpenAI-style history → Interactions steps (stateless). */
export function toSteps(messages) {
  const names = new Map(), steps = [];
  for (const m of messages ?? []) {
    if (m.role === 'user') steps.push({ type: 'user_input', content: toContent(m.content) });
    else if (m.role === 'assistant') {
      const t = textOf(m.content); if (t) steps.push({ type: 'model_output', content: [{ type: 'text', text: t }] });
      for (const tc of m.tool_calls ?? []) {
        let args = tc.function?.arguments ?? '{}'; if (typeof args === 'string') { try { args = JSON.parse(args || '{}'); } catch { args = {}; } }
        names.set(tc.id, tc.function?.name);
        steps.push(...recall(tc.id), { type: 'function_call', id: tc.id, name: tc.function?.name, arguments: args });
      }
    } else if (m.role === 'tool') steps.push({ type: 'function_result', call_id: m.tool_call_id, name: m.name ?? names.get(m.tool_call_id) ?? 'tool', result: [{ type: 'text', text: textOf(m.content) }] });
    else if (m.role === 'system') steps.push({ type: 'user_input', content: [{ type: 'text', text: textOf(m.content) }] });
  }
  return steps;
}
export const toTools = tools => (tools ?? []).map(t => ({ type: 'function', name: t.function.name, description: t.function.description ?? '', parameters: clone(t.function.parameters ?? { type: 'object', properties: {} }) }));

export class GeminiInteractionsRoute {
  #secret;
  constructor(route, secret, { fetchImpl = globalThis.fetch, maxTokens = 2048, timeouts, guard, thinkingVisible = () => false } = {}) {
    this.route = route; this.#secret = secret; this.fetchImpl = fetchImpl; this.maxTokens = maxTokens; this.timeouts = timeouts; this.guard = guard; this.thinkingVisible = thinkingVisible;
  }
  payload({ messages, system_prompt, tools, model_override }) {
    const body = { model: model_override ?? this.route.model, input: toSteps(messages), stream: true, store: false, generation_config: { max_output_tokens: this.maxTokens } };
    if (system_prompt) body.system_instruction = system_prompt;
    if (tools?.length) { body.tools = toTools(tools); body.generation_config.tool_choice = 'auto'; }
    if (this.route.thinking_summary && this.thinkingVisible()) body.generation_config.thinking_summaries = 'auto';
    return body;
  }
  async *stream(input, evidence) {
    const { signal } = input;
    check(typeof this.#secret === 'string' && this.#secret.trim() && !/[\r\n]/.test(this.#secret), 503, 'not_configured');
    this.guard?.admit();
    const controller = new AbortController(), cancel = () => controller.abort();
    signal?.addEventListener('abort', cancel, { once: true }); if (signal?.aborted) cancel();
    let timedOut = false, visible = false, active = false, timer = null;
    const expire = phase => () => { timedOut = phase; cancel(); };
    const arm = ms => { clearTimeout(timer); timer = setTimeout(expire(active ? 'idle' : 'first_event'), ms); };
    const cap = ms => Math.max(1, Math.min(ms, input.attempt_budget_ms ?? Infinity)); // chain/turn budget clamp (w7)
    arm(cap(this.timeouts.firstEventMs)); const totalTimer = setTimeout(expire('total'), cap(this.timeouts.totalMs));
    let response;
    try {
      const body = this.payload(input);
      response = await this.fetchImpl(this.route.endpoint, { method: 'POST', redirect: 'error', signal: controller.signal, headers: { 'x-goog-api-key': this.#secret, 'Content-Type': 'application/json', Accept: 'text/event-stream' }, body: JSON.stringify(body) });
      evidence.http_status = response.status; evidence.protocol = 'interactions';
      if (response.status !== 200) {
        evidence.failure = await safeProviderFailure(response, { redact: t => t.replaceAll(this.#secret, '[REDACTED]') });
        const raw = JSON.stringify(evidence.failure ?? {});
        const daily = /per.?day|PerDay|daily/i.test(raw), exhausted = response.status === 429 || /RESOURCE_EXHAUSTED/.test(raw);
        const retryInfo = /"retryDelay"\s*:\s*"(\d+)s"/.exec(raw);
        if (exhausted) { const s = this.guard?.backoff({ retryAfterSeconds: evidence.failure?.headers?.retry_after_seconds ?? (retryInfo ? Number(retryInfo[1]) : null), daily }); throw Object.assign(new ApiError(429, daily ? 'quota_exhausted' : 'rate_limited'), { retryAfterSeconds: s }); }
        // 400 with tool history usually means missing thought signatures (see cache note) → fail over, never retry here.
        const codes = { 400: body.input.some(s => s.type === 'function_call') ? 'provider_failed' : 'provider_request_invalid', 401: 'unauthorized', 403: 'forbidden', 404: 'free_model_unavailable', 500: 'provider_failed', 502: 'provider_failed', 503: 'provider_overloaded', 504: 'provider_overloaded' };
        throw new ApiError(503, codes[response.status] ?? 'provider_failed');
      }
      check(response.headers.get('content-type')?.startsWith('text/event-stream') && response.body, 503, 'invalid_provider_stream');
      const calls = new Map(), kinds = new Map(); let thoughtSteps = [], textBytes = 0, thoughtBytes = 0, completed = false, status = null;
      for await (const data of sseData(response.body, { maxBytes: STREAM_MAX_BYTES })) {
        active = true; arm(this.timeouts.idleMs);
        if (data === '[DONE]') break;
        let ev; try { ev = JSON.parse(data); } catch { throw new ApiError(503, 'malformed_provider_json'); }
        const type = ev.event_type;
        if (type === 'error' || ev.error) {
          const e = ev.error ?? {}; const busy = Number(e.code) === 429 || e.status === 'RESOURCE_EXHAUSTED';
          if (busy && !visible) { const s = this.guard?.backoff({}); throw Object.assign(new ApiError(429, 'rate_limited'), { retryAfterSeconds: s }); }
          throw new ApiError(503, 'provider_stream_error', visible ? { reconciliation: true } : undefined);
        }
        if (type === 'interaction.created') { if (typeof ev.interaction?.model === 'string') evidence.actual_model = ev.interaction.model.slice(0, 200); continue; }
        if (type === 'step.start') {
          const s = ev.step ?? {}; kinds.set(ev.index, s.type);
          // chat-context-1522: a 5th+ parallel call (prod turn 6497bf72: five create_task after a declined reminder) used to
          // fail the whole turn with invalid_tool_index. Calls beyond MAX_CALLS (up to MAX_OVERFLOW_CALLS more) are now kept
          // and surfaced as tool_call_overflow; the chat loop decides (B1 NoBug round 2): with any write in the step NONE run
          // (too_many_parallel_writes), with read-only calls only the first MAX_CALLS run and the rest get not_executed.
          if (s.type === 'function_call') { check(calls.size < MAX_CALLS + MAX_OVERFLOW_CALLS, 503, 'invalid_tool_index'); calls.set(ev.index, { id: String(s.id ?? ''), name: String(s.name ?? ''), raw: '', thoughts: thoughtSteps }); thoughtSteps = []; }
          else if (s.type === 'thought') thoughtSteps.push({ ...clone(s), type: 'thought' });
          continue;
        }
        if (type === 'step.delta') {
          const d = ev.delta ?? {}, kind = kinds.get(ev.index);
          if (d.type === 'text') {
            check(typeof d.text === 'string', 503, 'invalid_provider_chunk');
            if (d.text) { textBytes += Buffer.byteLength(d.text); check(textBytes <= TEXT_MAX_BYTES, 503, 'output_too_large'); visible = true; yield { type: 'text_delta', text: d.text }; }
          } else if (d.type === 'thought_summary') {
            const t = d.content?.text ?? d.text; if (typeof t === 'string' && t) { thoughtBytes += Buffer.byteLength(t); const show = this.thinkingVisible(); if (show) visible = true; if (thoughtBytes <= THOUGHT_MAX_BYTES) yield { type: 'thinking_delta', text: t }; }
          } else if (d.type === 'thought_signature') { const last = thoughtSteps.at(-1); if (last && kind === 'thought') Object.assign(last, Object.fromEntries(Object.entries(d).filter(([k]) => k !== 'type'))); }
          else if (d.type === 'arguments_delta') { const c = calls.get(ev.index); check(c, 503, 'invalid_tool_index'); c.raw += typeof d.arguments === 'string' ? d.arguments : JSON.stringify(d.arguments ?? {}); check(c.raw.length <= 24000, 503, 'tool_too_large'); }
          continue;
        }
        if (type === 'interaction.completed') { completed = true; status = ev.interaction?.status ?? null; if (typeof ev.interaction?.model === 'string') evidence.actual_model = ev.interaction.model.slice(0, 200); continue; }
        if (type === 'interaction.status_update') { status = ev.status ?? status; continue; }
      }
      check(completed, 503, 'incomplete_provider_terminal', visible ? { reconciliation: true } : undefined);
      evidence.interaction_status = status;
      const ordered = [...calls.entries()].sort(([a], [b]) => a - b).map(([, c]) => c);
      if (ordered.length > MAX_CALLS) evidence.overflow_tool_calls = ordered.length - MAX_CALLS;
      for (const [i, c] of ordered.entries()) {
        check(c.id && c.name.length <= 80 && c.id.length <= 160 && input.tools?.some(x => x.function.name === c.name), 503, 'tool_not_allowed');
        let args; try { args = JSON.parse(c.raw || '{}'); } catch { if (i < MAX_CALLS) throw new ApiError(503, 'invalid_tool_arguments'); args = {}; }
        remember(c.id, c.thoughts); visible = true; yield { type: i < MAX_CALLS ? 'tool_call' : 'tool_call_overflow', id: c.id, name: c.name, arguments: args };
      }
      this.guard?.ok(); evidence.terminal_validated = true;
      yield { type: 'done', finish_reason: calls.size ? 'tool_calls' : 'stop', response_id: null };
    } catch (e) {
      // Hidden thinking (client did not ask for it) is not user-visible output, so a timeout then is still "before output".
      if (timedOut) { evidence.timeout_phase = timedOut; throw new ApiError(503, visible ? 'provider_timeout' : 'provider_timeout_before_output', visible ? { reconciliation: true } : undefined); }
      if (e instanceof ApiError) throw e;
      throw new ApiError(503, visible ? 'provider_interrupted' : 'provider_transport_failed', { reconciliation: true });
    } finally {
      clearTimeout(timer); clearTimeout(totalTimer); signal?.removeEventListener('abort', cancel); controller.abort();
      try { await response?.body?.cancel(); } catch {}
    }
  }
}
