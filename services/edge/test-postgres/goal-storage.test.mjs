// Real PostgreSQL lower-layer tests; intentionally outside the deny-net Edge test directory.
import test from 'node:test';
import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { pgCompatiblePool } from '../functions/_shared/postgres-pool.mjs';
import { PostgresRepository } from '../functions/_shared/core/integration/server-foundation/src/postgres-repository.mjs';
import { Foundation } from '../functions/_shared/core/integration/server-foundation/src/foundation.mjs';
import { Facade } from '../functions/_shared/core/facade-r2/src/facade.mjs';
import { BoundedStore } from '../functions/_shared/core/integration/edge-adapter/src/bounded-store.mjs';
import { stableUUID } from '../functions/_shared/core/src/local-output-facade.mjs';
import { ProactiveGoalKernel } from '../functions/_shared/core/integration/server-foundation/src/proactive-goal-kernel.mjs';

// Fixed container loopback only. No URL/env passthrough and no Supabase/Auth/provider import.
const sql = postgres({ host: '127.0.0.1', port: 5432, database: 'catpaw_goal_synthetic', username: 'postgres', ssl: false,
  max: 6, prepare: false, connect_timeout: 3, connection: { application_name: 'catpaw-goal-storage-test', statement_timeout: '4000' } });
const repository = new PostgresRepository(pgCompatiblePool(sql));
const info = (await sql`SELECT current_database() AS database,version() AS version,current_setting('transaction_isolation') AS isolation`)[0];
assert.equal(info.database, 'catpaw_goal_synthetic'); assert.match(info.version, /^PostgreSQL 17\./);
console.info(JSON.stringify({ execution_layer: 'real_disposable_postgres', ...info, production_kernel_enabled: false }));
await sql.unsafe(`CREATE SCHEMA catpaw;
 CREATE TABLE catpaw.scopes(scope_id uuid PRIMARY KEY,data jsonb NOT NULL);
 CREATE TABLE catpaw.goals(scope_id uuid NOT NULL,id uuid NOT NULL,data jsonb NOT NULL,PRIMARY KEY(scope_id,id));
 CREATE TABLE catpaw.events(scope_id uuid NOT NULL,id uuid NOT NULL,data jsonb NOT NULL,PRIMARY KEY(scope_id,id));
 CREATE TABLE public.records(owner text NOT NULL,kind text NOT NULL,id text NOT NULL,data jsonb NOT NULL,updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(owner,kind,id));`);
const uid = value => stableUUID(`synthetic-postgres-goal-floor:${value}`);
async function fixture(label) {
  const scope = { scope_id: uid(label+'scope'), profile_id: uid(label+'profile'), workspace_id: uid(label+'workspace') };
  const principal = { subject_id: uid(label+'subject'), scopes: [scope] };
  const foundation = new Foundation(repository, { guardKey: 'synthetic-pg-test-placeholder' });
  await foundation.bootstrapScope(principal, scope.scope_id);
  const owner = foundation.identity(principal, scope.scope_id).owner, goalId = uid(label+'goal');
  await foundation.createGoal(principal, scope.scope_id, { goal_id: goalId, title: 'Synthetic PG goal', description: 'Storage primitives only' });
  return { scope, principal, foundation, owner, goalId };
}
async function workerFixture(label) {
  const f = await fixture(label), facade = new Facade({ repository, authenticate: async () => f.principal });
  const d = (await facade.createDelegation('synthetic', f.scope.scope_id, { delegation_id: uid(label+'delegation'), title: 'Synthetic PG task', goal: 'No effects', requirements: 'Storage only', stop_conditions: ['Stop'], synthetic_fixture_id: 'report' })).delegation;
  const run = await facade.createRun('synthetic', f.scope.scope_id, d.id, { operation_id: uid(label+'operation'), run_id: uid(label+'run'), expected_revision: 1, expected_grant_epoch: 1 });
  let millis = Date.now();
  const admitTask = async (tx, owner, id, options) => {
    await tx.withScope(f.scope.scope_id, async scoped => { assert.equal((await scoped.scope()).identity.owner, owner); });
    return facade.admittedTask(tx, owner, id, options);
  };
  const store = () => new BoundedStore({ repository, owners: [f.owner], admitTask, now: () => millis, invocation: { open: true, deadline: millis + 30000 } });
  return { ...f, facade, d, taskId: run.task.id, store, now: () => millis, advance: ms => { millis += ms; } };
}
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
async function waitForRealLock() {
  const until = Date.now() + 2000;
  while (Date.now() < until) {
    const [{ count }] = await sql`SELECT count(*)::integer AS count FROM pg_stat_activity WHERE application_name='catpaw-goal-storage-test' AND wait_event_type='Lock'`;
    if (count > 0) return;
  }
  assert.fail('No real PostgreSQL lock wait observed');
}

test('real PG: scoped CAS contenders have one winner; another scope cannot update the Goal', async () => {
  const f = await fixture('cas');
  const values = await Promise.all([1,2].map(() => repository.transaction(f.scope.scope_id, tx => tx.compareAndSwap('goals', f.goalId, { revision: 1 }, { revision: 2 }))));
  assert.equal(values.filter(Boolean).length, 1);
  const other = await fixture('other');
  assert.equal(await repository.transaction(other.scope.scope_id, tx => tx.compareAndSwap('goals', f.goalId, { revision: 2 }, { revision: 3 })), null);
});

