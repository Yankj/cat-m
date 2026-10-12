import { clone, ensure, exact, hash, integer, instant, json, text, uuid } from './common.mjs';

export const GOAL_CONTRACT = Object.freeze({ name: 'catpaw.proactive-goal', schema_version: 1,
  action_kind: 'catpaw.goal.synthetic', execution_layer: 'synthetic_test_double' });
const PENDING = new Set(['awaiting_review', 'approved']);
const OPERATIONS = new Set(['choose_travel_plan', 'purchase', 'send_report']);
const envelope = input => { ensure(input?.schema_version === 1, 'contract_version_unsupported', 422); };
const liveGoal = goal => ensure(goal.proactive?.state === 'active', 'goal_stopped', 409);

/** Opt-in domain extension of Foundation goals/events + existing actions/bindings/tasks.
 * No HTTP registration, model, poller, lease allocator, database migration or real transport.
 * Authority/admitTask are the composition root's existing fresh session/consent and worker hooks.
 */
export class ProactiveGoalKernel {
  constructor({ foundation, authorize, admitTask }) {
    ensure(foundation?.repository?.transaction && typeof authorize === 'function' && typeof admitTask === 'function', 'goal_authority_missing', 503);
    ensure(foundation.repository.execution_layer === GOAL_CONTRACT.execution_layer, 'production_kernel_disabled', 403);
    Object.assign(this, { foundation, authorize, admitTask, repository: foundation.repository });
  }
  now() { return this.foundation.now(); }
  async transaction(principal, scopeId, operation, fn, finalize = async () => {}) {
    return this.foundation.scoped(principal, scopeId, async tx => {
      const scope = this.foundation.identity(principal, scopeId);
      await this.authorize(tx.records, { principal, scope, operation });
      const result = await fn(tx, scope.owner);
      // All awaited mutations remain rollbackable until fresh authority passes again.
      await this.authorize(tx.records, { principal, scope, operation });
      await finalize(tx, scope.owner);
      return result;
    });
  }
  async goal(tx, principal, goalId) {
    const goal = await this.foundation.required(tx, 'goals', goalId);
    ensure(goal.subject_id === principal.subject_id, 'not_found', 404);
    return goal;
  }
  completion(input) {
    envelope(input);
    if (input.kind === 'actual_arrival') {
      exact(input, ['schema_version', 'kind', 'location', 'deadline']); text(input.location, 200); instant(input.deadline);
    } else {
      exact(input, ['schema_version', 'kind', 'report_key']); ensure(input.kind === 'delivery_confirmed'); text(input.report_key, 200);
    }
    return clone(input);
  }
  async confirmGoal(principal, scopeId, goalId, input) {
    envelope(input); exact(input, ['schema_version', 'expected_revision', 'completion'], ['quiet_until']); integer(input.expected_revision, 1);
    const completion = this.completion(input.completion); if (input.quiet_until != null) instant(input.quiet_until);
    return this.transaction(principal, scopeId, 'confirm_goal', async tx => {
      const goal = await this.goal(tx, principal, goalId); ensure(!goal.proactive, 'goal_already_confirmed', 409);
      const next = await tx.compareAndSwap('goals', goal.id, { revision: input.expected_revision }, {
        revision: goal.revision + 1, proactive: { schema_version: 1, state: 'active', completion, event_heads: {}, quiet_until: input.quiet_until ?? null }
      });
      ensure(next, 'goal_version_conflict', 409);
      await this.emit(tx, next, 'goal_confirmed', {});
      return next; // Goal confirmation grants no action permission.
    });
  }
  async emit(tx, goal, type, refs, notify = false) {
    const event = await this.foundation.emit(tx, type, { schema_version: 1, synthetic: true, goal_id: goal.id, goal_version: goal.revision, ...clone(refs) });
    if (notify) {
      const owner = (await tx.scope()).identity.owner;
      const row = { id: hash({ scope_id: tx.scopeId, event_id: event.id, channel: 'synthetic_inbox' }), schema_version: 1, synthetic: true,
        scope_id: tx.scopeId, subject_id: goal.subject_id, goal_id: goal.id, goal_version: goal.revision,
        event_id: event.id, topic: type, state: 'pending', created_at: this.now() };
      ensure(await tx.records.insertIfAbsent(owner, 'catpaw-notification-outbox', row), 'outbox_conflict', 409);
    }
    return event;
  }
  async invalidate(tx, owner, goal) {
    // Existing actions are the proposal/effect authority; no parallel proposal table.
    for (const action of await tx.records.list(owner, 'actions')) {
      if (action.kind !== GOAL_CONTRACT.action_kind || action.data.scope_id !== goal.scope_id || action.data.goal_id !== goal.id || action.data.goal_version === goal.revision) continue;
      if (PENDING.has(action.status)) await tx.records.compareAndSwap(owner, 'actions', action.id, { status: action.status }, { status: 'expired', invalidated_by_goal_version: goal.revision });
      if (action.status === 'executing') await tx.records.compareAndSwap(owner, 'actions', action.id, { status: 'executing' }, { status: 'outcome_unknown' });
    }
    if (goal.proactive.state !== 'active') {
      for (const binding of (await tx.list('bindings')).filter(b => b.goal_id === goal.id)) {
        const task = await tx.records.get(owner, 'tasks', binding.task_id);
        if (task && !['succeeded', 'failed', 'cancelled', 'outcome_unknown'].includes(task.status)) {
          await tx.records.compareAndSwap(owner, 'tasks', task.id, { status: task.status, leaseId: task.leaseId }, {
            status: goal.proactive.state === 'paused' ? 'paused' : 'cancelled', leaseId: null, leaseUntil: null, updatedAt: this.now()
          });
        }
      }
    }
  }
  async changeGoal(principal, scopeId, goalId, input) {
    envelope(input); exact(input, ['schema_version', 'expected_revision', 'state'], ['completion', 'quiet_until']); integer(input.expected_revision, 1);
    ensure(['active', 'paused', 'revoked'].includes(input.state));
    if (input.completion) this.completion(input.completion); if (input.quiet_until != null) instant(input.quiet_until);
    return this.transaction(principal, scopeId, 'change_goal', async (tx, owner) => {
      const goal = await this.goal(tx, principal, goalId); ensure(goal.proactive && !['revoked', 'completed'].includes(goal.proactive.state), 'goal_stopped', 409);
      const proactive = { ...goal.proactive, state: input.state,
        ...input.completion ? { completion: clone(input.completion) } : {},
        ...Object.hasOwn(input, 'quiet_until') ? { quiet_until: input.quiet_until } : {} };
      const next = await tx.compareAndSwap('goals', goal.id, { revision: input.expected_revision }, { revision: goal.revision + 1, proactive });
      ensure(next, 'goal_version_conflict', 409); await this.invalidate(tx, owner, next);
      await this.emit(tx, next, 'goal_changed', { state: input.state }); return next;
    });
  }
  eventInput(input, trust) {
    envelope(input); exact(input, ['schema_version', 'source_key', 'revision', 'type', 'payload']); text(input.source_key, 160); integer(input.revision, 1);
    const p = input.payload;
    if (['arrival_estimate', 'actual_arrival'].includes(input.type)) {
      exact(p, ['location', 'at']); text(p.location, 200); instant(p.at);
    } else if (input.type === 'report_generated') {
      exact(p, ['report_key', 'artifact_hash']); text(p.report_key, 200); ensure(/^[a-f0-9]{64}$/.test(p.artifact_hash));
    } else if (input.type === 'delivery_confirmed') {
      exact(p, ['report_key', 'receipt_id']); text(p.report_key, 200); text(p.receipt_id, 200);
    } else {
      ensure(input.type === 'user_completed' && trust === 'user_direct', 'untrusted_completion', 403);
      exact(p, ['statement']); text(p.statement, 500);
    }
    return clone(input);
  }
  ingestUserEvent(principal, scopeId, goalId, input) { return this.ingest(principal, scopeId, goalId, input, 'user_direct'); }
  ingestSyntheticEvent(principal, scopeId, goalId, input, adapter) {
    this.synthetic(adapter); return this.ingest(principal, scopeId, goalId, input, 'synthetic_adapter');
  }
  async ingest(principal, scopeId, goalId, input, trust) {
    // Internal trusted ingress only. Trust is assigned by entrypoint, never third-party payload metadata.
    ensure(['user_direct', 'synthetic_adapter'].includes(trust), 'untrusted_source', 403); this.eventInput(input, trust);
    return this.transaction(principal, scopeId, 'ingest_event', async (tx, owner) => {
      const goal = await this.goal(tx, principal, goalId); ensure(goal.proactive, 'goal_unconfirmed', 409);
      const digest = hash({ ...input, trust }), key = hash({ source_key: input.source_key, trust });
      const prior = (await tx.list('events')).find(e => e.type === 'goal_observed' && e.refs.goal_id === goalId && e.refs.source_key_hash === key && e.refs.source_revision === input.revision);
      if (prior) { ensure(prior.refs.input_hash === digest, 'event_revision_conflict', 409); return { disposition: 'duplicate', event: prior, goal }; }
      liveGoal(goal);
      const head = goal.proactive.event_heads[key];
      if (head && input.revision < head.revision) return { disposition: 'out_of_order', goal };
      ensure(!head || input.revision > head.revision, 'event_revision_conflict', 409);
      const completion = goal.proactive.completion, p = input.payload;
      const completed = input.type === 'user_completed' || (completion.kind === 'actual_arrival' && input.type === 'actual_arrival' && p.location === completion.location && Date.parse(p.at) <= Date.parse(this.now()) && Date.parse(p.at) <= Date.parse(completion.deadline)) ||
        (completion.kind === 'delivery_confirmed' && input.type === 'delivery_confirmed' && p.report_key === completion.report_key);
      const next = { ...goal, revision: goal.revision + 1, proactive: { ...goal.proactive, state: completed ? 'completed' : 'active', event_heads: { ...goal.proactive.event_heads } } };
      const event = await this.emit(tx, next, 'goal_observed', { source_key_hash: key, source_revision: input.revision, input_hash: digest,
        trust, observation: { type: input.type, payload: clone(p) } });
      next.proactive.event_heads[key] = { revision: input.revision, event_id: event.id, input_hash: digest };
      ensure(await tx.compareAndSwap('goals', goal.id, { revision: goal.revision }, { revision: next.revision, proactive: next.proactive }), 'goal_version_conflict', 409);
      await this.invalidate(tx, owner, next);
      if (completed) await this.emit(tx, next, 'goal_completed', { evidence_event_id: event.id });
      return { disposition: 'accepted', event, goal: next };
    });
  }
  async workerFence(tx, owner, principal, goal, taskId, leaseId, control) {
    ensure(typeof control?.assertLive === 'function', 'worker_control_required', 503); control.assertLive();
    const binding = (await tx.list('bindings')).find(b => b.goal_id === goal.id && b.task_id === taskId);
    ensure(binding, 'goal_task_binding_missing', 409);
    const admitted = await this.admitTask(tx.records, owner, taskId, { running: true, leaseId });
    const task = await tx.records.get(owner, 'tasks', taskId);
    ensure(admitted.run?.id === binding.run_id && admitted.run.frozen_request?.subject_id === principal.subject_id && admitted.run.frozen_request.scope.scope_id === tx.scopeId &&
      admitted.run.request_hash === binding.request_hash && hash(task?.state?.catpaw ?? {}) === hash(admitted.task?.state?.catpaw ?? {}), 'goal_task_binding_conflict', 409);
    ensure(task.status === 'running' && task.leaseId === leaseId && Date.parse(task.leaseUntil) > Date.parse(this.now()), 'lease_lost', 409);
    control.assertLive();
  }
  async evidence(tx, goal, ids) {
    ensure(Array.isArray(ids) && ids.length > 0 && ids.length <= 8 && new Set(ids).size === ids.length);
    for (const eventId of ids) {
      const event = await this.foundation.required(tx, 'events', eventId);
      ensure(event.type === 'goal_observed' && event.refs.goal_id === goal.id && Object.values(goal.proactive.event_heads).some(h => h.event_id === event.id), 'evidence_superseded', 409);
    }
  }
  async propose(principal, scopeId, goalId, input, control) {
    envelope(input); exact(input, ['schema_version', 'proposal_id', 'goal_version', 'task_id', 'lease_id', 'evidence_ids', 'operation', 'arguments', 'summary', 'expires_at']);
    uuid(input.proposal_id); uuid(input.lease_id); integer(input.goal_version, 1); text(input.task_id, 200); text(input.summary, 1000); instant(input.expires_at); json(input.arguments, 2000);
    ensure(OPERATIONS.has(input.operation), 'operation_unsupported', 422);
    return this.transaction(principal, scopeId, 'propose', async (tx, owner) => {
      const goal = await this.goal(tx, principal, goalId); liveGoal(goal); ensure(goal.revision === input.goal_version, 'goal_version_conflict', 409);
      await this.evidence(tx, goal, input.evidence_ids); await this.workerFence(tx, owner, principal, goal, input.task_id, input.lease_id, control);
      ensure(Date.parse(input.expires_at) > Date.parse(this.now()), 'proposal_expired', 409);
      const data = { schema_version: 1, synthetic: true, scope_id: scopeId, goal_id: goalId, goal_version: goal.revision, subject_id: principal.subject_id,
        evidence_ids: clone(input.evidence_ids), operation: input.operation, arguments: clone(input.arguments), summary: input.summary };
      const digest = hash({ data, task_id: input.task_id, expires_at: input.expires_at }), effectKey = hash({ scope_id: scopeId, goal_id: goalId, operation: input.operation, arguments: input.arguments });
      const old = await tx.records.get(owner, 'actions', input.proposal_id);
      if (old) { ensure(old.kind === GOAL_CONTRACT.action_kind && old.hash === digest && old.taskId === input.task_id && old.expiresAt === input.expires_at, 'proposal_conflict', 409); return old; }
      // A new goal version/approval cannot bypass a possibly applied effect with the same intent.
      const actions = await tx.records.list(owner, 'actions');
      for (const a of actions) if (a.kind === GOAL_CONTRACT.action_kind && a.effect_key === effectKey && PENDING.has(a.status) && Date.parse(a.expiresAt) <= Date.parse(this.now())) {
        ensure(await tx.records.compareAndSwap(owner, 'actions', a.id, { status: a.status }, { status: 'expired' }), 'action_conflict', 409); a.status = 'expired';
      }
      const same = actions.find(a => a.kind === GOAL_CONTRACT.action_kind && a.effect_key === effectKey && ['awaiting_review', 'approved', 'executing', 'outcome_unknown', 'succeeded'].includes(a.status));
      ensure(!same, same?.status === 'outcome_unknown' || same?.status === 'executing' ? 'reconciliation_required' : 'effect_already_reserved', 409);
      const action = { id: input.proposal_id, kind: GOAL_CONTRACT.action_kind, data, hash: digest, effect_key: effectKey,
        taskId: input.task_id, status: 'awaiting_review', expiresAt: input.expires_at, createdAt: this.now() };
      ensure(await tx.records.insertIfAbsent(owner, 'actions', action), 'proposal_conflict', 409);
      ensure(await tx.records.insertIfAbsent(owner, 'catpaw-approval-bindings', { id: action.id, schema_version: 1, synthetic: true, goal_id: goalId, goal_version: goal.revision,
        subject_id: principal.subject_id, scope_id: scopeId, task_id: action.taskId, action_digest: digest, decision: null }), 'proposal_conflict', 409);
      await this.emit(tx, goal, 'goal_proposal_ready', { action_id: action.id, action_digest: digest, evidence_ids: data.evidence_ids }, true);
      control.assertLive(); return action;
    }, async (tx, owner) => { await this.current(tx, owner, principal, input.proposal_id, { leaseId: input.lease_id, control }); });
  }
  async action(tx, owner, principal, actionId) {
    const action = await tx.records.get(owner, 'actions', uuid(actionId));
    ensure(action?.kind === GOAL_CONTRACT.action_kind && action.data.subject_id === principal.subject_id && action.data.scope_id === tx.scopeId, 'not_found', 404);
    const goal = await this.goal(tx, principal, action.data.goal_id); return { action, goal };
  }
  async current(tx, owner, principal, actionId, { status, leaseId, control } = {}) {
    const { action, goal } = await this.action(tx, owner, principal, actionId); liveGoal(goal);
    ensure(goal.revision === action.data.goal_version, 'goal_version_conflict', 409);
    ensure(action.hash === hash({ data: action.data, task_id: action.taskId, expires_at: action.expiresAt }), 'proposal_corrupt', 409); ensure(Date.parse(action.expiresAt) > Date.parse(this.now()), 'proposal_expired', 409);
    await this.evidence(tx, goal, action.data.evidence_ids);
    if (status) ensure(action.status === status, ['executing', 'outcome_unknown'].includes(action.status) ? 'reconciliation_required' : 'approval_consumed', 409);
    if (leaseId) await this.workerFence(tx, owner, principal, goal, action.taskId, leaseId, control);
    return { action, goal };
  }
  async decide(principal, scopeId, actionId, input) {
    envelope(input); exact(input, ['schema_version', 'goal_version', 'action_digest', 'decision']); integer(input.goal_version, 1); ensure(['approve', 'deny'].includes(input.decision));
    return this.transaction(principal, scopeId, 'decide', async (tx, owner) => {
      const { action, goal } = await this.current(tx, owner, principal, actionId);
      ensure(input.goal_version === goal.revision && input.action_digest === action.hash, 'approval_stale', 409);
      const binding = await tx.records.get(owner, 'catpaw-approval-bindings', action.id);
      if (binding?.decision === input.decision && binding.action_digest === action.hash) return action;
      ensure(action.status === 'awaiting_review' && binding?.decision === null, 'approval_consumed', 409);
      const event = await this.emit(tx, goal, 'goal_action_decided', { action_id: action.id, action_digest: action.hash, decision: input.decision, actor_id: principal.subject_id });
      await tx.records.put(owner, 'catpaw-approval-bindings', { ...binding, decision: input.decision, decision_event_id: event.id });
      const next = await tx.records.compareAndSwap(owner, 'actions', action.id, { status: 'awaiting_review', hash: action.hash }, { status: input.decision === 'approve' ? 'approved' : 'denied' });
      ensure(next, 'approval_consumed', 409); return next;
    });
  }
  async approved(tx, owner, principal, actionId, leaseId, control, status) {
    const current = await this.current(tx, owner, principal, actionId, { status, leaseId, control });
    const b = await tx.records.get(owner, 'catpaw-approval-bindings', actionId);
    ensure(b?.decision === 'approve' && b.subject_id === principal.subject_id && b.scope_id === tx.scopeId && b.goal_id === current.goal.id && b.goal_version === current.goal.revision && b.action_digest === current.action.hash, 'action_permission_required', 403);
    return current;
  }
  synthetic(adapter) {
    ensure(this.repository.execution_layer === GOAL_CONTRACT.execution_layer && adapter?.synthetic === true && adapter?.schema_version === 1, 'real_adapter_disabled', 403);
  }
  async dispatchSynthetic(principal, scopeId, actionId, { lease_id, control }, adapter) {
    this.synthetic(adapter); uuid(lease_id);
    const prepared = await this.transaction(principal, scopeId, 'dispatch', async (tx, owner) => {
      const { action } = await this.approved(tx, owner, principal, actionId, lease_id, control, 'approved');
      const next = await tx.records.compareAndSwap(owner, 'actions', action.id, { status: 'approved', hash: action.hash }, { status: 'executing', dispatch_lease_id: lease_id, dispatched_at: this.now() });
      ensure(next, 'approval_consumed', 409); control.assertLive(); return next;
    }, async (tx, owner) => { await this.approved(tx, owner, principal, actionId, lease_id, control, 'executing'); });
    let receipt;
    try {
      receipt = await adapter.dispatch({ action: clone(prepared), beforeEffect: () => this.transaction(principal, scopeId, 'before_effect', async (tx, owner) => {
        await this.approved(tx, owner, principal, actionId, lease_id, control, 'executing'); control.assertLive();
      }, async (tx, owner) => { await this.approved(tx, owner, principal, actionId, lease_id, control, 'executing'); }) });
    } catch { receipt = { schema_version: 1, synthetic: true, state: 'unknown' }; }
    try {
      return await this.transaction(principal, scopeId, 'settle', async (tx, owner) => {
        const { goal } = await this.approved(tx, owner, principal, actionId, lease_id, control, 'executing');
        const confirmed = receipt?.schema_version === 1 && receipt.synthetic === true && receipt.state === 'confirmed' && receipt.effect_key === prepared.effect_key;
        const next = await tx.records.compareAndSwap(owner, 'actions', actionId, { status: 'executing', dispatch_lease_id: lease_id }, { status: confirmed ? 'succeeded' : 'outcome_unknown', outcome: confirmed ? clone(receipt) : { schema_version: 1, synthetic: true, state: 'unknown' } });
        ensure(next, 'action_conflict', 409);
        await this.emit(tx, goal, 'goal_action_outcome', { action_id: actionId, state: next.status }, true);
        control.assertLive(); return next; // Accepted effect never completes the goal.
      }, async (tx, owner) => { await this.approved(tx, owner, principal, actionId, lease_id, control); });
    } catch {
      // Audit fallback cannot publish success, complete a goal or regain permission. Do not replay.
      return this.repository.transaction(async tx => {
        const owner = this.foundation.identity(principal, scopeId).owner;
        return await tx.compareAndSwap(owner, 'actions', actionId, { status: 'executing', dispatch_lease_id: lease_id }, { status: 'outcome_unknown' }) ?? await tx.get(owner, 'actions', actionId);
      });
    }
  }
  async reconcileSynthetic(principal, scopeId, actionId, adapter) {
    this.synthetic(adapter);
    const observed = await this.transaction(principal, scopeId, 'reconcile_read', async (tx, owner) => {
      const { action } = await this.action(tx, owner, principal, actionId);
      ensure(['executing', 'outcome_unknown'].includes(action.status), 'reconciliation_not_needed', 409); return action;
    });
    // Pure lookup only. Allow audit reconciliation after goal stop/version/lease changes.
    const receipt = await adapter.reconcile({ effect_key: observed.effect_key });
    return this.transaction(principal, scopeId, 'reconcile_commit', async (tx, owner) => {
      const { action, goal } = await this.action(tx, owner, principal, actionId);
      ensure(['executing', 'outcome_unknown'].includes(action.status), 'reconciliation_not_needed', 409);
      ensure(receipt?.schema_version === 1 && receipt.synthetic === true && receipt.effect_key === action.effect_key && ['confirmed', 'not_applied', 'unknown'].includes(receipt.state), 'invalid_reconciliation', 422);
      const next = await tx.records.compareAndSwap(owner, 'actions', actionId, { status: action.status }, { status: { confirmed: 'succeeded', not_applied: 'failed', unknown: 'outcome_unknown' }[receipt.state], outcome: clone(receipt) });
      ensure(next, 'action_conflict', 409);
      await this.emit(tx, goal, 'goal_action_reconciled', { action_id: actionId, state: next.status }); return next;
    });
  }
  async publishSyntheticInbox(principal, scopeId, { limit = 10 } = {}) {
    ensure(this.repository.execution_layer === GOAL_CONTRACT.execution_layer, 'real_adapter_disabled', 403); integer(limit, 1, 100);
    return this.transaction(principal, scopeId, 'publish_inbox', async (tx, owner) => {
      const published = [];
      for (const row of (await tx.records.list(owner, 'catpaw-notification-outbox')).filter(r => r.scope_id === scopeId && r.subject_id === principal.subject_id && r.state === 'pending').slice(0, limit)) {
        const goal = await this.goal(tx, principal, row.goal_id);
        if (goal.proactive.state !== 'active' || goal.revision !== row.goal_version) {
          await tx.records.compareAndSwap(owner, 'catpaw-notification-outbox', row.id, { state: 'pending' }, { state: 'cancelled' }); continue;
        }
        if (goal.proactive.quiet_until && Date.parse(goal.proactive.quiet_until) > Date.parse(this.now())) continue;
        const notification = { ...row, state: 'published', published_at: this.now() };
        await tx.records.insertIfAbsent(owner, 'catpaw-notifications', notification);
        ensure(await tx.records.compareAndSwap(owner, 'catpaw-notification-outbox', row.id, { state: 'pending' }, { state: 'published' }), 'outbox_conflict', 409);
        published.push(notification);
      }
      return published;
    });
  }
}
