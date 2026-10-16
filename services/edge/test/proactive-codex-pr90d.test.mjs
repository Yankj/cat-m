// Codex PR90 round 4 (2484e15): sender checks suggestion status; undo restores snooze_until; evaluate at the future fire time.
import test from 'node:test'; import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';

const U = crypto.randomUUID(), BASE = '/catpaw/proactive/v1';
const TOK = { device_id: 'd1', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw' };
const fakeLLM = out => ({ lastRoute: () => 'fake', decide: async () => out });
function setup({ t = '2026-10-15T02:00:00Z', wrap = s => s } = {}) {
  const clock = { t: Date.parse(t) }, store = wrap(createMemoryStore()), sent = [];
  const apns = { configured: true, send: async (tk, ev) => { sent.push(ev); return { ok: true }; } };
  const decision = createDecisionService({ store, model: fakeLLM({ decision: 'notify', reason: '该出发了', confidence: 0.9, suggested_actions: ['create_reminder', 'snooze', 'dismiss'] }), now: () => clock.t });
  const svc = createProactiveService({ store, decision, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
  const call = async (method, path, body) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: 'Bearer u' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { clock, store, svc, call, sent };
}
const meeting = (ctx = {}) => ({ context: { time_zone: 'Asia/Shanghai', ...ctx }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'evt-c3-' + crypto.randomUUID(), data: { title: '评审', minutes_until: 20 } }] });


test('PR90d #5: remote notify → dismiss → flush sends nothing (pending cancelled, status checked at the sender)', async () => {
  const { call, svc, store, sent } = setup(); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting({ delivery: 'remote' }))).body.event_id;
  assert.equal((await store.getEvent(U, id)).push_state, 'pending');
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'dismiss', operation_id: 'op-d' });
  assert.equal((await store.getEvent(U, id)).push_state, 'skipped', 'dismiss cancels the pending push');
  await svc.tick(); assert.equal(sent.length, 0);
});

test('PR90d #5: the sender skips a pending row whose suggestion is no longer pending (row re-armed / raced)', async () => {
  const { svc, store, sent } = setup(); await store.upsertToken(U, TOK);
  const ev = await store.insertEvent({ user_id: U, task_id: null, conversation_id: null, kind: 'proactive_decision', title: 'r', body: 'b', dedupe_key: 'st-1', push_state: 'pending',
    payload: { decision: 'notify', delivery: 'remote', time_zone: 'Asia/Shanghai', suggestion: { status: 'dismissed', taken: [{ action: 'dismiss', at: '2026-10-15T01:00:00Z' }], history: [], ops: {} } } });
  await svc.tick();
  assert.equal(sent.length, 0); assert.equal((await store.getEvent(U, ev.id)).push_state, 'skipped');
});

test('PR90d #5: remote snooze holds the push until it resurfaces', async () => {
  const { call, svc, store, clock, sent } = setup(); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting({ delivery: 'remote' }))).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-s', minutes: 10 });
  await svc.tick(); assert.equal(sent.length, 0, 'not pushed while snoozed');
  clock.t += 11 * 60_000; await svc.tick(); await svc.tick();
  assert.equal(sent.length, 1, 'pushed once after it resurfaces');
});

test('PR90d #4: snooze(10) → snooze(60) → undo restores the first snooze_until', async () => {
  const { call, store, clock } = setup(); const t0 = clock.t;
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-s1', minutes: 10 });
  clock.t += 60_000;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-s2', minutes: 60 });
  await call('POST', `${BASE}/suggestions/${id}/undo`, { operation_id: 'op-u' });
  const st = (await store.getEvent(U, id)).payload.suggestion;
  assert.equal(st.status, 'snoozed'); assert.equal(st.snooze_until, new Date(t0 + 10 * 60_000).toISOString());
  clock.t = t0 + 11 * 60_000; await store.resurfaceSnoozed(new Date(clock.t).toISOString());
  assert.equal((await store.getEvent(U, id)).payload.suggestion.status, 'pending', 'resurfaces at the restored time');
});

test('PR90d #4: snooze → dismiss → undo is snoozed again with its snooze_until', async () => {
  const { call, store, clock } = setup(); const t0 = clock.t;
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-s1', minutes: 30 });
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'dismiss', operation_id: 'op-d' });
  await call('POST', `${BASE}/suggestions/${id}/undo`, { operation_id: 'op-u' });
  const st = (await store.getEvent(U, id)).payload.suggestion;
  assert.equal(st.status, 'snoozed'); assert.equal(st.snooze_until, new Date(t0 + 30 * 60_000).toISOString());
});

test('PR90d P2: preschedule evaluate uses the future fire time (evaluate_at) for quiet hours; out-of-range ignored', async () => {
  const { call } = setup({ t: '2026-10-15T15:00:00Z' });   // 23:00 Asia/Shanghai (quiet)
  const at = (await call('POST', BASE + '/evaluate', meeting({ evaluate_at: '2026-10-16T01:00:00Z' }))).body;   // 09:00 next morning
  assert.equal(at.decision, 'notify', 'judged at the fire instant, not the night it was scheduled');
  const now = (await call('POST', BASE + '/evaluate', meeting())).body;
  assert.equal(now.decision, 'card', 'without evaluate_at: quiet hours now');
  const far = (await call('POST', BASE + '/evaluate', meeting({ evaluate_at: '2026-10-20T01:00:00Z' }))).body;
  assert.equal(far.decision, 'card', 'evaluate_at beyond 36h is ignored');
});
