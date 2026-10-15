import {check,hash,iso,clone,UUID} from '../facade-r2/src/common.mjs';
import {PLAN_CONTRACT,PLAN_RECEIPT_KINDS,initialPlanContent,validatePlanAmendment,planBinding,samePlan,planTaskSteps} from './plan-contract.mjs';
import {hasUnresolvedSourceReads} from './task-source-service.mjs';
import {invalidatePendingTaskActionsInTransaction} from './task-action-service.mjs';

const HEAD='catpaw-task-plan-heads',VERSIONS='catpaw-task-plan-versions',OPS='catpaw-task-plan-operations',RECEIPTS='catpaw-task-plan-receipts';
const pending=head=>head.accepted_revision!==head.applied_revision;
const terminal=new Set(['succeeded','failed','cancelled']);
const unknown=task=>task.status==='outcome_unknown'||task.state?.local_model?.round?.state==='dispatched';
async function effectUnknown(tx,owner,run){
 if(await hasUnresolvedSourceReads(tx,owner,run.id))return true;
 for(const binding of await tx.list(owner,'catpaw-approval-bindings'))if(binding.run_id===run.id){const action=await tx.get(owner,'actions',binding.id);if(['executing','outcome_unknown','failed'].includes(action?.status)&&binding.reconciliation_state!=='resolved_local')return true;}
 return false;
}
// Received calls are preserved until settled. A terminal, non-effect call can be
// superseded before execution; the full original round remains in the checkpoint ledger.
function safe(task){
 if(unknown(task))return false;
 const round=task.state?.local_model?.round;
 return !round||(round.state==='received'&&(round.next===round.calls.length||['ask_user','finish_task'].includes(round.calls[round.next]?.name)));
}
export async function taskPlanCheckpointReady(tx,owner,run,task){const head=await tx.get(owner,HEAD,run.id);return Boolean(head&&pending(head)&&safe(task)&&!await effectUnknown(tx,owner,run));}
export async function taskPlanExecutionDisposition(tx,owner,run,task){const head=await tx.get(owner,HEAD,run.id);return head&&pending(head)?unknown(task)||await effectUnknown(tx,owner,run)?'blocked_unknown':'pending':'applied';}
function boundHead(head,run){
 if(head)check(head.run_id===run.id&&head.task_id===run.task_id&&head.scope_id===run.frozen_request.scope.scope_id&&head.subject_id===run.frozen_request.subject_id&&head.conversation_id===run.frozen_request.conversation_id&&Number.isSafeInteger(head.accepted_revision)&&head.accepted_revision>=head.applied_revision&&Number.isSafeInteger(head.applied_revision)&&head.applied_revision>0,409,'plan_binding_conflict');
 return head;
}
async function headFor(tx,owner,run){await tx.lock(owner,HEAD,run.id);return boundHead(await tx.get(owner,HEAD,run.id),run);}
export async function createTaskPlan(tx,owner,run,task){
 const content=initialPlanContent(run.frozen_request.args),plan_hash=hash(content),created_at=iso();
 const head={id:run.id,run_id:run.id,task_id:task.id,conversation_id:run.frozen_request.conversation_id,scope_id:run.frozen_request.scope.scope_id,subject_id:run.frozen_request.subject_id,accepted_revision:1,accepted_plan_hash:plan_hash,applied_revision:1,applied_plan_hash:plan_hash,application_state:'applied',created_at};
 check(await tx.insertIfAbsent(owner,VERSIONS,{id:`${run.id}:1`,run_id:run.id,revision:1,plan_hash,content,created_at}),409,'revision_conflict');
 check(await tx.insertIfAbsent(owner,HEAD,head),409,'revision_conflict');
 return {...task,plan:planTaskSteps(content),state:{...task.state,plan_binding:planBinding(head)}};
}
export async function planSnapshot(tx,owner,run,task){
 const head=boundHead(await tx.get(owner,HEAD,run.id),run);if(!head)return null;
 const accepted=await tx.get(owner,VERSIONS,`${run.id}:${head.accepted_revision}`),applied=await tx.get(owner,VERSIONS,`${run.id}:${head.applied_revision}`);
 check(accepted?.run_id===run.id&&accepted.revision===head.accepted_revision&&applied?.run_id===run.id&&applied.revision===head.applied_revision&&hash(accepted.content)===head.accepted_plan_hash&&hash(applied.content)===head.applied_plan_hash,409,'plan_hash_conflict');
 const receipts=(await tx.list(owner,RECEIPTS)).filter(r=>r.run_id===run.id&&r.plan_revision===head.applied_revision&&r.plan_hash===head.applied_plan_hash).map(({step_id,plan_revision,plan_hash,status,receipt_kind,receipt_hash,created_at})=>({step_id,plan_revision,plan_hash,status,receipt_kind,receipt_hash,created_at}));
 receipts.sort((a,b)=>['compose','save','verify'].indexOf(a.step_id)-['compose','save','verify'].indexOf(b.step_id));
 return {run_id:run.id,task_id:task.id,conversation_id:head.conversation_id,accepted_revision:head.accepted_revision,accepted_plan_hash:head.accepted_plan_hash,applied_revision:head.applied_revision,applied_plan_hash:head.applied_plan_hash,application_state:pending(head)?(unknown(task)||await effectUnknown(tx,owner,run)?'blocked_unknown':'pending'):'applied',task_status:task.status,content:clone(accepted.content),applied_content:clone(applied.content),step_receipts:receipts};
}
async function viewer(facade,tx,ctx){check(typeof facade.beforePlanRead==='function',503,'plan_authority_not_configured');await facade.beforePlanRead(tx,ctx);}
async function resolve(facade,tx,scoped,scopeID,runID){
 await tx.withScope(scopeID,async()=>{});
 const run=await facade.ownedRun(tx,scoped.owner,runID,scoped.principal,scopeID);
 const d=await facade.ownedDelegation(tx,scoped.owner,run.delegation_id,scoped.principal,{lock:true,scopeID});
 await tx.lock(scoped.owner,'tasks',run.task_id);const task=await tx.get(scoped.owner,'tasks',run.task_id);check(task,404,'not_found');
 const head=await headFor(tx,scoped.owner,run);check(head,404,'not_found');
 return {...scoped,run,task,head,d};
}
export async function readTaskPlan(facade,auth,scopeID,runID,operationID){
 if(operationID!==undefined)check(UUID.test(operationID),422,'schema_invalid');
 const scoped=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{
  const ctx=await resolve(facade,tx,scoped,scopeID,runID);await viewer(facade,tx,ctx);
  const plan=await planSnapshot(tx,ctx.owner,ctx.run,ctx.task);
  let amendment;if(operationID!==undefined){const op=await tx.get(ctx.owner,OPS,operationID.toLowerCase());check(op?.run_id===runID,404,'not_found');amendment=publicOperation(op,ctx.head,plan.application_state);}
  await viewer(facade,tx,ctx);
  return {schema_version:1,contract:PLAN_CONTRACT,plan,...amendment?{amendment}:{}};
 });
}
function publicOperation(op,head,disposition){return {operation_id:op.id,state:head.applied_revision>=op.accepted_revision?'applied':disposition,accepted_revision:op.accepted_revision,accepted_plan_hash:op.accepted_plan_hash};}
export async function amendTaskPlan(facade,auth,scopeID,runID,input){
 input=validatePlanAmendment(input);input.operation_id=input.operation_id.toLowerCase();
 const request_hash=hash({run_id:runID,...input}),scoped=await facade.scoped(auth,scopeID);
 const committed=await facade.repository.transaction(async tx=>{
  let ctx=await resolve(facade,tx,scoped,scopeID,runID);ctx.content=input.content;
  check(typeof facade.beforePlanWrite==='function',503,'plan_authority_not_configured');await facade.beforePlanWrite(tx,ctx);
  const prior=await tx.get(ctx.owner,OPS,input.operation_id);
  if(prior){check(prior.run_id===runID&&prior.request_hash===request_hash,409,'plan_operation_conflict');const plan=await planSnapshot(tx,ctx.owner,ctx.run,ctx.task);await facade.beforePlanWrite(tx,ctx);return {envelope:{schema_version:1,contract:PLAN_CONTRACT,plan,amendment:publicOperation(prior,ctx.head,plan.application_state)},wake:null};}
  check(ctx.d.state==='active'&&ctx.d.grant_epoch===input.expected_grant_epoch&&ctx.d.grant_epoch===ctx.run.grant_epoch&&ctx.d.revision===ctx.run.delegation_revision,409,'grant_conflict');
  check(ctx.head.accepted_revision===input.expected_revision,409,'revision_conflict');check(ctx.head.accepted_plan_hash===input.expected_plan_hash,409,'plan_hash_conflict');
  check(!pending(ctx.head),409,'plan_application_pending');
  check(!terminal.has(ctx.task.status)&&ctx.task.status!=='paused',409,'plan_task_not_editable');
  // A received report-revision operation freezes its plan/result relation. A
  // separate ordinary amendment cannot replace that plan and strand execution.
  check(!ctx.task.state?.task_revision,409,'plan_revision_in_progress');
  if(ctx.run.frozen_request.completion_contract?.mode==='single_local_report')check(hash(input.content.stop_conditions)===hash(ctx.run.frozen_request.args.stop_conditions),409,'plan_completion_contract_conflict');
  // Completion validation and amendment share the same delegation/task/head locks.
  // Once validated, a running task is committing that revision and cannot accept a new one.
  check(!await tx.get(ctx.owner,RECEIPTS,`${runID}:${ctx.head.applied_revision}:verify`),409,'plan_completion_committing');
  const revision=ctx.head.accepted_revision+1,plan_hash=hash(input.content),created_at=iso();
  check(await tx.insertIfAbsent(ctx.owner,VERSIONS,{id:`${runID}:${revision}`,run_id:runID,revision,plan_hash,content:clone(input.content),created_at}),409,'revision_conflict');
  ctx.head={...ctx.head,accepted_revision:revision,accepted_plan_hash:plan_hash,application_state:unknown(ctx.task)||await effectUnknown(tx,ctx.owner,ctx.run)?'blocked_unknown':'pending',updated_at:created_at};await tx.put(ctx.owner,HEAD,ctx.head);
  // A changed plan cannot consume an old approval. Consumed/unknown effects remain reconcilable.
  await invalidatePendingTaskActionsInTransaction(tx,ctx.owner,{run_id:ctx.run.id,task_id:ctx.task.id,reason:'plan_changed'});
  for(const b of await tx.list(ctx.owner,'catpaw-approval-bindings'))if(b.task_id===ctx.task.id){const a=await tx.get(ctx.owner,'actions',b.id);if(a?.status==='awaiting_review')check(await tx.compareAndSwap(ctx.owner,'actions',b.id,{status:'awaiting_review'},{status:'denied'}),409,'approval_stale');}
  if(ctx.task.status!=='running'&&safe(ctx.task)){const applied=await applyPendingPlan(tx,ctx.owner,ctx.run,ctx.task,ctx.head);ctx={...ctx,...applied};}
  const op={id:input.operation_id,run_id:runID,task_id:ctx.task.id,request_hash,accepted_revision:revision,accepted_plan_hash:plan_hash,state:ctx.head.application_state,created_at};check(await tx.insertIfAbsent(ctx.owner,OPS,op),409,'plan_operation_conflict');
  await facade.beforePlanWrite(tx,ctx);const plan=await planSnapshot(tx,ctx.owner,ctx.run,ctx.task);await facade.beforePlanWrite(tx,ctx);
  const wake=plan.application_state==='blocked_unknown'?null:{owner:ctx.owner,run_id:ctx.run.id,task_id:ctx.task.id,turn_id:ctx.run.frozen_request.turn_id,source_auth:clone(ctx.run.frozen_request.source_auth)};
  return {envelope:{schema_version:1,contract:PLAN_CONTRACT,plan,amendment:publicOperation(op,ctx.head,plan.application_state)},wake};
 });
 // The transaction is committed before best-effort continuation. Reads/replays never
 // enter this port, and the original frozen source remains the worker's authority.
 if(committed.wake)try{await facade.onPlanAmendmentAccepted?.(committed.wake);}catch{/* accepted records remain authoritative if hosting retention is unavailable */}
 return committed.envelope;
}
export async function applyPendingPlan(tx,owner,run,task,head,{running=false}={}){
 if(!head||!pending(head)||!safe(task)||await effectUnknown(tx,owner,run)||(!running&&task.status==='running'))return {task,head,applied:false};
 const version=await tx.get(owner,VERSIONS,`${run.id}:${head.accepted_revision}`);check(version&&hash(version.content)===head.accepted_plan_hash,409,'plan_hash_conflict');
 const previous=task.state.local_model;
 if(previous)check(await tx.insertIfAbsent(owner,'catpaw-task-plan-checkpoints',{id:`${run.id}:${head.applied_revision}:${head.accepted_revision}`,run_id:run.id,plan_binding:planBinding(head),local_model:clone(previous),created_at:iso()}),409,'revision_conflict');
 const binding={revision:head.accepted_revision,plan_hash:head.accepted_plan_hash};
 const local=previous?{...clone(previous),messages:[...clone(previous.messages),{role:'user',content:JSON.stringify({plan_amendment:{...binding,content:version.content},instruction:'Continue this same report task using the applied plan. Earlier outputs are history; read the frozen sources again for this revision when required, then save and validate its report.'})}],round:null,artifact:null,artifact_validation:null,source_reads:null,finished:false}:undefined;
 task={...task,title:version.content.title,prompt:version.content.goal,plan:planTaskSteps(version.content),state:{...task.state,plan_binding:binding,...local?{local_model:local}:{}},...!running?{status:'scheduled',leaseId:null,leaseUntil:null,nextRunAt:iso()}:{},updatedAt:iso()};
 head={...head,applied_revision:binding.revision,applied_plan_hash:binding.plan_hash,application_state:'applied',updated_at:iso()};
 await tx.put(owner,'tasks',task);await tx.put(owner,HEAD,head);return {task,head,applied:true};
}
export async function effectiveTaskRequest(tx,owner,run,task){
 const head=boundHead(await tx.get(owner,HEAD,run.id),run);if(!head)return clone(run.frozen_request);
 check(samePlan(task.state.plan_binding,planBinding(head)),409,'plan_binding_conflict');const v=await tx.get(owner,VERSIONS,`${run.id}:${head.applied_revision}`);check(v&&hash(v.content)===head.applied_plan_hash,409,'plan_hash_conflict');
 // Freeze remains unchanged; only effective execution arguments carry the applied revision.
 return {...clone(run.frozen_request),args:clone(v.content),applied_plan:planBinding(head)};
}
// This trusted port is reached only after a complete received revision call and
// exact artifact/authority CAS. Ordinary amendTaskPlan still rejects terminal work.
export async function reopenTaskForRevisionInTransaction(tx,owner,run,task,head,requirements,revision,{assertLive=()=>{}}={}){
 assertLive();check(task.status==='succeeded'&&task.leaseId===null&&task.leaseUntil===null&&!pending(head)&&safe(task)&&!await effectUnknown(tx,owner,run),409,'revision_task_not_editable');assertLive();
 const old=await tx.get(owner,VERSIONS,`${run.id}:${head.applied_revision}`);assertLive();check(old&&hash(old.content)===head.applied_plan_hash,409,'plan_hash_conflict');
 const content={...clone(old.content),requirements},number=head.accepted_revision+1,plan_hash=hash(content),now=iso(),binding={revision:number,plan_hash};
 check(await tx.insertIfAbsent(owner,VERSIONS,{id:`${run.id}:${number}`,run_id:run.id,revision:number,plan_hash,content,created_at:now}),409,'revision_conflict');assertLive();
 check(await tx.insertIfAbsent(owner,'catpaw-task-plan-checkpoints',{id:`${run.id}:${head.applied_revision}:${number}`,run_id:run.id,conversation_id:run.frozen_request.conversation_id,plan_binding:planBinding(head),local_model:clone(task.state.local_model??null),artifact_ids:clone(task.artifactIds),user_artifact_revision:clone(task.state.user_artifact_revision??null),previous_task_status:task.status,previous_task_revision:clone(task.state.task_revision??null),revision_operation_id:revision.operation_id,created_at:now}),409,'revision_conflict');assertLive();
 const state={...clone(task.state),plan_binding:binding,local_model:null,task_revision:{...clone(revision),plan_reference:binding}};delete state.user_artifact_revision;
 const next={...task,title:content.title,prompt:content.goal,plan:planTaskSteps(content),status:'scheduled',leaseId:null,leaseUntil:null,nextRunAt:now,artifactIds:[],state,question:null,result:null,error:null,updatedAt:now};
 await tx.put(owner,'tasks',next);assertLive();await tx.put(owner,HEAD,{...head,accepted_revision:number,accepted_plan_hash:plan_hash,applied_revision:number,applied_plan_hash:plan_hash,application_state:'applied',updated_at:now});assertLive();
 await invalidatePendingTaskActionsInTransaction(tx,owner,{run_id:run.id,task_id:task.id,reason:'plan_changed'});assertLive();
 for(const b of await tx.list(owner,'catpaw-approval-bindings'))if(b.task_id===task.id){const a=await tx.get(owner,'actions',b.id);assertLive();if(a?.status==='awaiting_review')check(await tx.compareAndSwap(owner,'actions',b.id,{status:'awaiting_review'},{status:'denied'}),409,'approval_stale');assertLive();}
 return {task:next,plan_reference:binding};
}
export async function recordPlanReceipt(tx,owner,run,task,step_id,source){
 const head=await tx.get(owner,HEAD,run.id);if(!head)return;
 const binding=planBinding(head);check(samePlan(task.state.plan_binding,binding),409,'plan_binding_conflict');
 const id=`${run.id}:${binding.revision}:${step_id}`,old=await tx.get(owner,RECEIPTS,id);if(old)return old;
 const receipt={id,run_id:run.id,task_id:task.id,step_id,plan_revision:binding.revision,plan_hash:binding.plan_hash,status:'succeeded',receipt_kind:PLAN_RECEIPT_KINDS[step_id],receipt_hash:hash(source),created_at:iso()};check(receipt.receipt_kind,422,'schema_invalid');
 check(await tx.insertIfAbsent(owner,RECEIPTS,receipt),409,'revision_conflict');return receipt;
}
export async function completionPlanCheck(tx,owner,run,task,artifact){
 const head=await tx.get(owner,HEAD,run.id);if(!head)return;
 check(!pending(head),409,'plan_application_pending');check(samePlan(task.state.plan_binding,planBinding(head))&&samePlan(artifact.plan_reference,planBinding(head)),409,'completion_plan_superseded');
 for(const step of ['compose','save']){const r=await tx.get(owner,RECEIPTS,`${run.id}:${head.applied_revision}:${step}`);check(r?.plan_hash===head.applied_plan_hash,409,'completion_plan_receipt_required');}
}
