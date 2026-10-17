// Real Postgres layer. Run: CATPAW_PG_TEST_URL=postgres://postgres@localhost:55432/postgres deno test -A test/proactive-tasks-pg.test.mjs
// DB must have test/fixtures/supabase-stub.sql + supabase/migrations/20261015120000_proactive_tasks.sql applied.
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgStore } from '../supabase/functions/_shared/proactive/pg-store.mjs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
test('pg store: CRUD, claim-once under concurrency, recurrence advance, RLS isolation', { skip: !url }, async () => {
  const sql = postgres(url, { max: 5, prepare: false, onnotice: () => {} });
  try {
    const U1 = crypto.randomUUID(), U2 = crypto.randomUUID(); await sql`insert into auth.users(id) values(${U1}),(${U2})`;
    const clock = { t: Date.parse('2026-10-15T12:00:00Z') };
    const svc = createProactiveService({ log: (...a) => console.error(...a), store: createPgStore(sql), schedulerSecret: 's', now: () => clock.t, verifyUser: async h => ({ sub: h === 'Bearer u2' ? U2 : U1 }) });
    const call = async (m, p, b, a = 'Bearer u1', h = {}) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + p, { method: m, headers: { authorization: a, ...h }, body: b ? JSON.stringify(b) : undefined })); return { status: r.status, body: await r.json() }; };
    const op = crypto.randomUUID();
    const a = await call('POST', '/tasks', { operation_id: op, title: '喝水', due_at: '2026-10-15T11:59:00Z', recurrence: { freq: 'daily' }, time_zone: 'Asia/Shanghai' });
    assert.equal(a.status, 201, JSON.stringify(a.body)); assert.equal((await call('POST', '/tasks', { operation_id: op, title: '喝水' })).status, 200);
    const id = a.body.task.id;
    assert.equal((await call('PATCH', '/tasks/' + id, { expected_revision: 1, notes: '500ml' })).body.task.revision, 2);
    assert.equal((await call('PATCH', '/tasks/' + id, { expected_revision: 1, notes: 'x' })).status, 409);
    assert.equal((await call('GET', '/tasks/' + id, null, 'Bearer u2')).status, 404);
    const ticks = await Promise.all([1, 2, 3, 4].map(() => call('POST', '/scheduler/tick', null, '', { 'x-catpaw-scheduler-secret': 's' })));
    assert.equal(ticks.reduce((n, t) => n + t.body.claimed, 0), 1, JSON.stringify(ticks.map(t => t.body)));
    const t = (await call('GET', '/tasks/' + id)).body.task; assert.equal(t.next_fire_at, '2026-10-16T11:59:00.000Z'); assert.equal(t.fire_count, 1);
    const evs = (await call('GET', '/events')).body.events; assert.ok(evs.some(e => e.kind === 'reminder_due' && e.body.includes('喝水')));
    assert.equal((await call('PUT', '/devices/tokens', { device_id: 'd', kind: 'apns', token: 'ab'.repeat(32), bundle_id: 'b' })).status, 200);
    assert.equal((await call('PUT', '/devices/tokens', { device_id: 'd', kind: 'apns', token: 'cd'.repeat(32), bundle_id: 'b' })).status, 200);
    // RLS as anonymous-auth user
    const seen = await sql.begin(async tx => { await tx`set local role authenticated`; await tx`select set_config('request.jwt.claim.sub', ${U2}, true)`; return tx`select count(*)::int n from proactive.tasks`; });
    assert.equal(seen[0].n, 0);
    const own = await sql.begin(async tx => { await tx`set local role authenticated`; await tx`select set_config('request.jwt.claim.sub', ${U1}, true)`; return [await tx`select count(*)::int n from proactive.tasks`, await tx`select count(*)::int n from proactive.device_push_tokens`]; });
    assert.ok(own[0][0].n >= 1); assert.equal(own[1][0].n, 1);
    await assert.rejects(sql.begin(async tx => { await tx`set local role authenticated`; await tx`select set_config('request.jwt.claim.sub', ${U2}, true)`; await tx`insert into proactive.tasks(user_id,operation_id,title) values(${U1},${crypto.randomUUID()},'spoof')`; }));
    await assert.rejects(sql.begin(async tx => { await tx`set local role authenticated`; await tx`select * from proactive.claim_due_reminders(now(),1)`; }));
  } finally { await sql.end(); }
});
