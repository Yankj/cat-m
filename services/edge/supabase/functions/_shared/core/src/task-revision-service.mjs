import {check,hash,clone,iso,immutableBody,UUID} from '../facade-r2/src/common.mjs';
import {stableUUID} from './local-output-facade.mjs';
import {samePlan} from './plan-contract.mjs';
import {hasUnresolvedSourceReads} from './task-source-service.mjs';
import {reopenTaskForRevisionInTransaction} from './task-plan-service.mjs';
import {TASK_REVISION_CONTRACT,TASK_REVISION_KINDS,TASK_REVISION_LIMITS,validateTaskRevisionTarget,validateTaskRevisionTool,taskRevisionReceiptHash,publicTaskRevisionReceipt} from './task-revision-contract.mjs';
const OPS=TASK_REVISION_KINDS.operations,RESULTS=TASK_REVISION_KINDS.results,PUBLICATIONS=TASK_REVISION_KINDS.artifact_receipts;
const permission=(facade,assertLive)=>{const clock=facade.taskRevisionNow??Date.now,started=clock();return ()=>{assertLive();const now=clock();check(now>=started&&now-started<TASK_REVISION_LIMITS.write_budget_ms,409,'revision_deadline');};};
async function authority(facade,tx,ctx,write=true){const hook=write?facade.beforeTaskRevisionWrite:facade.beforeTaskRevisionRead;check(typeof hook==='function',503,'revision_authority_not_configured');const result=await hook(tx,ctx);check(typeof result?.source_current==='boolean',503,'revision_authority_result_required');if(write)check(result.source_current,403,'revision_source_not_current');return result.source_current;}
async function unresolved(tx,owner,run,task){
 if(task.state.local_model?.round?.state==='dispatched'||await hasUnresolvedSourceReads(tx,owner,run.id))return true;
 for(const b of await tx.list(owner,'catpaw-approval-bindings'))if(b.run_id===run.id){const action=await tx.get(owner,'actions',b.id);if(['executing','outcome_unknown','failed'].includes(action?.status)&&b.reconciliation_state!=='resolved_local')return true;}
 return false;
}
async function resolve(facade,tx,{owner,scope,principal,conversation,turn,target,assertLive=()=>{}},eligible=true){
 const wait=async f=>{assertLive();const v=await f();assertLive();return v;};
 let scopeRow;await wait(()=>tx.withScope(scope.scope_id,async scoped=>{scopeRow=await scoped.scope();check(scopeRow.identity.owner===owner,403,'scope_forbidden');}));
 const run=await wait(()=>facade.ownedRun(tx,owner,target.run_id,principal,scope.scope_id)),f=run.frozen_request;
 check(f.conversation_id===conversation.id&&f.subject_id===principal.subject_id&&run.task_id===target.task_id&&hash(f)===run.request_hash,409,'revision_target_binding_conflict');
 const d=await wait(()=>facade.ownedDelegation(tx,owner,run.delegation_id,principal,{lock:true,scopeID:scope.scope_id}));
 await wait(()=>tx.lock(owner,'tasks',run.task_id));const task=await wait(()=>tx.get(owner,'tasks',run.task_id)),tag=task?.state?.catpaw;
 check(tag?.run_id===run.id&&['operation_id','delegation_id','request_hash','grant_epoch','delegation_revision'].every(k=>tag[k]===run[k]),409,'revision_task_binding_conflict');
 check(d.state==='active'&&d.grant_epoch===run.grant_epoch&&d.revision===run.delegation_revision&&target.expected_grant_epoch===run.grant_epoch,409,'grant_conflict');
 check(scopeRow.generation===f.memory_generation,409,'memory_generation_superseded');
 await wait(()=>tx.lock(owner,'catpaw-task-plan-heads',run.id));const head=await wait(()=>tx.get(owner,'catpaw-task-plan-heads',run.id)),planReference={revision:target.expected_plan_revision,plan_hash:target.expected_plan_hash};
 check(head?.run_id===run.id&&head.task_id===task.id&&head.scope_id===scope.scope_id&&head.subject_id===principal.subject_id&&head.conversation_id===conversation.id,409,'revision_plan_binding_conflict');
 check(head.accepted_revision===head.applied_revision&&samePlan(task.state.plan_binding,planReference)&&head.applied_revision===planReference.revision&&head.applied_plan_hash===planReference.plan_hash,409,'revision_plan_conflict');
 const plan=await wait(()=>tx.get(owner,'catpaw-task-plan-versions',`${run.id}:${planReference.revision}`));check(plan?.plan_hash===planReference.plan_hash&&hash(plan.content)===planReference.plan_hash,409,'revision_plan_binding_conflict');
 const ref=target.artifact_reference;await wait(()=>tx.lock(owner,'catpaw-artifact-heads',ref.artifact_id));const artifactHead=await wait(()=>tx.get(owner,'catpaw-artifact-heads',ref.artifact_id));
 check(artifactHead&&artifactHead.version===ref.version&&artifactHead.content_hash===ref.content_hash&&samePlan(artifactHead.plan_reference,planReference)&&run.artifact_references.some(r=>hash(r)===hash(ref))&&task.artifactIds.includes(ref.artifact_id),409,'revision_artifact_conflict');
 const artifact=await wait(()=>tx.get(owner,'catpaw-artifact-versions',`${ref.artifact_id}:${ref.version}`));
 check(artifact?.run_id===run.id&&artifact.task_id===task.id&&artifact.content_hash===ref.content_hash&&typeof artifact.body==='string'&&Buffer.byteLength(artifact.body)<=TASK_REVISION_LIMITS.body_bytes&&hash(artifact.body)===ref.content_hash&&samePlan(artifact.plan_reference,planReference),409,'revision_artifact_binding_conflict');
 let body;try{body=JSON.parse(artifact.body);}catch{check(false,409,'revision_artifact_corrupt');}check(body?.kind==='report'&&body.data?.conversation_id===conversation.id&&typeof body.data.content==='string'&&immutableBody(body)===artifact.body,409,'revision_artifact_corrupt');
 if(eligible){check(task.status==='succeeded'&&task.leaseId===null&&task.leaseUntil===null,409,'revision_task_not_editable');check(!await wait(()=>unresolved(tx,owner,run,task)),409,'revision_original_outcome_unknown');}
 check(turn.source_auth?.subject_id===f.subject_id&&turn.source_auth.scope_id===scope.scope_id&&turn.source_auth.consent_revision===f.source_auth?.consent_revision,403,'revision_consent_conflict');
 return {owner,scope,principal,conversation,turn,target,run,d,task,head,artifact,plan,base_body:artifact.body,raw_instruction:turn.input.message.text,fresh_source_auth:clone(turn.source_auth),scopeRow};
}
export async function freezeTaskRevisionTargetInTransaction(facade,tx,args){
 const target=validateTaskRevisionTarget(args.target),live=permission(facade,args.assertLive??(()=>{})),ctx=await resolve(facade,tx,{...args,target,assertLive:live});live();await authority(facade,tx,ctx);live();
 const frozen={schema_version:1,contract:TASK_REVISION_CONTRACT,target:clone(target),scope_id:args.scope.scope_id,subject_id:args.principal.subject_id,conversation_id:args.conversation.id,turn_id:args.turn.id,input_hash:hash(args.turn.input),raw_instruction:args.turn.input.message.text,instruction_hash:hash(args.turn.input.message.text),base_body:ctx.base_body,base_body_hash:hash(ctx.base_body),original_request_hash:ctx.run.request_hash,original_source_auth:clone(ctx.run.frozen_request.source_auth),fresh_source_auth:clone(args.turn.source_auth),memory_generation:ctx.scopeRow.generation};
 await authority(facade,tx,ctx);live();return frozen;
}
function validFrozen(turn){const f=turn.revision_target;check(f?.contract===TASK_REVISION_CONTRACT&&f.turn_id===turn.id&&f.input_hash===hash(turn.input)&&f.raw_instruction===turn.input.message.text&&f.instruction_hash===hash(f.raw_instruction)&&f.base_body_hash===hash(f.base_body)&&hash(f.fresh_source_auth)===hash(turn.source_auth),409,'revision_frozen_conflict');return f;}
export async function assertTaskRevisionTurnBoundaryInTransaction(facade,tx,args){
 const assertLive=args.assertLive??(()=>{}),f=validFrozen(args.turn);assertLive();
 const run=await facade.ownedRun(tx,args.owner,f.target.run_id,args.principal,args.scope.scope_id);assertLive();check(run.request_hash===f.original_request_hash&&hash(run.frozen_request)===run.request_hash&&hash(run.frozen_request.source_auth)===hash(f.original_source_auth),409,'revision_frozen_conflict');
 const d=await facade.ownedDelegation(tx,args.owner,run.delegation_id,args.principal,{lock:true,scopeID:args.scope.scope_id});assertLive();check(d.state==='active'&&d.grant_epoch===run.grant_epoch&&d.revision===run.delegation_revision,409,'grant_conflict');
 await tx.withScope(args.scope.scope_id,async scoped=>{const row=await scoped.scope();assertLive();check(row.generation===f.memory_generation&&row.generation===run.frozen_request.memory_generation,409,'memory_generation_superseded');});assertLive();
 const task=await tx.get(args.owner,'tasks',run.task_id),conversation=await tx.get(args.owner,'native-chat-conversations',f.conversation_id);assertLive();check(conversation?.state==='active'&&conversation.grant_epoch===args.turn.grant_epoch&&!args.turn.content_redacted,409,'grant_conflict');
 await authority(facade,tx,{...args,run,d,task,conversation,raw_instruction:f.raw_instruction,base_body:f.base_body,fresh_source_auth:f.fresh_source_auth});assertLive();
 return {run,task};
}
function operationValid(op){check(op&&op.id===op.receipt?.operation_id&&hash(op.frozen)===op.operation_hash&&op.receipt.operation_hash===op.operation_hash&&taskRevisionReceiptHash(op.receipt)===op.receipt_hash,409,'revision_operation_corrupt');return op;}
export async function acceptTaskRevisionInTransaction(facade,tx,args){
 const live=permission(facade,args.assertLive??(()=>{})),f=validFrozen(args.turn);check(f.target.intent==='revise_report',422,'revision_tool_not_allowed');const a=validateTaskRevisionTool(args.call.arguments);
 const checkpoint=args.turn.dispatch_checkpoint;check(checkpoint?.state==='received'&&checkpoint.round_hash===hash(checkpoint.round)&&checkpoint.round?.calls.length===1&&hash(checkpoint.round.calls[0])===hash(args.call),409,'revision_received_round_required');
 const id=stableUUID(`${args.turn.id}:${args.call.id}:${TASK_REVISION_CONTRACT}`),frozen={...clone(f),call_id:args.call.id,requirements:a.requirements},operationHash=hash(frozen);await tx.lock(args.owner,OPS,id);live();const prior=await tx.get(args.owner,OPS,id);live();
 if(prior){operationValid(prior);check(prior.operation_hash===operationHash,409,'revision_operation_conflict');return {receipt:publicTaskRevisionReceipt(prior),wake:null};}
 const ctx=await resolve(facade,tx,{...args,target:f.target,assertLive:live});check(ctx.run.request_hash===f.original_request_hash&&ctx.base_body===f.base_body&&hash(ctx.run.frozen_request.source_auth)===hash(f.original_source_auth)&&ctx.scopeRow.generation===f.memory_generation,409,'revision_frozen_conflict');await authority(facade,tx,ctx);live();
 const plan=await reopenTaskForRevisionInTransaction(tx,ctx.owner,ctx.run,ctx.task,ctx.head,a.requirements,{operation_id:id,operation_hash:operationHash,base_reference:clone(f.target.artifact_reference)},{assertLive:live});live();
 const acceptedAt=iso(),receipt={operation_id:id,operation_hash:operationHash,scope_id:f.scope_id,subject_id:f.subject_id,conversation_id:f.conversation_id,turn_id:f.turn_id,call_id:args.call.id,run_id:ctx.run.id,task_id:ctx.task.id,base_reference:clone(f.target.artifact_reference),base_plan_reference:{revision:f.target.expected_plan_revision,plan_hash:f.target.expected_plan_hash},accepted_plan_reference:clone(plan.plan_reference),instruction_hash:f.instruction_hash,source_auth_hash:hash(f.original_source_auth),fresh_source_auth_hash:hash(f.fresh_source_auth),grant_epoch:ctx.run.grant_epoch,accepted_at:acceptedAt};
 const op={id,conversation_id:f.conversation_id,run_id:ctx.run.id,task_id:ctx.task.id,frozen,operation_hash:operationHash,receipt,receipt_hash:taskRevisionReceiptHash(receipt)};check(await tx.insertIfAbsent(ctx.owner,OPS,op),409,'revision_operation_conflict');live();await assertTaskRevisionTurnBoundaryInTransaction(facade,tx,{...args,assertLive:live});live();
 return {receipt:publicTaskRevisionReceipt(op),wake:{owner:ctx.owner,run_id:ctx.run.id,task_id:ctx.task.id,turn_id:ctx.run.frozen_request.turn_id,source_auth:clone(f.original_source_auth)}};
}
export async function readTaskRevisionContext(tx,owner,run,task){
 const pointer=task.state?.task_revision;if(!pointer)return null;const op=operationValid(await tx.get(owner,OPS,pointer.operation_id)),f=op.frozen;
 check(pointer.operation_hash===op.operation_hash&&op.receipt.run_id===run.id&&op.receipt.task_id===task.id&&samePlan(pointer.plan_reference,task.state.plan_binding)&&samePlan(pointer.plan_reference,op.receipt.accepted_plan_reference)&&hash(pointer.base_reference)===hash(op.receipt.base_reference)&&f.original_request_hash===run.request_hash&&hash(f.original_source_auth)===hash(run.frozen_request.source_auth)&&f.base_body_hash===hash(f.base_body),409,'revision_execution_binding_conflict');
 return {operation_id:op.id,operation_hash:op.operation_hash,plan_reference:clone(pointer.plan_reference),base_reference:clone(pointer.base_reference),raw_instruction:f.raw_instruction,instruction_hash:f.instruction_hash,base_body:f.base_body,source_auth:clone(f.fresh_source_auth),original_source_auth:clone(f.original_source_auth),turn_id:f.turn_id,conversation_id:f.conversation_id,scope_id:f.scope_id,memory_generation:f.memory_generation};
}
export async function assertTaskRevisionAuthorityInTransaction(facade,tx,owner,run,task,{assertLive=()=>{}}={}){
 assertLive();const context=await readTaskRevisionContext(tx,owner,run,task);assertLive();if(!context)return null;
 const turn=await tx.get(owner,'native-chat-turns',context.turn_id);assertLive();check(turn&&hash(turn.source_auth)===hash(context.source_auth)&&!turn.content_redacted,409,'revision_source_not_current');
 const conversation=await tx.get(owner,'native-chat-conversations',context.conversation_id);assertLive();check(conversation?.state==='active'&&conversation.grant_epoch===turn.grant_epoch,409,'grant_conflict');
 await authority(facade,tx,{owner,scope:run.frozen_request.scope,principal:{subject_id:run.frozen_request.subject_id,...context.source_auth},conversation,turn,run,task,head:null,base_body:context.base_body,raw_instruction:context.raw_instruction,fresh_source_auth:context.source_auth});assertLive();return context;
}
export const taskRevisionContextInTransaction=assertTaskRevisionAuthorityInTransaction;
const artifactRef=row=>({artifact_id:row.artifact_id,version:row.version,content_hash:row.content_hash});
const publicationID=(operationID,row)=>`${operationID}:${row.version}:${row.content_hash}`;
function modelRelationValid(row,context){
 check(row?.artifact_id===context.base_reference.artifact_id&&Number.isSafeInteger(row.version)&&row.version>context.base_reference.version&&row.version-context.base_reference.version<=TASK_REVISION_LIMITS.max_versions&&samePlan(row.plan_reference,context.plan_reference)&&typeof row.body==='string'&&hash(row.body)===row.content_hash,409,'revision_result_binding_conflict');
 let body;try{body=JSON.parse(row.body);}catch{check(false,409,'revision_result_binding_conflict');}const relation=body.data?.model_revision;
 check(relation?.operation_id===context.operation_id&&relation.operation_hash===context.operation_hash&&relation.instruction_hash===context.instruction_hash&&hash(relation.base_reference)===hash(context.base_reference)&&samePlan(relation.plan_reference,context.plan_reference),409,'revision_result_relation_required');return body;
}
function publicationValid(receipt,row,context){
 const {receipt_hash,...fields}=receipt??{};check(receipt&&hash(fields)===receipt_hash&&receipt.id===publicationID(context.operation_id,row)&&receipt.operation_hash===context.operation_hash&&receipt.instruction_hash===context.instruction_hash&&hash(receipt.base_reference)===hash(context.base_reference)&&samePlan(receipt.plan_reference,context.plan_reference)&&hash(receipt.artifact_reference)===hash(artifactRef(row))&&receipt.body_hash===hash(row.body),409,'revision_publication_receipt_required');return receipt;
}
export async function recordTaskRevisionArtifactReceiptInTransaction(facade,tx,owner,run,task,row,{assertLive=()=>{}}={}){
 const context=await assertTaskRevisionAuthorityInTransaction(facade,tx,owner,run,task,{assertLive});if(!context)return null;const body=modelRelationValid(row,context),id=publicationID(context.operation_id,row),prior=await tx.get(owner,PUBLICATIONS,id);assertLive();if(prior){const valid=publicationValid(prior,row,context);await assertTaskRevisionAuthorityInTransaction(facade,tx,owner,run,task,{assertLive});return valid;}
 const round=task.state.local_model?.round,call=round?.calls?.[round.next];check(round?.state==='received'&&['save_artifact','save_sourced_report_v1'].includes(call?.name)&&Number.isSafeInteger(round.next),409,'revision_publication_received_call_required');
 check(call.arguments.title===body.title&&call.arguments.summary===body.summary&&call.arguments.content===body.data.content,409,'revision_publication_arguments_conflict');
 if(row.version===context.base_reference.version+1){const base=await tx.get(owner,'catpaw-artifact-versions',`${row.artifact_id}:${context.base_reference.version}`);assertLive();check(base?.content_hash===context.base_reference.content_hash&&base.body===context.base_body,409,'revision_base_superseded');}
 else {const previous=await tx.get(owner,'catpaw-artifact-versions',`${row.artifact_id}:${row.version-1}`);assertLive();modelRelationValid(previous,context);publicationValid(await tx.get(owner,PUBLICATIONS,publicationID(context.operation_id,previous)),previous,context);assertLive();}
 const fields={id,operation_id:context.operation_id,operation_hash:context.operation_hash,conversation_id:context.conversation_id,run_id:run.id,task_id:task.id,base_reference:context.base_reference,plan_reference:context.plan_reference,instruction_hash:context.instruction_hash,artifact_reference:artifactRef(row),body_hash:hash(row.body),call_id:call.id,call_name:call.name,arguments_hash:hash(call.arguments),round_hash:hash({text:round.text,calls:round.calls}),model_dispatch_request_hash:round.request_hash??null,created_at:row.created_at};
 const receipt={...fields,receipt_hash:hash(fields)};check(await tx.insertIfAbsent(owner,PUBLICATIONS,receipt),409,'revision_publication_conflict');assertLive();await assertTaskRevisionAuthorityInTransaction(facade,tx,owner,run,task,{assertLive});assertLive();return receipt;
}
export async function recordTaskRevisionResultInTransaction(facade,tx,owner,run,task,artifact,{assertLive=()=>{}}={}){
 const context=await assertTaskRevisionAuthorityInTransaction(facade,tx,owner,run,task,{assertLive});if(!context)return null;
 modelRelationValid(artifact,context);
 let publication;for(let version=context.base_reference.version+1;version<=artifact.version;version++){const row=await tx.get(owner,'catpaw-artifact-versions',`${artifact.artifact_id}:${version}`);assertLive();modelRelationValid(row,context);publication=publicationValid(await tx.get(owner,PUBLICATIONS,publicationID(context.operation_id,row)),row,context);assertLive();}
 const head=await tx.get(owner,'catpaw-artifact-heads',artifact.artifact_id);assertLive();check(hash(artifactRef(head))===hash(artifactRef(artifact)),409,'revision_result_superseded');
 for(const step of ['compose','save','verify']){const r=await tx.get(owner,'catpaw-task-plan-receipts',`${run.id}:${context.plan_reference.revision}:${step}`);assertLive();check(r?.plan_hash===context.plan_reference.plan_hash,409,'revision_result_receipt_required');}
 const result_reference=artifactRef(artifact),fields={id:context.operation_id,operation_id:context.operation_id,operation_hash:context.operation_hash,conversation_id:context.conversation_id,run_id:run.id,task_id:task.id,base_reference:context.base_reference,plan_reference:context.plan_reference,result_reference,artifact_receipt_reference:{id:publication.id,receipt_hash:publication.receipt_hash},committed_at:iso()},prior=await tx.get(owner,RESULTS,context.operation_id);assertLive();
 if(prior){check(hash(prior.result_reference)===hash(result_reference),409,'revision_result_conflict');await assertTaskRevisionAuthorityInTransaction(facade,tx,owner,run,task,{assertLive});return prior;}const result={...fields,receipt_hash:hash(fields)};check(await tx.insertIfAbsent(owner,RESULTS,result),409,'revision_result_conflict');assertLive();await assertTaskRevisionAuthorityInTransaction(facade,tx,owner,run,task,{assertLive});assertLive();return result;
}
export async function readTaskRevision(facade,auth,scopeID,runID,operationID){
 check(UUID.test(runID)&&UUID.test(operationID),422,'revision_schema_invalid');const scoped=await facade.scoped(auth,scopeID);
 return facade.repository.transaction(async tx=>{await tx.withScope(scopeID,async()=>{});const run=await facade.ownedRun(tx,scoped.owner,runID,scoped.principal,scopeID),conversation=await tx.get(scoped.owner,'native-chat-conversations',run.frozen_request.conversation_id),task=await tx.get(scoped.owner,'tasks',run.task_id),ctx={...scoped,run,task,conversation};await authority(facade,tx,ctx,false);
  const found=await tx.get(scoped.owner,OPS,operationID);check(found,404,'not_found');const op=operationValid(found);check(op.receipt.run_id===runID&&op.receipt.scope_id===scopeID&&op.receipt.subject_id===scoped.principal.subject_id,404,'not_found');const result=await tx.get(scoped.owner,RESULTS,operationID);let revision=publicTaskRevisionReceipt(op);
  if(result){
   const {receipt_hash,...fields}=result;check(hash(fields)===receipt_hash&&result.operation_hash===op.operation_hash,409,'revision_result_corrupt');
   // Result verification precedes the separate worker settlement transaction.
   // Only an actual succeeded task, or its immutable trusted reopen checkpoint,
   // proves completion. A transport/verification receipt alone cannot do so.
   let settled=task?.status==='succeeded'&&task.state?.task_revision?.operation_id===op.id&&samePlan(task.state.plan_binding,op.receipt.accepted_plan_reference)&&task.state.local_model?.finished===true&&hash(task.state.local_model.artifact)===hash(result.result_reference);
   if(!settled)for(const checkpoint of await tx.list(scoped.owner,'catpaw-task-plan-checkpoints'))if(checkpoint.run_id===runID&&checkpoint.previous_task_status==='succeeded'&&checkpoint.previous_task_revision?.operation_id===op.id&&checkpoint.previous_task_revision.operation_hash===op.operation_hash&&samePlan(checkpoint.previous_task_revision.plan_reference,op.receipt.accepted_plan_reference)&&checkpoint.local_model?.finished===true&&hash(checkpoint.local_model.artifact)===hash(result.result_reference)){settled=true;break;}
   if(settled)revision={...revision,state:'completed',result_reference:clone(result.result_reference),result_receipt_hash:receipt_hash};
  }
  if(revision.state!=='completed'&&(task?.status==='outcome_unknown'||task?.state?.local_model?.round?.state==='dispatched'))revision.state='blocked_unknown';
  await authority(facade,tx,ctx,false);return {schema_version:1,contract:TASK_REVISION_CONTRACT,revision};});
}
