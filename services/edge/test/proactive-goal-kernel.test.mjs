import test from 'node:test';
import assert from 'node:assert/strict';
import { Foundation } from '../supabase/functions/_shared/core/integration/server-foundation/src/foundation.mjs';
import { TestRepository } from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import { PostgresTransaction } from '../supabase/functions/_shared/core/integration/server-foundation/src/postgres-repository.mjs';
import { ProactiveGoalKernel } from '../supabase/functions/_shared/core/integration/server-foundation/src/proactive-goal-kernel.mjs';
import { ensure, hash } from '../supabase/functions/_shared/core/integration/server-foundation/src/common.mjs';
import { Facade } from '../supabase/functions/_shared/core/facade-r2/src/facade.mjs';
import { FencedWorkerStore } from '../supabase/functions/_shared/core/facade-r2/src/fenced-worker-store.mjs';
import { stableUUID } from '../supabase/functions/_shared/core/src/local-output-facade.mjs';
import { assertConsent, consentId } from '../supabase/functions/_shared/consent.mjs';
import { membershipOwner } from '../supabase/functions/_shared/authority.mjs';
import { SyntheticGoalAdapter } from './fixtures/synthetic-goal-adapter.mjs';
import { RestoreDispatchBarrier } from '../supabase/functions/_shared/core/integration/server-foundation/src/restore-dispatch-barrier.mjs';
import { SyntheticRestoreAuthority } from './fixtures/synthetic-restore-authority.mjs';

const uid = label => stableUUID(`synthetic-goal-kernel:${label}`);
const start = Date.parse('2026-10-12T12:00:00Z');
const arrival = { schema_version: 1, kind: 'actual_arrival', location: '合成会场', deadline: '2026-10-12T16:00:00Z' };
const delivery = { schema_version: 1, kind: 'delivery_confirmed', report_key: 'synthetic-weekly-report' };
const error = code => e => e.code === code;

async function fixture({ completion = arrival, quiet_until = null } = {}) {
  let millis = start, sequence = 0;
  const repository = new TestRepository();
  const scope = { scope_id: uid('scope'), profile_id: uid('profile'), workspace_id: uid('workspace'), local_output: true };
  const principal = { subject_id: uid('subject'), session_id: uid('session'), issuer: 'https://synthetic.example.invalid/auth/v1', issued_at: 1, scopes: [scope] };
  const foundation = new Foundation(repository, { guardKey: 'synthetic-goal-guard-placeholder', clock: () => new Date(millis) });
  await foundation.bootstrapScope(principal, scope.scope_id);
  const owner = foundation.identity(principal, scope.scope_id).owner, authOwner = membershipOwner(principal.issuer);
  const restoreAuthority = new SyntheticRestoreAuthority({ scope_id: scope.scope_id, incarnation_id: uid('incarnation-1'), valid_until: new Date(start + 86400000).toISOString() });
  const restoreBarrier = new RestoreDispatchBarrier({ readMarker: restoreAuthority.readMarker, authorizeBinding: restoreAuthority.authorizeBinding, clock: () => new Date(millis) });
  await foundation.scoped(principal, scope.scope_id, tx => restoreBarrier.bind(tx.records, owner, scope.scope_id, { expected_revision: 0, review_id: 'synthetic-reviewed-bootstrap' }));
  restoreAuthority.open();
  const authorize = async (tx, { principal: actor, scope: identity }) => {
    const session = await tx.get(authOwner, 'app-sessions', actor.session_id);
    const membership = await tx.get(authOwner, 'scope-memberships', actor.subject_id);
    ensure(session?.state === 'active' && session.subject_id === actor.subject_id && session.expires_at > millis / 1000, 'session_revoked', 401);
    ensure(membership?.state === 'active' && membership.scopes.some(s => s.scope_id === identity.scope_id && s.profile_id === identity.profile_id && s.workspace_id === identity.workspace_id), 'scope_forbidden', 403);
  };
  await repository.transaction(async tx => {
    await tx.put(authOwner, 'app-sessions', { id: principal.session_id, subject_id: principal.subject_id, state: 'active', expires_at: (start + 86400000) / 1000 });
    await tx.put(authOwner, 'scope-memberships', { id: principal.subject_id, state: 'active', scopes: [scope] });
  });
  const facade = new Facade({ repository, authenticate: async () => principal });
  const goalId = uid('goal'), cid = uid('conversation');
  await foundation.createGoal(principal, scope.scope_id, { goal_id: goalId, title: '合成最终目标', description: '仅领域内核测试，无外部任务' });
  const d = (await facade.createDelegation('synthetic', scope.scope_id, { delegation_id: uid('delegation'), title: 'Synthetic existing task', goal: 'Synthetic planning', requirements: 'Supplied evidence only', stop_conditions: ['Hold for approval'], synthetic_fixture_id: 'report' })).delegation;
  const view = await facade.createRun('synthetic', scope.scope_id, d.id, { operation_id: uid('operation'), run_id: uid('run'), expected_revision: 1, expected_grant_epoch: 1 });
  const taskId = view.task.id, leaseId = uid('lease'), runId = view.run.id;
  const source = { subject_id: principal.subject_id, scope_id: scope.scope_id, session_id: principal.session_id, issuer: principal.issuer, issued_at: 1, consent_revision: 1 };
  await repository.transaction(async tx => {
    const run = await tx.get(owner, 'catpaw-runs', runId);
    await tx.put(owner, 'catpaw-runs', { ...run, frozen_request: { ...run.frozen_request, subject_id: principal.subject_id, conversation_id: cid, source_auth: source } });
    await tx.put(owner, 'provider-consents', { id: consentId(principal.subject_id, cid), scope_id: scope.scope_id, subject_id: principal.subject_id, route_hash: 'synthetic-route', revision: 1, decision: 'allow' });
  });
  await foundation.scoped(principal, scope.scope_id, tx => tx.put('conversations', { id: cid, scope_id: scope.scope_id, subject_id: principal.subject_id }));
  await foundation.linkExecution(principal, scope.scope_id, { conversation_id: cid, turn_id: uid('turn'), call_id: 'synthetic-call', delegation_id: d.id,
    operation_id: uid('operation'), run_id: runId, task_id: taskId, request_hash: view.run.request_hash, delegation_revision: 1, grant_epoch: 1, goal_id: goalId });
  const workerStore = new FencedWorkerStore(facade);
  assert.ok(await workerStore.compareAndSwap(owner, 'tasks', taskId, { status: 'queued', leaseId: null }, { status: 'running', leaseId, leaseUntil: new Date(start + 60000).toISOString() }));
  const admitTask = async (tx, actor, id, options) => {
    const admitted = await facade.admittedTask(tx, actor, id, options);
    await assertConsent(tx, actor, admitted.run.frozen_request.source_auth, cid, 'synthetic-route');
    return admitted;
  };
  const makeKernel = (f = foundation, auth = authorize, barrier = restoreBarrier) => new ProactiveGoalKernel({ foundation: f, authorize: auth, admitTask, restoreBarrier: barrier });
  const kernel = makeKernel();
  const initial = await kernel.confirmGoal(principal, scope.scope_id, goalId, { schema_version: 1, expected_revision: 1, completion, quiet_until });
  const control = { assertLive: () => ensure(millis < start + 50000, 'invocation_closed', 409) };
  const adapter = new SyntheticGoalAdapter();
  const goal = () => foundation.scoped(principal, scope.scope_id, tx => tx.get('goals', goalId));
  const action = id => repository.transaction(tx => tx.get(owner, 'actions', id));
  const events = () => foundation.scoped(principal, scope.scope_id, tx => tx.list('events'));
  const observe = (type, payload, revision = 1, source_key = `synthetic:${type}`) => kernel.ingestSyntheticEvent(principal, scope.scope_id, goalId, { schema_version: 1, source_key, revision, type, payload }, adapter);
  const propose = async (observation, overrides = {}, k = kernel) => {
    const g = await goal();
    return k.propose(principal, scope.scope_id, goalId, { schema_version: 1, proposal_id: uid(`proposal-${++sequence}`), goal_version: g.revision,
      task_id: taskId, lease_id: leaseId, evidence_ids: [observation.event.id], operation: completion.kind === 'actual_arrival' ? 'purchase' : 'send_report',
      arguments: { synthetic_option: 'B', estimated_arrival: '14:00' }, summary: '基于当前合成证据，待用户批准', expires_at: new Date(start + 3600000).toISOString(), ...overrides }, control);
  };
  const decide = (a, decision = 'approve', k = kernel) => k.decide(principal, scope.scope_id, a.id, { schema_version: 1, goal_version: a.data.goal_version, action_digest: a.hash, decision });
  const dispatch = (a, aAdapter = adapter, k = kernel) => k.dispatchSynthetic(principal, scope.scope_id, a.id, { lease_id: leaseId, control }, aAdapter);
  const change = async (state, extra = {}) => kernel.changeGoal(principal, scope.scope_id, goalId, { schema_version: 1, expected_revision: (await goal()).revision, state, ...extra });
  return { repository, foundation, kernel, scope, principal, owner, authOwner, facade, goalId, taskId, leaseId, control, adapter, initial,
    makeKernel, goal, action, events, observe, propose, decide, dispatch, change, restoreAuthority, restoreBarrier, now: () => millis, advance: ms => { millis += ms; } };
}
const delayedArrival = f => f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T17:00:00Z' });

