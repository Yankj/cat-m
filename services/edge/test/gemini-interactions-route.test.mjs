import test from 'node:test'; import assert from 'node:assert/strict';
import {beforeEach} from 'node:test';import {_routeHealthForTests as __health} from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
beforeEach(()=>__health.clear()); // w7: route breaker state is per isolate; isolate tests
import { FreeRouteChainProvider, readFreeRouteChain, withRoutePreference } from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
import { collectRound } from '../supabase/functions/_shared/core/src/openrouter-provider.mjs';
import { GeminiRateGuard, toSteps, toContent, _signatureCacheForTests } from '../supabase/functions/_shared/core/src/gemini-interactions-route.mjs';

const env = o => k => o[k];
const KEY = 'gem-test-key-not-real';
const sse = (frames, { delay = 0 } = {}) => new Response(new ReadableStream({ async start(c) { for (const f of frames) { if (delay) await new Promise(r => setTimeout(r, delay)); c.enqueue(new TextEncoder().encode(`event: x\ndata: ${typeof f === 'string' ? f : JSON.stringify(f)}\n\n`)); } c.close(); } }), { status: 200, headers: { 'content-type': 'text/event-stream' } });
const orOk = text => sse([{ choices: [{ index: 0, delta: { content: text } }] }, { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }, '[DONE]']);
const created = { event_type: 'interaction.created', interaction: { id: 'i1', model: 'gemini-3.5-flash-lite', status: 'in_progress' } };
const completed = status => ({ event_type: 'interaction.completed', interaction: { id: 'i1', status } });
const gText = (...parts) => sse([created, { event_type: 'step.start', index: 0, step: { type: 'model_output' } }, ...parts.map(t => ({ event_type: 'step.delta', index: 0, delta: { type: 'text', text: t } })), { event_type: 'step.stop', index: 0 }, completed('completed'), '[DONE]']);
const REMINDER = [{ type: 'function', function: { name: 'reminder_create', description: '创建提醒', parameters: { type: 'object', properties: { title: { type: 'string' }, due_at: { type: 'string' } }, required: ['title'] } } }];
const chain = (o, extra = {}) => { const c = readFreeRouteChain(env({ CATPAW_PRIVATE_MODEL_KEY: 'o', CATPAW_GEMINI_API_KEY: KEY, ...o })); return new FreeRouteChainProvider({ ...c, ...extra }); };
const collect = async (p, input = {}) => { const out = []; for await (const e of p.stream({ messages: [{ role: 'user', content: '你好' }], system_prompt: '你是猫爪', tools: [], ...input })) if (e.type !== 'route_info') out.push(e); return out; };

test('switch: off / primary / fallback, Interactions endpoint by default, invalid values rejected', () => {
  assert.equal(readFreeRouteChain(env({ CATPAW_PRIVATE_MODEL_KEY: 'o', CATPAW_GEMINI_API_KEY: KEY, CATPAW_GEMINI_ROUTE: 'off' })), null);
  assert.deepEqual(readFreeRouteChain(env({ CATPAW_PRIVATE_MODEL_KEY: 'o', CATPAW_GEMINI_API_KEY: KEY })).routes.map(r => r.id), ['gemini', 'openrouter']);
  const fb = readFreeRouteChain(env({ CATPAW_PRIVATE_MODEL_KEY: 'o', CATPAW_GEMINI_API_KEY: KEY, CATPAW_GEMINI_ROUTE: 'fallback' }));
  assert.deepEqual(fb.routes.map(r => r.id), ['openrouter', 'gemini']);
  assert.equal(fb.routes[1].endpoint, 'https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse'); assert.equal(fb.routes[1].protocol, 'interactions');
  const pr = readFreeRouteChain(env({ CATPAW_PRIVATE_MODEL_KEY: 'o', CATPAW_GEMINI_API_KEY: KEY, CATPAW_AGNES_API_KEY: 'a', CATPAW_GEMINI_ROUTE: 'primary' }));
  assert.deepEqual(pr.routes.map(r => r.id), ['gemini', 'openrouter', 'agnes']);
  assert.match(readFreeRouteChain(env({ CATPAW_GEMINI_API_KEY: KEY, CATPAW_GEMINI_PROTOCOL: 'openai_compat' })).routes[0].endpoint, /openai\/chat\/completions$/);
  assert.throws(() => readFreeRouteChain(env({ CATPAW_GEMINI_API_KEY: KEY, CATPAW_GEMINI_ROUTE: 'always' })), /gemini_route_mode_invalid/);
  assert.throws(() => readFreeRouteChain(env({ CATPAW_GEMINI_API_KEY: KEY, CATPAW_GEMINI_RPM: '0' })), /gemini_rpm_invalid/);
  assert.ok(!JSON.stringify(fb.routes).includes(KEY), 'route description never carries the key');
});

