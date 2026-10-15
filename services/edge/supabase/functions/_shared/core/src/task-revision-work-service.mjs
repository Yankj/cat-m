import {check,hash,clone,UUID} from '../facade-r2/src/common.mjs';
import {TASK_REVISION_WORK_GRANT_CONTRACT,TASK_WORK_GRANT_KINDS,TASK_REVISION_WORK_GRANT_KINDS,workGrantReference} from './task-work-grant-contract.mjs';
import {TASK_REVISION_KINDS,publicTaskRevisionReceipt} from './task-revision-contract.mjs';
import {TASK_REVISION_WORK_CONTRACT,validateFrozenRevisionWorkIntent,assertRevisionWorkNewExecutionWindow,revisionWorkIntentHash,revisionWorkReceiptHash,validatePublicRevisionWorkReceipt} from './task-revision-work-contract.mjs';

const OPS=TASK_REVISION_KINDS.operations;
export function publicRevisionWorkReceipt(operation,revision=publicTaskRevisionReceipt(operation)){
 const intent=operation.frozen?.revision_work_intent;
 check(intent&&operation.work_grant_reference&&operation.work_grant_receipt_hash,409,'revision_work_receipt_required');
 const fields={schema_version:1,contract:TASK_REVISION_WORK_CONTRACT,decision_id:intent.decision_id,input_hash:intent.input_hash,target_hash:intent.target_hash,work_intent_hash:revisionWorkIntentHash(intent),revision:clone(revision),grant_reference:clone(operation.work_grant_reference),grant_receipt_hash:operation.work_grant_receipt_hash};
 const receipt={...fields,receipt_hash:revisionWorkReceiptHash(fields)};validatePublicRevisionWorkReceipt(receipt);return receipt;
}
/** Runs inside the existing chat/tool transaction. Reopen, new plan, operation,
 * new bounded grant, exact receipt and the chat tool result commit together. */
export async function admitTaskRevisionWorkInTransaction(facade,tx,ctx,operation,plan,{assertLive=()=>{}}={}){
 const intent=operation.frozen.revision_work_intent;
 validateFrozenRevisionWorkIntent(intent,{turn:ctx.turn,target:operation.frozen.target,scope:ctx.scope,conversation:ctx.conversation,routeHash:facade.acceptedWorkRouteHash,callName:'revise_current_report_work_v1'});
 check(facade.revisionWorkExecutionReady===true&&typeof facade.workGrantService?.admitRevisionInTransaction==='function',503,'revision_work_execution_not_configured');
 assertRevisionWorkNewExecutionWindow(intent,facade.workGrantService.now());
 const source=ctx.run.frozen_request.public_sources??null;
 check(intent.tool_policy===(source?'public_sources_v1':'local_output_v1'),409,'revision_work_source_policy_conflict');
 if(source)check(facade.publicSourcesEnabled===true&&facade.workGrantService.sourceService,503,'revision_work_source_not_configured');
 const version=await tx.get(ctx.owner,'catpaw-task-plan-versions',ctx.run.id+':'+plan.plan_reference.revision);assertLive();
 check(version?.plan_hash===plan.plan_reference.plan_hash&&hash(version.content)===version.plan_hash,409,'revision_work_plan_conflict');
 const terms={schema_version:2,contract:TASK_REVISION_WORK_GRANT_CONTRACT,mode:'accepted_revision',grant_id:intent.decision_id,scope:clone(ctx.run.frozen_request.scope),subject_id:ctx.principal.subject_id,conversation_id:ctx.conversation.id,source_auth:clone(operation.frozen.fresh_source_auth),origin:clone(ctx.run.frozen_request.run_binding),input_hash:intent.input_hash,args_hash:hash(version.content),model_configuration_hash:hash(facade.modelConfiguration),route_hash:intent.route_hash,source_catalog_hash:source?hash(source):null,memory_generation:operation.frozen.memory_generation,accepted_at:operation.receipt.accepted_at,not_after:intent.not_after,execution_budget_ms:intent.execution_budget_ms,limits:clone(intent.limits),allowed_tools:source?['read_public_sources_v1','save_sourced_report_v1','finish_task','ask_user']:['save_artifact','finish_task','ask_user'],revision_binding:{operation_id:operation.id,operation_hash:operation.operation_hash,accepted_plan_reference:clone(plan.plan_reference),target_hash:intent.target_hash,input_hash:intent.input_hash}};
 for(const kind of [TASK_WORK_GRANT_KINDS.terms,TASK_REVISION_WORK_GRANT_KINDS.terms])check(!await tx.get(ctx.owner,kind,intent.decision_id),409,'revision_work_decision_reused');assertLive();
 const reference=workGrantReference(terms),op={...operation,work_grant_reference:reference};
 check(await tx.insertIfAbsent(ctx.owner,OPS,op),409,'revision_operation_conflict');assertLive();
 const task=await tx.get(ctx.owner,'tasks',ctx.task.id);assertLive();
 check(task?.state?.task_revision?.operation_id===op.id&&task.state.task_revision.operation_hash===op.operation_hash,409,'revision_work_task_conflict');
 await tx.put(ctx.owner,'tasks',{...task,state:{...task.state,task_revision:{...task.state.task_revision,work_grant_reference:reference}}});assertLive();
 const identity={owner:ctx.owner,scope_id:terms.scope.scope_id,subject_id:terms.subject_id,grant_id:terms.grant_id};
 const admitted=await facade.workGrantService.admitRevisionInTransaction(tx,{identity,principal:ctx.principal,terms});assertLive();
 const saved={...op,work_grant_receipt_hash:admitted.receipt.receipt_hash};await tx.put(ctx.owner,OPS,saved);assertLive();
 const current=await facade.workGrantService.current(tx,identity,facade.workGrantService.permission(undefined,assertLive));
 check(current.row.receipt.receipt_hash===saved.work_grant_receipt_hash,409,'revision_work_receipt_conflict');
 return {operation:saved,work_receipt:publicRevisionWorkReceipt(saved)};
}
export async function readTaskRevisionWork(facade,auth,scopeID,runID,operationID,readRevision){
 check(UUID.test(runID)&&UUID.test(operationID),422,'revision_work_schema_invalid');
 const result=await readRevision(facade,auth,scopeID,runID,operationID),trusted=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{
  await tx.withScope(scopeID,async()=>{});const run=await facade.ownedRun(tx,trusted.owner,runID,trusted.principal,scopeID);
  const ctx={...trusted,run,task:await tx.get(trusted.owner,'tasks',run.task_id),conversation:await tx.get(trusted.owner,'native-chat-conversations',run.frozen_request.conversation_id)};
  check(typeof facade.beforeTaskRevisionRead==='function',503,'revision_authority_not_configured');await facade.beforeTaskRevisionRead(tx,ctx);
  const op=await tx.get(trusted.owner,OPS,operationID);check(op?.receipt?.run_id===runID&&op.receipt.scope_id===scopeID&&op.receipt.subject_id===trusted.principal.subject_id&&op.work_grant_reference,404,'not_found');
  const receipt=publicRevisionWorkReceipt(op,result.revision);await facade.beforeTaskRevisionRead(tx,ctx);return receipt;
 });
}