test('travel: evidence-bound alternative waits for explicit approval; estimate 14:00 is not actual arrival', async () => {
  const f = await fixture(), evidence = await delayedArrival(f), a = await f.propose(evidence);
  assert.equal(a.status, 'awaiting_review'); assert.equal(f.adapter.effect_calls, 0);
  await assert.rejects(f.dispatch(a), error('approval_consumed'));
  await f.decide(a); assert.equal((await f.dispatch(a)).status, 'succeeded');
  assert.equal((await f.goal()).proactive.state, 'active');
  await f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T14:00:00Z' }, 2);
  assert.equal((await f.goal()).proactive.state, 'active');
  await f.observe('actual_arrival', { location: '合成机场', at: '2026-10-12T14:00:00Z' });
  assert.equal((await f.goal()).proactive.state, 'active');
  await f.observe('actual_arrival', { location: '合成会场', at: '2026-10-12T15:45:00Z' }, 2);
  assert.equal((await f.goal()).proactive.state, 'active', 'Future timestamp is not an actual arrival');
  f.advance(13500000);
  await f.observe('actual_arrival', { location: '合成会场', at: '2026-10-12T15:45:00Z' }, 3);
  assert.equal((await f.goal()).proactive.state, 'completed');
  assert.equal((await f.repository.transaction(tx => tx.get(f.owner, 'tasks', f.taskId))).status, 'cancelled');
});

test('report generation, provider acceptance and reconciled effect do not mean confirmed delivery', async () => {
  const f = await fixture({ completion: delivery });
  const evidence = await f.observe('report_generated', { report_key: delivery.report_key, artifact_hash: hash('synthetic generated report') });
  assert.equal((await f.goal()).proactive.state, 'active');
  const a = await f.propose(evidence), adapter = new SyntheticGoalAdapter({ loseAcknowledgement: true });
  await f.decide(a); assert.equal((await f.dispatch(a, adapter)).status, 'outcome_unknown');
  assert.equal((await f.kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, adapter)).status, 'succeeded');
  assert.equal((await f.goal()).proactive.state, 'active');
  await f.observe('delivery_confirmed', { report_key: 'another-report', receipt_id: 'synthetic-receipt' });
  assert.equal((await f.goal()).proactive.state, 'active');
  await f.observe('delivery_confirmed', { report_key: delivery.report_key, receipt_id: 'synthetic-independent-delivery-receipt' }, 2);
  assert.equal((await f.goal()).proactive.state, 'completed');
});

