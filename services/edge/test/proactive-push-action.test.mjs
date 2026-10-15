import test from 'node:test'; import assert from 'node:assert/strict';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createApnsSender } from '../supabase/functions/_shared/proactive/apns.mjs';

const U1 = crypto.randomUUID(), U2 = crypto.randomUUID();
function setup(apns) {
  const clock = { t: Date.parse('2026-10-15T04:00:00Z') }, store = createMemoryStore();
  const svc = createProactiveService({ store, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async h => ({ sub: h === 'Bearer u2' ? U2 : U1 }) });
  const call = async (method, path, body, auth = 'Bearer u1') => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: auth }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { clock, store, svc, call, tick: () => svc.tick() };
}
const TOK = { device_id: 'd1', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw' };

test('APNs missing env degrades: sender unconfigured, /push/test reports apns_not_configured, no network', async () => {
  let fetched = 0; const apns = createApnsSender({ keyId: undefined, teamId: undefined, privateKeyPem: undefined, topic: undefined, fetchImpl: async () => { fetched++; } });
  assert.equal(apns.configured, false);
  const { call } = setup(apns);
  assert.equal((await call('POST', '/push/test')).body.state, 'no_device');
  await call('PUT', '/devices/tokens', TOK);
  const r = await call('POST', '/push/test'); assert.equal(r.body.state, 'apns_not_configured'); assert.equal(r.body.apns_configured, false); assert.equal(fetched, 0);
  assert.equal((await call('GET', '/health', null, '')).body.apns, false);
});

test('/push/test sends through a configured sender stub', async () => {
  const sent = []; const { call } = setup({ configured: true, send: async (t, ev) => { sent.push([t.token, ev.title]); return { ok: true }; } });
  await call('PUT', '/devices/tokens', TOK);
  assert.equal((await call('POST', '/push/test')).body.state, 'sent'); assert.equal(sent.length, 1);
});

test('push action: snooze reschedules the task, idempotent, owner-scoped; done closes', async () => {
  const { call, tick, store, clock } = setup(null);
  const t = (await call('POST', '/tasks', { operation_id: crypto.randomUUID(), title: '吃药', due_at: '2026-10-15T04:00:00Z' })).body.task;
  await tick();
  const ev = (await call('GET', '/events')).body.events.find(e => e.kind === 'reminder_due');
  assert.equal((await call('POST', '/push/action', { event_id: ev.id, action: 'snooze_10m' }, 'Bearer u2')).status, 404);
  assert.equal((await call('POST', '/push/action', { event_id: ev.id, action: 'nope' })).status, 422);
  const a = await call('POST', '/push/action', { event_id: ev.id, action: 'snooze_10m' });
  assert.equal(a.body.applied, true); assert.equal(a.body.task.status, 'snoozed'); assert.equal(a.body.task.next_fire_at, '2026-10-15T04:10:00.000Z');
  const again = await call('POST', '/push/action', { event_id: ev.id, action: 'done' }); assert.equal(again.body.applied, false); assert.equal(again.body.action, 'snooze_10m');
  assert.ok((await store.getEvent(U1, ev.id)).opened_at);
  clock.t = Date.parse('2026-10-15T04:10:05Z'); assert.equal((await tick()).claimed, 1);
  const ev2 = (await call('GET', '/events')).body.events.filter(e => e.kind === 'reminder_due').at(-1);
  assert.equal((await call('POST', '/push/action', { event_id: ev2.id, action: 'done' })).body.task.status, 'done');
  assert.equal((await call('GET', '/tasks/' + t.id)).body.task.status, 'done');
});