test('real PG: Goal/event/records outbox roll back together on the same reserved connection', async () => {
  const f = await fixture('rollback');
  await assert.rejects(repository.transaction(f.scope.scope_id, async tx => {
    assert.ok(await tx.compareAndSwap('goals', f.goalId, { revision: 1 }, { revision: 2 }));
    await f.foundation.emit(tx, 'synthetic_outbox_rollback', {});
    await tx.records.insertIfAbsent(f.owner, 'catpaw-notification-outbox', { id: 'synthetic-rollback', state: 'pending' });
    throw new Error('synthetic_transaction_abort');
  }), /synthetic_transaction_abort/);
  await repository.transaction(f.scope.scope_id, async tx => {
    assert.equal((await tx.get('goals', f.goalId)).revision, 1); assert.equal((await tx.scope()).last_sequence, 1);
    assert.equal((await tx.list('events')).length, 1); assert.equal(await tx.records.get(f.owner, 'catpaw-notification-outbox', 'synthetic-rollback'), null);
  });
});

test('real PG: existing BoundedStore arbitrates competing leases and rejects old/expired settlement', async () => {
  const f = await workerFixture('lease'), a = f.store(), b = f.store(), leaseA = uid('leaseA'), leaseB = uid('leaseB');
  const claim = (store, leaseId) => store.compareAndSwap(f.owner, 'tasks', f.taskId, { status: 'queued', leaseId: null }, { status: 'running', leaseId, leaseUntil: new Date(f.now()+5000).toISOString() });
  const claims = await Promise.all([claim(a, leaseA), claim(b, leaseB)]); assert.equal(claims.filter(Boolean).length, 1);
  const current = claims.find(Boolean); f.advance(5001);
  assert.equal(await a.compareAndSwap(f.owner, 'tasks', f.taskId, { status: 'running', leaseId: current.leaseId }, { status: 'succeeded', leaseId: null, leaseUntil: null }), null);
  const successor = uid('successor');
  assert.ok(await b.compareAndSwap(f.owner, 'tasks', f.taskId, { status: 'running', leaseId: current.leaseId, leaseUntil: current.leaseUntil }, { status: 'running', leaseId: successor, leaseUntil: new Date(f.now()+5000).toISOString() }));
  assert.equal(await a.compareAndSwap(f.owner, 'tasks', f.taskId, { status: 'running', leaseId: current.leaseId }, { status: 'succeeded', leaseId: null, leaseUntil: null }), null);
});

test('real PG: existing delegation revoke racing worker claim fences subsequent lease commits', async () => {
  const f = await workerFixture('revoke'), store = f.store(), leaseId = uid('revoke-lease');
  await Promise.all([store.compareAndSwap(f.owner, 'tasks', f.taskId, { status: 'queued', leaseId: null }, { status: 'running', leaseId, leaseUntil: new Date(f.now()+5000).toISOString() }),
    f.facade.control('synthetic', f.scope.scope_id, f.d.id, { action: 'revoke', expected_revision: 1, expected_grant_epoch: 1 })]);
  const task = await repository.transaction(tx => tx.get(f.owner, 'tasks', f.taskId));
  assert.equal(task.status, 'cancelled'); assert.equal(task.leaseId, null);
  assert.equal(await store.compareAndSwap(f.owner, 'tasks', f.taskId, { status: 'running', leaseId }, { status: 'succeeded', leaseId: null, leaseUntil: null }), null);
});

test('real PG: scope row lock orders approval/revocation CAS and prevents approval resurrection', async () => {
  const f = await fixture('approval'), actionId = uid('approval'), held = deferred(), release = deferred();
  await repository.transaction(tx => tx.put(f.owner, 'actions', { id: actionId, status: 'awaiting_review' }));
  const approving = repository.transaction(f.scope.scope_id, async tx => {
    assert.equal((await tx.get('goals', f.goalId)).revision, 1); held.resolve(); await release.promise;
    return tx.records.compareAndSwap(f.owner, 'actions', actionId, { status: 'awaiting_review' }, { status: 'approved' });
  });
  await held.promise;
  const revoking = repository.transaction(f.scope.scope_id, async tx => {
    assert.ok(await tx.compareAndSwap('goals', f.goalId, { revision: 1 }, { revision: 2, state: 'revoked' }));
    const action = await tx.records.get(f.owner, 'actions', actionId);
    return tx.records.compareAndSwap(f.owner, 'actions', actionId, { status: action.status }, { status: 'expired' });
  });
  try { await waitForRealLock(); } finally { release.resolve(); }
  assert.ok(await approving); assert.ok(await revoking);
  assert.equal((await repository.transaction(tx => tx.get(f.owner, 'actions', actionId))).status, 'expired');
});

test('real PG: concurrent notification inserts wait on unique constraint and persist one entry', async () => {
  const f = await fixture('notification'), held = deferred(), release = deferred();
  const insert = tx => tx.insertIfAbsent(f.owner, 'catpaw-notifications', { id: 'synthetic-notification-key', schema_version: 1, synthetic: true });
  const first = repository.transaction(async tx => { const value = await insert(tx); held.resolve(); await release.promise; return value; });
  await held.promise; const second = repository.transaction(insert);
  try { await waitForRealLock(); } finally { release.resolve(); }
  assert.ok(await first); assert.equal(await second, null);
  assert.equal((await repository.transaction(tx => tx.list(f.owner, 'catpaw-notifications'))).length, 1);
});

test('real PG remains rejected by the production Goal kernel constructor', () => {
  assert.throws(() => new ProactiveGoalKernel({ foundation: { repository }, authorize() {}, admitTask() {} }), e => e.code === 'production_kernel_disabled');
});
test.after(async () => { await sql.end({ timeout: 2 }); });
