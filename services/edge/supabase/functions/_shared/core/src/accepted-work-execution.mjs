import {resolveExecutionGrantInTransaction} from './task-work-execution-selector.mjs';
import {check,hash,clone} from '../facade-r2/src/common.mjs';
import {TASK_WORK_GRANT_LIMITS as LIMITS,validateWorkGrantIdentity,validateWorkGrantReference,workGrantDueIdentity} from './task-work-grant-contract.mjs';
import {workerExecutionContext} from './task-control-contract.mjs';

export const ACCEPTED_WORK_EXECUTION_CAPABILITY=Object.freeze({schema_version:1,executor:'bounded_single_step_v1',whole:false,model:true,public_source:true,local_continuation:true,terminal_ack:true});
const iso=ms=>new Date(ms).toISOString();

/** Same scoped transaction, same maintained TaskWorker. These ports never
 * renew an HTTP token, manufacture source permission or send a request. */
export function acceptedWorkExecution(service,owner,run,{now=Date.now,task=null}={}){
 const reference=task?.state?.task_revision?.work_grant_reference??run?.frozen_request?.work_grant_reference;if(reference===undefined)return null;
 validateWorkGrantReference(reference);
 check(service?.repository&&typeof service.assertNewDispatchInTransaction==='function',503,'accepted_work_executor_not_configured');
 const identity=validateWorkGrantIdentity({owner,scope_id:run.frozen_request.scope.scope_id,subject_id:run.frozen_request.subject_id,grant_id:reference.grant_id});
 return new AcceptedWorkExecution({service,identity,reference,owner,runID:run.id,now});
}
export async function acceptedWorkClaimEligibleInTransaction(tx,service,owner,run,{now=Date.now,assertLive=()=>{}}={}){
 const task=await tx.get(owner,'tasks',run.task_id);assertLive();const work=acceptedWorkExecution(service,owner,run,{now,task});return work?work.eligibleForClaim(tx,{assertLive}):true;
}
class AcceptedWorkExecution{
 constructor(input){Object.assign(this,input);}
 async current(tx,{assertLive=()=>{}}={}){const run=await tx.get(this.owner,'catpaw-runs',this.runID),task=await tx.get(this.owner,'tasks',run?.task_id);assertLive();const selected=await resolveExecutionGrantInTransaction(tx,this.owner,run,task,{assertLive});check(selected&&hash(selected.identity)===hash(this.identity)&&hash(selected.reference)===hash(this.reference),409,'work_grant_revision_superseded');await this.service.assertAcceptedGrantCurrentInTransaction(tx,this.identity,{assertLive});return this.service.current(tx,this.identity,this.service.permission(undefined,assertLive));}
 due(ctx){const due=ctx.reservations.find(r=>r.frozen.input.kind==='due');check(due?.state==='reserved'&&this.now()<Date.parse(due.frozen.input.deadline_at)&&!ctx.reservations.some(r=>r.state==='unknown'),409,'accepted_work_due_not_open');return due;}
 async eligibleForClaim(tx,options={}){const ctx=await this.current(tx,options),due=ctx.reservations.find(r=>r.frozen.input.kind==='due');return !ctx.reservations.some(r=>r.state==='unknown')&&(!due||due.state==='reserved'&&this.now()<Date.parse(due.frozen.input.deadline_at));}
 async claim(tx,options={}){
  let ctx=await this.current(tx,options),due=ctx.reservations.find(r=>r.frozen.input.kind==='due');
  if(!due){await this.service.reserveInTransaction(tx,this.identity,{...workGrantDueIdentity(ctx.terms,ctx.run),kind:'due',deadline_at:iso(Math.min(Date.parse(ctx.terms.not_after),this.now()+ctx.terms.execution_budget_ms))});ctx=await this.current(tx,options);}
  this.due(ctx);
 }
 async running(tx,options={}){const ctx=await this.current(tx,options);this.due(ctx);return ctx;}
 async deadline(tx,options={}){const ctx=await this.running(tx,options);return Math.min(Date.parse(this.due(ctx).frozen.input.deadline_at),Date.parse(ctx.terms.not_after),Date.parse(ctx.task.leaseUntil));}
 async reserveModel(tx,requestHash,{assertLive,deadline}={}){
  const ctx=await this.running(tx,{assertLive}),local=ctx.task.state.local_model??{step:0,messages:[],round:null,artifact:null};check(!local.round,409,'round_already_checkpointed');
  const operation={operation_id:hash({contract:'catpaw.accepted-model-attempt.v1',run_id:ctx.run.id,plan_reference:ctx.task.state.plan_binding,step:local.step,request_hash:requestHash}),operation_key:hash({kind:'model',plan_reference:ctx.task.state.plan_binding,step:local.step}),kind:'model',request_hash:requestHash,deadline_at:iso(Math.min(this.now()+LIMITS.result_budget_ms,deadline,Date.parse(this.due(ctx).frozen.input.deadline_at),Date.parse(ctx.terms.not_after)))};
  const result=await this.service.reserveInTransaction(tx,this.identity,operation,{execution:workerExecutionContext(ctx.run,ctx.task)});check(result.created&&result.may_dispatch,409,'accepted_work_original_dispatch_replayed');return result.reservation;
 }
 async guardModel(tx,reservation,{assertLive}={}){
  const ctx=await this.running(tx,{assertLive}),round=ctx.task.state.local_model?.round;
  await this.service.assertNewDispatchInTransaction(tx,this.identity,{original_reservation:reservation,execution:workerExecutionContext(ctx.run,ctx.task),durable_checkpoint:{kind:'model',request_hash:round?.request_hash,checkpoint_hash:hash(round)}},{assertLive});
 }
 async receivedModel(tx,{assertLive}={}){
  const ctx=await this.running(tx,{assertLive}),local=ctx.task.state.local_model,point=local?.work_grant_round,round=local?.round;check(point&&round?.state==='received'&&point.request_hash===round.request_hash,409,'accepted_work_original_model_required');
  return this.service.settleTransportOutcomeInTransaction(tx,this.identity,{operation_id:point.operation_id,request_hash:point.request_hash,outcome:'received',receipt_reference:{receipt_id:point.operation_id,receipt_hash:hash(round)}},{execution:workerExecutionContext(ctx.run,ctx.task),assertLive});
 }
 async commitReceived(tx,mutate,{assertLive,deadline}={}){
  const ctx=await this.running(tx,{assertLive}),point=ctx.task.state.local_model?.work_grant_round;check(point,409,'accepted_work_original_model_required');
  return this.service.commitReceivedContinuationInTransaction(tx,this.identity,point.operation_id,mutate,{execution:workerExecutionContext(ctx.run,ctx.task),currentSliceDeadline:deadline,assertLive});
 }
 async reserveSource(tx,read,{assertLive}={}){
  const ctx=await this.running(tx,{assertLive}),due=this.due(ctx),result=await this.service.reserveInTransaction(tx,this.identity,{operation_id:read.id,operation_key:hash({kind:'source',plan_reference:read.plan_reference,source_id:read.source_id}),kind:'source',request_hash:read.request_hash,deadline_at:iso(Math.min(this.now()+LIMITS.result_budget_ms,Date.parse(due.frozen.input.deadline_at),Date.parse(ctx.terms.not_after),Date.parse(ctx.task.leaseUntil)))},{execution:workerExecutionContext(ctx.run,ctx.task)});check(result.created&&result.may_dispatch,409,'accepted_work_original_dispatch_replayed');return result.reservation;
 }
 async guardSource(tx,read,{assertLive}={}){
  const ctx=await this.running(tx,{assertLive}),original=ctx.reservations.find(r=>r.id===read.id);check(original,409,'accepted_work_original_source_required');
  await this.service.assertNewDispatchInTransaction(tx,this.identity,{original_reservation:original,execution:workerExecutionContext(ctx.run,ctx.task),durable_checkpoint:{kind:'source',read_id:read.id,request_hash:read.request_hash,checkpoint_hash:hash(read)}},{assertLive});
 }
 async receivedSource(tx,read,{assertLive}={}){
  const ctx=await this.running(tx,{assertLive}),verified=await this.service.sourceService.validateWorkGrantTransportReceiptInTransaction(tx,ctx.owner,ctx.run,ctx.task,{read_id:read.id,request_hash:read.request_hash,lease_id:read.dispatch_lease_id});
  return this.service.settleTransportOutcomeInTransaction(tx,this.identity,{operation_id:read.id,request_hash:read.request_hash,outcome:'received',receipt_reference:verified},{execution:workerExecutionContext(ctx.run,ctx.task),assertLive});
 }
 async failedSource(tx,read,{assertLive}={}){const ctx=await this.running(tx,{assertLive});return this.service.settleSourceFailureInTransaction(tx,this.identity,read.id,{execution:workerExecutionContext(ctx.run,ctx.task),assertLive});}
 async acknowledge(tx,previous,next,{assertLive=()=>{}}={}){
  if(!['succeeded','failed','outcome_unknown'].includes(next.status))return;
  let proof=null;
  if(next.status==='succeeded'){
   const ctx=await this.current(tx,{assertLive}),reference=next.state.local_model?.artifact,plan=next.state.plan_binding,verify=await tx.get(ctx.owner,'catpaw-task-plan-receipts',ctx.run.id+':'+plan?.revision+':verify');assertLive();
   check(reference&&verify,409,'accepted_work_completion_receipt_required');proof={artifact_reference:clone(reference),plan_reference:clone(plan),verification_receipt:{id:verify.id,receipt_hash:verify.receipt_hash}};
  }
  return this.service.settleOriginalAttemptInTransaction(tx,this.identity,{previous_task:previous,attempt_id:previous.leaseId,completion_receipt:proof},{assertLive});
 }
}