test('event duplicate is idempotent; conflicting same revision rejects; later-ingested older revision cannot replace head', async () => {
  const f = await fixture(), newest = await f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T17:00:00Z' }, 4);
  const count = (await f.events()).length;
  const duplicate = await f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T17:00:00Z' }, 4);
  assert.equal(duplicate.disposition, 'duplicate'); assert.equal(duplicate.event.id, newest.event.id);
  assert.equal((await f.events()).length, count);
  await assert.rejects(f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T14:00:00Z' }, 4), error('event_revision_conflict'));
  assert.equal((await f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T14:00:00Z' }, 2)).disposition, 'out_of_order');
  assert.equal((await f.goal()).revision, newest.goal.revision);
});

test('CAS version race has one winner; goal update expires both suggestion and approval', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const input = { schema_version: 1, expected_revision: e.goal.revision, state: 'active' };
  const results = await Promise.allSettled([f.kernel.changeGoal(f.principal, f.scope.scope_id, f.goalId, input), f.kernel.changeGoal(f.principal, f.scope.scope_id, f.goalId, input)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(results.find(r => r.status === 'rejected').reason.code, 'goal_version_conflict');
  assert.equal((await f.action(a.id)).status, 'expired');
  await assert.rejects(f.decide(a), error('goal_version_conflict')); await assert.rejects(f.dispatch(a), error('goal_version_conflict'));
  assert.equal(f.adapter.effect_calls, 0);
});

test('accepted event correction expires approvals and excludes superseded evidence from new proposals', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  await f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T18:00:00Z' }, 2);
  await assert.rejects(f.propose(e), error('evidence_superseded'));
  assert.equal((await f.action(a.id)).status, 'expired');
});

test('cross tenant and same-scope other subject cannot adopt goals, approve or dispatch', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e);
  const stranger = { ...f.principal, subject_id: uid('other-subject'), session_id: uid('other-session') };
  await f.repository.transaction(async tx => {
    await tx.put(f.authOwner, 'app-sessions', { id: stranger.session_id, subject_id: stranger.subject_id, state: 'active', expires_at: (start + 100000) / 1000 });
    await tx.put(f.authOwner, 'scope-memberships', { id: stranger.subject_id, state: 'active', scopes: [f.scope] });
  });
  await assert.rejects(f.kernel.decide(stranger, f.scope.scope_id, a.id, { schema_version: 1, goal_version: a.data.goal_version, action_digest: a.hash, decision: 'approve' }), error('not_found'));
  await assert.rejects(f.kernel.changeGoal(stranger, f.scope.scope_id, f.goalId, { schema_version: 1, expected_revision: e.goal.revision, state: 'revoked' }), error('not_found'));
  await assert.rejects(f.kernel.confirmGoal(f.principal, uid('other-scope'), f.goalId, { schema_version: 1, expected_revision: 1, completion: arrival }), error('scope_forbidden'));
  await assert.rejects(f.kernel.dispatchSynthetic(stranger, f.scope.scope_id, a.id, { lease_id: f.leaseId, control: f.control }, f.adapter), error('not_found'));
  assert.equal(f.adapter.dispatch_calls, 0);
});

for (const state of ['paused', 'revoked']) test(`${state} stops existing task lease, actions and pending notifications`, async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a); await f.change(state);
  await assert.rejects(f.dispatch(a), error('goal_stopped')); assert.equal(f.adapter.effect_calls, 0);
  const task = await f.repository.transaction(tx => tx.get(f.owner, 'tasks', f.taskId));
  assert.equal(task.leaseId, null); assert.equal(task.status, state === 'paused' ? 'paused' : 'cancelled');
  assert.deepEqual(await f.kernel.publishSyntheticInbox(f.principal, f.scope.scope_id), []);
});

test('user completes independently: cancel pending purchase and never regain permissions on new observation', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  await assert.rejects(f.kernel.ingestSyntheticEvent(f.principal, f.scope.scope_id, f.goalId, { schema_version: 1, source_key: 'external', revision: 1, type: 'user_completed', payload: { statement: 'User is done' } }, f.adapter), error('untrusted_completion'));
  await f.kernel.ingestUserEvent(f.principal, f.scope.scope_id, f.goalId, { schema_version: 1, source_key: 'user-completion', revision: 1, type: 'user_completed', payload: { statement: '我已经自行到会场了' } });
  await assert.rejects(f.dispatch(a), error('goal_stopped'));
  await assert.rejects(f.change('active'), error('goal_stopped'));
  await assert.rejects(f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T13:00:00Z' }, 2), error('goal_stopped'));
});

test('worker lease loss, lease replacement and invocation reserve close prevent effects', async () => {
  for (const mode of ['expired', 'replaced', 'budget']) {
    const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
    if (mode === 'budget') f.advance(50000);
    else await f.repository.transaction(tx => tx.compareAndSwap(f.owner, 'tasks', f.taskId, { leaseId: f.leaseId }, mode === 'expired' ? { leaseUntil: new Date(start).toISOString() } : { leaseId: uid('successor-lease') }));
    await assert.rejects(f.dispatch(a), error(mode === 'budget' ? 'invocation_closed' : 'lease_lost'));
    assert.equal(f.adapter.effect_calls, 0);
  }
});

test('revocation at transport boundary checks again; no effect and durable unknown is read-only reconcilable', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const adapter = new SyntheticGoalAdapter({ beforeEffect: () => f.change('revoked') });
  assert.equal((await f.dispatch(a, adapter)).status, 'outcome_unknown'); assert.equal(adapter.effect_calls, 0);
  await f.kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, adapter);
  assert.equal(adapter.dispatch_calls, 1); assert.equal(adapter.reconcile_calls, 1);
  assert.equal((await f.goal()).proactive.state, 'revoked');
});