test('request mapping: stateless store=false, system_instruction, tools, inline image, tool history with names', async () => {
  let req; const p = chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl: async (url, init) => { req = { url, init }; return gText('好'); } });
  const img = 'data:image/png;base64,iVBORw0KGgo=';
  const messages = [{ role: 'user', content: [{ type: 'text', text: '这是什么' }, { type: 'image_url', image_url: { url: img } }] },
    { role: 'assistant', content: '', tool_calls: [{ id: 'c1', type: 'function', function: { name: 'reminder_create', arguments: '{"title":"喝水"}' } }] },
    { role: 'tool', tool_call_id: 'c1', content: '{"ok":true}' }];
  await collect(p, { messages, tools: REMINDER });
  const body = JSON.parse(req.init.body);
  assert.equal(req.init.headers['x-goog-api-key'], KEY); assert.ok(!req.url.includes(KEY) && !req.init.body.includes(KEY));
  assert.equal(body.store, false); assert.equal(body.stream, true); assert.equal(body.system_instruction, '你是猫爪'); assert.equal(body.generation_config.tool_choice, 'auto');
  assert.deepEqual(body.tools[0], { type: 'function', name: 'reminder_create', description: '创建提醒', parameters: REMINDER[0].function.parameters });
  assert.deepEqual(body.input[0].content[1], { type: 'image', mime_type: 'image/png', data: 'iVBORw0KGgo=' });
  // R1-P1: placeholder signature is OFF by default → v52 request shape (no thought step).
  assert.deepEqual(body.input.slice(1).map(s => [s.type, s.name ?? null]), [['function_call', 'reminder_create'], ['function_result', 'reminder_create']]);
  assert.deepEqual(body.input[1].arguments, { title: '喝水' });
  // CATPAW_GEMINI_PLACEHOLDER_SIGNATURE=true: c1 is a current-turn call with no cached signature → placeholder thought step first.
  const p2 = chain({ CATPAW_GEMINI_ROUTE: 'primary', CATPAW_GEMINI_PLACEHOLDER_SIGNATURE: 'true' }, { fetchImpl: async (url, init) => { req = { url, init }; return gText('好'); } });
  await collect(p2, { messages, tools: REMINDER });
  const body2 = JSON.parse(req.init.body);
  assert.deepEqual(body2.input.slice(1).map(s => [s.type, s.name ?? null]), [['thought', null], ['function_call', 'reminder_create'], ['function_result', 'reminder_create']]);
  assert.equal(body2.input[1].signature, 'skip_thought_signature_validator');
  assert.throws(() => toContent([{ type: 'image_url', image_url: { url: 'https://example.com/a.png' } }]), /image_input_unsupported/);
});

