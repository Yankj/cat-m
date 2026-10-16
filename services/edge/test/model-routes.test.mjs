import test from 'node:test'; import assert from 'node:assert/strict';
import { FreeRouteChainProvider, readFreeRouteChain, withRoutePreference, assertRouteSelection, modelRoutesList, _routeHealthForTests, freeRouteStatus } from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
import { readConfig } from '../supabase/functions/_shared/config.mjs';
const env = o => k => o[k];
const sse = frames => new Response(new ReadableStream({ start(c) { for (const f of frames) c.enqueue(new TextEncoder().encode(`data: ${f}\n\n`)); c.close(); } }), { status: 200, headers: { 'content-type': 'text/event-stream' } });
const ok = t => sse([JSON.stringify({ choices: [{ index: 0, delta: { content: t } }] }), JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }), '[DONE]']);
const busy = () => new Response('{"error":{"message":"rate limit"}}', { status: 429 });
const E = { CATPAW_PRIVATE_MODEL_KEY: 'or-secret', CATPAW_OPENCODE_API_KEY: 'oc-secret' };
const all = async (p, opts) => { const out = []; const run = async () => { for await (const e of p.stream({ messages: [], system_prompt: 's', tools: [] })) out.push(e); }; await withRoutePreference(opts?.route ?? null, run, { model: opts?.model ?? null }); return out; };