test('fresh session and existing provider consent are checked before effect', async () => {
  for (const mode of ['session', 'consent']) {
    const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
    await f.repository.transaction(tx => mode === 'session'
      ? tx.compareAndSwap(f.authOwner, 'app-sessions', f.principal.session_id, { state: 'active' }, { state: 'revoked' })
      : tx.compareAndSwap(f.owner, 'provider-consents', consentId(f.principal.subject_id, uid('conversation')), { revision: 1 }, { decision: 'deny', revision: 2 }));
    await assert.rejects(f.dispatch(a), error(mode === 'session' ? 'session_revoked' : 'provider_consent_required'));
    assert.equal(f.adapter.dispatch_calls, 0);
  }
});

test('unknown acknowledgement survives repository restore; never replay, including a new goal version', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const adapter = new SyntheticGoalAdapter({ loseAcknowledgement: true });
  assert.equal((await f.dispatch(a, adapter)).status, 'outcome_unknown');
  const restored = new TestRepository(f.repository.snapshot()), foundation = new Foundation(restored, { guardKey: 'synthetic-restored-guard-placeholder', clock: () => new Date(f.now()) });
  const kernel = f.makeKernel(foundation), resumedAdapter = new SyntheticGoalAdapter({ effects: adapter.snapshot() });
  await assert.rejects(f.dispatch(a, resumedAdapter, kernel), error('reconciliation_required'));
  await f.change('active'); await assert.rejects(f.propose(e), error('reconciliation_required'));
  assert.equal((await kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, resumedAdapter)).status, 'succeeded');
  assert.equal(resumedAdapter.dispatch_calls, 0); assert.equal(adapter.effect_calls, 1);
  assert.equal((await f.goal()).proactive.state, 'active');
});

test('lost lease after effect records unknown instead of acknowledging success or repeating', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const adapter = new SyntheticGoalAdapter({ afterEffect: () => f.repository.transaction(tx => tx.compareAndSwap(f.owner, 'tasks', f.taskId, { leaseId: f.leaseId }, { leaseId: uid('successor') })) });
  assert.equal((await f.dispatch(a, adapter)).status, 'outcome_unknown');
  assert.equal(adapter.effect_calls, 1);
  await assert.rejects(f.dispatch(a, adapter), error('reconciliation_required'));
  await f.kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, adapter);
  assert.equal((await f.goal()).proactive.state, 'active');
});

test('unknown/no-effect lookup does not authorize retry; not-applied receipt needs a fresh proposal', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const adapter = new SyntheticGoalAdapter({ beforeEffect: () => { throw new Error('synthetic interruption'); } });
  assert.equal((await f.dispatch(a, adapter)).status, 'outcome_unknown');
  assert.equal((await f.kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, adapter)).status, 'outcome_unknown');
  await assert.rejects(f.propose(e), error('reconciliation_required'));
  adapter.reconcile = async ({ effect_key }) => ({ schema_version: 1, synthetic: true, state: 'not_applied', effect_key });
  assert.equal((await f.kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, adapter)).status, 'failed');
  const next = await f.propose(e); assert.equal(next.status, 'awaiting_review');
  assert.equal(adapter.effect_calls, 0);
});

test('quiet period suppresses notification; restored outbox publishes one deduplicated inbox entry', async () => {
  const f = await fixture({ quiet_until: new Date(start + 1000).toISOString() }), e = await delayedArrival(f), a = await f.propose(e);
  // Same proposal retry emits neither a new decision nor a second outbox entry.
  await f.propose(e, { proposal_id: a.id });
  assert.deepEqual(await f.kernel.publishSyntheticInbox(f.principal, f.scope.scope_id), []);
  f.advance(1001);
  const restored = new TestRepository(f.repository.snapshot()), foundation = new Foundation(restored, { guardKey: 'synthetic-restored-guard-placeholder', clock: () => new Date(f.now()) }), kernel = f.makeKernel(foundation);
  assert.equal((await kernel.publishSyntheticInbox(f.principal, f.scope.scope_id)).length, 1);
  assert.deepEqual(await kernel.publishSyntheticInbox(f.principal, f.scope.scope_id), []);
  assert.equal((await restored.transaction(tx => tx.list(f.owner, 'catpaw-notifications'))).length, 1);
});

test('outbox + proposal roll back atomically if authority fails after writes', async () => {
  const f = await fixture(), e = await delayedArrival(f); let checks = 0;
  const kernel = f.makeKernel(f.foundation, async () => { ensure(++checks < 2, 'session_revoked', 401); });
  await assert.rejects(f.propose(e, {}, kernel), error('session_revoked'));
  assert.equal((await f.repository.transaction(tx => tx.list(f.owner, 'actions'))).length, 0);
  assert.equal((await f.repository.transaction(tx => tx.list(f.owner, 'catpaw-notification-outbox'))).length, 0);
});

test('final authority await cannot carry proposal across worker lease expiry', async () => {
  const f = await fixture(), e = await delayedArrival(f); let checks = 0;
  const kernel = f.makeKernel(f.foundation, async () => { if (++checks === 2) f.advance(60001); });
  await assert.rejects(f.propose(e, {}, kernel), error('invocation_closed'));
  assert.equal((await f.repository.transaction(tx => tx.list(f.owner, 'actions'))).length, 0);
});

test('approved proposal expires by clock; user denial is idempotent and cannot dispatch', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e, { expires_at: new Date(start + 1000).toISOString() });
  await f.decide(a); f.advance(1001);
  await assert.rejects(f.dispatch(a), error('proposal_expired'));
  const denied = await f.propose(e);
  assert.equal((await f.action(a.id)).status, 'expired');
  assert.equal((await f.decide(denied, 'deny')).status, 'denied');
  const count = (await f.events()).length;
  assert.equal((await f.decide(denied, 'deny')).status, 'denied'); assert.equal((await f.events()).length, count);
  await assert.rejects(f.dispatch(denied), error('approval_consumed')); assert.equal(f.adapter.effect_calls, 0);
});