test('streaming: text deltas, reminder_create function call via arguments_delta, thought signature cached and replayed', async () => {
  _signatureCacheForTests.clear();
  const frames = [created,
    { event_type: 'step.start', index: 0, step: { type: 'thought' } }, { event_type: 'step.delta', index: 0, delta: { type: 'thought_signature', signature: 'SIG123' } }, { event_type: 'step.stop', index: 0 },
    { event_type: 'step.start', index: 1, step: { type: 'model_output' } }, { event_type: 'step.delta', index: 1, delta: { type: 'text', text: '好的，' } }, { event_type: 'step.stop', index: 1 },
    { event_type: 'step.start', index: 2, step: { type: 'function_call', id: 'fc9', name: 'reminder_create', arguments: {} } },
    { event_type: 'step.delta', index: 2, delta: { type: 'arguments_delta', arguments: '{"title":"开会",' } }, { event_type: 'step.delta', index: 2, delta: { type: 'arguments_delta', arguments: '"due_at":"2026-10-16T15:00:00+08:00"}' } },
    { event_type: 'step.stop', index: 2 }, completed('requires_action'), '[DONE]'];
  const p = chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl: async () => sse(frames) });
  const out = await collect(p, { tools: REMINDER });
  assert.deepEqual(out.map(e => e.type), ['text_delta', 'tool_call', 'done']);
  assert.deepEqual(out[1], { type: 'tool_call', id: 'fc9', name: 'reminder_create', arguments: { title: '开会', due_at: '2026-10-16T15:00:00+08:00' } });
  assert.equal(out[2].finish_reason, 'tool_calls');
  const steps = toSteps([{ role: 'assistant', content: '', tool_calls: [{ id: 'fc9', function: { name: 'reminder_create', arguments: '{}' } }] }]);
  assert.deepEqual(steps.map(s => s.type), ['thought', 'function_call']); assert.equal(steps[0].signature, 'SIG123');
});

test('429 → backoff cooldown and immediate fallback to OpenRouter; next turn skips Gemini without calling Google', async () => {
  const urls = []; const guard = new GeminiRateGuard({ rpm: 10 });
  const fetchImpl = async url => { urls.push(url); return url.includes('googleapis') ? new Response('{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"retryDelay":"20s"}]}}', { status: 429 }) : orOk('来自 OpenRouter'); };
  const p = chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl, geminiGuard: guard });
  assert.equal((await collect(p))[0].text, '来自 OpenRouter');
  assert.ok(guard.coolUntil - Date.now() > 15000);
  await collect(p); assert.equal(urls.filter(u => u.includes('googleapis')).length, 1, 'cooling down: Google not called again');
  assert.equal(p.observations[0].route, 'gemini'); assert.ok(['rate_limited', 'quota_exhausted'].includes(p.observations[0].error));
  assert.deepEqual(p.observations.slice(2).map(o => o.route), ['openrouter'], 'w7 breaker: next auto turn starts on the healthy route (no Gemini hop)');
});

test('daily quota → quota_exhausted with 1 h cooldown; per-minute limiter falls back without a request', async () => {
  let t = 0; const g = new GeminiRateGuard({ rpm: 1, now: () => t });
  g.admit(); assert.throws(() => g.admit(), e => e.code === 'rate_limited' && e.localGuard === 'rpm'); t = 61000; g.admit();
  const guard = new GeminiRateGuard({ rpm: 5 }); const fetchImpl = async url => url.includes('googleapis') ? new Response('{"error":{"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded for metric generate_requests_per_model_per_day"}}', { status: 429 }) : orOk('ok');
  const p = chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl, geminiGuard: guard });
  await collect(p); assert.equal(p.observations[0].error, 'quota_exhausted'); assert.ok(guard.coolUntil - Date.now() > 3500000);
});

test('400 on tool history (missing thought signatures) fails over before output; no retry storm', async () => {
  _signatureCacheForTests.clear(); const urls = [];
  const p = chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl: async url => { urls.push(url); return url.includes('googleapis') ? new Response('{"error":{"code":400,"message":"function call is missing a thought_signature"}}', { status: 400 }) : orOk('续写'); } });
  const out = await collect(p, { tools: REMINDER, messages: [{ role: 'user', content: '提醒我' }, { role: 'assistant', content: '', tool_calls: [{ id: 'x1', function: { name: 'reminder_create', arguments: '{}' } }] }, { role: 'tool', tool_call_id: 'x1', content: '{"ok":true}' }] });
  assert.equal(out[0].text, '续写'); assert.equal(urls.length, 2);
});

