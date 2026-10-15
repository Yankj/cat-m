import test from 'node:test'; import assert from 'node:assert/strict';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { nextOccurrence, validateRecurrence } from '../supabase/functions/_shared/proactive/recurrence.mjs';
import { createApnsSender } from '../supabase/functions/_shared/proactive/apns.mjs';
import { createReminderModel } from '../supabase/functions/_shared/proactive/model.mjs';
import { TASK_TOOLS } from '../supabase/functions/_shared/proactive/contract.mjs';
import { generateKeyPair, exportPKCS8 } from 'npm:jose@6.2.12';

const U1 = crypto.randomUUID(), U2 = crypto.randomUUID(), SECRET = 's3cret';
function setup({ model = null, apns = null, t0 = Date.parse('2026-10-15T12:00:00Z') } = {}) {
  const clock = { t: t0 }, store = createMemoryStore();
  const svc = createProactiveService({ store, schedulerSecret: SECRET, model, apns, now: () => clock.t, verifyUser: async h => { if (h === 'Bearer u1') return { sub: U1 }; if (h === 'Bearer u2') return { sub: U2 }; const e = new Error('x'); e.status = 401; throw e; } });
  const call = async (method, path, body, auth = 'Bearer u1', headers = {}) => { const r = await svc.handle(new Request('https://x.supabase.co/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: auth, ...headers }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  const tick = () => call('POST', '/scheduler/tick', null, '', { 'x-catpaw-scheduler-secret': SECRET });
  return { clock, store, svc, call, tick };
}

test('recurrence: daily keeps Shanghai wall clock; monthly clamps; interval; count/until', () => {
  assert.equal(nextOccurrence('2026-10-15T01:00:00.000Z', { freq: 'daily', interval: 1 }, 'Asia/Shanghai', Date.parse('2026-10-15T01:00:00Z')), '2026-10-16T01:00:00.000Z');
  assert.equal(nextOccurrence('2026-01-31T01:00:00.000Z', { freq: 'monthly', interval: 1 }, 'Asia/Shanghai', Date.parse('2026-01-31T02:00:00Z')), '2026-02-28T01:00:00.000Z');
  // DST: 09:00 New York stays 09:00 across Nov 1 2026
  assert.equal(nextOccurrence('2026-10-31T13:00:00.000Z', { freq: 'daily', interval: 1 }, 'America/New_York', Date.parse('2026-10-31T13:00:00Z')), '2026-11-01T14:00:00.000Z');
  assert.equal(nextOccurrence('2026-10-15T00:00:00.000Z', { freq: 'interval', interval_seconds: 3600 }, 'UTC', Date.parse('2026-10-15T02:30:00Z')), '2026-10-15T03:00:00.000Z');
  assert.equal(nextOccurrence('2026-10-15T00:00:00.000Z', { freq: 'daily', interval: 1, count: 2 }, 'UTC', 0, 2), null);
  assert.equal(nextOccurrence('2026-10-15T00:00:00.000Z', { freq: 'weekly', interval: 1, until: '2026-10-20T00:00:00Z' }, 'UTC', Date.parse('2026-10-15T00:00:00Z')), null);
  assert.throws(() => validateRecurrence({ freq: 'interval', interval_seconds: 10 }));
});

test('task CRUD: auth, idempotent create, revision conflict, owner isolation', async () => {
  const { call } = setup();
  assert.equal((await call('GET', '/tasks', null, '')).status, 401);
  const op = crypto.randomUUID(), body = { operation_id: op, title: '交房租', due_at: '2026-10-16T09:00:00+08:00' };
  const a = await call('POST', '/tasks', body); assert.equal(a.status, 201); assert.equal(a.body.task.next_fire_at, '2026-10-16T01:00:00.000Z');
  const b = await call('POST', '/tasks', body); assert.equal(b.status, 200); assert.equal(b.body.task.id, a.body.task.id);
  const id = a.body.task.id;
  assert.equal((await call('GET', '/tasks/' + id, null, 'Bearer u2')).status, 404);
  assert.equal((await call('PATCH', '/tasks/' + id, { title: 'x' }, 'Bearer u2')).status, 404);
  const p = await call('PATCH', '/tasks/' + id, { expected_revision: 1, title: '交房租 3800' }); assert.equal(p.status, 200); assert.equal(p.body.task.revision, 2);
  assert.equal((await call('PATCH', '/tasks/' + id, { expected_revision: 1, title: 'stale' })).body.error, 'revision_conflict');
  assert.equal((await call('POST', '/tasks', { operation_id: crypto.randomUUID(), title: 'x', bogus: 1 })).status, 422);
  assert.equal((await call('DELETE', '/tasks/' + id)).body.task.status, 'cancelled');
  assert.equal((await call('GET', '/tasks?status=open')).body.tasks.length, 0);
});

test('scheduler: secret required, fires once, model text, recurring advances, dedupe on re-tick', async () => {
  let calls = 0; const model = { reminder: async c => { calls++; return `该${c.title}啦`; } };
  const { call, tick, clock } = setup({ model });
  assert.equal((await call('POST', '/scheduler/tick', null, '', { 'x-catpaw-scheduler-secret': 'no' })).status, 403);
  await call('POST', '/tasks', { operation_id: crypto.randomUUID(), title: '喝水', due_at: '2026-10-15T12:00:00Z', recurrence: { freq: 'interval', interval_seconds: 3600 } });
  await call('POST', '/tasks', { operation_id: crypto.randomUUID(), title: '明天开会', due_at: '2026-10-16T12:00:00Z' });
  const r1 = await tick(); assert.equal(r1.body.claimed, 1); assert.equal(r1.body.results[0].source, 'model'); assert.equal(r1.body.results[0].next_fire_at, '2026-10-15T13:00:00.000Z');
  assert.equal((await tick()).body.claimed, 0);
  clock.t = Date.parse('2026-10-15T13:00:30Z'); assert.equal((await tick()).body.claimed, 1);
  const ev = (await call('GET', '/events')).body.events.filter(e => e.kind === 'reminder_due'); assert.equal(ev.length, 2); assert.equal(ev[0].body, '该喝水啦'); assert.equal(calls, 2);
  assert.equal((await call('GET', '/events', null, 'Bearer u2')).body.events.length, 0);
  assert.equal((await call('POST', `/events/${ev[0].id}/read`)).body.ok, true);
});

test('scheduler: model failure falls back to template; one-shot stops; snooze refires', async () => {
  const { call, tick, clock } = setup({ model: { reminder: async () => { throw new Error('429'); } } });
  const t = (await call('POST', '/tasks', { operation_id: crypto.randomUUID(), title: '取快递', notes: '菜鸟驿站', due_at: '2026-10-15T11:00:00Z' })).body.task;
  const r = await tick(); assert.equal(r.body.results[0].source, 'template'); assert.equal(r.body.results[0].next_fire_at, null);
  const cur = (await call('GET', '/tasks/' + t.id)).body.task; assert.equal(cur.next_fire_at, null);
  await call('PATCH', '/tasks/' + t.id, { snooze_until: '2026-10-15T12:10:00Z' });
  clock.t = Date.parse('2026-10-15T12:10:00Z'); assert.equal((await tick()).body.claimed, 1);
  assert.equal((await call('GET', '/tasks/' + t.id)).body.task.status, 'open');
});

test('agent tool contract: create idempotent per operation, update, list, bad args', async () => {
  const { svc } = setup(); const conv = crypto.randomUUID(), op = crypto.randomUUID();
  assert.deepEqual(TASK_TOOLS.map(t => t.function.name), ['create_task', 'update_task', 'list_tasks']);
  const a = await svc.executeTool(U1, { name: 'create_task', arguments: JSON.stringify({ title: '给妈妈打电话', due_at: '2026-10-18T19:00:00+08:00', recurrence: { freq: 'weekly' } }) }, { conversation_id: conv, turn_id: crypto.randomUUID(), operation_id: op });
  assert.equal(a.ok, true); assert.equal(a.created, true);
  const b = await svc.executeTool(U1, { name: 'create_task', arguments: { title: '给妈妈打电话' } }, { conversation_id: conv, operation_id: op }); assert.equal(b.created, false);
  const u = await svc.executeTool(U1, { name: 'update_task', arguments: { task_id: a.task.id, status: 'done' } }); assert.equal(u.task.status, 'done'); assert.equal(u.task.next_fire_at, null);
  assert.equal((await svc.executeTool(U1, { name: 'list_tasks', arguments: { status: 'all' } })).tasks.length, 1);
  assert.equal((await svc.executeTool(U2, { name: 'update_task', arguments: { task_id: a.task.id, status: 'open' } })).error, 'task_not_found');
  assert.equal((await svc.executeTool(U1, { name: 'create_task', arguments: '{bad' }, { operation_id: op })).error, 'arguments_invalid');
  assert.equal((await svc.executeTool(U1, { name: 'rm_rf', arguments: {} })).error, 'unknown_tool');
});

test('push: no device / apns unconfigured / configured sends alert + live activity, 410 disables token', async () => {
  const { privateKey } = await generateKeyPair('ES256', { extractable: true }); const pem = await exportPKCS8(privateKey); const sent = [];
  const apns = createApnsSender({ keyId: 'KEY1234567', teamId: 'TEAM123456', privateKeyPem: pem, topic: 'ai.catpaw.app', fetchImpl: async (url, o) => { sent.push({ url, h: o.headers, b: JSON.parse(o.body) }); return url.includes('dead') || url.includes('dead'.replace(/./g, 'd')) ? new Response('{"reason":"Unregistered"}', { status: 410 }) : new Response(null, { status: 200 }); } });
  const { call, tick, store } = setup({ apns });
  await call('POST', '/tasks', { operation_id: crypto.randomUUID(), title: 'A', due_at: '2026-10-15T11:00:00Z' });
  let r = await tick(); assert.equal(r.body.push.no_device, 1);
  assert.equal((await call('PUT', '/devices/tokens', { device_id: 'iphone', kind: 'apns', token: 'ab'.repeat(32), bundle_id: 'ai.catpaw.app' })).status, 200);
  assert.equal((await call('PUT', '/devices/tokens', { device_id: 'iphone', kind: 'live_activity_update', token: 'cd'.repeat(32), bundle_id: 'ai.catpaw.app', activity_id: 'act1' })).status, 200);
  assert.equal((await call('PUT', '/devices/tokens', { device_id: 'x', kind: 'apns', token: 'zz' })).status, 422);
  await call('POST', '/tasks', { operation_id: crypto.randomUUID(), title: 'B', due_at: '2026-10-15T11:30:00Z' });
  r = await tick(); assert.equal(r.body.push.sent, 1); assert.equal(sent.length, 2);
  assert.ok(sent[0].url.startsWith('https://api.sandbox.push.apple.com/3/device/')); assert.equal(sent[0].h['apns-push-type'], 'alert'); assert.match(sent[0].h.authorization, /^bearer ey/);
  assert.equal(sent[1].h['apns-topic'], 'ai.catpaw.app.push-type.liveactivity'); assert.equal(sent[1].b.aps.event, 'update');
  const off = setup(); await off.call('PUT', '/devices/tokens', { device_id: 'i', kind: 'apns', token: 'ab'.repeat(32), bundle_id: 'b' }); await off.call('POST', '/tasks', { operation_id: crypto.randomUUID(), title: 'C', due_at: '2026-10-15T11:00:00Z' });
  assert.equal((await off.tick()).body.push.skipped, 1);
  const dead = createApnsSender({ keyId: 'K', teamId: 'T', privateKeyPem: pem, topic: 'b', fetchImpl: async () => new Response('{"reason":"BadDeviceToken"}', { status: 400 }) });
  assert.equal((await dead.send({ kind: 'apns', token: 'ab', environment: 'sandbox', bundle_id: 'b' }, { id: 'e', title: 't', body: 'b' })).unregistered, true);
  void store;
});

test('model adapter uses the configured free route and zero-price provider policy', async () => {
  let seen; const m = createReminderModel({ apiKey: 'k', route: { endpoint: 'https://openrouter.ai/api/v1/chat/completions', model: 'apodex/apodex-1.1-mini:free', routing_policy: { only: ['novita/bf16'], allow_fallbacks: false } }, fetchImpl: async (u, o) => { seen = JSON.parse(o.body); return Response.json({ choices: [{ message: { content: ' 记得喝水哦 ' } }] }); } });
  assert.equal(await m.reminder({ title: '喝水', time_zone: 'Asia/Shanghai', fire_count: 0 }, Date.now()), '记得喝水哦');
  assert.equal(seen.model, 'apodex/apodex-1.1-mini:free'); assert.equal(seen.provider.allow_fallbacks, false);
  assert.equal(createReminderModel({ apiKey: null, route: {} }), null);
});