test('arrival after 16:00 fails time-bound completion and a stale quiet-period message is cancelled', async () => {
  const f = await fixture({ quiet_until: new Date(start + 1000).toISOString() }), e = await delayedArrival(f);
  await f.propose(e);
  await f.observe('arrival_estimate', { location: '合成会场', at: '2026-10-12T18:00:00Z' }, 2);
  f.advance(18000000);
  await f.observe('actual_arrival', { location: '合成会场', at: '2026-10-12T17:00:00Z' });
  assert.equal((await f.goal()).proactive.state, 'active');
  assert.deepEqual(await f.kernel.publishSyntheticInbox(f.principal, f.scope.scope_id), []);
  assert.equal((await f.repository.transaction(tx => tx.list(f.owner, 'catpaw-notification-outbox')))[0].state, 'cancelled');
});

test('outcome publication cannot consume finalization reserve after its final authority await', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a); let checks = 0;
  const kernel = f.makeKernel(f.foundation, async (_tx, { operation }) => { if (operation === 'settle' && ++checks === 2) f.advance(50000); });
  assert.equal((await f.dispatch(a, f.adapter, kernel)).status, 'outcome_unknown');
  assert.equal(f.adapter.effect_calls, 1);
  assert.equal((await f.events()).filter(e => e.type === 'goal_action_outcome').length, 0);
  assert.equal((await f.goal()).proactive.state, 'active');
});

test('unsupported version, third-party permission text, expired proposals and non-synthetic adapters fail closed', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e);
  await assert.rejects(f.kernel.ingestUserEvent(f.principal, f.scope.scope_id, f.goalId, { schema_version: 2 }), error('contract_version_unsupported'));
  await assert.rejects(f.kernel.ingestSyntheticEvent(f.principal, f.scope.scope_id, f.goalId, { schema_version: 1, source_key: 'external', revision: 1, type: 'arrival_estimate', payload: { location: '合成会场', at: '2026-10-12T14:00:00Z', permissions: ['purchase', 'send_report'] } }, f.adapter), error('schema_invalid'));
  await assert.rejects(f.dispatch(a, { schema_version: 1, synthetic: false }), error('real_adapter_disabled'));
  await assert.rejects(f.propose(e, { expires_at: '2026-10-12T11:00:00Z' }), error('proposal_expired'));
  await assert.rejects(f.decide({ ...a, hash: hash('tampered') }), error('approval_stale'));
  const repository = { transaction() {}, execution_layer: 'postgres_unverified' };
  assert.throws(() => new ProactiveGoalKernel({ foundation: { repository }, authorize() {}, admitTask() {} }), error('production_kernel_disabled'));
  assert.equal(f.adapter.effect_calls, 0);
});

test('scoped CAS SQL uses scope predicate and parameterized JSON; serializer test is not real PG evidence', async () => {
  const calls = [], connection = { query: async (sql, args) => { calls.push({ sql, args }); return { rows: [{ data: { revision: 3 } }] }; } };
  const tx = new PostgresTransaction(connection, uid('sql-scope'));
  assert.deepEqual(await tx.compareAndSwap('goals', uid('sql-goal'), { revision: 2 }, { revision: 3 }), { revision: 3 });
  assert.match(calls[0].sql, /scope_id=\$1 AND id=\$2/); assert.match(calls[0].sql, /IS DISTINCT FROM/);
  assert.deepEqual(calls[0].args, [uid('sql-scope'), uid('sql-goal'), '{"revision":2}', '{"revision":3}']);
  await assert.rejects(tx.compareAndSwap('events', uid('immutable'), {}, {}), error('immutable_or_duplicate'));
  await assert.rejects(tx.compareAndSwap('goals', uid('sql-goal'), {}, { scope_id: uid('other-scope') }), error('identity_patch_forbidden'));
});

test('adversarial: stopping a goal rejects a binding to another subject task before clearing its lease', async () => {
  const f = await fixture();
  await f.repository.transaction(async tx => {
    const run = await tx.get(f.owner, 'catpaw-runs', uid('run'));
    await tx.put(f.owner, 'catpaw-runs', { ...run, frozen_request: { ...run.frozen_request, subject_id: uid('victim-subject') } });
  });
  await assert.rejects(f.change('revoked'), error('goal_task_binding_conflict'));
  const task = await f.repository.transaction(tx => tx.get(f.owner, 'tasks', f.taskId));
  assert.equal(task.status, 'running'); assert.equal(task.leaseId, f.leaseId);
  assert.equal((await f.goal()).proactive.state, 'active');
});

test('adversarial: binding and run scope mismatch cannot cancel another scope task', async () => {
  const f = await fixture();
  await f.repository.transaction(async tx => {
    const run = await tx.get(f.owner, 'catpaw-runs', uid('run'));
    await tx.put(f.owner, 'catpaw-runs', { ...run, frozen_request: { ...run.frozen_request, scope: { ...run.frozen_request.scope, scope_id: uid('victim-scope') } } });
  });
  await assert.rejects(f.change('paused'), error('goal_task_binding_conflict'));
  assert.equal((await f.repository.transaction(tx => tx.get(f.owner, 'tasks', f.taskId))).leaseId, f.leaseId);
});

test('adversarial: approved projection without immutable user Decision cannot grant action permission', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e);
  await f.repository.transaction(async tx => {
    await tx.compareAndSwap(f.owner, 'actions', a.id, { status: 'awaiting_review' }, { status: 'approved' });
    const b = await tx.get(f.owner, 'catpaw-approval-bindings', a.id);
    await tx.put(f.owner, 'catpaw-approval-bindings', { ...b, decision: 'approve' });
  });
  await assert.rejects(f.dispatch(a), error('action_permission_required')); assert.equal(f.adapter.effect_calls, 0);
});

test('adversarial: lease expiry during last approval read prevents synchronous adapter effect', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  f.control.assertLive = () => {}; // Isolate task lease from the shorter invocation budget.
  const original = f.repository.transaction.bind(f.repository); let reads = 0;
  f.repository.transaction = (scope, fn) => typeof scope === 'function' ? original(scope) : original(scope, async tx => {
    const get = tx.records.get.bind(tx.records);
    tx.records.get = async (...args) => {
      const row = await get(...args);
      if (args[1] === 'catpaw-approval-bindings' && ++reads === 4) f.advance(60001);
      return row;
    };
    return fn(tx);
  });
  assert.equal((await f.dispatch(a)).status, 'outcome_unknown');
  assert.equal(f.adapter.effect_calls, 0);
});

