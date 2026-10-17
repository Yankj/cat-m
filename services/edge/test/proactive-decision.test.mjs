import test from 'node:test'; import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService, ruleDecide } from '../supabase/functions/_shared/proactive/decision.mjs';
import { createDecisionModel } from '../supabase/functions/_shared/proactive/decision-model.mjs';
import { createInMemoryRecall } from '../supabase/functions/_shared/proactive/memory-recall.mjs';

const FX = JSON.parse(readFileSync(new URL('./fixtures/proactive/meeting-travel-signals.json', import.meta.url)));
const sc = n => structuredClone(FX.scenarios.find(s => s.name === n).request);
const U = crypto.randomUUID(), U2 = crypto.randomUUID(), BASE = '/catpaw/proactive/v1';
function setup({ model = null, t = '2026-10-15T02:00:00Z', config = {} } = {}) {
  const clock = { t: Date.parse(t) }, store = createMemoryStore(), memory = createInMemoryRecall({ [U]: FX.memories });
  const decision = createDecisionService({ store, model, memory, now: () => clock.t, config });
  const svc = createProactiveService({ store, decision, schedulerSecret: 's', now: () => clock.t, verifyUser: async h => ({ sub: h === 'Bearer u2' ? U2 : U }) });
  const call = async (method, path, body, auth = 'Bearer u1') => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: auth }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { clock, store, call, memory };
}
const fakeLLM = (out, calls = []) => ({ lastRoute: () => 'fake', decide: async i => { calls.push(i); if (out instanceof Error) throw out; return typeof out === 'function' ? out(i) : out; } });

test('rules: fixture scenarios produce the expected baseline decision', () => {
  for (const s of FX.scenarios) assert.equal(ruleDecide(s.request.signals, s.request.context).decision, s.expect_rules, s.name);
});

test('evaluate with LLM: structured output validated, memories passed + cited, suggestion shape for client', async () => {
  const calls = [];
  const { call } = setup({ model: fakeLLM(i => ({ decision: 'interrupt', title: '该出发了', reason: '会议 35 分钟后开始，打车要 50 分钟', confidence: 0.9, trigger: 'meeting_upcoming', suggested_actions: ['notify_attendees', { kind: 'create_reminder' }, 'rm -rf'], used_memory_ids: [i.memories[0].id, 'forged'] }), calls) });
  const r = await call('POST', BASE + '/evaluate', sc('meeting_soon_far'));
  assert.equal(r.status, 200); assert.equal(r.body.decision, 'interrupt'); assert.equal(r.body.source, 'llm:fake');
  assert.deepEqual(r.body.suggested_actions, ['notify_attendees', 'create_reminder', 'snooze', 'dismiss']);
  assert.ok(calls[0].memories.some(m => m.id === 'mem-taxi')); assert.deepEqual(r.body.used_memories.map(m => m.id), ['mem-taxi']);
  const s = r.body.suggestion; assert.equal(s.id, r.body.event_id); assert.equal(s.title, '该出发了'); assert.equal(s.status, 'pending');
  assert.deepEqual(s.memories, [{ id: 'mem-taxi', content: '用户去静安一般打车，不坐地铁' }]);
  assert.equal(s.signals[0].kind, 'calendar'); assert.match(s.signals[0].text, /客户方案评审/);
  const ev = (await call('GET', BASE + '/events/' + s.id)).body.event; assert.equal(ev.explanation.why, s.reason); assert.equal(ev.explanation.undo.body_template.event_id, s.id);
  assert.equal((await call('GET', BASE + '/events/' + s.id, null, 'Bearer u2')).status, 404);
});

test('LLM invalid / unavailable → deterministic rules fallback; low confidence degrades', async () => {
  let { call } = setup({ model: fakeLLM({ decision: 'yell', reason: 'x', confidence: 2 }) });
  let r = await call('POST', BASE + '/evaluate', sc('flight_delayed_affects_meeting')); assert.equal(r.body.source, 'rules'); assert.equal(r.body.decision, 'interrupt');
  ({ call } = setup({ model: fakeLLM(new Error('openrouter_http_429')) }));
  r = await call('POST', BASE + '/evaluate', sc('meeting_conflict')); assert.equal(r.body.source, 'rules'); assert.equal(r.body.decision, 'card');
  ({ call } = setup({ model: fakeLLM({ decision: 'interrupt', reason: '可能有点事', confidence: 0.5 }) }));
  r = await call('POST', BASE + '/evaluate', sc('meeting_soon_far')); assert.equal(r.body.decision, 'notify'); assert.match(r.body.trace.join(), /threshold/);
  ({ call } = setup({ model: fakeLLM({ decision: 'interrupt', reason: '不确定', confidence: 0.3 }) }));
  r = await call('POST', BASE + '/evaluate', sc('meeting_soon_far')); assert.equal(r.body.decision, 'card');
});

