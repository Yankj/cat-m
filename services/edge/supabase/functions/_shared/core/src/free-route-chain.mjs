// Model route chain (R7 MVP). Ordered OpenAI-compatible routes. Billing rule:
// a route is enabled ONLY when its key is explicitly configured (no key, no route);
// see each catalog entry's `billing` note. Routes; on rate limit / capacity failure BEFORE any event is yielded, the
// chain moves to the next configured free route. Once text or a tool call has
// been emitted the turn is never re-dispatched (no silent resend).
// Secrets are supplied by the composition root from environment only.
import { AsyncLocalStorage } from 'node:async_hooks';
import { Buffer } from 'node:buffer';
import { ApiError, check, clone } from '../facade-r2/src/common.mjs';
import { safeProviderFailure } from './provider-errors.mjs';
import { sseData } from './openrouter-provider.mjs';
import { GeminiInteractionsRoute, GeminiRateGuard, GEMINI_INTERACTIONS_ENDPOINT } from './gemini-interactions-route.mjs';

export const FREE_ROUTE_CATALOG = Object.freeze({
  // Gemini: Interactions API by default (docs' recommended interface since 2026-06); CATPAW_GEMINI_PROTOCOL=openai_compat keeps the old endpoint.
  gemini: Object.freeze({ id: 'gemini', provider: 'Google Gemini API (free tier)', endpoint: GEMINI_INTERACTIONS_ENDPOINT, compat_endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions', protocol: 'interactions', model: 'gemini-3.5-flash-lite', secret: 'CATPAW_GEMINI_API_KEY', policy_url: 'https://ai.google.dev/gemini-api/terms', thinking_summary: true }),
  groq: Object.freeze({ id: 'groq', provider: 'Groq (free tier)', endpoint: 'https://api.groq.com/openai/v1/chat/completions', model: 'openai/gpt-oss-120b', secret: 'CATPAW_GROQ_API_KEY', policy_url: 'https://groq.com/privacy-policy', thinking_summary: false }),
  // Agnes AI (https://wiki.agnes-ai.com/en/docs/pricing.md, read 2026-10-15): agnes-3.0-flash and
  // agnes-2.5-flash are currently $0 (promo; list price $0.05/M in, $0.15/M out, $0.005/M cached).
  // agnes-2.5-pro is PAID ($0.45/M in, $0.90/M out). Free accounts: RPM 20 (429); 402 = balance/quota.
  // Overriding CATPAW_AGNES_MODEL to a Pro model, or the promo ending, makes this route billable.
  agnes: Object.freeze({ id: 'agnes', provider: 'Agnes AI', endpoint: 'https://apihub.agnes-ai.com/v1/chat/completions', model: 'agnes-3.0-flash', secret: 'CATPAW_AGNES_API_KEY', policy_url: 'https://wiki.agnes-ai.com/en/docs/privacy-policy.md', thinking_summary: true, billing: 'promo_free_flash_paid_pro' }),
  openrouter: Object.freeze({ id: 'openrouter', provider: 'OpenRouter (:free models)', endpoint: 'https://openrouter.ai/api/v1/chat/completions', model: 'apodex/apodex-1.1-mini:free', secret: 'CATPAW_PRIVATE_MODEL_KEY', policy_url: 'https://openrouter.ai/privacy', thinking_summary: false }),
});
// Production default stays the existing OpenRouter free route (existing key); Gemini/Groq are optional extras.
// Agnes is the busy fallback after the free routes; CATPAW_MODEL_ROUTE_ORDER can reorder.
export const DEFAULT_CHAIN_ORDER = Object.freeze(['openrouter', 'gemini', 'groq', 'agnes']);
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

/** Build the consented route description from env. Only routes with an explicitly configured key are
 * enabled; returns null (frozen single OpenRouter route) unless a Gemini, Groq or Agnes key is deployed. */
// Gemini switch CATPAW_GEMINI_ROUTE: off | primary | fallback (unset = fallback once CATPAW_GEMINI_API_KEY is set).
// primary puts Gemini first in the default order; an explicit CATPAW_MODEL_ROUTE_ORDER always wins.
export function readGeminiSwitch(get) {
  const mode = String(get('CATPAW_GEMINI_ROUTE') ?? '').trim().toLowerCase() || 'fallback';
  check(['off', 'primary', 'fallback'].includes(mode), 422, 'gemini_route_mode_invalid');
  const protocol = String(get('CATPAW_GEMINI_PROTOCOL') ?? '').trim().toLowerCase() || 'interactions';
  check(['interactions', 'openai_compat'].includes(protocol), 422, 'gemini_protocol_invalid');
  const rpmText = get('CATPAW_GEMINI_RPM'); const rpm = rpmText ? Number(rpmText) : 10;
  check(Number.isInteger(rpm) && rpm >= 1 && rpm <= 1000, 422, 'gemini_rpm_invalid');
  return { mode, protocol, rpm };
}
export function readFreeRouteChain(get) {
  const gemini = readGeminiSwitch(get);
  const defaultOrder = gemini.mode === 'primary' ? ['gemini', ...DEFAULT_CHAIN_ORDER.filter(id => id !== 'gemini')] : DEFAULT_CHAIN_ORDER;
  const configuredOrder = (get('CATPAW_MODEL_ROUTE_ORDER') || defaultOrder.join(',')).split(',').map(s => s.trim()).filter(Boolean);
  check(configuredOrder.every(id => Object.hasOwn(FREE_ROUTE_CATALOG, id)) && new Set(configuredOrder).size === configuredOrder.length, 422, 'model_route_order_invalid');
  const routes = configuredOrder.filter(id => !!get(FREE_ROUTE_CATALOG[id].secret) && !(id === 'gemini' && gemini.mode === 'off')).map(id => {
    const r = FREE_ROUTE_CATALOG[id];
    const model = get(`CATPAW_${id.toUpperCase()}_MODEL`) || r.model;
    check(/^[A-Za-z0-9._:/-]{1,120}$/.test(model), 422, 'model_route_model_invalid');
    if (id === 'openrouter') check(model.endsWith(':free'), 422, 'paid_or_router_model_denied');
    if (id === 'agnes') check(/^agnes-[0-9a-z.-]+$/.test(model), 422, 'model_route_model_invalid');
    const ms = name => { const v = get(`CATPAW_${id.toUpperCase()}_${name}_TIMEOUT_MS`); if (v === undefined || v === null || v === '') return undefined; check(/^[0-9]{4,6}$/.test(v), 422, 'model_route_timeout_invalid'); return Number(v); };
    const timeouts = Object.fromEntries([['firstEventMs', ms('FIRST_EVENT')], ['idleMs', ms('IDLE')], ['totalMs', ms('TOTAL')]].filter(([, v]) => v !== undefined));
    const geminiExtra = id === 'gemini' ? { protocol: gemini.protocol, rpm: gemini.rpm, image_input: gemini.protocol === 'interactions' } : {};
    return { id, provider: r.provider, endpoint: id === 'gemini' && gemini.protocol === 'openai_compat' ? r.compat_endpoint : r.endpoint, model, ...geminiExtra, policy_url: r.policy_url, billing: r.billing ?? 'free_tier', thinking_summary: r.thinking_summary && get('CATPAW_THINKING_SUMMARY') !== '0', ...Object.keys(timeouts).length ? { timeouts } : {} };
  });
  // Chain only exists when an extra free route key is deployed; otherwise the frozen single route stays.
  if (!routes.length || !routes.some(r => r.id !== 'openrouter')) return null;
  const secrets = Object.fromEntries(routes.map(r => [r.id, get(FREE_ROUTE_CATALOG[r.id].secret)]));
  return { routes, secrets, autoFailover: get('CATPAW_MODEL_AUTO_FAILOVER') !== '0' };
}

// Reasoning routes (Agnes) may think for a long time before the first event; others keep the
// historical single budget for every stage. Values are bounded to the Edge wall clock.
// One answer is ≤2048 tokens (≤64kB text) plus reasoning; OpenAI-style chunks carry ~200-300 bytes of
// JSON framing per token, so the wire cap must be far above the text cap.
export const STREAM_MAX_BYTES = 4_000_000, THOUGHT_MAX_BYTES = 16000;
export const REASONING_ROUTE_TIMEOUTS = Object.freeze({ firstEventMs: 75000, idleMs: 20000, totalMs: 100000 });
export function routeTimeouts(route, timeoutMs) {
  const base = route.id === 'agnes' ? REASONING_ROUTE_TIMEOUTS : { firstEventMs: timeoutMs, idleMs: timeoutMs, totalMs: timeoutMs };
  const t = { ...base, ...route.timeouts };
  check(['firstEventMs', 'idleMs', 'totalMs'].every(k => Number.isInteger(t[k]) && t[k] >= 1000 && t[k] <= 110000) && t.firstEventMs <= t.totalMs && t.idleMs <= t.totalMs, 422, 'model_route_timeout_invalid');
  return t;
}

class OpenAICompatibleRoute {
  #secret;
  constructor(route, secret, { fetchImpl = globalThis.fetch, maxTokens = 2048, timeoutMs = 20000, thinkingVisible = () => true } = {}) {
    this.route = route; this.#secret = secret; this.fetchImpl = fetchImpl; this.maxTokens = maxTokens; this.timeoutMs = timeoutMs; this.thinkingVisible = thinkingVisible;
    this.timeouts = routeTimeouts(route, timeoutMs);
  }
  payload({ messages, system_prompt, tools }) {
    const body = { model: this.route.model, messages: [{ role: 'system', content: system_prompt }, ...clone(messages)], stream: true, max_tokens: this.maxTokens };
    if (tools?.length) { body.tools = clone(tools); body.tool_choice = 'auto'; }
    if (this.route.id === 'openrouter') body.provider = { ...(this.route.model === 'apodex/apodex-1.1-mini:free' ? { only: ['novita/bf16'] } : {}), allow_fallbacks: false, data_collection: 'deny', max_price: { prompt: 0, completion: 0, request: 0, image: 0 } };
    // Gemini OpenAI-compat: request thought summaries; they arrive as separate parts.
    if (this.route.id === 'gemini' && this.route.thinking_summary) body.extra_body = { google: { thinking_config: { include_thoughts: true } } };
    // Agnes (vLLM-style): Thinking only when the client will render reasoning_summary (saves latency otherwise).
    if (this.route.id === 'agnes') body.chat_template_kwargs = { enable_thinking: this.route.thinking_summary && clientAcceptsReasoningSummary() };
    return body;
  }
  async *stream(input, evidence) {
    const { signal } = input;
    check(typeof this.#secret === 'string' && this.#secret.trim() && !/[\r\n]/.test(this.#secret), 503, 'not_configured');
    const controller = new AbortController(), cancel = () => controller.abort();
    signal?.addEventListener('abort', cancel, { once: true }); if (signal?.aborted) cancel();
    // Staged timeouts: a generous wait for the first upstream event (reasoning models think before
    // their first token), then an idle timeout reset by every event, reasoning included; a total cap.
    let timedOut = false, emitted = false, timer = null;
    const expire = phase => () => { timedOut = phase; cancel(); };
    const arm = ms => { clearTimeout(timer); timer = setTimeout(expire(emittedOrActive ? 'idle' : 'first_event'), ms); };
    let emittedOrActive = false; arm(this.timeouts.firstEventMs);
    const totalTimer = setTimeout(expire('total'), this.timeouts.totalMs);
    let response;
    try {
      response = await this.fetchImpl(this.route.endpoint, { method: 'POST', redirect: 'error', signal: controller.signal, headers: { Authorization: `Bearer ${this.#secret}`, 'Content-Type': 'application/json', Accept: 'text/event-stream' }, body: JSON.stringify(this.payload(input)) });
      evidence.http_status = response.status;
      if (response.status !== 200) evidence.failure = await safeProviderFailure(response, { redact: t => t.replaceAll(this.#secret, '[REDACTED]') });
      const codes = { 401: 'unauthorized', 402: 'quota_exhausted', 403: 'forbidden', 404: 'free_model_unavailable', 429: 'rate_limited', 500: 'provider_failed', 502: 'provider_failed', 503: 'provider_overloaded', 529: 'provider_overloaded' };
      check(response.status === 200, response.status === 429 ? 429 : 503, codes[response.status] ?? 'provider_failed');
      check(response.headers.get('content-type')?.startsWith('text/event-stream') && response.body, 503, 'invalid_provider_stream');
      let finish = null, done = false, textBytes = 0, thoughtBytes = 0; const calls = new Map();
      for await (const data of sseData(response.body, { maxBytes: STREAM_MAX_BYTES })) {
        emittedOrActive = true; arm(this.timeouts.idleMs);
        if (data === '[DONE]') { done = true; break; }
        let chunk; try { chunk = JSON.parse(data); } catch { throw new ApiError(503, 'malformed_provider_json'); }
        if (chunk.error) throw new ApiError(emitted ? 503 : 429, Number(chunk.error?.code) === 429 || chunk.error?.status === 'RESOURCE_EXHAUSTED' ? 'rate_limited' : 'provider_stream_error', emitted ? { reconciliation: true } : undefined);
        if (typeof chunk.model === 'string') evidence.actual_model = chunk.model.slice(0, 200);
        const c = Array.isArray(chunk.choices) ? chunk.choices.find(x => (x.index ?? 0) === 0) : null; if (!c) continue;
        const delta = c.delta ?? {};
        // Thought summary: Gemini marks thought parts; OpenRouter/Groq may use `reasoning`.
        const thought = delta.extra_content?.google?.thought === true ? delta.content : (typeof delta.reasoning === 'string' ? delta.reasoning : typeof delta.reasoning_content === 'string' ? delta.reasoning_content : null);
        if (thought) { thoughtBytes += Buffer.byteLength(thought); if (this.thinkingVisible()) emitted = true; /* hidden thinking is not user-visible output: a later timeout stays 'before output' and can fail over */ if (thoughtBytes <= THOUGHT_MAX_BYTES) yield { type: 'thinking_delta', text: thought }; /* longer thinking still counts as activity; only the summary is capped */ }
        else if (delta.content) {
          check(typeof delta.content === 'string', 503, 'invalid_provider_chunk');
          // Agnes (verified live 2026-10-15) streams `reasoning_content` then `\n\n` before the answer; drop leading blank text.
          const text = textBytes === 0 && thoughtBytes > 0 ? delta.content.replace(/^\s+/, '') : delta.content;
          if (text) { textBytes += Buffer.byteLength(text); check(textBytes <= 64000, 503, 'output_too_large'); emitted = true; yield { type: 'text_delta', text }; }
        }
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
      if (timedOut) { evidence.timeout_phase = timedOut; throw new ApiError(503, emitted ? 'provider_timeout' : 'provider_timeout_before_output', emitted ? { reconciliation: true } : undefined); }
      if (e instanceof ApiError) throw e;
      throw new ApiError(503, emitted ? 'provider_interrupted' : 'provider_transport_failed', { reconciliation: true });
    } finally {
      clearTimeout(timer); clearTimeout(totalTimer); signal?.removeEventListener('abort', cancel); controller.abort();
      try { await response?.body?.cancel(); } catch {}
    }
  }
}

// One limiter per isolate so concurrent turns share the Gemini RPM budget and 429 cooldown.
let geminiGuardSingleton = null;
const sharedGeminiGuard = rpm => { if (!geminiGuardSingleton || geminiGuardSingleton.rpm !== rpm) geminiGuardSingleton = new GeminiRateGuard({ rpm }); return geminiGuardSingleton; };
/** Provider port compatible with OpenRouterProvider (identity/reality/assertReady/stream). */
export class FreeRouteChainProvider {
  #routes; #observations = [];
  constructor({ routes, secrets, fetchImpl, timeoutMs = 20000, beforeStream = null, emitThinking = true, autoFailover = true, maxInPlaceRetrySeconds = 12, geminiGuard = null }) {
    check(Array.isArray(routes) && routes.length > 0, 503, 'not_configured');
    const thinkingVisible = () => this.emitThinking && clientAcceptsReasoningSummary();
    this.#routes = routes.map(r => r.id === 'gemini' && r.protocol === 'interactions'
      ? new GeminiInteractionsRoute(r, secrets[r.id], { fetchImpl, timeouts: routeTimeouts(r, timeoutMs), guard: geminiGuard ?? sharedGeminiGuard(r.rpm), thinkingVisible })
      : new OpenAICompatibleRoute(r, secrets[r.id], { fetchImpl, timeoutMs, thinkingVisible }));
    this.beforeStream = beforeStream; this.emitThinking = emitThinking; this.autoFailover = autoFailover; this.maxInPlaceRetrySeconds = maxInPlaceRetrySeconds;
    this.identity = { provider: 'free-route-chain', routes: routes.map(r => ({ id: r.id, model: r.model, endpoint: r.endpoint })), free_only: false, keyed_routes_only: true, billing: routes.map(r => ({ id: r.id, billing: r.billing ?? 'free_tier' })), max_tokens: 2048, adapter_version: 1 };
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
    try { yield* this.#pass(input); }
    catch (e) {
      // R7 busy: one automatic in-place retry, only when nothing was emitted (same accepted turn, no resend)
      // and the provider's retry-after fits the Edge budget.
      const wait = e?.retryAfterSeconds;
      if (!(e instanceof ApiError) || e.code !== 'rate_limited' || e.emitted || !Number.isFinite(wait) || wait > this.maxInPlaceRetrySeconds) throw e;
      await new Promise((resolve, reject) => { const t = setTimeout(resolve, wait * 1000); input.signal?.addEventListener('abort', () => { clearTimeout(t); reject(input.signal.reason ?? new ApiError(503, 'provider_interrupted')); }, { once: true }); });
      yield* this.#pass(input);
    }
  }
  async *#pass(input) {
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
        if (emitted && e && typeof e === 'object') e.emitted = true;
        if (emitted || !(e instanceof ApiError) || !FAILOVER_CODES.has(e.code)) throw e;
        const ra = evidence.failure?.headers?.retry_after_seconds; if (Number.isFinite(ra)) e.retryAfterSeconds = Math.min(3600, Math.ceil(ra));
        if (!this.autoFailover) throw e;
        last = e; // busy before any output: try next free route
      }
    }
    throw last ?? new ApiError(503, 'provider_failed');
  }
}