test('adversarial: latest deletion tombstone blocks restoring stale Goal and approved Action', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const staleGoal = await f.goal(), staleAction = await f.action(a.id);
  if (typeof f.kernel.deleteGoal === 'function') {
    await f.kernel.deleteGoal(f.principal, f.scope.scope_id, f.goalId, { schema_version: 1, expected_revision: staleGoal.revision });
  } else await f.foundation.scoped(f.principal, f.scope.scope_id, tx => tx.remove('goals', f.goalId));
  await f.foundation.scoped(f.principal, f.scope.scope_id, tx => tx.put('goals', staleGoal));
  await f.repository.transaction(tx => tx.put(f.owner, 'actions', staleAction));
  // Only authority/tombstone is current; stale content restored through the privileged store path.
  await assert.rejects(f.dispatch(a), error('goal_deleted'));
  assert.equal(f.adapter.effect_calls, 0);
});

test('adversarial: cross-goal and cross-scope evidence references reject before proposal persistence', async () => {
  const f = await fixture(), otherGoal = uid('other-goal');
  await f.foundation.createGoal(f.principal, f.scope.scope_id, { goal_id: otherGoal, title: 'Synthetic other goal', description: 'Synthetic unrelated scope evidence' });
  await f.kernel.confirmGoal(f.principal, f.scope.scope_id, otherGoal, { schema_version: 1, expected_revision: 1, completion: arrival });
  const e = await f.kernel.ingestSyntheticEvent(f.principal, f.scope.scope_id, otherGoal, { schema_version: 1, source_key: 'other-source', revision: 1, type: 'arrival_estimate', payload: { location: '合成会场', at: '2026-10-12T17:00:00Z' } }, f.adapter);
  await assert.rejects(f.propose(e), error('evidence_superseded'));
  const foreignScope = { ...f.scope, scope_id: uid('foreign-scope') };
  f.principal.scopes.push(foreignScope); await f.foundation.bootstrapScope(f.principal, foreignScope.scope_id);
  const foreign = await f.foundation.scoped(f.principal, foreignScope.scope_id, tx => f.foundation.emit(tx, 'goal_observed', { goal_id: f.goalId }));
  await assert.rejects(f.propose({ event: foreign }), error('not_found'));
  assert.equal((await f.repository.transaction(tx => tx.list(f.owner, 'actions'))).length, 0);
});

test('adversarial: concurrent user approval and revoke leave no usable approval or worker lease', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e);
  const results = await Promise.allSettled([f.decide(a), f.change('revoked')]);
  assert.equal(results[1].status, 'fulfilled'); assert.equal((await f.goal()).proactive.state, 'revoked');
  await assert.rejects(f.dispatch(a), error('goal_stopped')); assert.equal(f.adapter.effect_calls, 0);
  assert.equal((await f.repository.transaction(tx => tx.get(f.owner, 'tasks', f.taskId))).leaseId, null);
});

test('adversarial: competing dispatches and restored unknown never replay a single effect', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const adapter = new SyntheticGoalAdapter({ loseAcknowledgement: true });
  const results = await Promise.allSettled([f.dispatch(a, adapter), f.dispatch(a, adapter)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(results.find(r => r.status === 'rejected').reason.code, 'reconciliation_required');
  assert.equal(adapter.effect_calls, 1);
  const restored = new TestRepository(f.repository.snapshot()), foundation = new Foundation(restored, { guardKey: 'synthetic-restored-guard-placeholder', clock: () => new Date(f.now()) });
  await assert.rejects(f.dispatch(a, adapter, f.makeKernel(foundation)), error('reconciliation_required'));
  assert.equal(adapter.dispatch_calls, 1);
});

test('adversarial: concurrent inbox publishers and stale outbox restore preserve one stored notification', async () => {
  const f = await fixture(), e = await delayedArrival(f); await f.propose(e);
  const pending = await f.repository.transaction(tx => tx.list(f.owner, 'catpaw-notification-outbox'));
  const results = await Promise.all([f.kernel.publishSyntheticInbox(f.principal, f.scope.scope_id), f.kernel.publishSyntheticInbox(f.principal, f.scope.scope_id)]);
  assert.equal(results.flat().length, 1);
  // Keep latest inbox uniqueness ledger while restoring only stale pending outbox rows.
  await f.repository.transaction(async tx => { for (const row of pending) await tx.put(f.owner, 'catpaw-notification-outbox', row); });
  assert.deepEqual(await f.kernel.publishSyntheticInbox(f.principal, f.scope.scope_id), []);
  assert.equal((await f.repository.transaction(tx => tx.list(f.owner, 'catpaw-notifications'))).length, 1);
});

test('adversarial: logical deletion is atomic; unknown remains audit-reconcilable after Goal body removal', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const adapter = new SyntheticGoalAdapter({ loseAcknowledgement: true }); await f.dispatch(a, adapter);
  let checks = 0; const failed = f.makeKernel(f.foundation, async () => { ensure(++checks < 2, 'session_revoked', 401); });
  const input = { schema_version: 1, expected_revision: (await f.goal()).revision };
  await assert.rejects(failed.deleteGoal(f.principal, f.scope.scope_id, f.goalId, input), error('session_revoked'));
  assert.equal((await f.repository.transaction(tx => tx.list(f.owner, 'catpaw-goal-tombstones'))).length, 0);
  await f.kernel.deleteGoal(f.principal, f.scope.scope_id, f.goalId, input);
  await assert.rejects(f.foundation.scoped(f.principal, f.scope.scope_id, tx => f.kernel.goal(tx, { subject_id: uid('foreign-deleted-subject') }, f.goalId)), error('not_found'));
  await f.foundation.scoped(f.principal, f.scope.scope_id, tx => tx.remove('goals', f.goalId));
  assert.equal((await f.kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, adapter)).status, 'succeeded');
  await assert.rejects(f.dispatch(a, adapter), error('goal_deleted'));
  assert.deepEqual(await f.kernel.publishSyntheticInbox(f.principal, f.scope.scope_id), []);
  assert.equal(adapter.dispatch_calls, 1);
});

