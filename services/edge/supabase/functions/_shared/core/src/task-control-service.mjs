import {check,hash,clone,UUID,iso,shape} from '../facade-r2/src/common.mjs';
import {TASK_CONTROL_CONTRACT,TASK_CONTROL_OPERATIONS,TASK_CONTROL_LIMITS,taskControlRevision,validateTaskControlRequest,taskControlReceiptHash} from './task-control-contract.mjs';
import {samePlan} from './plan-contract.mjs';
import {invalidatePendingTaskActionsInTransaction} from './task-action-service.mjs';
import {lockTaskWorkSourceInTransaction,readTaskWorkGrantLifecycleInTransaction,transitionTaskWorkGrantInTransaction} from './task-work-grant-lifecycle.mjs';

const terminal=new Set(['succeeded','failed','cancelled']);
async function resolve(facade,tx,scoped,scopeID,runID){
 await tx.withScope(scopeID,async scopedTx=>{const row=await scopedTx.scope();check(row.identity.owner===scoped.owner,403,'scope_forbidden');});
 const run=await facade.ownedRun(tx,scoped.owner,runID,scoped.principal,scopeID),f=run.frozen_request;
 check(hash(f)===run.request_hash,409,'control_run_binding_conflict');
 await lockTaskWorkSourceInTransaction(tx,{scope_id:scopeID,owner:scoped.owner,source:f.source_auth});
 const workGrant=await readTaskWorkGrantLifecycleInTransaction(tx,scoped.owner,run,{now:facade.taskControlNow??Date.now});
 const d=await facade.ownedDelegation(tx,scoped.owner,run.delegation_id,scoped.principal,{lock:true,scopeID});await tx.lock(scoped.owner,'tasks',run.task_id);
 const task=await tx.get(scoped.owner,'tasks',run.task_id),tag=task?.state?.catpaw;
 check(task?.id===run.task_id&&tag?.run_id===run.id&&['operation_id','delegation_id','delegation_revision','grant_epoch','request_hash'].every(k=>tag[k]===run[k]),409,'control_task_binding_conflict');
 await tx.lock(scoped.owner,'catpaw-task-plan-heads',run.id);const head=await tx.get(scoped.owner,'catpaw-task-plan-heads',run.id);
 check(head?.run_id===run.id&&head.task_id===task.id&&head.scope_id===scopeID&&head.subject_id===scoped.principal.subject_id&&samePlan(task.state.plan_binding,{revision:head.applied_revision,plan_hash:head.applied_plan_hash}),409,'control_plan_binding_conflict');
 return {...scoped,run,task,d,head,workGrant};
}
async function authority(facade,tx,ctx,write=false){
 const hook=write?facade.beforeTaskControlWrite:facade.beforeTaskControlRead;check(typeof hook==='function',503,'control_authority_not_configured');
 const result=await hook(tx,ctx);check(typeof result?.source_current==='boolean',503,'control_authority_result_required');return result;
}
export async function unresolvedTaskOperations(tx,owner,run,task,workGrant=null){
 const result=[],round=task.state?.local_model?.round;
 if(round?.state==='dispatched'){check(/^[a-f0-9]{64}$/.test(round.request_hash??''),409,'control_dispatch_identity_missing');result.push({kind:'model',operation_id:round.request_hash,state:'dispatched',can_retry:false});}
 for(const r of await tx.list(owner,'catpaw-task-source-reads'))if(r.run_id===run.id&&['dispatched','unknown'].includes(r.state))result.push({kind:'public_source',operation_id:r.id,state:r.state,can_retry:false});
 for(const b of await tx.list(owner,'catpaw-approval-bindings'))if(b.run_id===run.id){const a=await tx.get(owner,'actions',b.id);if(['executing','outcome_unknown','failed'].includes(a?.status)&&b.reconciliation_state!=='resolved_local')result.push({kind:'effect',operation_id:b.id,state:a.status,can_retry:false});}
 if(run.frozen_request.work_grant_reference){
  workGrant??=await readTaskWorkGrantLifecycleInTransaction(tx,owner,run);
  for(const row of workGrant.reservations)if(row.frozen.input.kind!=='due'&&['reserved','unknown'].includes(row.state)){
   const kind=row.frozen.input.kind==='model'?'model':'public_source',existing=result.find(r=>r.kind===kind&&r.operation_id===(kind==='model'?row.frozen.input.request_hash:row.id));
   if(existing)existing.operation_id=row.id;
   else result.push({kind,operation_id:row.id,state:row.state==='reserved'?'dispatched':'unknown',can_retry:false});
  }
 }
 check(result.length<=TASK_CONTROL_LIMITS.unknown_operations,409,'control_unknown_inventory_limit');return result.sort((a,b)=>(a.kind+':'+a.operation_id).localeCompare(b.kind+':'+b.operation_id));
}
async function snapshot(facade,tx,ctx){
 const source=await authority(facade,tx,ctx),{run,task,d,head,workGrant}=ctx,unknown=await unresolvedTaskOperations(tx,ctx.owner,run,task,workGrant),grantOpen=d.state==='active'&&d.grant_epoch===run.grant_epoch&&d.revision===run.delegation_revision&&workGrant?.state.state!=='revoked',open=grantOpen&&!workGrant?.dueClosed;
 const unknownBarrier=task.status==='outcome_unknown'||task.state?.task_control?.previous_status==='outcome_unknown';
 const reason=!grantOpen?'grant_changed':workGrant?.dueUnknown?'original_outcome_unknown':workGrant?.dueClosed?'grant_changed':workGrant?.expired?'work_grant_expired':!source.source_current?(source.reason??'source_not_current'):unknown.length?'original_outcome_unknown':unknownBarrier?'original_outcome_identity_missing':task.status==='paused'?(task.state?.task_control?.reason??'user_paused'):null;
 const value={scope_id:run.frozen_request.scope.scope_id,subject_id:run.frozen_request.subject_id,conversation_id:run.frozen_request.conversation_id,run_id:run.id,task_id:task.id,run_request_hash:run.request_hash,delegation_id:run.delegation_id,delegation_revision:run.delegation_revision,grant_epoch:run.grant_epoch,authority_reference:{delegation_revision:d.revision,grant_epoch:d.grant_epoch,state:d.state},execution_revision:taskControlRevision(task),task_status:task.status,plan_reference:clone(task.state.plan_binding),source_authorization_current:source.source_current,blocked_reason:reason,unresolved_operations:unknown,
  can_pause:open&&(!workGrant||workGrant.state.state==='active')&&!terminal.has(task.status)&&task.status!=='paused',can_resume:open&&(!workGrant||workGrant.state.state==='paused'&&!workGrant.expired)&&source.source_current&&task.status==='paused'&&task.state?.task_control?.reason==='user_paused'&&!unknown.length&&!unknownBarrier&&head.accepted_revision===head.applied_revision,can_revoke:d.state!=='revoked'&&!terminal.has(task.status)};
 return {...value,snapshot_hash:hash(value)};
}
function validOperation(op,ctx){
 const corrupt=()=>check(false,409,'control_operation_corrupt');
 let input;try{
  shape(op?.frozen,['scope_id','subject_id','run_id','task_id','run_request_hash','source_auth','input']);
  shape(op?.receipt,['operation_id','operation_hash','scope_id','subject_id','conversation_id','run_id','task_id','run_request_hash','action','base_execution_revision','accepted_execution_revision','base_snapshot_hash','grant_epoch','plan_reference','result_task_status','applied_at','state','receipt_hash']);
  shape(op.receipt.plan_reference,['revision','plan_hash']);
  input=validateTaskControlRequest(op.frozen.input);
 }catch{corrupt();}
 const f=ctx.run.frozen_request,r=op.receipt;
 check(op.run_id===ctx.run.id&&op.task_id===ctx.task.id&&op.scope_id===f.scope.scope_id&&op.subject_id===ctx.principal.subject_id&&op.conversation_id===f.conversation_id&&op.id===input.operation_id&&op.id===r.operation_id&&
  op.frozen.scope_id===op.scope_id&&op.frozen.subject_id===op.subject_id&&op.frozen.run_id===op.run_id&&op.frozen.task_id===op.task_id&&op.frozen.run_request_hash===ctx.run.request_hash&&hash(op.frozen.source_auth)===hash(f.source_auth)&&
  hash(op.frozen)===op.operation_hash&&r.operation_hash===op.operation_hash&&op.request_hash===hash({scope_id:op.scope_id,run_id:op.run_id,...input})&&
  r.scope_id===op.scope_id&&r.subject_id===op.subject_id&&r.conversation_id===op.conversation_id&&r.run_id===op.run_id&&r.task_id===op.task_id&&r.run_request_hash===ctx.run.request_hash&&
  r.action===input.action&&r.base_execution_revision===input.expected_execution_revision&&r.accepted_execution_revision===r.base_execution_revision+1&&Number.isSafeInteger(r.accepted_execution_revision)&&
  r.base_snapshot_hash===input.expected_snapshot_hash&&r.grant_epoch===input.expected_grant_epoch&&r.grant_epoch===ctx.run.grant_epoch&&samePlan(r.plan_reference,{revision:input.expected_plan_revision,plan_hash:input.expected_plan_hash})&&
  (r.action==='pause'?r.result_task_status==='paused':r.action==='revoke'?r.result_task_status==='cancelled':['scheduled','waiting_input'].includes(r.result_task_status))&&r.state==='applied'&&typeof r.applied_at==='string'&&Number.isFinite(Date.parse(r.applied_at))&&new Date(r.applied_at).toISOString()===r.applied_at&&taskControlReceiptHash(r)===r.receipt_hash,409,'control_operation_corrupt');
 return clone(r);
}
export async function readTaskControl(facade,auth,scopeID,runID,operationID){
 check(UUID.test(runID)&&(!operationID||UUID.test(operationID)),422,'control_schema_invalid');const scoped=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{const ctx=await resolve(facade,tx,scoped,scopeID,runID),control=await snapshot(facade,tx,ctx);let operation;if(operationID){const op=await tx.get(ctx.owner,TASK_CONTROL_OPERATIONS,operationID);check(op,404,'not_found');operation=validOperation(op,ctx);}await authority(facade,tx,ctx);return {schema_version:1,contract:TASK_CONTROL_CONTRACT,control,...operation?{operation}:{}};});
}
export async function controlTask(facade,auth,scopeID,runID,input,{signal=null}={}){
 input=validateTaskControlRequest(input);const scoped=await facade.scoped(auth,scopeID),requestHash=hash({scope_id:scopeID,run_id:runID,...input}),clock=facade.taskControlNow??Date.now,started=clock();
 check(Number.isSafeInteger(started),409,'control_deadline');let lastClock=started;
 const live=()=>{check(!signal?.aborted,409,'control_cancelled');const now=clock();check(Number.isSafeInteger(now)&&now>=lastClock&&now-started<TASK_CONTROL_LIMITS.write_budget_ms,409,'control_deadline');lastClock=now;};
 const committed=await facade.repository.transaction(async tx=>{
  live();let ctx=await resolve(facade,tx,scoped,scopeID,runID);live();ctx.action=input.action;await authority(facade,tx,ctx,true);live();
  const prior=await tx.get(ctx.owner,TASK_CONTROL_OPERATIONS,input.operation_id);live();
  if(prior){check(prior.request_hash===requestHash,409,'control_operation_conflict');const operation=validOperation(prior,ctx),control=await snapshot(facade,tx,ctx);live();return {envelope:{schema_version:1,contract:TASK_CONTROL_CONTRACT,control,operation},wake:null,abort:null};}
  const before=await snapshot(facade,tx,ctx);live();check(before.snapshot_hash===input.expected_snapshot_hash&&before.execution_revision===input.expected_execution_revision,409,'control_snapshot_conflict');check(before.grant_epoch===input.expected_grant_epoch&&samePlan(before.plan_reference,{revision:input.expected_plan_revision,plan_hash:input.expected_plan_hash}),409,'control_binding_conflict');
  check(before[{pause:'can_pause',resume:'can_resume',revoke:'can_revoke'}[input.action]],409,input.action==='resume'&&(before.unresolved_operations.length||before.blocked_reason==='original_outcome_identity_missing')?'control_original_outcome_unknown':'control_action_not_available');
  const revision=before.execution_revision+1,at=iso(),previous=ctx.task.state.task_control?.previous_status??ctx.task.status;
  const nextStatus=input.action==='pause'?'paused':input.action==='revoke'?'cancelled':previous==='waiting_input'?'waiting_input':'scheduled';
  const next={...ctx.task,status:nextStatus,leaseId:null,leaseUntil:null,...nextStatus==='scheduled'?{nextRunAt:at}:{},state:{...clone(ctx.task.state),task_control:{revision,operation_id:input.operation_id,reason:input.action==='pause'?'user_paused':input.action==='revoke'?'user_revoked':null,previous_status:input.action==='pause'?ctx.task.status:previous}},updatedAt:at};
  // The finite grant state changes before task/delegation under the same exact
  // control transaction. Original immutable terms and spent budget are retained.
  await transitionTaskWorkGrantInTransaction(tx,ctx.owner,ctx.run,{action:input.action,now:clock,assertLive:live});live();
  await tx.put(ctx.owner,'tasks',next);live();if(input.action==='revoke'){const d={...ctx.d,state:'revoked',revision:ctx.d.revision+1,grant_epoch:ctx.d.grant_epoch+1};await tx.put(ctx.owner,'catpaw-delegations',d);live();}
  await invalidatePendingTaskActionsInTransaction(tx,ctx.owner,{run_id:runID,task_id:next.id,reason:input.action==='revoke'?'grant_changed':'task_not_active'});live();
  for(const b of await tx.list(ctx.owner,'catpaw-approval-bindings'))if(b.run_id===runID){const a=await tx.get(ctx.owner,'actions',b.id);if(a?.status==='awaiting_review')check(await tx.compareAndSwap(ctx.owner,'actions',b.id,{status:'awaiting_review'},{status:'denied'}),409,'control_approval_conflict');live();}
  const frozen={scope_id:scopeID,subject_id:ctx.principal.subject_id,run_id:runID,task_id:next.id,run_request_hash:ctx.run.request_hash,source_auth:clone(ctx.run.frozen_request.source_auth),input:clone(input)},operationHash=hash(frozen);
  const fields={operation_id:input.operation_id,operation_hash:operationHash,scope_id:scopeID,subject_id:ctx.principal.subject_id,conversation_id:ctx.run.frozen_request.conversation_id,run_id:runID,task_id:next.id,run_request_hash:ctx.run.request_hash,action:input.action,base_execution_revision:before.execution_revision,accepted_execution_revision:revision,base_snapshot_hash:before.snapshot_hash,grant_epoch:before.grant_epoch,plan_reference:before.plan_reference,result_task_status:nextStatus,applied_at:at,state:'applied'};
  const receipt={...fields,receipt_hash:taskControlReceiptHash(fields)};check(await tx.insertIfAbsent(ctx.owner,TASK_CONTROL_OPERATIONS,{id:input.operation_id,scope_id:scopeID,subject_id:ctx.principal.subject_id,conversation_id:ctx.run.frozen_request.conversation_id,run_id:runID,task_id:next.id,request_hash:requestHash,operation_hash:operationHash,frozen,receipt}),409,'control_operation_conflict');live();
  ctx={...ctx,task:next,action:input.action};await authority(facade,tx,ctx,true);live();const current=await resolve(facade,tx,scoped,scopeID,runID);live();check(taskControlRevision(current.task)===revision&&current.task.status===nextStatus&&current.task.leaseId===null,409,'control_commit_conflict');const control=await snapshot(facade,tx,current);live();await authority(facade,tx,{...current,action:input.action},true);live();
  if(ctx.workGrant){const grant=await readTaskWorkGrantLifecycleInTransaction(tx,ctx.owner,ctx.run,{now:clock,assertLive:live});check(grant.state.state==={pause:'paused',resume:'active',revoke:'revoked'}[input.action]&&hash(grant.terms)===hash(ctx.workGrant.terms)&&hash(grant.state.consumed)===hash(ctx.workGrant.state.consumed)&&(input.action!=='resume'||!grant.expired&&!grant.dueClosed),409,'control_commit_conflict');live();}
  return {envelope:{schema_version:1,contract:TASK_CONTROL_CONTRACT,control,operation:receipt},abort:input.action==='resume'?null:next.id,wake:nextStatus==='scheduled'?{owner:ctx.owner,run_id:runID,task_id:next.id,turn_id:ctx.run.frozen_request.turn_id,source_auth:clone(ctx.workGrant?.terms.source_auth??ctx.run.frozen_request.source_auth),...ctx.workGrant?.terms.schema_version===2?{revision_work_operation_id:ctx.workGrant.terms.revision_binding.operation_id}:{}}:null};
 });
 if(committed.abort)facade.abortTask(committed.abort);if(committed.wake)try{await facade.onTaskControlAccepted?.(committed.wake);}catch{/* durable state remains authoritative */}return committed.envelope;
}
