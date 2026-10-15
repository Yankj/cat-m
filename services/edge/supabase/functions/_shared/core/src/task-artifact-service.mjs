import {check,hash,clone,immutableBody} from '../facade-r2/src/common.mjs';
import {samePlan} from './plan-contract.mjs';
import {hasUnresolvedSourceReads} from './task-source-service.mjs';
import {invalidatePendingTaskActionsInTransaction} from './task-action-service.mjs';
import {TASK_ARTIFACT_CONTRACT,TASK_ARTIFACT_KINDS,TASK_ARTIFACT_LIMITS,taskArtifactUUID,taskArtifactID,taskArtifactVersion,validateArtifactAmendment,artifactReceiptHash,artifactReference,userRevisionBody} from './task-artifact-contract.mjs';

const HEADS='catpaw-artifact-heads',VERSIONS='catpaw-artifact-versions',PLAN_HEADS='catpaw-task-plan-heads';
const terminal=new Set(['succeeded','failed','cancelled']);
function clock(facade){const value=facade.artifactClock?.()??Date.now(),ms=value instanceof Date?value.getTime():value;check(Number.isFinite(ms)&&Number.isSafeInteger(ms),503,'artifact_clock_invalid');return ms;}
function permission(facade,{signal,assertLive=()=>{}}={}){const started=clock(facade),deadline=started+TASK_ARTIFACT_LIMITS.write_budget_ms;return ()=>{assertLive();check(!signal?.aborted,409,'artifact_edit_cancelled');const now=clock(facade);check(now>=started&&now<deadline,409,'artifact_edit_deadline');};}
async function authority(facade,tx,ctx,write=false){
 const hook=write?facade.beforeArtifactWrite:facade.beforeArtifactRead;check(typeof hook==='function',503,'artifact_authority_not_configured');
 const result=await hook(tx,{...ctx,source_auth:clone(ctx.run.frozen_request.source_auth)});check(result&&typeof result.source_current==='boolean',503,'artifact_authority_result_required');
 if(write)check(result.source_current,403,'artifact_source_not_current');return result.source_current;
}
async function resolve(facade,tx,scoped,scopeID,runID,artifactID){
 taskArtifactUUID(scopeID);taskArtifactUUID(runID);taskArtifactID(artifactID);
 let scopeRow;await tx.withScope(scopeID,async scope=>{scopeRow=await scope.scope();check(scopeRow.identity.owner===scoped.owner,403,'scope_forbidden');});
 const run=await facade.ownedRun(tx,scoped.owner,runID,scoped.principal,scopeID),f=run.frozen_request;
 check(f.subject_id===scoped.principal.subject_id&&f.scope.scope_id===scopeID&&f.source_auth?.subject_id===f.subject_id&&f.source_auth.scope_id===scopeID&&hash(f)===run.request_hash,409,'artifact_source_binding_conflict');
 const d=await facade.ownedDelegation(tx,scoped.owner,run.delegation_id,scoped.principal,{lock:true,scopeID});
 await tx.lock(scoped.owner,'tasks',run.task_id);const task=await tx.get(scoped.owner,'tasks',run.task_id),tag=task?.state?.catpaw;
 check(task?.id===run.task_id&&d.id===run.delegation_id&&tag?.run_id===run.id&&['operation_id','delegation_id','request_hash','grant_epoch','delegation_revision'].every(k=>tag[k]===run[k]),409,'artifact_task_binding_conflict');
 await tx.lock(scoped.owner,PLAN_HEADS,run.id);const planHead=await tx.get(scoped.owner,PLAN_HEADS,run.id),planReference=task.state.plan_binding;
 check(planHead?.run_id===run.id&&planHead.task_id===task.id&&planHead.scope_id===scopeID&&planHead.subject_id===f.subject_id&&planHead.conversation_id===f.conversation_id&&Number.isSafeInteger(planHead.accepted_revision)&&planHead.accepted_revision>=planHead.applied_revision&&Number.isSafeInteger(planHead.applied_revision)&&planHead.applied_revision>0&&samePlan(planReference,{revision:planHead.applied_revision,plan_hash:planHead.applied_plan_hash}),409,'artifact_plan_binding_conflict');
 const planVersion=await tx.get(scoped.owner,'catpaw-task-plan-versions',`${run.id}:${planReference.revision}`);check(planVersion?.run_id===run.id&&planVersion.revision===planReference.revision&&planVersion.plan_hash===planReference.plan_hash&&hash(planVersion.content)===planReference.plan_hash,409,'artifact_plan_binding_conflict');
 await tx.lock(scoped.owner,HEADS,artifactID);const artifactHead=await tx.get(scoped.owner,HEADS,artifactID);
 // The original immutable versions remain readable while a revision has no new
 // active artifact yet. Run/head/version ownership is checked independently;
 // artifactIds is the current execution's output list, not the history authority.
 check(artifactHead?.id===artifactID&&artifactHead.artifact_id===artifactID&&run.artifact_references?.some(ref=>hash(ref)===hash(artifactReference(artifactHead))),404,'not_found');
 return {...scoped,scopeRow,run,d,task,planHead,planReference,artifactHead,artifactID};
}
async function versionFor(tx,ctx,version){
 taskArtifactVersion(version);const row=await tx.get(ctx.owner,VERSIONS,`${ctx.artifactID}:${version}`);
 check(row?.id===`${ctx.artifactID}:${version}`&&row.artifact_id===ctx.artifactID&&row.version===version&&row.run_id===ctx.run.id&&row.task_id===ctx.task.id,404,'not_found');
 check(row.mime_type==='application/json'&&typeof row.body==='string'&&new TextEncoder().encode(row.body).length<=TASK_ARTIFACT_LIMITS.body_bytes&&hash(row.body)===row.content_hash,409,'artifact_corrupt');
 let body;try{body=JSON.parse(row.body);}catch{check(false,409,'artifact_corrupt');}
 check(body.kind==='report'&&typeof body.title==='string'&&typeof body.summary==='string'&&body.data&&typeof body.data.content==='string'&&body.data.conversation_id===ctx.run.frozen_request.conversation_id&&immutableBody(body)===row.body,409,'artifact_corrupt');
 check(Number.isSafeInteger(row.plan_reference?.revision)&&row.plan_reference.revision>0&&/^[a-f0-9]{64}$/.test(row.plan_reference.plan_hash),409,'artifact_plan_binding_conflict');
 const plan=await tx.get(ctx.owner,'catpaw-task-plan-versions',`${ctx.run.id}:${row.plan_reference.revision}`);check(plan?.run_id===ctx.run.id&&plan.revision===row.plan_reference.revision&&plan.plan_hash===row.plan_reference.plan_hash&&hash(plan.content)===row.plan_reference.plan_hash,409,'artifact_plan_binding_conflict');
 if(version===ctx.artifactHead.version)check(row.content_hash===ctx.artifactHead.content_hash&&samePlan(row.plan_reference,ctx.artifactHead.plan_reference),409,'artifact_corrupt');
 if(row.origin==='user_revision'){
  const {receipt}=await operationFor(tx,ctx,row.revision_operation_id),revision=body.data.user_revision;
  check(body.data.source==='user_revision'&&body.data.updated_at===row.created_at&&row.created_at===receipt.committed_at&&hash(artifactReference(row))===hash(receipt.result_reference)&&hash({title:body.title,summary:body.summary,content:body.data.content})===hash(receipt.content)&&revision?.author==='user'&&revision.operation_id===receipt.operation_id&&hash(revision.base_reference)===hash(receipt.base_reference)&&hash(row.base_reference)===hash(receipt.base_reference)&&samePlan(revision.plan_reference,receipt.plan_reference)&&samePlan(row.plan_reference,receipt.plan_reference)&&revision.grant_epoch===receipt.grant_epoch&&revision.source_evidence_boundary===receipt.source_evidence_boundary&&row.source_evidence_boundary===receipt.source_evidence_boundary&&revision.claims_verification==='not_rechecked',409,'artifact_operation_corrupt');
 }
 return {row,body};
}
function boundary(row,body){return row.origin==='user_revision'?body.data.user_revision?.source_evidence_boundary:body.data.source_contract==='sourced-report-v1'?'agent_original':'supplied_context_only';}
function editableReason(ctx,row,sourceCurrent){
 if(!sourceCurrent)return 'source_authority_changed';
 if(ctx.d.state!=='active'||ctx.d.grant_epoch!==ctx.run.grant_epoch||ctx.d.revision!==ctx.run.delegation_revision)return 'grant_changed';
 if(ctx.scopeRow.generation!==ctx.run.frozen_request.memory_generation)return 'memory_generation_superseded';
 if(!terminal.has(ctx.task.status))return 'artifact_task_not_terminal';
 if(ctx.task.leaseId!==null||ctx.task.leaseUntil!==null)return 'artifact_active_lease';
 if(ctx.task.state.local_model?.round?.state==='dispatched')return 'artifact_original_outcome_unknown';
 if(row.version!==ctx.artifactHead.version||row.content_hash!==ctx.artifactHead.content_hash)return 'artifact_version_conflict';
 if(ctx.planHead.accepted_revision!==ctx.planHead.applied_revision||!samePlan(row.plan_reference,ctx.planReference))return 'artifact_plan_conflict';
 return null;
}
async function unresolved(tx,ctx){
 if(await hasUnresolvedSourceReads(tx,ctx.owner,ctx.run.id))return true;
 for(const b of await tx.list(ctx.owner,'catpaw-approval-bindings'))if(b.run_id===ctx.run.id){const action=await tx.get(ctx.owner,'actions',b.id);if(['executing','outcome_unknown','failed'].includes(action?.status)&&b.reconciliation_state!=='resolved_local')return true;}
 return false;
}
function snapshot(ctx,row,body,sourceCurrent,blocked){
 const f=ctx.run.frozen_request,reason=editableReason(ctx,row,sourceCurrent)??(blocked?'artifact_original_outcome_unknown':null);
 return {artifact_id:row.artifact_id,scope_id:f.scope.scope_id,subject_id:f.subject_id,run_id:ctx.run.id,task_id:ctx.task.id,conversation_id:f.conversation_id,run_request_hash:ctx.run.request_hash,source_auth_hash:hash(f.source_auth),delegation_id:ctx.run.delegation_id,delegation_revision:ctx.run.delegation_revision,grant_epoch:ctx.run.grant_epoch,version:row.version,content_hash:row.content_hash,mime_type:row.mime_type,body:row.body,created_at:row.created_at,plan_reference:clone(row.plan_reference),origin:row.origin==='user_revision'?'user_revision':'agent',is_current:row.version===ctx.artifactHead.version&&row.content_hash===ctx.artifactHead.content_hash,current_reference:artifactReference(ctx.artifactHead),source_evidence_boundary:boundary(row,body),editable:reason===null,edit_blocked_reason:reason};
}
function envelope(artifact,amendment){return {schema_version:1,contract:TASK_ARTIFACT_CONTRACT,artifact,...amendment?{amendment}:{}};}
async function operationFor(tx,ctx,operationID){
 const op=await tx.get(ctx.owner,TASK_ARTIFACT_KINDS.operations,operationID);check(op?.run_id===ctx.run.id&&op.artifact_id===ctx.artifactID&&op.task_id===ctx.task.id&&op.scope_id===ctx.scope.scope_id&&op.subject_id===ctx.principal.subject_id,404,'not_found');
 check(hash(op.frozen)===op.operation_hash&&op.frozen.operation_id===operationID&&op.frozen.run_id===ctx.run.id&&op.frozen.task_id===ctx.task.id&&op.frozen.scope_id===ctx.scope.scope_id&&op.frozen.subject_id===ctx.principal.subject_id&&op.frozen.conversation_id===ctx.run.frozen_request.conversation_id&&op.frozen.artifact_id===ctx.artifactID&&op.frozen.delegation_id===ctx.run.delegation_id&&op.frozen.delegation_revision===ctx.run.delegation_revision&&op.frozen.grant_epoch===ctx.run.grant_epoch&&op.frozen.run_request_hash===ctx.run.request_hash&&hash(op.frozen.source_auth)===hash(ctx.run.frozen_request.source_auth),409,'artifact_operation_corrupt');
 const stored=await tx.get(ctx.owner,TASK_ARTIFACT_KINDS.receipts,operationID);check(stored?.id===operationID,409,'artifact_operation_corrupt');const {id,...receipt}=stored;
 const {source_auth,...publicFrozen}=op.frozen;
 check(receipt.receipt_hash===artifactReceiptHash(receipt)&&Object.entries(publicFrozen).every(([key,value])=>key in receipt&&hash(receipt[key])===hash(value))&&receipt.state==='applied'&&receipt.origin==='user_revision'&&['original_snapshot_only','supplied_context_only'].includes(receipt.source_evidence_boundary)&&receipt.source_auth_hash===hash(source_auth)&&receipt.result_reference?.artifact_id===ctx.artifactID&&receipt.result_reference.version===receipt.base_reference.version+1,409,'artifact_operation_corrupt');
 return {op,receipt};
}
async function read(facade,auth,scopeID,runID,artifactID,{version=null,operationID=null}={}){
 if(version!==null)taskArtifactVersion(version);if(operationID!==null)operationID=taskArtifactUUID(operationID);const scoped=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{
  const ctx=await resolve(facade,tx,scoped,scopeID,runID,artifactID);await authority(facade,tx,ctx);let amendment;
  if(operationID!==null){amendment=(await operationFor(tx,ctx,operationID)).receipt;version=amendment.result_reference.version;}
  const {row,body}=await versionFor(tx,ctx,version??ctx.artifactHead.version);if(amendment)check(hash(artifactReference(row))===hash(amendment.result_reference),409,'artifact_operation_corrupt');
  const blocked=await unresolved(tx,ctx),sourceCurrent=await authority(facade,tx,ctx);
  return envelope(snapshot(ctx,row,body,sourceCurrent,blocked),amendment);
 });
}
export const readTaskArtifact=(facade,auth,scopeID,runID,artifactID,options={})=>read(facade,auth,scopeID,runID,artifactID,options);
export const readTaskArtifactOperation=(facade,auth,scopeID,runID,artifactID,operationID)=>read(facade,auth,scopeID,runID,artifactID,{operationID});
async function preserveSources(facade,tx,ctx,base){
 if(base.data.source_contract!=='sourced-report-v1')return 'supplied_context_only';
 check(facade.sourceService,503,'source_service_not_configured');
 const citations=base.data.original_citations??base.data.citations;
 check(Array.isArray(citations),409,'artifact_source_snapshot_conflict');
 const bound=await facade.sourceService.validateCitationsInTransaction(tx,ctx.owner,ctx.run,ctx.task,citations.map(({source_id,quote})=>({source_id,quote})));
 check(hash(bound.sources)===hash(base.data.sources)&&hash(bound.citations)===hash(citations)&&hash(bound.receipt_references)===hash(base.data.source_receipt_references),409,'artifact_source_snapshot_conflict');return 'original_snapshot_only';
}
async function projectTask(facade,tx,ctx,committed_at){
 const projection=await facade.runProjection(tx,ctx.owner,ctx.run.id),authoritative={scope_id:ctx.scope.scope_id,task_id:ctx.task.id,status:projection.run.state,authorization_state:projection.run.authorization_state,grant_epoch:projection.run.grant_epoch,updated_at:ctx.task.updatedAt};
 const digest=hash({authoritative,artifacts:projection.run.artifact_references,attempts:projection.run.attempts,...projection.plan?{plan:projection.plan}:{}});
 await tx.lock(ctx.owner,'catpaw-task-projection-versions',ctx.run.id);const prior=await tx.get(ctx.owner,'catpaw-task-projection-versions',ctx.run.id);
 check(await tx.put(ctx.owner,'catpaw-task-projection-versions',{id:ctx.run.id,scope_id:ctx.scope.scope_id,subject_id:ctx.principal.subject_id,projection_hash:digest,version:(prior?.version??0)+1,version_kind:'owner_projection_revision',updated_at:committed_at}),409,'artifact_projection_conflict');
}
export async function amendTaskArtifact(facade,auth,scopeID,runID,artifactID,input,options={}){
 input=validateArtifactAmendment(input);const live=permission(facade,options),request_hash=hash({contract:TASK_ARTIFACT_CONTRACT,scope_id:scopeID,run_id:runID,artifact_id:artifactID,...input}),scoped=await facade.scoped(auth,scopeID);live();
 return facade.repository.transaction(async tx=>{
  let ctx=await resolve(facade,tx,scoped,scopeID,runID,artifactID);ctx.content=input.content;live();
  check(![runID,ctx.run.operation_id,ctx.run.delegation_id,ctx.run.frozen_request.conversation_id,ctx.run.frozen_request.turn_id].includes(input.operation_id),422,'artifact_operation_identity_conflict');
  await tx.lock(ctx.owner,TASK_ARTIFACT_KINDS.operations,input.operation_id);const prior=await tx.get(ctx.owner,TASK_ARTIFACT_KINDS.operations,input.operation_id);live();
  if(prior){check(prior.request_hash===request_hash,409,'artifact_operation_conflict');const {receipt}=await operationFor(tx,ctx,input.operation_id),{row,body}=await versionFor(tx,ctx,receipt.result_reference.version),blocked=await unresolved(tx,ctx);check(hash(artifactReference(row))===hash(receipt.result_reference),409,'artifact_operation_corrupt');const sourceCurrent=await authority(facade,tx,ctx);live();return envelope(snapshot(ctx,row,body,sourceCurrent,blocked),receipt);}
  await authority(facade,tx,ctx,true);live();const {row:base,body:original}=await versionFor(tx,ctx,ctx.artifactHead.version);live();
  const reason=editableReason(ctx,base,true);check(reason===null,409,reason);check(!await unresolved(tx,ctx),409,'artifact_original_outcome_unknown');live();
  check(ctx.run.grant_epoch===input.expected_grant_epoch,409,'artifact_grant_conflict');check(samePlan(ctx.planReference,{revision:input.expected_plan_revision,plan_hash:input.expected_plan_hash}),409,'artifact_plan_conflict');
  check(ctx.artifactHead.version===input.expected_version,409,'artifact_version_conflict');check(ctx.artifactHead.content_hash===input.expected_content_hash,409,'artifact_hash_conflict');
  const source_evidence_boundary=await preserveSources(facade,tx,ctx,original);live();const committed_at=new Date(clock(facade)).toISOString(),base_reference=artifactReference(base);
  const frozen={operation_id:input.operation_id,scope_id:scopeID,subject_id:ctx.principal.subject_id,run_id:runID,task_id:ctx.task.id,conversation_id:ctx.run.frozen_request.conversation_id,artifact_id:artifactID,run_request_hash:ctx.run.request_hash,source_auth:clone(ctx.run.frozen_request.source_auth),delegation_id:ctx.run.delegation_id,delegation_revision:ctx.run.delegation_revision,grant_epoch:ctx.run.grant_epoch,plan_reference:clone(ctx.planReference),base_reference,content:clone(input.content)};
  const body=userRevisionBody(original,input.content,{...frozen,committed_at,source_evidence_boundary}),result_reference={artifact_id:artifactID,version:base.version+1,content_hash:hash(body)};
  const version={id:`${artifactID}:${result_reference.version}`,...result_reference,run_id:runID,task_id:ctx.task.id,conversation_id:frozen.conversation_id,plan_reference:clone(ctx.planReference),mime_type:'application/json',body,created_at:committed_at,origin:'user_revision',revision_operation_id:input.operation_id,base_reference,source_evidence_boundary};
  check(await tx.insertIfAbsent(ctx.owner,VERSIONS,version),409,'artifact_version_conflict');live();
  check(await tx.compareAndSwap(ctx.owner,HEADS,artifactID,{version:base.version,content_hash:base.content_hash},{...result_reference,plan_reference:clone(ctx.planReference)}),409,'artifact_version_conflict');live();
  const parsed=JSON.parse(body),agent=await tx.get(ctx.owner,'agent-artifacts',artifactID);await tx.put(ctx.owner,'agent-artifacts',{id:artifactID,taskId:ctx.task.id,...parsed,createdAt:agent?.createdAt??committed_at,updatedAt:committed_at});live();
  ctx.run={...ctx.run,artifact_references:ctx.run.artifact_references.map(ref=>ref.artifact_id===artifactID?result_reference:ref)};await tx.put(ctx.owner,'catpaw-runs',ctx.run);live();
  ctx.task={...ctx.task,state:{...ctx.task.state,user_artifact_revision:{operation_id:input.operation_id,reference:clone(result_reference),origin:'user_revision'}},updatedAt:committed_at};await tx.put(ctx.owner,'tasks',ctx.task);live();
  await invalidatePendingTaskActionsInTransaction(tx,ctx.owner,{run_id:runID,task_id:ctx.task.id,reason:'artifact_changed'});live();
  for(const b of await tx.list(ctx.owner,'catpaw-approval-bindings'))if(b.run_id===runID&&b.task_id===ctx.task.id&&b.artifact_reference?.artifact_id===artifactID){const action=await tx.get(ctx.owner,'actions',b.id);if(action?.status==='awaiting_review')check(await tx.compareAndSwap(ctx.owner,'actions',b.id,{status:'awaiting_review'},{status:'denied'}),409,'approval_stale');live();}
  await projectTask(facade,tx,ctx,committed_at);live();
  const {source_auth,...publicFrozen}=frozen,receiptFields={...publicFrozen,state:'applied',source_auth_hash:hash(source_auth),result_reference,origin:'user_revision',source_evidence_boundary,committed_at},receipt={...receiptFields,receipt_hash:artifactReceiptHash(receiptFields)};
  check(await tx.insertIfAbsent(ctx.owner,TASK_ARTIFACT_KINDS.operations,{id:input.operation_id,run_id:runID,task_id:ctx.task.id,conversation_id:frozen.conversation_id,artifact_id:artifactID,scope_id:scopeID,subject_id:frozen.subject_id,request_hash,frozen,operation_hash:hash(frozen),created_at:committed_at}),409,'artifact_operation_conflict');live();
  check(await tx.insertIfAbsent(ctx.owner,TASK_ARTIFACT_KINDS.receipts,{id:input.operation_id,...receipt}),409,'artifact_operation_conflict');live();
  ctx=await resolve(facade,tx,scoped,scopeID,runID,artifactID);ctx.content=input.content;live();
  const current=await versionFor(tx,ctx,result_reference.version);live();const blocked=await unresolved(tx,ctx);live();
  await authority(facade,tx,ctx,true);live();check(editableReason(ctx,current.row,true)===null&&!blocked,409,'artifact_edit_no_longer_current');
  return envelope(snapshot(ctx,current.row,current.body,true,false),receipt);
 });
}