test('known limitation: undetected full rollback with unchanged trusted external marker can replay', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const stale = f.repository.snapshot(), first = new SyntheticGoalAdapter({ loseAcknowledgement: true });
  await f.dispatch(a, first); assert.equal(first.effect_calls, 1);
  await f.kernel.deleteGoal(f.principal, f.scope.scope_id, f.goalId, { schema_version: 1, expected_revision: (await f.goal()).revision });
  // Deliberately unsafe test-only full rollback loses tombstone AND executing/unknown effects ledger.
  const rolledBack = new TestRepository(stale), foundation = new Foundation(rolledBack, { guardKey: 'synthetic-unsafe-restore-placeholder', clock: () => new Date(f.now()) });
  const second = new SyntheticGoalAdapter(); await f.dispatch(a, second, f.makeKernel(foundation));
  assert.equal(second.effect_calls, 1, 'This reproduces duplicate intent after an unsafe full rollback, not a safety PASS');
  assert.equal((await rolledBack.transaction(tx => tx.list(f.owner, 'catpaw-goal-tombstones'))).length, 0);
});

test('adversarial: corrupt effect key cannot bypass unknown reservation or misdirect reconciliation', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const adapter = new SyntheticGoalAdapter({ loseAcknowledgement: true }); await f.dispatch(a, adapter);
  await f.repository.transaction(tx => tx.compareAndSwap(f.owner, 'actions', a.id, { status: 'outcome_unknown' }, { effect_key: hash('synthetic-corrupted-key') }));
  await assert.rejects(f.propose(e), error('proposal_corrupt'));
  await assert.rejects(f.kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, adapter), error('proposal_corrupt'));
  assert.equal(adapter.dispatch_calls, 1); assert.equal(adapter.reconcile_calls, 0);
});

test('restore barrier: missing authority fails closed while effect inspection stays read-only', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const missing = f.makeKernel(f.foundation, undefined, null);
  await assert.rejects(f.dispatch(a, f.adapter, missing), error('restore_authority_missing'));
  const before = f.repository.snapshot();
  const read = await missing.inspectEffectSynthetic(f.principal, f.scope.scope_id, a.id, f.adapter);
  assert.equal(read.read_only, true); assert.equal(read.receipt.state, 'unknown');
  assert.deepEqual(f.repository.snapshot(), before); assert.equal(f.adapter.dispatch_calls, 0);
});

test('restore barrier: locked, missing, expired, wrong-scope and unavailable markers forbid dispatch', async () => {
  for (const mode of ['locked', 'missing', 'expired', 'scope', 'unavailable']) {
    const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
    const expected = { locked: 'restore_dispatch_locked', missing: 'restore_authority_missing', expired: 'restore_marker_expired', scope: 'restore_marker_scope_conflict', unavailable: 'restore_authority_unavailable' }[mode];
    if (mode === 'locked') f.restoreAuthority.lock();
    if (mode === 'missing') f.restoreAuthority.available = false;
    if (mode === 'expired') f.restoreAuthority.current.valid_until = new Date(f.now()).toISOString();
    if (mode === 'scope') f.restoreAuthority.current.scope_id = uid('foreign-marker-scope');
    if (mode === 'unavailable') f.restoreBarrier.readMarker = async () => { throw new Error('synthetic_external_unavailable'); };
    await assert.rejects(f.dispatch(a), error(expected)); assert.equal(f.adapter.dispatch_calls, 0);
    assert.equal((await f.kernel.inspectEffectSynthetic(f.principal, f.scope.scope_id, a.id, f.adapter)).read_only, true);
  }
});

test('restore barrier: absent database binding and marker mismatch cannot fall back to same-DB epochs', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const snapshot = f.repository.snapshot(); snapshot.records = snapshot.records.filter(([key]) => JSON.parse(key)[1] !== 'catpaw-recovery-bindings');
  const restored = new TestRepository(snapshot), foundation = new Foundation(restored, { guardKey: 'synthetic-restored-marker-placeholder', clock: () => new Date(f.now()) });
  await assert.rejects(f.dispatch(a, f.adapter, f.makeKernel(foundation)), error('restore_binding_missing'));
  f.restoreAuthority.current.recovery_epoch++;
  await assert.rejects(f.dispatch(a), error('restore_binding_mismatch')); assert.equal(f.adapter.effect_calls, 0);
});

test('restore barrier: whole rollback with trusted external restore lock/rotation rejects old approved action', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const stale = f.repository.snapshot(), first = new SyntheticGoalAdapter({ loseAcknowledgement: true });
  await f.dispatch(a, first); assert.equal(first.effect_calls, 1);
  await f.kernel.deleteGoal(f.principal, f.scope.scope_id, f.goalId, { schema_version: 1, expected_revision: (await f.goal()).revision });
  f.restoreAuthority.restore(uid('incarnation-after-full-restore'));
  const restored = new TestRepository(stale), foundation = new Foundation(restored, { guardKey: 'synthetic-restored-barrier-placeholder', clock: () => new Date(f.now()) }), kernel = f.makeKernel(foundation), second = new SyntheticGoalAdapter();
  await assert.rejects(f.dispatch(a, second, kernel), error('restore_dispatch_locked'));
  const inspection = await kernel.inspectEffectSynthetic(f.principal, f.scope.scope_id, a.id, first);
  assert.equal(inspection.receipt.state, 'confirmed'); assert.equal((await restored.transaction(tx => tx.get(f.owner, 'actions', a.id))).status, 'approved');
  f.restoreAuthority.open();
  await assert.rejects(f.dispatch(a, second, kernel), error('restore_binding_mismatch'));
  f.restoreAuthority.lock();
  await foundation.scoped(f.principal, f.scope.scope_id, tx => f.restoreBarrier.bind(tx.records, f.owner, f.scope.scope_id, { expected_revision: 1, review_id: 'synthetic-reviewed-full-restore' }));
  f.restoreAuthority.open();
  await assert.rejects(f.dispatch(a, second, kernel), error('restore_fence_mismatch'));
  assert.equal(second.dispatch_calls, 0); assert.equal(second.effect_calls, 0);
});

