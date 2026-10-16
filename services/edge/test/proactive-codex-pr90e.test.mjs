// Codex PR90 round 5 (e76f019): send licence vs concurrent dismiss; terminal push states never overwritten;
// real client operation ids for repeated snooze + undo; an old op replay never cancels a re-armed push.
import test from 'node:test'; import assert from 'node:assert/strict';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';

const U = crypto.randomUUID(), BASE = '/catpaw/proactive/v1';
const TOK = { device_id: 'd1', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw' };
const fakeLLM = out => ({ lastRoute: () => 'fake', decide: async () => out });
function setup({ t = '2026-10-15T02:00:00Z' } = {}) {
  const clock = { t: Date.parse(t) }, store = createMemoryStore(), sent = [];
  const apns = { configured: true, send: async (tk, ev) => { sent.push(ev); return { ok: true }; } };
  const decision = createDecisionService({ store, model: fakeLLM({ decision: 'notify', reason: '该出发了', confidence: 0.9, suggested_actions: ['create_reminder', 'snooze', 'dismiss'] }), now: () => clock.t });
  const svc = createProactiveService({ store, decision, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
  const call = async (method, path, body) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: 'Bearer u' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { clock, store, svc, call, sent };
}
const meeting = (ctx = {}) => ({ context: { time_zone: 'Asia/Shanghai', ...ctx }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'evt-e-' + crypto.randomUUID(), data: { title: '评审', minutes_until: 20 } }] });

test('PR90e #6: dismiss completing while the sender awaits tokens → nothing is sent, the row stays cancelled', async () => {
  const { call, svc, store, sent } = setup(); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting({ delivery: 'remote' }))).body.event_id;
  const real = store.tokensFor.bind(store); let once = true;
  store.tokensFor = async uid => { if (once) { once = false; await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'dismiss', operation_id: 'op-d' }); } return real(uid); };
  await svc.flushPush();
  const ev = await store.getEvent(U, id);
  assert.equal(sent.length, 0, 'undo completed before the send started → no push');
  assert.equal(ev.payload.suggestion.status, 'dismissed'); assert.notEqual(ev.push_state, 'sent');
});

test('PR90e #6: a terminal push state is never overwritten by a late setPush', async () => {
  const { call, store } = setup(); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting({ delivery: 'remote' }))).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'dismiss', operation_id: 'op-d' });
  await store.setPush(id, 'sent', null);
  assert.equal((await store.getEvent(U, id)).push_state, 'skipped');
});

test('PR90e #5: repeated snooze with the real client ids (op-<id>-snooze, -n2) + until → undo keeps the first, device == cloud', async () => {
  const { call, store, clock } = setup(); const t0 = clock.t;
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  const u1 = new Date(t0 + 10 * 60_000).toISOString(), u2 = new Date(t0 + 70 * 60_000).toISOString();
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: `op-${id}-snooze`, until: u1 });
  clock.t += 60_000;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: `op-${id}-snooze-n2`, until: u2 });
  let st = (await store.getEvent(U, id)).payload.suggestion;
  assert.equal(st.taken.length, 2, 'two intents recorded'); assert.equal(st.snooze_until, u2, 'the device-chosen until is stored');
  await call('POST', `${BASE}/suggestions/${id}/undo`, { operation_id: `undo-${id}-g0` });
  st = (await store.getEvent(U, id)).payload.suggestion;
  assert.equal(st.status, 'snoozed'); assert.equal(st.taken.length, 1); assert.equal(st.snooze_until, u1);
  // A retry of the same intent is idempotent.
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: `op-${id}-snooze-n2`, until: u2 });
  assert.equal((await store.getEvent(U, id)).payload.suggestion.taken.length, 1, 'replayed op not re-applied');
});

test('PR90e #5: an old snooze op replayed after the push was re-armed does not cancel it', async () => {
  const { call, store, clock } = setup(); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting({ delivery: 'remote' }))).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-s1', minutes: 10 });
  clock.t += 11 * 60_000; await store.resurfaceSnoozed(new Date(clock.t).toISOString());
  assert.equal((await store.getEvent(U, id)).push_state, 'pending');
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-s1', minutes: 10 });
  assert.equal((await store.getEvent(U, id)).push_state, 'pending', 'replay changed nothing → re-armed push kept');
});
