import test from 'node:test';
import assert from 'node:assert/strict';
import {createProactiveService} from '../../../services/edge/supabase/functions/_shared/proactive/service.mjs';
import {createMemoryStore} from '../../../services/edge/supabase/functions/_shared/proactive/memory-store.mjs';
import {UID, T0, latch, check} from './helpers.mjs';

function fixture({store = createMemoryStore(), model = null, apns = null} = {}) {
  const clock = {t: T0};
  const make = () => createProactiveService({store, model, apns, verifyUser: async () => ({sub: UID}), schedulerSecret: 'synthetic-scheduler', now: () => clock.t});
  const service = make();
  const create = (extra = {}) => service.createTask(UID, {operation_id: crypto.randomUUID(), title: 'synthetic-family-reminder', due_at: new Date(T0).toISOString(), time_zone: 'UTC', ...extra});
  return {store, clock, service, make, create};
}
const reminders = store => store._dump().events.filter(e => e.kind === 'reminder_due');
const recurring = {recurrence: {freq: 'interval', interval_seconds: 3600}};
const NEXT = new Date(T0 + 3600000).toISOString();

test('REM-01 a worker lost after claim must recover within two synthetic scheduling periods', async t => {
  const f = fixture(), {task} = await f.create();
  const initial = await f.store.claimDue(new Date(T0).toISOString(), 50);
  assert.equal(initial.length, 1);
  const restarted = f.make(); // New worker/service, same real in-memory store and occurrence set.
  f.clock.t += 60000; const a = await restarted.tick();
  f.clock.t += 60000; const b = await restarted.tick();
  const row = await f.store.getTask(UID, task.id);
  check(t, 'REM-01', {initialClaim: initial.length, recoveryClaims: a.claimed + b.claimed, dueUnresolved: row.next_fire_at !== null, reminderEvents: reminders(f.store).length}, {initialClaim: 1, recoveryClaims: 0, dueUnresolved: true, reminderEvents: 0}, {initialClaim: 1, recoveryClaims: 1, dueUnresolved: false, reminderEvents: 1}, 'Claim abandonment is injected at the store boundary; worker object restart preserves one in-memory store. No process kill, database persistence or SQL lease proof.');
});

test('REM-02 an abandoned first batch must not starve the later 50 due reminders', async t => {
  const f = fixture();
  for (let i = 0; i < 100; i++) await f.create();
  assert.equal((await f.store.claimDue(new Date(T0).toISOString(), 50)).length, 50);
  const restarted = f.make();
  f.clock.t += 60000; const a = await restarted.tick();
  f.clock.t += 60000; const b = await restarted.tick();
  check(t, 'REM-02', {recoveryClaims: a.claimed + b.claimed, reminderEvents: reminders(f.store).length, completedOccurrences: f.store._dump().tasks.filter(r => r.fire_count === 1).length}, {recoveryClaims: 0, reminderEvents: 0, completedOccurrences: 0}, {recoveryClaims: 100, reminderEvents: 100, completedOccurrences: 100}, 'Two synthetic 60-second periods and limit=50; real SQL fairness/lease timing remains unverified.');
});

test('REM-03 cancellation before event commit: 100 controlled interleavings emit no new event or dispatch', {timeout: 15000}, async t => {
  const positions = ['model_wait', 'owner_read_before', 'owner_read_after', 'event_insert_before'];
  const totals = Object.fromEntries(positions.map(p => [p, {iterations: 0, postCancelEvents: 0, dispatches: 0, cancellationRetained: 0}]));
  for (let i = 0; i < 100; i++) {
    const position = positions[i % positions.length], reached = latch(), resume = latch();
    const store = createMemoryStore(); let active = false, consumed = false, dispatches = 0;
    const pause = async point => { if (active && !consumed && position === point) { consumed = true; reached.resolve(); await resume.promise; } };
    const getTask = store.getTask.bind(store), insertEvent = store.insertEvent.bind(store);
    store.getTask = async (...args) => { await pause('owner_read_before'); const row = await getTask(...args); await pause('owner_read_after'); return row; };
    store.insertEvent = async event => { if (event.kind === 'reminder_due') await pause('event_insert_before'); return insertEvent(event); };
    const model = {reminder: async () => { await pause('model_wait'); return 'synthetic-reminder-text'; }};
    const f = fixture({store, model, apns: {configured: true, send: async () => { dispatches++; return {ok: true}; }}});
    await store.upsertToken(UID, {device_id: 'synthetic-device', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'synthetic.family.fixture'});
    const {task} = await f.create(); active = true;
    const pending = f.service.tick();
    await reached.promise;
    const cancelled = await f.service.patchTask(UID, task.id, {status: 'cancelled'});
    assert.equal(cancelled.status, 'cancelled');
    const eventCountAtCancel = reminders(store).length;
    assert.equal(eventCountAtCancel, 0, 'cancellation completed before event commit');
    resume.resolve(); await pending;
    const final = await store.getTask(UID, task.id);
    const n = totals[position]; n.iterations++; n.postCancelEvents += reminders(store).length - eventCountAtCancel; n.dispatches += dispatches; n.cancellationRetained += Number(final.status === 'cancelled' && final.next_fire_at === null);
  }
  const actual = {interleavings: 100, positions: 4, postCancelEvents: Object.values(totals).reduce((n, r) => n + r.postCancelEvents, 0), dispatches: Object.values(totals).reduce((n, r) => n + r.dispatches, 0), cancellationRetained: Object.values(totals).reduce((n, r) => n + r.cancellationRetained, 0)};
  t.diagnostic('FAMILY_INTERLEAVINGS ' + JSON.stringify(totals));
  check(t, 'REM-03', actual, {interleavings: 100, positions: 4, postCancelEvents: 100, dispatches: 100, cancellationRetained: 100}, {interleavings: 100, positions: 4, postCancelEvents: 0, dispatches: 0, cancellationRetained: 100}, 'Dispatches are calls to an inert synthetic APNs adapter; no notification left this process.');
});