test('opencode: enabled only with key; official endpoint; zero-retention default allow-list; paid models denied', () => {
  const c = readFreeRouteChain(env(E));
  const f = c.routes.find(r => r.id === 'opencode');
  assert.equal(f.endpoint, 'https://opencode.ai/inference/openai/v1/chat/completions');
  assert.equal(f.model, 'deepseek-v4.1-flash-free'); assert.deepEqual(f.models, ['deepseek-v4.1-flash-free', 'glm-5.3-flash-free', 'longcat-2.5-preview-free', 'space-bunny-free']);
  assert.deepEqual(c.routes.map(r => r.id), ['openrouter', 'opencode']);
  assert.equal(readFreeRouteChain(env({ ...E, CATPAW_OPENCODE_BASE_URL: 'https://oc.example.internal/v1/' })).routes[1].endpoint, 'https://oc.example.internal/v1/chat/completions');
  assert.throws(() => readFreeRouteChain(env({ ...E, CATPAW_OPENCODE_BASE_URL: 'http://plain.example' })), e => e.code === 'opencode_base_url_invalid');
  assert.deepEqual(readFreeRouteChain(env({ ...E, CATPAW_OPENCODE_MODEL: 'glm-5.3-flash-free', CATPAW_OPENCODE_MODELS: 'glm-5.3-flash-free' })).routes[1].models, ['glm-5.3-flash-free']);
  assert.throws(() => readFreeRouteChain(env({ ...E, CATPAW_OPENCODE_MODEL: 'gpt-6-sol' })), e => e.code === 'paid_or_router_model_denied');
  assert.throws(() => readFreeRouteChain(env({ ...E, CATPAW_OPENCODE_MODELS: 'deepseek-v4-pro' })), e => e.code === 'paid_or_router_model_denied');
  assert.equal(readFreeRouteChain(env({ CATPAW_PRIVATE_MODEL_KEY: 'o', CATPAW_OPENCODE_BASE_URL: 'https://x' })), null);
  assert.deepEqual(readFreeRouteChain(env({ ...E, CATPAW_GEMINI_API_KEY: 'g', CATPAW_GROQ_API_KEY: 'q', CATPAW_AGNES_API_KEY: 'a' })).routes.map(r => r.id), ['openrouter', 'gemini', 'groq', 'opencode', 'agnes']);
});
test('consent: opencode changes routeHash and discloses OpenCode Zen with policy link', () => {
  const c = readConfig(env(E)); const s = JSON.stringify(c.route);
  assert.notEqual(c.routeHash, readConfig(env({ CATPAW_PRIVATE_MODEL_KEY: 'o' })).routeHash);
  assert.match(c.route.opencode_disclosure, /OpenCode Zen/); assert.match(c.route.opencode_disclosure, /https:\/\/opencode\.ai\/legal\/privacy-policy/);
  assert.ok(c.route.data_fields.some(x => /opencode/.test(x))); assert.equal(c.route.aggregator_disclosure, undefined);
  assert.doesNotMatch(s, /secret/);
});
test('route list: no secrets or internal URLs; status from health', () => {
  const c = readFreeRouteChain(env(E)); _routeHealthForTests.clear();
  let body = modelRoutesList(c); const s = JSON.stringify(body);
  assert.equal(body.contract, 'catpaw.model-routes.v1'); assert.doesNotMatch(s, /secret|endpoint/);
  const f = body.routes.find(r => r.id === 'opencode');
  assert.equal(f.display_name, 'OpenCode Zen (free)'); assert.equal(f.status, 'online'); assert.equal(f.free, true); assert.equal(f.last_error, null);
  assert.equal(f.data_note, 'zero_retention'); assert.equal(f.policy_url, 'https://opencode.ai/legal/privacy-policy');
  assert.deepEqual(f.models[0], { id: 'deepseek-v4.1-flash-free', default: true });
  assert.ok(JSON.stringify(freeRouteStatus(c)).indexOf('oc-secret') < 0);
});
test('selection: explicit error codes', () => {
  const c = readFreeRouteChain(env(E));
  assert.doesNotThrow(() => assertRouteSelection(c, { rawRoute: 'auto' }));
  assert.doesNotThrow(() => assertRouteSelection(c, { rawRoute: 'opencode', model: 'glm-5.3-flash-free' }));
  assert.throws(() => assertRouteSelection(c, { rawRoute: 'nope' }), e => e.code === 'model_route_unknown');
  assert.throws(() => assertRouteSelection(c, { rawRoute: 'gemini' }), e => e.code === 'model_route_unavailable');
  assert.throws(() => assertRouteSelection(c, { rawRoute: 'opencode', model: 'gpt-6-sol' }), e => e.code === 'model_not_allowed');
  assert.throws(() => assertRouteSelection(c, { rawRoute: 'auto', model: 'auto' }), e => e.code === 'model_not_allowed');
});
test('stream: failover reported in route_info with switches; health degraded', async () => {
  _routeHealthForTests.clear(); const c = readFreeRouteChain(env(E)); const calls = [];
  const p = new FreeRouteChainProvider({ ...c, fetchImpl: async (url, init) => { calls.push({ url, body: JSON.parse(init.body), auth: init.headers.Authorization }); return calls.length === 1 ? busy() : ok('hi'); } });
  const out = await all(p);
  const ri = out.find(e => e.type === 'route_info');
  assert.deepEqual({ route: ri.route, failover: ri.failover, from: ri.from, requested_route: ri.requested_route }, { route: 'opencode', failover: true, from: ['openrouter'], requested_route: 'auto' });
  assert.deepEqual(ri.switches, [{ from: 'openrouter', to: 'opencode', code: 'rate_limited' }]);
  assert.equal(out.indexOf(ri) < out.findIndex(e => e.type === 'text_delta'), true);
  assert.equal(calls[1].auth, 'Bearer oc-secret'); assert.equal(calls[1].body.model, 'deepseek-v4.1-flash-free');
  const list = modelRoutesList(c); assert.equal(list.routes.find(r => r.id === 'openrouter').status, 'degraded');
  assert.equal(list.routes.find(r => r.id === 'openrouter').last_error.code, 'rate_limited');
});
test('stream: X-Catpaw-Route + X-Catpaw-Model pick route and model', async () => {
  const c = readFreeRouteChain(env(E)); const calls = [];
  const p = new FreeRouteChainProvider({ ...c, fetchImpl: async (url, init) => { calls.push({ url, body: JSON.parse(init.body) }); return ok('x'); } });
  const out = await all(p, { route: 'opencode', model: 'glm-5.3-flash-free' });
  assert.equal(calls[0].url, 'https://opencode.ai/inference/openai/v1/chat/completions'); assert.equal(calls[0].body.model, 'glm-5.3-flash-free');
  const ri = out.find(e => e.type === 'route_info'); assert.equal(ri.model, 'glm-5.3-flash-free'); assert.equal(ri.requested_route, 'opencode'); assert.equal(ri.failover, false);
});
