// Free-tier model route chain (R7 MVP). Ordered zero-cost OpenAI-compatible
// routes; on rate limit / capacity failure BEFORE any event is yielded, the
// chain moves to the next configured free route. Once text or a tool call has
// been emitted the turn is never re-dispatched (no silent resend).
// Secrets are supplied by the composition root from environment only.
import { AsyncLocalStorage } from 'node:async_hooks';
import { Buffer } from 'node:buffer';
import { ApiError, check, clone } from '../facade-r2/src/common.mjs';
import { safeProviderFailure } from './provider-errors.mjs';
import { sseData } from './openrouter-provider.mjs';

export const FREE_ROUTE_CATALOG = Object.freeze({
  gemini: Object.freeze({ id: 'gemini', provider: 'Google Gemini API (free tier)', endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions', model: 'gemini-3.5-flash-lite', secret: 'CATPAW_GEMINI_API_KEY', policy_url: 'https://ai.google.dev/gemini-api/terms', thinking_summary: true }),
  groq: Object.freeze({ id: 'groq', provider: 'Groq (free tier)', endpoint: 'https://api.groq.com/openai/v1/chat/completions', model: 'openai/gpt-oss-120b', secret: 'CATPAW_GROQ_API_KEY', policy_url: 'https://groq.com/privacy-policy', thinking_summary: false }),
  openrouter: Object.freeze({ id: 'openrouter', provider: 'OpenRouter (:free models)', endpoint: 'https://openrouter.ai/api/v1/chat/completions', model: 'apodex/apodex-1.1-mini:free', secret: 'CATPAW_PRIVATE_MODEL_KEY', policy_url: 'https://openrouter.ai/privacy', thinking_summary: false }),
});
// Production default stays the existing OpenRouter free route (existing key); Gemini/Groq are optional extras.
export const DEFAULT_CHAIN_ORDER = Object.freeze(['openrouter', 'gemini', 'groq']);
// Codes that mean "this free route is busy/unavailable right now"; safe to fail over
// only because nothing has been streamed to the user yet.
export const FAILOVER_CODES = new Set(['rate_limited', 'quota_exhausted', 'free_model_unavailable', 'provider_failed', 'provider_overloaded', 'provider_timeout_before_output', 'not_configured']);

const preferenceStore = new AsyncLocalStorage();
/** Run an HTTP request with a developer route preference (header X-Catpaw-Route; allow-list only). */
export function withRoutePreference(preference, fn, { reasoningSummary = false } = {}) {
  const value = typeof preference === 'string' && Object.hasOwn(FREE_ROUTE_CATALOG, preference) ? preference : null;
  return preferenceStore.run({ preference: value, reasoningSummary: reasoningSummary === true }, fn);
}
/** Only clients that advertise `X-Catpaw-Reasoning-Summary: 1` decode the optional wire event. */
export const clientAcceptsReasoningSummary = () => preferenceStore.getStore()?.reasoningSummary === true;
export const currentRoutePreference = () => preferenceStore.getStore()?.preference ?? null;

/** Build the consented route description from env. Returns null unless a Gemini or Groq key is deployed. */
export function readFreeRouteChain(get) {
  const configuredOrder = (get('CATPAW_MODEL_ROUTE_ORDER') || DEFAULT_CHAIN_ORDER.join(',')).split(',').map(s => s.trim()).filter(Boolean);
  check(configuredOrder.every(id => Object.hasOwn(FREE_ROUTE_CATALOG, id)) && new Set(configuredOrder).size === configuredOrder.length, 422, 'model_route_order_invalid');
  const routes = configuredOrder.filter(id => !!get(FREE_ROUTE_CATALOG[id].secret)).map(id => {
    const r = FREE_ROUTE_CATALOG[id];
    const model = get(`CATPAW_${id.toUpperCase()}_MODEL`) || r.model;
    check(/^[A-Za-z0-9._:/-]{1,120}$/.test(model), 422, 'model_route_model_invalid');
    if (id === 'openrouter') check(model.endsWith(':free'), 422, 'paid_or_router_model_denied');
    return { id, provider: r.provider, endpoint: r.endpoint, model, policy_url: r.policy_url, thinking_summary: r.thinking_summary && get('CATPAW_THINKING_SUMMARY') !== '0' };
  });
  // Chain only exists when an extra free route key is deployed; otherwise the frozen single route stays.
  if (!routes.length || !(get(FREE_ROUTE_CATALOG.gemini.secret) || get(FREE_ROUTE_CATALOG.groq.secret))) return null;
  const secrets = Object.fromEntries(routes.map(r => [r.id, get(FREE_ROUTE_CATALOG[r.id].secret)]));
  return { routes, secrets, autoFailover: get('CATPAW_MODEL_AUTO_FAILOVER') !== '0' };
}

class OpenAICompatibleRoute {
  #secret;
  constructor(route, secret, { fetchImpl = globalThis.fetch, maxTokens = 2048, timeoutMs = 20000 } = {}) {
    this.route = route; this.#secret = secret; this.fetchImpl = fetchImpl; this.maxTokens = maxTokens; this.timeoutMs = timeoutMs;
  }
  payload({ messages, system_prompt, tools }) {
    const body = { model: this.route.model, messages: [{ role: 'system', content: system_prompt }, ...clone(messages)], stream: true, max_tokens: this.maxTokens };
    if (tools?.length) { body.tools = clone(tools); body.tool_choice = 'auto'; }
    if (this.route.id === 'openrouter') body.provider = { ...(this.route.model === 'apodex/apodex-1.1-mini:free' ? { only: ['novita/bf16'] } : {}), allow_fallbacks: false, data_collection: 'deny', max_price: { prompt: 0, completion: 0, request: 0, image: 0 } };
    // Gemini OpenAI-compat: request thought summaries; they arrive as separate parts.
    if (this.route.id === 'gemini' && this.route.thinking_summary) body.extra_body = { google: { thinking_config: { include_thoughts: true } } };
    return body;
  }
  async *stream(input, evidence) {
    const { signal } = input;
    check(typeof this.#secret === 'string' && this.#secret.trim() && !/[\r\n]/.test(this.#secret), 503, 'not_configured');
    const controller = new AbortController(), cancel = () => controller.abort();
    signal?.addEventListener('abort', cancel, { once: true }); if (signal?.aborted) cancel();
    let timedOut = false, emitted = false; const timer = setTimeout(() => { timedOut = true; cancel(); }, this.timeoutMs);
    let response;
    try {
      response = await this.fetchImpl(this.route.endpoint, { method: 'POST', redirect: 'error', signal: controller.signal, headers: { Authorization: `Bearer ${this.#secret}`, 'Content-Type': 'application/json', Accept: 'text/event-stream' }, body: JSON.stringify(this.payload(input)) });
      evidence.http_status = response.status;
      if (response.status !== 200) evidence.failure = await safeProviderFailure(response, { redact: t => t.replaceAll(this.#secret, '[REDACTED]') });
      const codes = { 401: 'unauthorized', 402: 'quota_exhausted', 403: 'forbidden', 404: 'free_model_unavailable', 429: 'rate_limited', 500: 'provider_failed', 502: 'provider_failed', 503: 'provider_overloaded', 529: 'provider_overloaded' };
      check(response.status === 200, response.status === 429 ? 429 : 503, codes[response.status] ?? 'provider_failed');
      check(response.headers.get('content-type')?.startsWith('text/event-stream') && response.body, 503, 'invalid_provider_stream');
      let finish = null, done = false, textBytes = 0, thoughtBytes = 0; const calls = new Map();
      for await (const data of sseData(response.body)) {
        if (data === '[DONE]') { done = true; break; }
        let chunk; try { chunk = JSON.parse(data); } catch { throw new ApiError(503, 'malformed_provider_json'); }
        if (chunk.error) throw new ApiError(emitted ? 503 : 429, Number(chunk.error?.code) === 429 || chunk.error?.status === 'RESOURCE_EXHAUSTED' ? 'rate_limited' : 'provider_stream_error', emitted ? { reconciliation: true } : undefined);
        if (typeof chunk.model === 'string') evidence.actual_model = chunk.model.slice(0, 200);
        const c = Array.isArray(chunk.choices) ? chunk.choices.find(x => (x.index ?? 0) === 0) : null; if (!c) continue;
        const delta = c.delta ?? {};
        // Thought summary: Gemini marks thought parts; OpenRouter/Groq may use `reasoning`.
        const thought = delta.extra_content?.google?.thought === true ? delta.content : (typeof delta.reasoning === 'string' ? delta.reasoning : null);
        if (thought) { thoughtBytes += Buffer.byteLength(thought); check(thoughtBytes <= 16000, 503, 'thought_too_large'); emitted = true; yield { type: 'thinking_delta', text: thought }; }
        else if (delta.content) { check(typeof delta.content === 'string', 503, 'invalid_provider_chunk'); textBytes += Buffer.byteLength(delta.content); check(textBytes <= 64000, 503, 'output_too_large'); emitted = true; yield { type: 'text_delta', text: delta.content }; }
        for (const part of delta.tool_calls ?? []) {
          const i = Number.isInteger(part.index) ? part.index : 0; check(i >= 0 && i < 4, 503, 'invalid_tool_index');
          const t = calls.get(i) ?? { id: '', name: '', raw: '' };
          if (part.id) { check(!t.id || t.id === part.id, 503, 'tool_id_changed'); t.id = part.id; }
          const f = part.function ?? {}; t.name += f.name ?? ''; t.raw += f.arguments ?? '';
          check(t.name.length <= 80 && t.raw.length <= 24000 && t.id.length <= 160, 503, 'tool_too_large'); calls.set(i, t);
        }
        if (c.finish_reason) finish = c.finish_reason;
      }
      check(done || finish, 503, 'incomplete_provider_terminal', { reconciliation: true });
      if (calls.size) finish = 'tool_calls'; else if (finish !== 'tool_calls') finish = 'stop';
      for (const [, t] of [...calls.entries()].sort(([a], [b]) => a - b)) {
        check(t.id && input.tools?.some(x => x.function.name === t.name), 503, 'tool_not_allowed');
        let args; try { args = JSON.parse(t.raw || '{}'); } catch { throw new ApiError(503, 'invalid_tool_arguments'); }
        emitted = true; yield { type: 'tool_call', id: t.id, name: t.name, arguments: args };
      }
      evidence.terminal_validated = true;
      yield { type: 'done', finish_reason: finish, response_id: null };
    } catch (e) {
      if (timedOut) throw new ApiError(503, emitted ? 'provider_timeout' : 'provider_timeout_before_output', emitted ? { reconciliation: true } : undefined);
      if (e instanceof ApiError) throw e;
      throw new ApiError(503, emitted ? 'provider_interrupted' : 'provider_transport_failed', { reconciliation: true });
    } finally {
      clearTimeout(timer); signal?.removeEventListener('abort', cancel); controller.abort();
      try { await response?.body?.cancel(); } catch {}
    }
  }
}

/** Provider port compatible with OpenRouterProvider (identity/reality/assertReady/stream). */
export class FreeRouteChainProvider {
  #routes; #observations = [];
  constructor({ routes, secrets, fetchImpl, timeoutMs = 20000, beforeStream = null, emitThinking = true, autoFailover = true }) {
    check(Array.isArray(routes) && routes.length > 0, 503, 'not_configured');
    this.#routes = routes.map(r => new OpenAICompatibleRoute(r, secrets[r.id], { fetchImpl, timeoutMs }));
    this.beforeStream = beforeStream; this.emitThinking = emitThinking; this.autoFailover = autoFailover;
    this.identity = { provider: 'free-route-chain', routes: routes.map(r => ({ id: r.id, model: r.model, endpoint: r.endpoint })), free_only: true, max_tokens: 2048, adapter_version: 1 };
  }
  get observations() { return clone(this.#observations); }
  get reality() { return 'provider_unverified'; }
  assertReady() { check(this.#routes.length > 0, 503, 'not_configured'); }
  order() {
    const pref = currentRoutePreference();
    if (!pref) return this.#routes;
    const chosen = this.#routes.filter(r => r.route.id === pref);
    return chosen.length ? [...chosen, ...this.#routes.filter(r => r.route.id !== pref)] : this.#routes;
  }
  async *stream(input) {
    this.assertReady(); input.signal?.throwIfAborted(); await this.beforeStream?.(input.provider_context); input.signal?.throwIfAborted(); input.assertDispatchReady?.();
    let last = null;
    for (const route of this.order()) {
      const evidence = { attempt: this.#observations.length + 1, route: route.route.id, requested_model: route.route.model, http_status: null, actual_model: null, terminal_validated: false };
      this.#observations.push(evidence);
      let emitted = false;
      try {
        for await (const event of route.stream(input, evidence)) {
          if (event.type === 'thinking_delta' && !(this.emitThinking && clientAcceptsReasoningSummary())) { evidence.thinking_bytes = (evidence.thinking_bytes ?? 0) + Buffer.byteLength(event.text); continue; }
          emitted = true; yield event;
        }
        return;
      } catch (e) {
        evidence.error = e?.code ?? 'provider_failed';
        input.signal?.throwIfAborted();
        if (emitted || !(e instanceof ApiError) || !FAILOVER_CODES.has(e.code)) throw e;
        const ra = evidence.failure?.headers?.retry_after_seconds; if (Number.isFinite(ra)) e.retryAfterSeconds = Math.min(3600, Math.ceil(ra));
        if (!this.autoFailover) throw e;
        last = e; // busy before any output: try next free route
      }
    }
    throw last ?? new ApiError(503, 'provider_failed');
  }
}