test('REM-04 insertEvent failure must preserve due and recover one stable occurrence', async t => {
  const f = fixture(), {task} = await f.create(recurring), original = f.store.insertEvent.bind(f.store);
  let faults = 1;
  f.store.insertEvent = async e => { if (e.kind === 'reminder_due' && faults-- > 0) throw Error('synthetic_event_write_failure'); return original(e); };
  const first = await f.service.tick(); assert.equal(first.results[0].error, 'fire_failed');
  await f.service.tick(); await f.service.tick();
  const row = await f.store.getTask(UID, task.id);
  check(t, 'REM-04', {reminderEvents: reminders(f.store).length, fireCount: row.fire_count, nextFire: row.next_fire_at}, {reminderEvents: 0, fireCount: 1, nextFire: null}, {reminderEvents: 1, fireCount: 1, nextFire: NEXT}, 'Fault before the real store write; not a database COMMIT failure.');
});

test('REM-05 first finishOccurrence failure must not discard the recurring next due', async t => {
  const f = fixture(), {task} = await f.create(recurring), original = f.store.finishOccurrence.bind(f.store);
  let faults = 1;
  f.store.finishOccurrence = async (...args) => { if (faults-- > 0) throw Error('synthetic_finish_failure'); return original(...args); };
  await f.service.tick(); await f.service.tick(); await f.service.tick();
  const row = await f.store.getTask(UID, task.id);
  check(t, 'REM-05', {reminderEvents: reminders(f.store).length, fireCount: row.fire_count, nextFire: row.next_fire_at}, {reminderEvents: 1, fireCount: 1, nextFire: null}, {reminderEvents: 1, fireCount: 1, nextFire: NEXT});
});

test('REM-06 both finish attempts failing must remain recoverable after storage recovers', async t => {
  const f = fixture(), {task} = await f.create(recurring), original = f.store.finishOccurrence.bind(f.store);
  let faults = 2;
  f.store.finishOccurrence = async (...args) => { if (faults-- > 0) throw Error('synthetic_finish_failure'); return original(...args); };
  await f.service.tick(); f.clock.t += 60000; await f.make().tick(); f.clock.t += 60000; await f.make().tick();
  const row = await f.store.getTask(UID, task.id);
  check(t, 'REM-06', {reminderEvents: reminders(f.store).length, fireCount: row.fire_count, nextFire: row.next_fire_at}, {reminderEvents: 1, fireCount: 0, nextFire: new Date(T0).toISOString()}, {reminderEvents: 1, fireCount: 1, nextFire: NEXT});
});

test('REM-07 claim failure before mutation keeps due and a later tick produces one event', async t => {
  const f = fixture(), {task} = await f.create(recurring), original = f.store.claimDue.bind(f.store);
  let faults = 1;
  f.store.claimDue = async (...args) => { if (faults-- > 0) throw Error('synthetic_claim_failure'); return original(...args); };
  await assert.rejects(f.service.tick(), /synthetic_claim_failure/);
  assert.equal((await f.store.getTask(UID, task.id)).next_fire_at, new Date(T0).toISOString());
  await f.service.tick(); await f.service.tick();
  const row = await f.store.getTask(UID, task.id);
  check(t, 'REM-07', {reminderEvents: reminders(f.store).length, fireCount: row.fire_count, nextFire: row.next_fire_at}, {reminderEvents: 1, fireCount: 1, nextFire: NEXT}, {reminderEvents: 1, fireCount: 1, nextFire: NEXT});
});

test('REM-08 lost finish acknowledgement must not duplicate the committed event', async t => {
  const f = fixture(), {task} = await f.create(recurring), original = f.store.finishOccurrence.bind(f.store);
  let faults = 1;
  f.store.finishOccurrence = async (...args) => { const result = await original(...args); if (faults-- > 0) throw Error('synthetic_finish_ack_lost'); return result; };
  const first = await f.service.tick(); assert.equal(first.results[0].error, 'fire_failed');
  await f.service.tick(); await f.service.tick();
  const row = await f.store.getTask(UID, task.id);
  check(t, 'REM-08', {reminderEvents: reminders(f.store).length, fireCount: row.fire_count, nextFire: row.next_fire_at}, {reminderEvents: 1, fireCount: 1, nextFire: NEXT}, {reminderEvents: 1, fireCount: 1, nextFire: NEXT}, 'Durable-state safety only: first tick still reports fire_failed despite a committed result.');
});

test('REM-09 task-created event write failure must reconcile on retry with the same operation identity', async t => {
  const f = fixture(), original = f.store.insertEvent.bind(f.store), operation_id = crypto.randomUUID();
  let faults = 1;
  f.store.insertEvent = async e => { if (e.kind === 'task_created' && faults-- > 0) throw Error('synthetic_created_event_failure'); return original(e); };
  await assert.rejects(f.create({operation_id}), /synthetic_created_event_failure/);
  await f.create({operation_id});
  check(t, 'REM-09', {tasks: f.store._dump().tasks.length, createdEvents: f.store._dump().events.filter(e => e.kind === 'task_created').length}, {tasks: 1, createdEvents: 0}, {tasks: 1, createdEvents: 1}, 'Existing createTask operation identity is retained; this checks a missing creation event, not an external notification.');
});
