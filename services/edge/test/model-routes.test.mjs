import test from 'node:test'; import assert from 'node:assert/strict';
import { FreeRouteChainProvider, readFreeRouteChain, withRoutePreference, assertRouteSelection, modelRoutesList, _routeHealthForTests, freeRouteStatus } from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
import { readConfig } from '../supabase/functions/_shared/config.mjs';
const env = o => k => o[k];
const sse = frames => new Response(new ReadableStream({ start(c) { for (const f of frames) c.enqueue(new TextEncoder().encode(`data: ${f}\n\n`)); c.close(); } }), { status: 200, headers: { 'content-type': 'text/event-stream' } });
const ok = t => sse([JSON.stringify({ choices: [{ index: 0, delta: { content: t } }] }), JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }), '[DONE]']);
const busy = () => new Response('{"error":{"message":"rate limit"}}', { status: 429 });
const E = { CATPAW_PRIVATE_MODEL_KEY: 'or-secret', CATPAW_FREELLMAPI_API_KEY: 'fl-secret', CATPAW_FREELLMAPI_BASE_URL: 'https://llm.example.internal:3001/v1/', CATPAW_FREELLMAPI_MODELS: 'deepseek-v4.1-flash-free,glm-5.3-flash-free' };
const all = async (p, opts) => { const out = []; const run = async () => { for await (const e of p.stream({ messages: [], system_prompt: 's', tools: [] })) out.push(e); }; await withRoutePreference(opts?.route ?? null, run, { model: opts?.model ?? null }); return out; };

test('freellmapi: enabled only with key + https base URL; endpoint normalised; models allow-list', () => {
  const c = readFreeRouteChain(env(E));
  const f = c.routes.find(r => r.id === 'freellmapi');
  assert.equal(f.endpoint, 'https://llm.example.internal:3001/v1/chat/completions');
  assert.equal(f.model, 'auto'); assert.deepEqual(f.models, ['auto', 'deepseek-v4.1-flash-free', 'glm-5.3-flash-free']);
  assert.deepEqual(c.routes.map(r => r.id), ['openrouter', 'freellmapi']);
  assert.throws(() => readFreeRouteChain(env({ ...E, CATPAW_FREELLMAPI_BASE_URL: 'http://plain.example' })), e => e.code === 'freellmapi_base_url_invalid');
  assert.equal(readFreeRouteChain(env({ CATPAW_PRIVATE_MODEL_KEY: 'o', CATPAW_FREELLMAPI_BASE_URL: 'https://x' })), null);
});
test('consent: freellmapi changes routeHash, discloses aggregator, hides base URL', () => {
  const c = readConfig(env(E)); const s = JSON.stringify(c.route);
  assert.notEqual(c.routeHash, readConfig(env({ CATPAW_PRIVATE_MODEL_KEY: 'o' })).routeHash);
  assert.match(c.route.aggregator_disclosure, /FreeLLMAPI/); assert.ok(c.route.data_fields.some(x => /freellmapi/.test(x)));
  assert.doesNotMatch(s, /example\.internal/); assert.doesNotMatch(s, /secret/);
});
test('route list: no secrets or internal URLs; status from health', () => {
  const c = readFreeRouteChain(env(E)); _routeHealthForTests.clear();
  let body = modelRoutesList(c); const s = JSON.stringify(body);
  assert.equal(body.contract, 'catpaw.model-routes.v1'); assert.doesNotMatch(s, /secret|example\.internal|endpoint/);
  const f = body.routes.find(r => r.id === 'freellmapi');
  assert.equal(f.display_name, 'Self-hosted FreeLLMAPI'); assert.equal(f.status, 'online'); assert.equal(f.free, true); assert.equal(f.last_error, null);
  assert.deepEqual(f.models[0], { id: 'auto', default: true });
  assert.ok(JSON.stringify(freeRouteStatus(c)).indexOf('example.internal') < 0);
});
test('selection: explicit error codes', () => {
  const c = readFreeRouteChain(env(E));
  assert.doesNotThrow(() => assertRouteSelection(c, { rawRoute: 'auto' }));
  assert.doesNotThrow(() => assertRouteSelection(c, { rawRoute: 'freellmapi', model: 'glm-5.3-flash-free' }));
  assert.throws(() => assertRouteSelection(c, { rawRoute: 'nope' }), e => e.code === 'model_route_unknown');
  assert.throws(() => assertRouteSelection(c, { rawRoute: 'gemini' }), e => e.code === 'model_route_unavailable');
  assert.throws(() => assertRouteSelection(c, { rawRoute: 'freellmapi', model: 'gpt-6-sol' }), e => e.code === 'model_not_allowed');
  assert.throws(() => assertRouteSelection(c, { rawRoute: 'auto', model: 'auto' }), e => e.code === 'model_not_allowed');
});
test('stream: failover reported in route_info with switches; health degraded', async () => {
  _routeHealthForTests.clear(); const c = readFreeRouteChain(env(E)); const calls = [];
  const p = new FreeRouteChainProvider({ ...c, fetchImpl: async (url, init) => { calls.push({ url, body: JSON.parse(init.body), auth: init.headers.Authorization }); return calls.length === 1 ? busy() : ok('hi'); } });
  const out = await all(p);
  const ri = out.find(e => e.type === 'route_info');
  assert.deepEqual({ route: ri.route, failover: ri.failover, from: ri.from, requested_route: ri.requested_route }, { route: 'freellmapi', failover: true, from: ['openrouter'], requested_route: 'auto' });
  assert.deepEqual(ri.switches, [{ from: 'openrouter', to: 'freellmapi', code: 'rate_limited' }]);
  assert.equal(out.indexOf(ri) < out.findIndex(e => e.type === 'text_delta'), true);
  assert.equal(calls[1].auth, 'Bearer fl-secret'); assert.equal(calls[1].body.model, 'auto');
  const list = modelRoutesList(c); assert.equal(list.routes.find(r => r.id === 'openrouter').status, 'degraded');
  assert.equal(list.routes.find(r => r.id === 'openrouter').last_error.code, 'rate_limited');
});
test('stream: X-Catpaw-Route + X-Catpaw-Model pick route and model', async () => {
  const c = readFreeRouteChain(env(E)); const calls = [];
  const p = new FreeRouteChainProvider({ ...c, fetchImpl: async (url, init) => { calls.push({ url, body: JSON.parse(init.body) }); return ok('x'); } });
  const out = await all(p, { route: 'freellmapi', model: 'glm-5.3-flash-free' });
  assert.match(calls[0].url, /example\.internal/); assert.equal(calls[0].body.model, 'glm-5.3-flash-free');
  const ri = out.find(e => e.type === 'route_info'); assert.equal(ri.model, 'glm-5.3-flash-free'); assert.equal(ri.requested_route, 'freellmapi'); assert.equal(ri.failover, false);
});
