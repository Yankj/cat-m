import {FencedWorkerStore} from '../facade-r2/src/fenced-worker-store.mjs';
import {LostLeaseError} from '../integration/edge-adapter/vendor/openmuse/runtime/engine/worker.mjs';
import {ApiError,check,clone,hash} from '../facade-r2/src/common.mjs';
import {taskControlRevision} from './task-control-contract.mjs';
import {captureTaskExecutionFence,assertTaskExecutionFence} from './task-execution-fence.mjs';

const stopped = error => error instanceof LostLeaseError || error instanceof ApiError && [403,409].includes(error.status);
const unknown = task => task.state?.local_model?.round?.state === 'dispatched';
const settledStatuses = new Set(['queued','scheduled','succeeded','failed','outcome_unknown','waiting_input','waiting_approval']);
const iso = ms => new Date(ms).toISOString();

/** Maintenance adapter for the unchanged TaskWorker. Authority and lease checks belong at
 * every write, including its heartbeat and error cleanup; they are not UI cancellation. */
export class TaskExecutionStore extends FencedWorkerStore {
  constructor(facade,{now=Date.now}={}) { super(facade);this.now=now; }
  ownerAllowed(owner) { check(typeof owner==='string'&&owner.startsWith('catpaw:'),403,'scope_forbidden'); }
  async admission(tx,owner,id,{leaseId=null}={}) {
    this.ownerAllowed(owner);
    const admitted=await this.facade.admittedTask(tx,owner,id);
    check(admitted.run?.frozen_request?.work_grant_reference===undefined,409,'accepted_work_whole_executor_unsupported');
    await tx.lock(owner,'tasks',id);
    const task=await tx.get(owner,'tasks',id);
    check(hash(task?.state?.catpaw)===hash(admitted.task.state.catpaw),409,'operation_conflict');
    if(leaseId!==null) {
      if(task.status!=='running'||task.leaseId!==leaseId||!(Date.parse(task.leaseUntil)>this.now()))throw new LostLeaseError();
      const attempt=await tx.get(owner,'runs',leaseId);
      check(attempt?.taskId===id&&attempt.status==='running',409,'execution_permission_changed');
      // Reading the attempt may await beyond lease expiry even with no takeover yet.
      assertTaskExecutionFence(task,leaseId,this.now(),attempt.execution);
    }
    return {...admitted,task};
  }
  validatePatch(task,patch) {
    check(!Object.hasOwn(patch,'id')&&!Object.hasOwn(patch,'input'),409,'authority_patch_forbidden');
    if(patch.state)check(hash(patch.state.catpaw)===hash(task.state.catpaw)&&
      hash(patch.state.task_control??null)===hash(task.state.task_control??null),409,'authority_patch_forbidden');
    if(unknown(task)&&patch.state) {
      const round=patch.state.local_model?.round;
      check(round&&['dispatched','received'].includes(round.state)&&
        round.request_hash===task.state.local_model.round.request_hash,409,'dispatch_receipt_required');
    }
  }
  async claimAllowed(tx,owner,task) {
    if(task.status==='queued')return true;
    if(task.status==='scheduled')return Date.parse(task.nextRunAt??'')<=this.now();
    if(task.status==='running')return Date.parse(task.leaseUntil??'')<=this.now();
    if(task.status!=='waiting_approval')return false;
    const action=task.actionId?await tx.get(owner,'actions',task.actionId):null;
    return !action||!['awaiting_review','executing'].includes(action.status);
  }
  async compareAndSwap(owner,kind,id,expected,patch) {
    this.ownerAllowed(owner);
    if(kind==='runs')return this.repository.transaction(async tx=>{
      // Cleanup may only close its own unacknowledged attempt, never alter task state.
      check(expected.status==='running'&&['failed','interrupted'].includes(patch.status)&&
        Object.keys(patch).every(k=>['status','finishedAt'].includes(k)),409,'audit_cleanup_only');
      const attempt=await tx.get(owner,'runs',id);
      if(!attempt||attempt.execution?.acknowledged)return null;
      return tx.compareAndSwap(owner,kind,id,expected,patch);
    });
    if(kind==='actions')return this.expireAction(owner,id,expected,patch);
    check(kind==='tasks',422,'unsupported_cas');
    try { return await this.repository.transaction(async tx=>{
      const admitted=await this.admission(tx,owner,id),previous=admitted.task;
      const claiming=patch.status==='running'&&Boolean(patch.leaseId);
      if(claiming) {
        if(!await this.claimAllowed(tx,owner,previous))return null;
        check(Date.parse(patch.leaseUntil)>this.now()&&patch.leaseId!==previous.leaseId,409,'invalid_lease');
      } else {
        // A weak expected filter cannot turn an unleased/stopped task into worker output.
        check(expected.status==='running'&&expected.leaseId,409,'lease_lost');
        await this.admission(tx,owner,id,{leaseId:expected.leaseId});
      }
      this.validatePatch(previous,patch);
      const settling=patch.leaseId===null&&patch.status&&patch.status!=='running';
      if(settling) {
        check(settledStatuses.has(patch.status),422,'invalid_step_status');
        patch=clone(patch);
        // Abort/error after durable dispatch cannot prove no request reached the provider.
        if(unknown(previous))patch={...patch,status:'outcome_unknown',error:'dispatch_outcome_unknown; do not automatically resend'};
      }
      const next=await tx.compareAndSwap(owner,'tasks',id,expected,patch);
      if(!next)return null;
      if(claiming)await this.claimAttempt(tx,owner,next,admitted.run);
      if(settling)await this.acknowledge(tx,owner,previous,next);
      const fresh=await this.admission(tx,owner,id,next.status==='running'?{leaseId:next.leaseId}:{});
      check(fresh.task.status===next.status&&fresh.task.leaseId===next.leaseId&&
        hash(fresh.task.state)===hash(next.state),409,'execution_permission_changed');
      // Final authority admission is awaited on this transaction immediately before commit.
      return next;
    }); } catch(error) { if(stopped(error))return null;throw error; }
  }
  async claimAttempt(tx,owner,task,run) {
    check(run?.task_id===task.id&&run.request_hash===task.state.catpaw.request_hash,409,'operation_conflict');
    for(const old of (await tx.list(owner,'runs')).filter(r=>r.taskId===task.id&&r.status==='running'&&r.id!==task.leaseId))
      await tx.compareAndSwap(owner,'runs',old.id,{status:'running'},{status:'interrupted',finishedAt:iso(this.now()),recoveryReason:'superseded_lease'});
    const attempt=await tx.insertIfAbsent(owner,'runs',{id:task.leaseId,taskId:task.id,startedAt:iso(this.now()),status:'running',
      execution:{...captureTaskExecutionFence(task),acknowledged:false}});
    const link=await tx.insertIfAbsent(owner,'catpaw-run-links',{id:task.leaseId,run_id:run.id,operation_id:run.operation_id,task_id:task.id,grant_epoch:run.grant_epoch});
    check(attempt&&link,409,'run_conflict');
  }
  async acknowledge(tx,owner,previous,next) {
    const attempt=await tx.get(owner,'runs',previous.leaseId),link=await tx.get(owner,'catpaw-run-links',previous.leaseId);
    check(attempt?.status==='running'&&link?.task_id===previous.id&&
      attempt.execution?.revision===taskControlRevision(previous),409,'run_conflict');
    const result=await tx.compareAndSwap(owner,'runs',previous.leaseId,{status:'running'},
      {status:next.status,finishedAt:iso(this.now()),execution:{...attempt.execution,acknowledged:true,checkpoint_out:hash(next.state)}});
    check(result,409,'run_conflict');
  }
  async expireAction(owner,id,expected,patch) {
    check(expected.status==='awaiting_review'&&patch.status==='expired'&&Object.keys(patch).every(k=>k==='status'),409,'action_cleanup_only');
    try {return await this.repository.transaction(async tx=>{
      const action=await tx.get(owner,'actions',id);
      if(!action?.taskId)return null;
      const {task}=await this.admission(tx,owner,action.taskId);
      if(task.status!=='waiting_approval'||task.actionId!==id||!(Date.parse(action.expiresAt)<=this.now()))return null;
      const next=await tx.compareAndSwap(owner,'actions',id,expected,patch);
      const final=await this.admission(tx,owner,action.taskId);
      check(final.task.status==='waiting_approval'&&final.task.actionId===id,409,'execution_permission_changed');
      return next;
    });}catch(error){if(stopped(error))return null;throw error;}
  }
  async put(owner,kind,value) {
    if(owner==='system'&&kind==='worker-status')return super.put(owner,kind,value);
    this.ownerAllowed(owner);
    check(['runs','run-events'].includes(kind),409,'immutable_writer_required');
    return this.repository.transaction(async tx=>{
      if(kind==='runs') {
        const old=await tx.get(owner,'runs',value.id),link=await tx.get(owner,'catpaw-run-links',value.id);
        check(old?.taskId===value.taskId&&link?.task_id===value.taskId,409,'run_conflict');
        // Acknowledged output and retired leases are immutable to a late worker's final put.
        if(old.execution?.acknowledged||old.status!=='running')return old;
        check(value.status==='running',409,'settlement_acknowledgement_required');
        await this.admission(tx,owner,value.taskId,{leaseId:value.id});
        const stored=await tx.put(owner,'runs',{...old,...value,execution:old.execution});
        await this.admission(tx,owner,value.taskId,{leaseId:value.id});
        return stored;
      }
      check(value.leaseId,409,'lease_lost');
      await this.admission(tx,owner,value.taskId,{leaseId:value.leaseId});
      const stored=await tx.insertIfAbsent(owner,kind,value);
      await this.admission(tx,owner,value.taskId,{leaseId:value.leaseId});
      return stored;
    });
  }
}
