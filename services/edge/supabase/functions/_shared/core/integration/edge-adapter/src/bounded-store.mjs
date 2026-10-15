import { LostLeaseError } from '../vendor/openmuse/runtime/engine/worker.mjs';
import { clone, ensure, id, iso, hash, checkpointHash, dispatched, AdapterError } from './common.mjs';
import {captureTaskExecutionFence,assertTaskExecutionFence,isTaskExecutionAuthorityFence} from '../../../src/task-execution-fence.mjs';
import {acceptedWorkExecution,acceptedWorkClaimEligibleInTransaction} from '../../../src/accepted-work-execution.mjs';
import {hasUnresolvedSourceReads} from '../../../src/task-source-service.mjs';

const denied=isTaskExecutionAuthorityFence;
const terminal = new Set(['scheduled', 'succeeded', 'failed', 'outcome_unknown', 'waiting_input', 'waiting_approval']);

/** Store port for the unchanged TaskWorker. Uses its tasks/runs/run-events, not another job engine. */
export class BoundedStore {
  constructor({ repository, owners, admitTask, now = Date.now, invocation, onCommit = async () => {}, workGrantService=null }) {
    ensure(repository?.transaction && typeof admitTask === 'function', 'authority_not_configured');
    ensure(Array.isArray(owners) && owners.length === 1 && owners.every(o => typeof o === 'string' && o.startsWith('catpaw:')), 'scope_not_configured');
    Object.assign(this, { repository, admitTask, now, invocation, onCommit, workGrantService });
    this.owners = new Set(owners);
    this.settlements = new Map();
  }
  allowed(owner) { ensure(this.owners.has(owner), 'scope_forbidden'); }
  live() { ensure(this.invocation.open && this.now() < this.invocation.deadline, 'invocation_closed'); }
  async admission(tx, owner, taskId, options = {}) {
    this.allowed(owner);
    // Owner hook must lock/verify fresh scope + delegation + hash (+ generation when used).
    const admitted = await this.admitTask(tx, owner, taskId, options);
    await tx.lock(owner, 'tasks', taskId); // same connection, AFTER the owner's authority lock order
    const task = await tx.get(owner, 'tasks', taskId);
    ensure(task?.state?.catpaw && hash(task.state.catpaw) === hash(admitted.task.state.catpaw), 'operation_conflict');
    if (options.running) {
      if (task.status !== 'running' || task.leaseId !== options.leaseId || Date.parse(task.leaseUntil) <= this.now()) throw new LostLeaseError();
      const attempt = await tx.get(owner, 'runs', options.leaseId);
      if(attempt?.taskId!==taskId||attempt.status!=='running'||attempt.slice?.acknowledged)throw new LostLeaseError();
      assertTaskExecutionFence(task,options.leaseId,this.now(),
        {authority_hash:attempt?.slice?.authority_hash,revision:attempt?.slice?.execution_revision});
    }
    const work=acceptedWorkExecution(this.workGrantService,owner,admitted.run,{now:this.now,task:admitted.task});if(work){if(options.running)await work.running(tx,{assertLive:()=>this.live()});else await work.current(tx,{assertLive:()=>this.live()});}
    return { ...admitted, task };
  }
  get(owner, kind, taskId) { this.allowed(owner); return this.repository.transaction(tx => tx.get(owner, kind, taskId)); }
  list(owner, kind) { this.allowed(owner); return this.repository.transaction(tx => tx.list(owner, kind)); }
  unresolvedDispatch(owner,task){this.allowed(owner);return dispatched(task)?Promise.resolve(true):this.repository.transaction(tx=>hasUnresolvedSourceReads(tx,owner,task.state.catpaw.run_id));}
  scan(kind) {
    ensure(kind === 'tasks', 'unsupported_scan');
    return this.repository.transaction(async tx => {
      this.live();
      const candidates = (await tx.scan('tasks')).filter(({ owner, value: t }) => this.owners.has(owner) && t.state?.catpaw && (
        t.status === 'queued' || t.status === 'scheduled' && Date.parse(t.nextRunAt ?? '') <= this.now() ||
        t.status === 'running' && Date.parse(t.leaseUntil ?? '') <= this.now() || t.status === 'waiting_approval'
      )).sort((a, b) => String(a.value.createdAt).localeCompare(String(b.value.createdAt)) || a.value.id.localeCompare(b.value.id));
      for (const candidate of candidates) {
        const { owner, value: t } = candidate;
        if (t.status === 'waiting_approval' && t.actionId) {
          const action = await tx.get(owner, 'actions', t.actionId);
          if (action?.status === 'executing' || action?.status === 'awaiting_review' && !(Date.parse(action.expiresAt ?? '') <= this.now())) continue;
        }
        try { const admitted=await this.admission(tx, owner, t.id);if(!await acceptedWorkClaimEligibleInTransaction(tx,this.workGrantService,owner,admitted.run,{now:this.now,assertLive:()=>this.live()}))continue; } catch (error) { if (denied(error)) continue; throw error; }
        return [candidate]; // one selection per invocation; TaskWorker's original CAS arbitrates competition
      }
      return [];
    });
  }
  async compareAndSwap(owner, kind, taskId, expected, patch) {
    this.allowed(owner);
    return this.repository.transaction(async tx => {
      if (kind !== 'tasks') {
        ensure(['runs', 'actions'].includes(kind), 'unsupported_cas');
        // The worker may close an unacknowledged attempt after invocation expiry.
        // This cleanup cannot acknowledge a continuation or mutate task/authority data.
        if (kind === 'runs') {
          ensure(expected.status === 'running' && ['failed', 'interrupted'].includes(patch.status) &&
            Object.keys(patch).every(key => ['status', 'finishedAt'].includes(key)), 'audit_cleanup_only');
          const run = await tx.get(owner, kind, taskId);
          if (run?.slice?.acknowledged) return null;
        }
        if (kind === 'actions') this.live();
        const result = await tx.compareAndSwap(owner, kind, taskId, expected, patch);
        if (kind === 'actions') this.live();
        return result;
      }
      let admission;
      try {
        this.live();
        admission = await this.admission(tx, owner, taskId, expected.status === 'running' && !patch.leaseId ? { running: true, leaseId: expected.leaseId } : {});
        this.live(); // lock/authority waits must not carry a write beyond invocation deadline
      } catch (error) { if (denied(error) || error instanceof LostLeaseError || error.code === 'invocation_closed') return null; throw error; }
      const previous = admission.task;
      const claiming = patch.status === 'running' && Boolean(patch.leaseId);
      if (claiming) {
        // A stale scan cannot take a still-live lease, even if an injected expected filter is weak.
        if (previous.status === 'running' && Date.parse(previous.leaseUntil) > this.now()) return null;
      } else if (expected.status === 'running') {
        if (previous.leaseId !== expected.leaseId || previous.status !== 'running' || Date.parse(previous.leaseUntil) <= this.now()) return null;
      }
      this.validatePatch(previous, patch);
      const settling = patch.leaseId === null && patch.status && patch.status !== 'running';
      if (settling) {
        const prepared = this.settlements.get(previous.leaseId);
        if (prepared && prepared !== checkpointHash(previous)) return null;
        // Original worker's abort catch requests queued; persist unknown if a send was checkpointed.
        patch = clone(patch);
        if (dispatched(previous)||await hasUnresolvedSourceReads(tx,owner,previous.state.catpaw.run_id)) patch = { ...patch, status: 'outcome_unknown', error: 'dispatch_outcome_unknown; do not automatically resend' };
        if (patch.status === 'queued') { patch.status = 'scheduled'; patch.nextRunAt = iso(this.now() + 1000); }
        ensure(terminal.has(patch.status), 'invalid_step_status');
        if (patch.status === 'scheduled') ensure(Date.parse(patch.nextRunAt) > this.now(), 'continuation_not_in_future');
      }
      const next = await tx.compareAndSwap(owner, 'tasks', taskId, expected, patch);
      if (!next) return null;
      if (claiming) await this.claimAttempt(tx, owner, next, admission.run);
      if (settling) await this.acknowledge(tx, owner, previous, next);
      this.live();
      // Re-read authority/generation after all awaited writes/hook, on THIS transaction.
      await this.admission(tx, owner, taskId, next.status === 'running' ? { running: true, leaseId: next.leaseId } : {});
      this.live(); // rollback all writes if an async authority/commit hook consumed the reserve
      return next;
    });
  }
  validatePatch(previous, patch) {
    if (patch.state) ensure(hash(patch.state.catpaw) === hash(previous.state.catpaw) &&
      hash(patch.state.task_control??null) === hash(previous.state.task_control??null), 'authority_patch_forbidden');
    ensure(!Object.hasOwn(patch, 'id') && !Object.hasOwn(patch, 'input'), 'authority_patch_forbidden');
  }
  async claimAttempt(tx, owner, task, businessRun) {
    ensure(businessRun?.id && businessRun.task_id === task.id && businessRun.request_hash === task.state.catpaw.request_hash, 'operation_conflict');
    for (const r of (await tx.list(owner, 'runs')).filter(r => r.taskId === task.id && r.status === 'running' && r.id !== task.leaseId)) {
      await tx.compareAndSwap(owner, 'runs', r.id, { status: 'running' }, { status: 'interrupted', finishedAt: iso(this.now()), recoveryReason: 'superseded_lease' });
    }
    const execution=captureTaskExecutionFence(task);
    await tx.insertIfAbsent(owner, 'runs', { id: task.leaseId, taskId: task.id, startedAt: iso(this.now()), status: 'running', slice: { authority_hash: execution.authority_hash, execution_revision:execution.revision, checkpoint_in: checkpointHash(task), acknowledged: false } });
    await tx.insertIfAbsent(owner, 'catpaw-run-links', { id: task.leaseId, run_id: businessRun.id, operation_id: businessRun.operation_id, task_id: task.id, grant_epoch: businessRun.grant_epoch });
    const work=acceptedWorkExecution(this.workGrantService,owner,businessRun,{now:this.now,task});if(work)await work.claim(tx,{assertLive:()=>this.live()});
  }
  async acknowledge(tx, owner, previous, next) {
    const attempt = await tx.get(owner, 'runs', previous.leaseId);
    const link = await tx.get(owner, 'catpaw-run-links', previous.leaseId);
    ensure(attempt?.status === 'running' && link?.task_id === previous.id, 'run_conflict');
    const ack = await tx.compareAndSwap(owner, 'runs', previous.leaseId, { status: 'running' }, {
      status: next.status, finishedAt: iso(this.now()), slice: { ...attempt.slice, acknowledged: true, checkpoint_out: checkpointHash(next), continuation: next.status === 'scheduled' ? next.nextRunAt : null },
    });
    ensure(ack, 'run_conflict');
    await tx.insertIfAbsent(owner, 'run-events', { id: id(), taskId: next.id, leaseId: previous.leaseId, date: iso(this.now()), kind: 'progress', title: 'Bounded step committed', detail: '', checkpoint_hash: checkpointHash(next), status: next.status });
    const run=await tx.get(owner,'catpaw-runs',next.state.catpaw.run_id),work=acceptedWorkExecution(this.workGrantService,owner,run,{now:this.now,task:next});if(work)await work.acknowledge(tx,previous,next,{assertLive:()=>this.live()});
    // Memory source/outbox hook must use THIS transaction, never fire-and-forget or call repository.transaction again.
    try { await this.onCommit(tx, { owner, previous, task: next, attempt: ack }); }
    catch { throw new AdapterError('commit_hook_failed'); }
  }
  put(owner, kind, value) {
    this.allowed(owner);
    ensure(['runs', 'run-events'].includes(kind), 'immutable_writer_required');
    return this.repository.transaction(async tx => {
      if (kind === 'runs') {
        const existing = await tx.get(owner, kind, value.id);
        ensure(existing?.taskId === value.taskId, 'run_conflict');
        // Original worker writes running/settled a second time. Preserve the atomic ack and metadata.
        if (existing.slice?.acknowledged || existing.status !== 'running') return existing;
        this.live();
        await this.admission(tx, owner, value.taskId, { running: true, leaseId: value.id });
        this.live();
        const result = await tx.put(owner, kind, { ...existing, ...value, slice: existing.slice });
        this.live();
        await this.admission(tx, owner, value.taskId, { running: true, leaseId: value.id });
        this.live();
        return result;
      }
      this.live();
      await this.admission(tx, owner, value.taskId, { running: true, leaseId: value.leaseId });
      this.live();
      const event = await tx.insertIfAbsent(owner, kind, value);
      this.live();
      await this.admission(tx, owner, value.taskId, { running: true, leaseId: value.leaseId });
      this.live();
      return event;
    });
  }
  async stepGuard(owner, taskId, leaseId, control) {
    return this.repository.transaction(async tx => {
      const { task } = await this.admission(tx, owner, taskId, { running: true, leaseId });
      this.stepLive(control); return task;
    });
  }
  executionDeadline(owner,taskId,leaseId){return this.repository.transaction(async tx=>{const admitted=await this.admission(tx,owner,taskId,{running:true,leaseId}),work=acceptedWorkExecution(this.workGrantService,owner,admitted.run,{now:this.now,task:admitted.task});return Math.min(this.invocation.deadline,Date.parse(admitted.task.leaseUntil),work?await work.deadline(tx,{assertLive:()=>this.live()}):this.invocation.deadline);});}
  beginModelDispatch(owner,taskId,leaseId,requestHash,control){return this.repository.transaction(async tx=>{
    const admitted=await this.admission(tx,owner,taskId,{running:true,leaseId});this.stepLive(control);const current=admitted.task,local=current.state.local_model??{step:0,messages:[],round:null,artifact:null};ensure(!local.round,'round_already_checkpointed');
    const work=acceptedWorkExecution(this.workGrantService,owner,admitted.run,{now:this.now,task:admitted.task}),reservation=work?await work.reserveModel(tx,requestHash,{assertLive:()=>this.stepLive(control),deadline:control.deadline}):null,round={state:'dispatched',request_hash:requestHash};
    const patch={state:{...current.state,local_model:{...local,round,...reservation?{work_grant_round:{operation_id:reservation.id,request_hash:requestHash,reservation_hash:reservation.reservation_hash}}:{}}}};this.validatePatch(current,patch);
    const task=await tx.compareAndSwap(owner,'tasks',taskId,{status:'running',leaseId},{...patch,updatedAt:iso(this.now())});ensure(task,'lease_lost');this.stepLive(control);await this.admission(tx,owner,taskId,{running:true,leaseId});if(work)await work.guardModel(tx,reservation,{assertLive:()=>this.stepLive(control)});this.stepLive(control);
    return {task,reservation,operation_key:hash({task:taskId,step:local.step,request_hash:requestHash})};
  });}
  guardModelTransport(owner,taskId,leaseId,reservation,control){return this.repository.transaction(async tx=>{const admitted=await this.admission(tx,owner,taskId,{running:true,leaseId});this.stepLive(control);const work=acceptedWorkExecution(this.workGrantService,owner,admitted.run,{now:this.now,task:admitted.task});ensure(work&&reservation,'accepted_work_original_dispatch_required');await work.guardModel(tx,reservation,{assertLive:()=>this.stepLive(control)});this.stepLive(control);});}
  receiveModel(owner,taskId,leaseId,output,control){return this.repository.transaction(async tx=>{
    const admitted=await this.admission(tx,owner,taskId,{running:true,leaseId});this.stepLive(control);const current=admitted.task;ensure(dispatched(current),'dispatch_checkpoint_required');ensure(output&&typeof output==='object'&&!Object.hasOwn(output,'state')&&!Object.hasOwn(output,'request_hash'),'invalid_received_round');
    const patch={state:{...current.state,local_model:{...current.state.local_model,round:{...clone(output),state:'received',request_hash:current.state.local_model.round.request_hash}}}};this.validatePatch(current,patch);
    const task=await tx.compareAndSwap(owner,'tasks',taskId,{status:'running',leaseId},{...patch,updatedAt:iso(this.now())});ensure(task,'lease_lost');this.stepLive(control);const work=acceptedWorkExecution(this.workGrantService,owner,admitted.run,{now:this.now,task:admitted.task});if(work)await work.receivedModel(tx,{assertLive:()=>this.stepLive(control)});await this.admission(tx,owner,taskId,{running:true,leaseId});this.stepLive(control);return task;
  });}
  stepLive(control) {
    this.live();
    if (!control.open) throw new LostLeaseError();
    if (control.signal.aborted) throw control.signal.reason instanceof AdapterError ? control.signal.reason : new LostLeaseError();
    if (this.now() >= control.deadline) throw new AdapterError('step_deadline');
  }
  checkpointStep(owner, taskId, leaseId, patch, control) {
    return this.repository.transaction(async tx => {
      const { task } = await this.admission(tx, owner, taskId, { running: true, leaseId });
      this.stepLive(control); this.validatePatch(task, patch);
      if (dispatched(task) && patch.state) {
        const nextRound = patch.state.local_model?.round;
        ensure(nextRound && ['dispatched', 'received'].includes(nextRound.state) && nextRound.request_hash === task.state.local_model.round.request_hash, 'dispatch_receipt_required');
      }
      ensure(!Object.hasOwn(patch, 'status') && !Object.hasOwn(patch, 'leaseId') && !Object.hasOwn(patch, 'leaseUntil') && !Object.hasOwn(patch, 'nextRunAt'), 'step_must_settle_through_worker');
      const next = await tx.compareAndSwap(owner, 'tasks', taskId, { status: 'running', leaseId }, { ...clone(patch), updatedAt: iso(this.now()) });
      if (!next) throw new LostLeaseError();
      this.stepLive(control); // awaited mutation can return after abort/deadline, before COMMIT
      await this.admission(tx, owner, taskId, { running: true, leaseId });
      this.stepLive(control); // include fresh memory generation / authority hook await
      return next;
    });
  }
  eventStep(owner, taskId, leaseId, kind, title, control) {
    return this.repository.transaction(async tx => {
      await this.admission(tx, owner, taskId, { running: true, leaseId }); this.stepLive(control);
      // Machine codes only; no prompt/provider payload or arbitrary error text in this wrapper.
      ensure(['progress', 'error', 'status'].includes(kind) && /^[a-z0-9_]{1,64}$/.test(title), 'unsafe_event');
      const event = await tx.insertIfAbsent(owner, 'run-events', { id: id(), taskId, leaseId, kind, title, detail: '', date: iso(this.now()) });
      this.stepLive(control); // awaited insert can return after abort/deadline, before COMMIT
      await this.admission(tx, owner, taskId, { running: true, leaseId });
      this.stepLive(control);
      return event;
    });
  }
  commitStep(owner, taskId, leaseId, operation, mutate, control) {
    ensure(typeof operation === 'string' && operation.length <= 128 && typeof mutate === 'function', 'invalid_local_operation');
    return this.repository.transaction(async tx => {
      const admitted = await this.admission(tx, owner, taskId, { running: true, leaseId }); this.stepLive(control);
      // Idempotence is delegated to original facade/artifact operation keys in this same transaction.
      // This wrapper only supplies fresh fenced authority; it does not create an effects table.
      const work=acceptedWorkExecution(this.workGrantService,owner,admitted.run,{now:this.now,task:admitted.task});
      const commit=()=>mutate(tx,{...admitted,operation,leaseId});
      const result = work?await work.commitReceived(tx,commit,{assertLive:()=>this.stepLive(control),deadline:control.deadline}):await commit();
      await this.admission(tx, owner, taskId, { running: true, leaseId });
      this.stepLive(control); // rollback if the callback crossed the step deadline/cancel boundary
      return result;
    });
  }
  prepareSettlement(task) { this.settlements.set(task.leaseId, checkpointHash(task)); }
}