test('restore barrier: operator review is required, binding only runs while locked, and old approvals expire after rebind', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const bind = review_id => f.foundation.scoped(f.principal, f.scope.scope_id, tx => f.restoreBarrier.bind(tx.records, f.owner, f.scope.scope_id, { expected_revision: 1, review_id }));
  await assert.rejects(bind('synthetic-reviewed-open'), error('restore_dispatch_locked'));
  f.restoreAuthority.lock(); await assert.rejects(bind('unreviewed'), error('restore_binding_operator_required'));
  await bind('synthetic-reviewed-manual-lock'); f.restoreAuthority.open();
  await assert.rejects(f.dispatch(a), error('restore_fence_mismatch')); assert.equal(f.adapter.effect_calls, 0);
});

test('restore barrier: marker change during operator binding rolls back database marker update', async () => {
  const f = await fixture(); f.restoreAuthority.lock();
  const barrier = new RestoreDispatchBarrier({ readMarker: f.restoreAuthority.readMarker, authorizeBinding: async () => { f.restoreAuthority.restore(uid('racing-restore')); return true; }, clock: () => new Date(f.now()) });
  await assert.rejects(f.foundation.scoped(f.principal, f.scope.scope_id, tx => barrier.bind(tx.records, f.owner, f.scope.scope_id, { expected_revision: 1, review_id: 'synthetic-reviewed-race' })), error('restore_marker_changed'));
  assert.equal((await f.repository.transaction(tx => tx.get(f.owner, 'catpaw-recovery-bindings', f.scope.scope_id))).revision, 1);
});

test('restore barrier: lock at transport boundary prevents effect; lock after effect retains unknown for reconciliation', async () => {
  for (const phase of ['before', 'after']) {
    const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
    const adapter = new SyntheticGoalAdapter({ ...(phase === 'before' ? { beforeEffect: async () => f.restoreAuthority.lock() } : { afterEffect: async () => f.restoreAuthority.lock() }) });
    assert.equal((await f.dispatch(a, adapter)).status, 'outcome_unknown'); assert.equal(adapter.effect_calls, phase === 'before' ? 0 : 1);
    const read = await f.kernel.inspectEffectSynthetic(f.principal, f.scope.scope_id, a.id, adapter); assert.equal(read.read_only, true);
    const reconciled = await f.kernel.reconcileSynthetic(f.principal, f.scope.scope_id, a.id, adapter);
    assert.equal(reconciled.status, phase === 'before' ? 'outcome_unknown' : 'succeeded'); assert.equal((await f.goal()).proactive.state, 'active');
    assert.equal(adapter.dispatch_calls, 1);
  }
});

test('restore barrier: external lock during final database binding read is checked again before effect', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  const original = f.repository.transaction.bind(f.repository); let reads = 0;
  f.repository.transaction = (scope, fn) => typeof scope === 'function' ? original(scope) : original(scope, async tx => {
    const get = tx.records.get.bind(tx.records);
    tx.records.get = async (...args) => { const row = await get(...args); if (args[1] === 'catpaw-recovery-bindings' && ++reads === 4) f.restoreAuthority.lock(); return row; };
    return fn(tx);
  });
  assert.equal((await f.dispatch(a)).status, 'outcome_unknown'); assert.equal(f.adapter.effect_calls, 0);
});

test('restore barrier: slow trusted marker reader cannot carry dispatch beyond finalization reserve', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a); let reads = 0;
  const original = f.restoreBarrier.readMarker;
  f.restoreBarrier.readMarker = async args => { const marker = await original(args); if (++reads === 2) f.advance(50000); return marker; };
  await assert.rejects(f.dispatch(a), error('invocation_closed')); assert.equal(f.adapter.dispatch_calls, 0);
});

test('restore barrier: client cannot supply recovery authority and legacy approved Action without a fence is blocked', async () => {
  const f = await fixture(), e = await delayedArrival(f);
  await assert.rejects(f.propose(e, { recovery_binding: { schema_version: 1, state: 'open' } }), error('schema_invalid'));
  const a = await f.propose(e); await f.decide(a); const snapshot = f.repository.snapshot();
  const action = snapshot.records.find(([key]) => JSON.parse(key)[1] === 'actions' && JSON.parse(key)[2] === a.id)[1];
  delete action.data.recovery_binding; action.hash = hash({ data: action.data, task_id: action.taskId, expires_at: action.expiresAt });
  const binding = snapshot.records.find(([key]) => JSON.parse(key)[1] === 'catpaw-approval-bindings' && JSON.parse(key)[2] === a.id)[1]; binding.action_digest = action.hash;
  const decision = snapshot.rows.find(([key]) => JSON.parse(key)[1] === 'events' && JSON.parse(key)[2] === binding.decision_event_id)[1]; decision.refs.action_digest = action.hash;
  const restored = new TestRepository(snapshot), foundation = new Foundation(restored, { guardKey: 'synthetic-legacy-fence-placeholder', clock: () => new Date(f.now()) });
  await assert.rejects(f.dispatch(a, f.adapter, f.makeKernel(foundation)), error('restore_fence_missing'));
  assert.equal(f.adapter.dispatch_calls, 0);
});

test('restore barrier: malformed external marker fails closed and cannot update frozen proposal', async () => {
  const f = await fixture(), e = await delayedArrival(f), a = await f.propose(e); await f.decide(a);
  f.restoreAuthority.current.schema_version = 2;
  await assert.rejects(f.dispatch(a), error('restore_marker_invalid'));
  assert.equal((await f.action(a.id)).data.recovery_binding.schema_version, 1); assert.equal(f.adapter.effect_calls, 0);
});