test('Codex P0-3: very low confidence is silent, not a card (better say nothing than say it wrong)', async () => {
  const { call } = setup({ model: fakeLLM({ decision: 'interrupt', reason: '几乎不确定', confidence: 0.01 }) });
  const r = await call('POST', BASE + '/evaluate', sc('meeting_soon_far'));
  assert.equal(r.body.decision, 'silent'); assert.match(r.body.trace.join(), /silent/);
  assert.equal(r.body.suggestion.status, 'dismissed');
});

test('dedupe by signal_hash within window; quiet hours and daily cap downgrade to card', async () => {
  const { call, clock } = setup({ config: { dailyCap: 1 } });
  assert.equal((await call('POST', BASE + '/evaluate', sc('meeting_soon_far'))).body.decision, 'interrupt');
  const d = await call('POST', BASE + '/evaluate', sc('meeting_soon_far')); assert.equal(d.body.decision, 'silent'); assert.equal(d.body.source, 'dedupe');
  assert.equal((await call('POST', BASE + '/evaluate', sc('flight_delayed_affects_meeting'))).body.decision, 'card'); // cap 1 used
  clock.t += 3600_000; assert.notEqual((await call('POST', BASE + '/evaluate', sc('meeting_soon_far'))).body.source, 'dedupe'); // window passed
  const q = setup({ t: '2026-10-15T15:30:00Z' }); // 23:30 CST
  assert.equal((await q.call('POST', BASE + '/evaluate', sc('flight_delayed_affects_meeting'))).body.decision, 'card');
});

test('suggestions API: list, action idempotent by operation_id, snooze/dismiss, undo restores', async () => {
  const { call } = setup();
  const id = (await call('POST', BASE + '/evaluate', sc('meeting_soon_far'))).body.event_id;
  await call('POST', BASE + '/evaluate', sc('nothing_to_do')); // silent → not listed
  const list = (await call('GET', BASE + '/suggestions')).body.suggestions; assert.equal(list.length, 1); assert.equal(list[0].id, id);
  assert.equal((await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'explode' })).status, 422);
  const op = crypto.randomUUID();
  const a1 = (await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'notify_attendees', operation_id: op })).body.suggestion;
  const a2 = (await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'notify_attendees', operation_id: op })).body.suggestion;
  // P0-5: per-action state — one effect done leaves the other open (create_reminder still offered).
  assert.equal(a1.status, 'pending'); assert.equal(a2.taken.length, 1); assert.deepEqual(a1.action_states, { notify_attendees: 'done' });
  assert.equal((await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'create_reminder' })).body.suggestion.status, 'done');
  assert.equal((await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze' })).body.suggestion.status, 'snoozed');
  let u = (await call('POST', `${BASE}/suggestions/${id}/undo`, {})).body.suggestion; assert.equal(u.status, 'done'); assert.equal(u.taken.length, 2);
  u = (await call('POST', `${BASE}/suggestions/${id}/undo`, {})).body.suggestion; assert.equal(u.status, 'pending'); assert.equal(u.taken.length, 1);
  assert.equal((await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'dismiss' }, 'Bearer u2')).status, 404);
  assert.equal((await call('GET', BASE + '/suggestions?status=pending')).body.suggestions.length, 1);
});

