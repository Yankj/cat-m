// v0.1 wrap: M1 migrations 20261023100000 / 20261023100100 + pg-store changes on REAL Postgres.
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-m1-pg.test.mjs
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgStore } from '../supabase/functions/_shared/proactive/pg-store.mjs';
import { createPgAgentMemoryStore } from '../supabase/functions/_shared/agent-memory/pg-store.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const conn = () => postgres(url, { max: 3, prepare: false, onnotice: () => {} });
async function user(sql) { const u = crypto.randomUUID(); await sql`insert into auth.users(id) values(${u})`; return u; }
async function task(sql, u, fireAt, status = 'open') { const r = await sql`insert into proactive.tasks(user_id,operation_id,title,status,next_fire_at) values(${u},${crypto.randomUUID()},'t',${status},${fireAt}) returning id`; return r[0].id; }

test('pg REM-01: a claimed occurrence is a 15 min lease, reclaimable only after expiry', { skip: !url }, async () => {
  const sql = conn(); try {
    const s = createPgStore(sql), u = await user(sql), t0 = new Date('2026-10-23T01:00:00Z');
    const id = await task(sql, u, t0);
    const mine = c => c.filter(x => x.task_id === id);
    assert.equal(mine(await s.claimDue(t0.toISOString(), 200)).length, 1, 'first claim');
    assert.equal(mine(await s.claimDue(new Date(+t0 + 400_000).toISOString(), 200)).length, 0, 'lease held past the max Edge wall clock (400s)');
    assert.equal(mine(await s.claimDue(new Date(+t0 + 901_000).toISOString(), 200)).length, 1, 'lease expired at +15min: reclaimed');
    await sql`update proactive.reminder_occurrences set state='generated' where task_id=${id}`;
    assert.equal(mine(await s.claimDue(new Date(+t0 + 3_600_000).toISOString(), 200)).length, 0, 'generated is final');
  } finally { await sql.end(); }
});

test('pg REM-01 concurrency: two workers never both hold a live lease', { skip: !url }, async () => {
  const a = conn(), b = conn(); try {
    const u = await user(a), t0 = new Date('2026-10-23T02:00:00Z'), id = await task(a, u, t0);
    const [x, y] = await Promise.all([createPgStore(a).claimDue(t0.toISOString(), 200), createPgStore(b).claimDue(t0.toISOString(), 200)]);
    assert.equal([...x, ...y].filter(c => c.task_id === id).length, 1);
  } finally { await a.end(); await b.end(); }
});

test('pg REM-02: expired leases are filtered before the limit (no starvation)', { skip: !url }, async () => {
  const sql = conn(); try {
    await sql`update proactive.tasks set status='done'`; // isolate from other tests' rows
    const s = createPgStore(sql), u = await user(sql), t0 = new Date('2026-10-23T03:00:00Z');
    const held = await task(sql, u, t0); const later = await task(sql, u, new Date(+t0 + 1000));
    assert.deepEqual((await s.claimDue(new Date(+t0 + 1000).toISOString(), 1)).map(c => c.task_id), [held]);
    const next = await s.claimDue(new Date(+t0 + 5000).toISOString(), 1);   // held lease (+4s) is live
    assert.deepEqual(next.map(c => c.task_id), [later], 'live lease skipped before limit; later row claimed');
  } finally { await sql.end(); }
});

test('pg REM-03/04: release keeps due; reminder_due only while task open and occurrence current', { skip: !url }, async () => {
  const sql = conn(); try {
    const s = createPgStore(sql), u = await user(sql), t0 = new Date('2026-10-23T04:00:00Z'), id = await task(sql, u, t0);
    const [c] = (await s.claimDue(t0.toISOString(), 200)).filter(x => x.task_id === id);
    await s.releaseOccurrence(c);
    const row = (await sql`select next_fire_at from proactive.tasks where id=${id}`)[0];
    assert.equal(+row.next_fire_at, +t0, 'fire failure keeps next_fire_at');
    assert.equal((await s.claimDue(t0.toISOString(), 200)).filter(x => x.task_id === id).length, 1, 'released claim is reclaimable at once');
    await sql`update proactive.tasks set status='cancelled' where id=${id}`;
    const ev = await s.insertEvent({ user_id: u, task_id: id, conversation_id: null, kind: 'reminder_due', title: 't', body: 'b', payload: { scheduled_at: t0.toISOString() }, dedupe_key: 'd-' + id });
    assert.equal(ev, null, 'cancelled first: no reminder_due');
    assert.equal((await sql`select count(*)::int n from proactive.events where task_id=${id}`)[0].n, 0);
  } finally { await sql.end(); }
});

