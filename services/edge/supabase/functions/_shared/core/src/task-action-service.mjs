import {check,hash,clone} from '../facade-r2/src/common.mjs';
import {TASK_ACTION_CONTRACT,TASK_ACTION_KINDS,TASK_ACTION_REGISTRY,TASK_ACTION_LIFETIME_MS,taskActionUUID,taskActionID,validateTaskActionProposal,validateTaskActionDecision} from './task-action-contract.mjs';

const PLAN_HEADS='catpaw-task-plan-heads';
const samePlan=(a,b)=>Boolean(a&&b&&a.revision===b.revision&&a.plan_hash===b.plan_hash);
const clock=facade=>{const value=facade.actionClock?.()??new Date();check(value instanceof Date&&Number.isFinite(value.getTime()),503,'action_clock_invalid');return value;};
async function authority(facade,tx,ctx,write=false){
 const hook=write?facade.beforeActionWrite:facade.beforeActionRead;
 check(typeof hook==='function',503,'action_authority_not_configured');
 // Trusted composition verifies the current viewer, original source session/consent and target/environment ownership.
 // A read may retain historical decisions after source revocation; it reports false instead of granting new authority.
 const result=await hook(tx,{...ctx,source_auth:clone(ctx.run.frozen_request.source_auth)});
 check(result&&typeof result.source_current==='boolean',503,'action_authority_result_required');
 if(write)check(result.source_current,403,'action_source_not_current');return result.source_current;
}
async function resolve(facade,tx,scoped,scopeID,runID){
 taskActionUUID(scopeID);taskActionUUID(runID);
 await tx.withScope(scopeID,async()=>{});
 const run=await facade.ownedRun(tx,scoped.owner,runID,scoped.principal,scopeID);
 check(run?.frozen_request?.subject_id===scoped.principal.subject_id&&run.frozen_request.scope.scope_id===scopeID&&run.frozen_request.source_auth?.subject_id===run.frozen_request.subject_id&&run.frozen_request.source_auth.scope_id===scopeID,409,'action_source_binding_conflict');
 const d=await facade.ownedDelegation(tx,scoped.owner,run.delegation_id,scoped.principal,{lock:true,scopeID});check(d?.id===run.delegation_id,409,'action_task_binding_conflict');
 await tx.lock(scoped.owner,'tasks',run.task_id);const task=await tx.get(scoped.owner,'tasks',run.task_id),tag=task?.state?.catpaw;
 check(tag?.run_id===run.id&&tag.delegation_id===run.delegation_id&&tag.request_hash===run.request_hash&&tag.grant_epoch===run.grant_epoch&&tag.delegation_revision===run.delegation_revision,409,'action_task_binding_conflict');
 await tx.lock(scoped.owner,PLAN_HEADS,run.id);const head=await tx.get(scoped.owner,PLAN_HEADS,run.id);
 check(head&&head.run_id===run.id&&head.task_id===task.id&&head.scope_id===scopeID&&head.subject_id===run.frozen_request.subject_id&&head.conversation_id===run.frozen_request.conversation_id,409,'action_plan_binding_conflict');
 return {...scoped,run,d,task,head};
}
async function actionFor(tx,ctx,id){
 taskActionUUID(id);await tx.lock(ctx.owner,TASK_ACTION_KINDS.actions,id);const action=await tx.get(ctx.owner,TASK_ACTION_KINDS.actions,id);check(action,404,'not_found');
 const f=action.frozen;
 check(action.id===id&&action.run_id===ctx.run.id&&action.task_id===ctx.task.id&&action.scope_id===ctx.scope.scope_id&&action.subject_id===ctx.principal.subject_id&&action.source_auth&&hash(action.source_auth)===hash(ctx.run.frozen_request.source_auth)&&f?.id===id&&f.scope_id===ctx.scope.scope_id&&f.subject_id===ctx.principal.subject_id&&f.conversation_id===ctx.run.frozen_request.conversation_id&&f.turn_id===ctx.run.frozen_request.turn_id&&f.run_id===ctx.run.id&&f.task_id===ctx.task.id&&f.request_hash===ctx.run.request_hash&&hash(f)===action.action_digest&&hash(f.parameters)===f.parameters_hash,409,'action_binding_conflict');
 return action;
}
async function artifactCurrent(tx,ctx,reference){
 if(reference===null)return true;
 const head=await tx.get(ctx.owner,'catpaw-artifact-heads',reference.artifact_id),version=await tx.get(ctx.owner,'catpaw-artifact-versions',`${reference.artifact_id}:${reference.version}`);
 return Boolean(head?.version===reference.version&&head.content_hash===reference.content_hash&&version?.run_id===ctx.run.id&&version.task_id===ctx.task.id&&version.content_hash===reference.content_hash&&hash(version.body)===reference.content_hash);
}
async function currentReason(tx,ctx,action,sourceCurrent,now){
 const f=action.frozen;
 if(action.superseded_by||action.invalidation_reason)return action.invalidation_reason??'newer_parameters';
 if(!sourceCurrent)return 'source_authority_changed';
 if(ctx.d.state!=='active'||ctx.d.grant_epoch!==f.grant_epoch||ctx.d.revision!==f.delegation_revision||ctx.run.grant_epoch!==f.grant_epoch||ctx.run.delegation_revision!==f.delegation_revision)return 'grant_changed';
 if(['cancelled','failed','paused'].includes(ctx.task.status))return 'task_not_active';
 if(ctx.head.accepted_revision!==ctx.head.applied_revision||ctx.head.accepted_revision!==f.plan_reference.revision||ctx.head.accepted_plan_hash!==f.plan_reference.plan_hash||ctx.head.applied_plan_hash!==f.plan_reference.plan_hash||!samePlan(ctx.task.state.plan_binding,f.plan_reference))return 'plan_changed';
 if(!await artifactCurrent(tx,ctx,f.artifact_reference))return 'artifact_changed';
 if(Date.parse(f.expires_at)<=now.getTime())return 'expired';return null;
}
function envelope(action,reason,decision){
 const f=action.frozen,registry=TASK_ACTION_REGISTRY[f.kind];check(registry,409,'action_kind_unsupported');
 const status=action.approval_status==='pending'&&reason?(reason==='expired'?'expired':'invalidated'):action.approval_status;
 const approved=action.approval_status==='approved';
 const result={schema_version:1,contract:TASK_ACTION_CONTRACT,action:{...clone(f),revision:action.revision,action_digest:action.action_digest,approval_status:status,approval_binding_current:reason===null,invalidation_reason:reason,decision_operation_id:action.decision_operation_id??null,
  execution_authorized:false,capability:{...registry,os_target_verified:false},effect:{status:approved&&reason===null?'waiting_device':'not_dispatched',receipt:null},...action.superseded_by?{superseded_by:action.superseded_by}:{}}};
 if(decision)result.decision={operation_id:decision.id,action_id:decision.action_id,decision:decision.decision,state:'accepted',action_digest:decision.action_digest,committed_at:decision.committed_at};
 return result;
}
async function finishRead(facade,tx,ctx,action,decision){
 const sourceCurrent=await authority(facade,tx,{...ctx,action,purpose:'read_original'});
 const reason=await currentReason(tx,ctx,action,sourceCurrent,clock(facade));
 // Recheck trusted authority after the last awaited object read; no later mutation or await follows this hook.
 const finalCurrent=await authority(facade,tx,{...ctx,action,purpose:'read_original'});
 const finalReason=!finalCurrent?'source_authority_changed':reason??(Date.parse(action.frozen.expires_at)<=clock(facade).getTime()?'expired':null);
 return envelope(action,finalReason,decision);
}
export async function readTaskAction(facade,auth,scopeID,runID,actionID,{decisionOperationID=null}={}){
 if(decisionOperationID!==null)taskActionUUID(decisionOperationID);
 const scoped=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{
  const ctx=await resolve(facade,tx,scoped,scopeID,runID),action=await actionFor(tx,ctx,actionID);let decision;
  if(decisionOperationID!==null){decision=await tx.get(ctx.owner,TASK_ACTION_KINDS.decisions,decisionOperationID);check(decision?.run_id===runID&&decision.action_id===actionID&&decision.action_digest===action.action_digest&&decision.subject_id===ctx.principal.subject_id&&decision.scope_id===scopeID,404,'not_found');}
  return finishRead(facade,tx,ctx,action,decision);
 });
}
export async function readTaskActions(facade,auth,scopeID,runID){
 const scoped=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{
  const ctx=await resolve(facade,tx,scoped,scopeID,runID),sourceCurrent=await authority(facade,tx,{...ctx,purpose:'read_catalog'});
  const rows=(await tx.list(ctx.owner,TASK_ACTION_KINDS.actions)).filter(row=>row.run_id===runID&&row.task_id===ctx.task.id);check(rows.length<=32,413,'action_catalog_too_large');
  const prepared=[];
  for(const row of rows.sort((a,b)=>a.id.localeCompare(b.id))){const action=await actionFor(tx,ctx,row.id);prepared.push({action,reason:await currentReason(tx,ctx,action,sourceCurrent,clock(facade))});}
  const finalCurrent=await authority(facade,tx,{...ctx,purpose:'read_catalog'}),now=clock(facade);
  return {schema_version:1,contract:TASK_ACTION_CONTRACT,run_id:runID,task_id:ctx.task.id,actions:prepared.map(({action,reason})=>envelope(action,!finalCurrent?'source_authority_changed':reason??(Date.parse(action.frozen.expires_at)<=now.getTime()?'expired':null)).action)};
 });
}
export async function proposeTaskAction(facade,auth,scopeID,runID,input){
 input=validateTaskActionProposal(input);const request_hash=hash({contract:TASK_ACTION_CONTRACT,run_id:runID,...input}),scoped=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{
  const ctx=await resolve(facade,tx,scoped,scopeID,runID);ctx.input=input;
  check(![runID,ctx.run.delegation_id,ctx.run.frozen_request.conversation_id,ctx.run.frozen_request.turn_id].includes(input.operation_id),422,'action_operation_identity_conflict');
  const id=taskActionID(runID,input.operation_id);
  for(const key of [id,...input.replaces_action_id?[input.replaces_action_id]:[]].sort())await tx.lock(ctx.owner,TASK_ACTION_KINDS.actions,key);
  await tx.lock(ctx.owner,TASK_ACTION_KINDS.proposals,input.operation_id);
  const prior=await tx.get(ctx.owner,TASK_ACTION_KINDS.proposals,input.operation_id);
  if(prior){check(prior.run_id===runID&&prior.request_hash===request_hash&&prior.action_id===id&&prior.subject_id===ctx.principal.subject_id&&prior.scope_id===scopeID,409,'action_operation_conflict');return finishRead(facade,tx,ctx,await actionFor(tx,ctx,id));}
  await authority(facade,tx,{...ctx,purpose:'propose'},true);
  check(ctx.d.state==='active'&&ctx.d.grant_epoch===input.expected_grant_epoch&&ctx.d.grant_epoch===ctx.run.grant_epoch&&ctx.d.revision===ctx.run.delegation_revision,409,'action_grant_conflict');
  check(!['cancelled','failed','paused'].includes(ctx.task.status),409,'action_task_not_active');
  check(ctx.head.accepted_revision===ctx.head.applied_revision&&ctx.head.accepted_revision===input.expected_plan_revision&&ctx.head.accepted_plan_hash===input.expected_plan_hash&&ctx.head.applied_plan_hash===input.expected_plan_hash&&samePlan(ctx.task.state.plan_binding,{revision:input.expected_plan_revision,plan_hash:input.expected_plan_hash}),409,'action_plan_conflict');
  check(await artifactCurrent(tx,ctx,input.artifact_reference),409,'action_artifact_conflict');
  if(input.replaces_action_id!==null){
   check(input.replaces_action_id!==id,422,'action_schema_invalid');const old=await actionFor(tx,ctx,input.replaces_action_id);
   check(old.approval_status==='pending'&&!old.superseded_by&&old.frozen.kind===input.kind,409,'action_replacement_conflict');
   check(await tx.compareAndSwap(ctx.owner,TASK_ACTION_KINDS.actions,old.id,{revision:old.revision,approval_status:'pending'},{revision:old.revision+1,approval_status:'invalidated',invalidation_reason:'newer_parameters',superseded_by:id}),409,'action_replacement_conflict');
  }
  const now=clock(facade),frozen={id,proposal_operation_id:input.operation_id,scope_id:scopeID,subject_id:ctx.run.frozen_request.subject_id,conversation_id:ctx.run.frozen_request.conversation_id,turn_id:ctx.run.frozen_request.turn_id,run_id:runID,task_id:ctx.task.id,request_hash:ctx.run.request_hash,delegation_id:ctx.d.id,delegation_revision:ctx.d.revision,grant_epoch:ctx.d.grant_epoch,plan_reference:{revision:input.expected_plan_revision,plan_hash:input.expected_plan_hash},kind:input.kind,tool_version:1,target:clone(input.target),parameters:clone(input.parameters),parameters_hash:hash(input.parameters),artifact_reference:clone(input.artifact_reference),created_at:now.toISOString(),expires_at:new Date(now.getTime()+TASK_ACTION_LIFETIME_MS).toISOString()};
  const action={id,run_id:runID,task_id:ctx.task.id,conversation_id:frozen.conversation_id,scope_id:scopeID,subject_id:frozen.subject_id,source_auth:clone(ctx.run.frozen_request.source_auth),frozen,action_digest:hash(frozen),revision:1,approval_status:'pending'};
  check(await tx.insertIfAbsent(ctx.owner,TASK_ACTION_KINDS.actions,action),409,'action_operation_conflict');
  check(await tx.insertIfAbsent(ctx.owner,TASK_ACTION_KINDS.proposals,{id:input.operation_id,action_id:id,run_id:runID,task_id:ctx.task.id,conversation_id:frozen.conversation_id,scope_id:scopeID,subject_id:frozen.subject_id,request_hash,created_at:frozen.created_at}),409,'action_operation_conflict');
  await authority(facade,tx,{...ctx,action,purpose:'propose'},true);
  check(Date.parse(frozen.expires_at)>clock(facade).getTime(),409,'action_approval_stale');
  return envelope(action,null);
 });
}
export async function decideTaskAction(facade,auth,scopeID,runID,actionID,input){
 input=validateTaskActionDecision(input);taskActionUUID(actionID);const request_hash=hash({contract:TASK_ACTION_CONTRACT,run_id:runID,action_id:actionID,...input}),scoped=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{
  const ctx=await resolve(facade,tx,scoped,scopeID,runID),action=await actionFor(tx,ctx,actionID);ctx.input=input;
  check(![actionID,action.frozen.proposal_operation_id,runID,ctx.run.delegation_id,ctx.run.frozen_request.conversation_id,ctx.run.frozen_request.turn_id].includes(input.operation_id),422,'action_operation_identity_conflict');
  await tx.lock(ctx.owner,TASK_ACTION_KINDS.decisions,input.operation_id);const prior=await tx.get(ctx.owner,TASK_ACTION_KINDS.decisions,input.operation_id);
  if(prior){check(prior.run_id===runID&&prior.action_id===actionID&&prior.request_hash===request_hash&&prior.action_digest===action.action_digest&&prior.subject_id===ctx.principal.subject_id&&prior.scope_id===scopeID,409,'action_operation_conflict');return finishRead(facade,tx,ctx,action,prior);}
  const sourceCurrent=await authority(facade,tx,{...ctx,action,purpose:'decide'});
  check(action.approval_status==='pending'&&!action.decision_operation_id,409,'action_approval_consumed');
  const reason=await currentReason(tx,ctx,action,sourceCurrent,clock(facade));check(reason===null,409,'action_approval_stale');
  check(action.revision===input.expected_revision&&action.action_digest===input.action_digest&&action.frozen.grant_epoch===input.expected_grant_epoch,409,'action_approval_stale');
  await authority(facade,tx,{...ctx,action,purpose:'decide'},true);
  const committed_at=clock(facade).toISOString(),status=input.decision==='approve'?'approved':'denied';
  const changed=await tx.compareAndSwap(ctx.owner,TASK_ACTION_KINDS.actions,actionID,{revision:action.revision,approval_status:'pending'},{revision:action.revision+1,approval_status:status,decision_operation_id:input.operation_id,decided_at:committed_at});check(changed,409,'action_approval_consumed');
  const decision={id:input.operation_id,action_id:actionID,run_id:runID,task_id:ctx.task.id,conversation_id:ctx.run.frozen_request.conversation_id,scope_id:scopeID,subject_id:ctx.principal.subject_id,request_hash,action_digest:action.action_digest,decision:input.decision,committed_at};
  check(await tx.insertIfAbsent(ctx.owner,TASK_ACTION_KINDS.decisions,decision),409,'action_operation_conflict');
  // No execute call exists. The durable original decision precedes any future registered device executor.
  await authority(facade,tx,{...ctx,action:changed,purpose:'decide'},true);
  check(Date.parse(changed.frozen.expires_at)>clock(facade).getTime(),409,'action_approval_stale');
  return envelope(changed,null,decision);
 });
}
/** Called only by trusted plan/grant/source transactions after scope/delegation/task/plan locks.
 * Consumed decisions are immutable. Pending rows are fenced; approved rows retain their approval fact but lose execution authority.
 */
export async function invalidatePendingTaskActionsInTransaction(tx,owner,{run_id,task_id,reason}){
 check(['plan_changed','artifact_changed','grant_changed','source_authority_changed','task_not_active'].includes(reason),422,'action_invalidation_reason_invalid');
 const rows=(await tx.list(owner,TASK_ACTION_KINDS.actions)).filter(a=>a.run_id===run_id&&a.task_id===task_id&&['pending','approved'].includes(a.approval_status));
 for(const row of rows.sort((a,b)=>a.id.localeCompare(b.id))){
  await tx.lock(owner,TASK_ACTION_KINDS.actions,row.id);const current=await tx.get(owner,TASK_ACTION_KINDS.actions,row.id);
  if(!current||!['pending','approved'].includes(current.approval_status)||current.invalidation_reason)continue;
  check(await tx.compareAndSwap(owner,TASK_ACTION_KINDS.actions,row.id,{revision:current.revision,approval_status:current.approval_status},{revision:current.revision+1,approval_status:current.approval_status==='pending'?'invalidated':'approved',invalidation_reason:reason}),409,'action_invalidation_conflict');
 }
 return rows.map(a=>a.id);
}
