import test from 'node:test'; import assert from 'node:assert/strict';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { parseQuietHours, isQuiet, quietEndsAt } from '../supabase/functions/_shared/proactive/throttle.mjs';

const U = crypto.randomUUID(), TOK = { device_id: 'd1', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw' };
function setup(t0, opts = {}) {
  const clock = { t: Date.parse(t0) }, store = createMemoryStore(), sent = [];
  const apns = { configured: true, send: async (t, ev) => { sent.push(ev); return { ok: true }; } };
  const svc = createProactiveService({ store, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }), ...opts });
  return { clock, store, svc, sent };
}
const agentEvent = (store, n) => store.insertEvent({ user_id: U, task_id: null, conversation_id: null, kind: 'agent_message', title: 't' + n, body: 'b' + n, payload: { time_zone: 'Asia/Shanghai' }, dedupe_key: 'k' + n });

test('quiet-hours helpers: Shanghai 22-8 window, end instant, parse', () => {
  const q = parseQuietHours('22-8');
  assert.equal(isQuiet(Date.parse('2026-10-15T15:00:00Z'), 'Asia/Shanghai', q), true);  // 23:00 CST
  assert.equal(isQuiet(Date.parse('2026-10-15T01:00:00Z'), 'Asia/Shanghai', q), false); // 09:00 CST
  assert.equal(new Date(quietEndsAt(Date.parse('2026-10-15T15:20:05Z'), 'Asia/Shanghai', q)).toISOString(), '2026-10-16T00:00:00.000Z');
  assert.equal(parseQuietHours('off'), null); assert.deepEqual(parseQuietHours('junk'), { start: 22, end: 8 });
});

test('agent pushes during quiet hours are deferred, then coalesced into one push at 08:00', async () => {
  const { clock, store, svc, sent } = setup('2026-10-15T15:00:00Z');
  await store.upsertToken(U, TOK); await agentEvent(store, 1); await agentEvent(store, 2);
  const r1 = await svc.flushPush(); assert.equal(r1.deferred, 2); assert.equal(sent.length, 0);
  clock.t = Date.parse('2026-10-15T23:59:00Z'); assert.equal((await svc.flushPush()).deferred, 0); assert.equal(sent.length, 0);
  clock.t = Date.parse('2026-10-16T00:00:30Z');
  const r2 = await svc.flushPush(); assert.equal(r2.sent, 1); assert.equal(r2.coalesced, 1);
  assert.equal(sent[0].title, '小猫有 2 条消息');
});

test('user-scheduled reminders bypass quiet hours and cap; agent pushes stop at daily cap', async () => {
  const { store, svc, sent } = setup('2026-10-15T15:00:00Z', { dailyPushCap: 1, quietHours: null });
  await store.upsertToken(U, TOK);
  await store.insertEvent({ user_id: U, kind: 'reminder_due', title: 'r', body: 'r', payload: { created_by: 'user' }, dedupe_key: 'r1' });
  await agentEvent(store, 1); assert.equal((await svc.flushPush()).sent, 2);
  await agentEvent(store, 2); const r = await svc.flushPush(); assert.equal(r.capped, 1); assert.equal(sent.length, 2);
});

test('quiet hours do not hold user reminders scheduled at 23:00', async () => {
  const { store, svc, sent } = setup('2026-10-15T15:00:00Z');
  await store.upsertToken(U, TOK);
  await store.insertEvent({ user_id: U, kind: 'reminder_due', title: 'r', body: 'r', payload: { created_by: 'user', time_zone: 'Asia/Shanghai' }, dedupe_key: 'r1' });
  assert.equal((await svc.flushPush()).sent, 1); assert.equal(sent.length, 1);
});