test('pg MEM-01: correction CAS on updated_at returns conflict for a late write', { skip: !url }, async () => {
  const sql = conn(); try {
    const m = createPgAgentMemoryStore(sql), u = await user(sql), now = new Date().toISOString();
    const { row } = await m.insert(u, { id: crypto.randomUUID(), kind: 'fact', content: 'v1', operation_id: 'op-' + crypto.randomUUID(), created_by: 'user', created_at: now, updated_at: now, pinned: false, embedding: null, expires_at: null, source_conversation_id: null, source_turn_id: null, undo_token_hash: null, undo_expires_at: null });
    const v0 = row.updated_at;
    const r1 = await m.update(u, row.id, { content: 'v2', updated_at: new Date(Date.now() + 1000).toISOString() }, { expectVersion: v0 });
    assert.equal(r1.content, 'v2');
    assert.deepEqual(await m.update(u, row.id, { content: 'stale', updated_at: new Date(Date.now() + 2000).toISOString() }, { expectVersion: v0 }), { conflict: true });
    assert.equal((await m.get(u, row.id)).content, 'v2');
  } finally { await sql.end(); }
});

test('pg MEM-03/04: clear generation fences writes; tombstone operation_id blocks replay', { skip: !url }, async () => {
  const sql = conn(); try {
    const m = createPgAgentMemoryStore(sql), u = await user(sql), now = new Date().toISOString(), op = 'op-' + crypto.randomUUID();
    const rec = () => ({ id: crypto.randomUUID(), kind: 'fact', content: 'x', operation_id: op, created_by: 'user', created_at: now, updated_at: now, pinned: false, embedding: null, expires_at: null, source_conversation_id: null, source_turn_id: null, undo_token_hash: null, undo_expires_at: null });
    const { row } = await m.insert(u, rec());
    assert.equal(await m.remove(u, [row.id]), 1);
    const t = await sql`select operation_id from agent_memory.memory_tombstones where user_id=${u} and memory_id=${row.id}`;
    assert.equal(t[0].operation_id, op, 'trigger stores operation_id');
    assert.equal((await m.insert(u, rec())).refused, 'deleted', 'replay after delete refused');
    const g = await m.clearGeneration(u);
    await m.removeAll(u);
    assert.equal(await m.clearGeneration(u), g + 1);
    assert.equal((await m.insert(u, { ...rec(), operation_id: 'op-' + crypto.randomUUID() }, { fence: g })).refused, 'cleared');
    assert.equal(await m.count(u), 0);
  } finally { await sql.end(); }
});

test('pg REM-05 (deploy review): re-claim of an in-flight reminder never sends twice; stale release cannot drop the new claim', { skip: !url }, async () => {
  const sql = conn(); try {
    const s = createPgStore(sql), u = await user(sql), t0 = new Date('2026-10-23T05:00:00Z'), id = await task(sql, u, t0);
    const mine = c => c.filter(x => x.task_id === id);
    const [a] = mine(await s.claimDue(t0.toISOString(), 200));                       // worker A claims, then stalls
    assert.equal(mine(await s.claimDue(new Date(+t0 + 400_000).toISOString(), 200)).length, 0, 'no re-claim within any tick runtime');
    const [b] = mine(await s.claimDue(new Date(+t0 + 901_000).toISOString(), 200));  // A presumed dead: B re-claims
    assert.ok(b, 'expired lease re-claimed');
    await s.releaseOccurrence(a);                                                     // A fails late: must not release B
    assert.equal((await sql`select count(*)::int n from proactive.reminder_occurrences where task_id=${id} and state='claimed'`)[0].n, 1, 'B claim kept');
    // both workers reach insertEvent (A was not dead after all): one reminder_due row, one push candidate
    const ev = w => s.insertEvent({ user_id: u, task_id: id, conversation_id: null, kind: 'reminder_due', title: 't', body: w, payload: { scheduled_at: t0.toISOString() }, dedupe_key: `due:${id}:${t0.toISOString()}` });
    const [ea, eb] = await Promise.all([ev('A'), ev('B')]);
    assert.equal([ea, eb].filter(Boolean).length, 1, 'idempotent send key: exactly one event');
    await s.finishOccurrence(b, { next_fire_at: null, fire_count: 1, status: 'open' });
    await s.finishOccurrence(a, { next_fire_at: new Date(+t0 + 86_400_000).toISOString(), fire_count: 1, status: 'open' });   // stale: fenced on next_fire_at
    const row = (await sql`select next_fire_at, fire_count from proactive.tasks where id=${id}`)[0];
    assert.deepEqual([row.next_fire_at, row.fire_count], [null, 1], 'stale finish is a no-op');
    assert.equal((await sql`select count(*)::int n from proactive.events where task_id=${id} and kind='reminder_due'`)[0].n, 1);
  } finally { await sql.end(); }
});