test('provider_timeout fix: hidden thinking then a stall is "before output" and fails over (Agnes and Gemini)', async () => {
  // Upstream sends one hidden reasoning chunk and then stalls; aborting the fetch errors the body like a real fetch does.
  const stall = signal => new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { reasoning_content: '想一想' } }] })}\n\n`)); signal.addEventListener('abort', () => c.error(new DOMException('aborted', 'AbortError')), { once: true }); } }), { status: 200, headers: { 'content-type': 'text/event-stream' } });
  const c = readFreeRouteChain(env({ CATPAW_AGNES_API_KEY: 'a', CATPAW_AGNES_IDLE_TIMEOUT_MS: '1000', CATPAW_AGNES_FIRST_EVENT_TIMEOUT_MS: '1000', CATPAW_PRIVATE_MODEL_KEY: 'o', CATPAW_MODEL_ROUTE_ORDER: 'agnes,openrouter' }));
  const p = new FreeRouteChainProvider({ ...c, fetchImpl: async (url, init) => url.includes('agnes') ? stall(init.signal) : orOk('回落成功') });
  const out = await collect(p); // client did not send X-Catpaw-Reasoning-Summary → thinking is hidden
  assert.equal(out[0].text, '回落成功'); assert.equal(p.observations[0].error, 'provider_timeout_before_output');
  // With the reasoning header the thinking was shown, so the same stall must stay a reconciliation-required timeout.
  const p2 = new FreeRouteChainProvider({ ...c, fetchImpl: async (url, init) => stall(init.signal), autoFailover: false });
  await assert.rejects(withRoutePreference(null, async () => { for await (const _ of p2.stream({ messages: [], system_prompt: 's', tools: [] })); }, { reasoningSummary: true }), e => e.code === 'provider_timeout');
});

test('Gemini stream error event 429 before output → rate_limited failover', async () => {
  const p = chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { geminiGuard: new GeminiRateGuard({ rpm: 10 }), fetchImpl: async url => url.includes('googleapis') ? sse([created, { event_type: 'error', error: { code: 429, status: 'RESOURCE_EXHAUSTED' } }]) : orOk('兜底') });
  assert.equal((await collect(p))[0].text, '兜底');
});

test('chat-context-1522 B1: 5th+ parallel function calls are surfaced as tool_call_overflow (never silently dropped, prod 6497bf72)', async () => {
  const TASK = [{ type: 'function', function: { name: 'create_task', description: '待办', parameters: { type: 'object', properties: { title: { type: 'string' } }, required: ['title'] } } }];
  const frames = [created];
  for (let i = 0; i < 6; i++) frames.push({ event_type: 'step.start', index: i, step: { type: 'function_call', id: 'fc' + i, name: 'create_task' } }, { event_type: 'step.delta', index: i, delta: { type: 'arguments_delta', arguments: `{"title":"t${i}"}` } }, { event_type: 'step.stop', index: i });
  frames.push(completed('requires_action'), '[DONE]');
  const p = chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl: async () => sse(frames) });
  const out = await collect(p, { tools: TASK });
  assert.deepEqual(out.filter(e => e.type === 'tool_call').map(c => c.id), ['fc0', 'fc1', 'fc2', 'fc3']);
  const extra = out.filter(e => e.type === 'tool_call_overflow');
  assert.deepEqual(extra.map(c => c.id), ['fc4', 'fc5']); assert.deepEqual(extra[1].arguments, { title: 't5' }, 'overflow arguments are kept for the model-facing result');
  assert.equal(out.at(-1).type, 'done'); assert.equal(out.at(-1).finish_reason, 'tool_calls');
  // Only the chat loop accepts overflow; every other collector keeps the old hard limit.
  const round = await collectRound(chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl: async () => sse(frames) }), { messages: [{ role: 'user', content: 'x' }], system_prompt: 's', tools: TASK }, async () => {}, { acceptOverflow: true });
  assert.deepEqual([round.calls.length, round.overflow.map(c => c.id)], [4, ['fc4', 'fc5']]);
  await assert.rejects(collectRound(chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl: async () => sse(frames) }), { messages: [{ role: 'user', content: 'x' }], system_prompt: 's', tools: TASK }), e => e.code === 'invalid_tool_index');
  // A runaway step beyond 16 calls still fails closed.
  const many = [created]; for (let i = 0; i < 17; i++) many.push({ event_type: 'step.start', index: i, step: { type: 'function_call', id: 'm' + i, name: 'create_task' } });
  many.push(completed('requires_action'), '[DONE]');
  await assert.rejects(collect(chain({ CATPAW_GEMINI_ROUTE: 'primary' }, { fetchImpl: async () => sse(many), autoFailover: false }), { tools: TASK }), e => e.code === 'invalid_tool_index');
});