test('feedback: idempotent, intrusive (+legacy disturbing) lowers weight and raises threshold, affects next evaluate', async () => {
  const { call, memory } = setup({ model: fakeLLM({ decision: 'interrupt', reason: '会议冲突需要处理', confidence: 0.7, trigger: 'meeting_conflict' }) });
  const id = (await call('POST', BASE + '/evaluate', sc('meeting_conflict'))).body.event_id;
  const f1 = await call('POST', `${BASE}/suggestions/${id}/feedback`, { value: 'intrusive' }); assert.equal(f1.body.applied, true);
  assert.equal(f1.body.weights.meeting_conflict.weight, 0.7); assert.equal(f1.body.weights.meeting_conflict.threshold_bump, 0.1);
  assert.equal((await call('POST', `${BASE}/suggestions/${id}/feedback`, { value: 'helpful' })).body.applied, false);
  assert.ok(memory.all(U).some(m => m.kind === 'preference'));
  const sc2 = sc('meeting_conflict'); sc2.signals[0].dedupe_key = 'another';
  const r = await call('POST', BASE + '/evaluate', sc2); assert.equal(r.body.decision, 'card'); // 0.7*0.7=0.49 < 0.7 → 2 steps
  const id2 = r.body.event_id;
  assert.equal((await call('POST', '/proactive/feedback', { event_id: id2, kind: 'disturbing' })).body.kind, 'intrusive');
  assert.equal((await call('POST', '/proactive/feedback', { event_id: id2, kind: 'meh' })).status, 422);
  assert.equal((await call('GET', BASE + '/weights')).body.weights.meeting_conflict.weight, 0.49);
});

test('decision model adapter: OpenRouter first then Agnes (only with the user\'s consent, B1); keys only from env, not exposed', async () => {
  const env = { CATPAW_PRIVATE_MODEL_KEY: 'k-or-xxxxxxxx', CATPAW_AGNES_API_KEY: 'k-ag-xxxxxxxx' }, hits = [];
  const fetchImpl = async (url, init) => { hits.push(url); if (url.includes('openrouter')) return new Response('busy', { status: 429 }); return Response.json({ choices: [{ message: { content: '<think>..</think>```json\n{"decision":"card","reason":"r","confidence":0.8}\n```' } }] }); };
  const m = createDecisionModel({ get: n => env[n], fetchImpl, consent: async (uid, r) => uid === 'u1' && r.id === 'agnes' });
  assert.deepEqual(m.routes, ['openrouter', 'agnes']);
  assert.equal((await m.decide({}, { uid: 'u1' })).decision, 'card'); assert.equal(m.lastRoute(), 'agnes'); assert.equal(hits.length, 2);
  assert.ok(!JSON.stringify(m).includes('k-or')); assert.equal(createDecisionModel({ get: () => undefined }), null);
});

test('P0-5: reminder then SMS on the same card; a cancelled SMS is never recorded as done', async () => {
  const { call } = setup();
  const id = (await call('POST', BASE + '/evaluate', sc('meeting_soon_far'))).body.event_id;
  let s = (await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'create_reminder', operation_id: 'op-r' })).body.suggestion;
  assert.equal(s.status, 'pending'); assert.equal(s.action_states.create_reminder, 'done');
  s = (await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'notify_attendees', outcome: 'cancelled', operation_id: 'op-c' })).body.suggestion;
  assert.equal(s.status, 'pending'); assert.equal(s.action_states.notify_attendees, undefined); assert.equal(s.taken.length, 1);
  s = (await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'notify_attendees', operation_id: 'op-s' })).body.suggestion;
  assert.equal(s.status, 'done'); assert.deepEqual(s.action_states, { create_reminder: 'done', notify_attendees: 'done' });
  s = (await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'notify_attendees', operation_id: 'op-s' })).body.suggestion;
  assert.equal(s.taken.length, 2); // replay: effect recorded exactly once
});
test('P0-4 client contract: iOS posts {value} to suggestions/:id/feedback for meeting_upcoming; next same-type decision degrades; weights persist', async () => {
  const { call } = setup({ model: fakeLLM({ decision: 'notify', reason: '该出发了', confidence: 0.8, trigger: 'meeting_upcoming' }) });
  const req = () => ({ signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: crypto.randomUUID(), data: { title: '周会', location: '望京', minutes_until: 40 } }], context: { time_zone: 'Asia/Shanghai', lead_minutes: 10 } });
  const first = await call('POST', BASE + '/evaluate', req()); assert.equal(first.body.decision, 'notify');
  const f = await call('POST', `${BASE}/suggestions/${first.body.event_id}/feedback`, { value: 'intrusive' });
  assert.equal(f.status, 200); assert.equal(f.body.applied, true); assert.equal(f.body.weights.meeting_upcoming.weight, 0.7);
  const next = await call('POST', BASE + '/evaluate', req());
  assert.equal(next.body.decision, 'card'); // 0.8×0.7=0.56 < 0.6+0.1 → one step down
  assert.equal((await call('GET', BASE + '/weights')).body.weights.meeting_upcoming.threshold_bump, 0.1);
});
