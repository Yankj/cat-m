import {check,hash,clone} from '../facade-r2/src/common.mjs';
import {validateWorkGrantReference,validateWorkGrantTerms,validateWorkGrantRunBinding,workGrantReference,workGrantKinds,workGrantDueIdentity,workGrantReceiptHash,TASK_WORK_GRANT_KINDS,TASK_REVISION_WORK_GRANT_KINDS} from './task-work-grant-contract.mjs';

const same=(a,b)=>a!==undefined&&b!==undefined&&hash(a)===hash(b);
export async function readWorkGrantRevisionBindingInTransaction(tx,owner,run,terms,{assertLive=()=>{}}={}){
 terms=validateWorkGrantTerms(terms);check(terms.schema_version===2,422,'work_grant_schema_invalid');const b=terms.revision_binding,operation=await tx.get(owner,'catpaw-task-revision-operations',b.operation_id);assertLive();check(operation?.frozen?.turn_id,409,'work_grant_run_binding_conflict');
 const plan=await tx.get(owner,'catpaw-task-plan-versions',run.id+':'+b.accepted_plan_reference.revision);assertLive();
 const turn=await tx.get(owner,'native-chat-turns',operation?.frozen?.turn_id);assertLive();
 check(turn?.content_redacted!==true,409,'revision_source_not_current');
 const run_binding=validateWorkGrantRunBinding(terms,run,{operation,plan,turn});return {operation,plan,turn,run_binding};
}
/** Facts only. This selector creates no permission, renewal, lease or dispatch.
 * Every consumer resolves the current segment from the same durable pointer. */
export async function resolveExecutionGrantInTransaction(tx,owner,run,task,{assertLive=()=>{}}={}){
 check(run&&task&&task.id===run.task_id&&same(task.state?.catpaw,{operation_id:run.operation_id,run_id:run.id,delegation_id:run.delegation_id,request_hash:run.request_hash,grant_epoch:run.grant_epoch,delegation_revision:run.delegation_revision}),409,'work_grant_task_binding_conflict');
 const pointer=task.state?.task_revision,ref=pointer?.work_grant_reference??run.frozen_request.work_grant_reference;
 if(!ref){for(const kinds of [TASK_WORK_GRANT_KINDS,TASK_REVISION_WORK_GRANT_KINDS])for(const kind of Object.values(kinds))for(const row of await tx.list(owner,kind))check(row.run_id!==run.id&&row.task_id!==task.id&&row.terms?.origin?.run_id!==run.id,409,'work_grant_record_corrupt');assertLive();return null;}
 const reference=validateWorkGrantReference(ref),kinds=workGrantKinds(reference);check(owner===run.frozen_request.scope.owner,403,'work_grant_scope_conflict');
 const row=await tx.get(owner,kinds.terms,reference.grant_id);assertLive();check(row,404,'work_grant_not_found');const terms=validateWorkGrantTerms(row.terms);
 check(same(reference,workGrantReference(terms))&&row.terms_hash===reference.terms_hash,409,'work_grant_record_corrupt');let run_binding,revision=null;
 if(terms.schema_version===2){revision=await readWorkGrantRevisionBindingInTransaction(tx,owner,run,terms,{assertLive});run_binding=revision.run_binding;check(row.receipt&&revision.operation.work_grant_receipt_hash===row.receipt.receipt_hash&&workGrantReceiptHash(row.receipt)===row.receipt.receipt_hash,409,'work_grant_record_corrupt');check(pointer&&same(pointer.work_grant_reference,reference)&&pointer.operation_id===terms.revision_binding.operation_id&&pointer.operation_hash===terms.revision_binding.operation_hash&&same(pointer.base_reference,revision.operation.receipt.base_reference)&&same(pointer.plan_reference,terms.revision_binding.accepted_plan_reference)&&same(task.state.plan_binding,pointer.plan_reference),409,'work_grant_revision_superseded');}
 else {check(!pointer?.work_grant_reference,409,'work_grant_revision_superseded');run_binding=validateWorkGrantRunBinding(terms,run);}
 check(row.id===terms.grant_id&&row.run_id===run.id&&row.task_id===task.id&&row.subject_id===terms.subject_id&&row.scope_id===terms.scope.scope_id&&row.conversation_id===terms.conversation_id&&same(row.run_binding,run_binding),409,'work_grant_record_corrupt');
 return {identity:{owner,scope_id:terms.scope.scope_id,subject_id:terms.subject_id,grant_id:terms.grant_id},reference:clone(reference),terms:clone(terms),kinds,run_binding,source_auth:clone(terms.source_auth),revision_binding:terms.schema_version===2?clone(terms.revision_binding):null,due:workGrantDueIdentity(terms,run),...revision?{revision}:{}};
}
