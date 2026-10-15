import {check,shape,UUID,hash,clone} from '../facade-r2/src/common.mjs';
import {taskRevisionReceiptHash} from './task-revision-contract.mjs';

export const TASK_WORK_GRANT_CONTRACT='catpaw.task-work-grant.v1';
export const TASK_REVISION_WORK_GRANT_CONTRACT='catpaw.task-work-grant.v2';
export const TASK_REVISION_WORK_GRANT_KINDS=Object.freeze({terms:'catpaw-revision-work-grant-terms',grants:'catpaw-revision-work-grants',reservations:'catpaw-revision-work-grant-reservations'});
export const TASK_WORK_ATTEMPT_ACK_CONTRACT='catpaw.work-attempt-ack.v1';
export const TASK_WORK_GRANT_KINDS=Object.freeze({terms:'catpaw-work-grant-terms',grants:'catpaw-work-grants',reservations:'catpaw-work-grant-reservations'});
export const TASK_WORK_GRANT_LIMITS=Object.freeze({lifetime_ms:86400000,execution_budget_ms:300000,result_budget_ms:30000,write_budget_ms:15000,due:1,model:20,source:12,payload_bytes:12000});
const digest=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const uuid=v=>typeof v==='string'&&UUID.test(v)&&v===v.toLowerCase();
const integer=(v,min,max=Number.MAX_SAFE_INTEGER)=>Number.isSafeInteger(v)&&v>=min&&v<=max;
export const workGrantInstant=v=>typeof v==='string'&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString()===v;
export const workGrantOperationID=v=>uuid(v)||digest(v);
function exact(value,fields){try{shape(value,fields);}catch{check(false,422,'work_grant_schema_invalid');}}
function sized(value){check(new TextEncoder().encode(JSON.stringify(value)).length<=TASK_WORK_GRANT_LIMITS.payload_bytes,413,'work_grant_request_too_large');}

/** Safety ceilings, not defaults or user consent. Every term must be explicit.
 * This version authorizes exactly one already frozen run, never recurring children. */
export function validateWorkGrantTerms(input){
 if(input?.contract===TASK_REVISION_WORK_GRANT_CONTRACT)return validateRevisionWorkGrantTerms(input);
 exact(input,['schema_version','contract','mode','grant_id','scope','subject_id','conversation_id','source_auth','origin','input_hash','args_hash','model_configuration_hash','route_hash','source_catalog_hash','memory_generation','accepted_at','not_after','execution_budget_ms','limits','allowed_tools']);
 exact(input.scope,['scope_id','profile_id','workspace_id','owner']);
 exact(input.source_auth,['subject_id','scope_id','session_id','issuer','issued_at','consent_revision']);
 exact(input.origin,['operation_id','run_id','delegation_id','task_id']);exact(input.limits,['due','model','source']);
 const s=input.scope,a=input.source_auth,o=input.origin,l=input.limits;
 let issuer;try{issuer=new URL(a.issuer);}catch{check(false,422,'work_grant_schema_invalid');}
 check(input.schema_version===1&&input.contract===TASK_WORK_GRANT_CONTRACT&&input.mode==='accepted_run'&&uuid(input.grant_id)&&uuid(input.subject_id)&&uuid(input.conversation_id)&&['scope_id','profile_id','workspace_id'].every(k=>uuid(s[k]))&&typeof s.owner==='string'&&/^catpaw:[a-f0-9]{64}$/.test(s.owner)&&
  a.subject_id===input.subject_id&&a.scope_id===s.scope_id&&uuid(a.session_id)&&typeof a.issuer==='string'&&a.issuer.length<=500&&issuer.protocol==='https:'&&!issuer.username&&!issuer.password&&!issuer.search&&!issuer.hash&&issuer.pathname==='/auth/v1'&&issuer.href===a.issuer&&integer(a.issued_at,1)&&integer(a.consent_revision,1)&&
  ['operation_id','run_id','delegation_id'].every(k=>uuid(o[k]))&&digest(o.task_id)&&['input_hash','args_hash','model_configuration_hash','route_hash'].every(k=>digest(input[k]))&&(input.source_catalog_hash===null||digest(input.source_catalog_hash))&&integer(input.memory_generation,1)&&
  workGrantInstant(input.accepted_at)&&workGrantInstant(input.not_after)&&Date.parse(input.not_after)>Date.parse(input.accepted_at)&&Date.parse(input.not_after)-Date.parse(input.accepted_at)<=TASK_WORK_GRANT_LIMITS.lifetime_ms&&integer(input.execution_budget_ms,1,TASK_WORK_GRANT_LIMITS.execution_budget_ms)&&input.execution_budget_ms<=Date.parse(input.not_after)-Date.parse(input.accepted_at)&&
  l.due===1&&integer(l.model,0,TASK_WORK_GRANT_LIMITS.model)&&integer(l.source,0,TASK_WORK_GRANT_LIMITS.source),422,'work_grant_schema_invalid');
 const tools=input.source_catalog_hash===null?['save_artifact','finish_task','ask_user']:['read_public_sources_v1','save_sourced_report_v1','finish_task','ask_user'];
 check(hash(input.allowed_tools)===hash(tools)&&(input.source_catalog_hash!==null||l.source===0),422,'work_grant_schema_invalid');sized(input);return clone(input);
}
export function workGrantReference(input){const terms=validateWorkGrantTerms(input);return {schema_version:terms.schema_version,contract:terms.contract,grant_id:terms.grant_id,terms_hash:hash(terms)};}
export function validateWorkGrantReference(input){
 exact(input,['schema_version','contract','grant_id','terms_hash']);check(((input.schema_version===1&&input.contract===TASK_WORK_GRANT_CONTRACT)||(input.schema_version===2&&input.contract===TASK_REVISION_WORK_GRANT_CONTRACT))&&uuid(input.grant_id)&&digest(input.terms_hash),422,'work_grant_schema_invalid');return clone(input);
}
export function workGrantKinds(input){
 check(input?.contract===TASK_WORK_GRANT_CONTRACT||input?.contract===TASK_REVISION_WORK_GRANT_CONTRACT,422,'work_grant_schema_invalid');return input.contract===TASK_REVISION_WORK_GRANT_CONTRACT?TASK_REVISION_WORK_GRANT_KINDS:TASK_WORK_GRANT_KINDS;
}
export function workGrantDueIdentity(input,run){
 const terms=validateWorkGrantTerms(input);return terms.schema_version===2?{operation_id:terms.revision_binding.operation_id,operation_key:hash({accepted_revision:terms.revision_binding.operation_id,grant_id:terms.grant_id}),request_hash:terms.revision_binding.operation_hash}:{operation_id:run.operation_id,operation_key:hash({accepted_run:run.id}),request_hash:run.request_hash};
}
function validateRevisionWorkGrantTerms(input){
 const {revision_binding,...fields}=input;exact(revision_binding,['operation_id','operation_hash','accepted_plan_reference','target_hash','input_hash']);exact(revision_binding.accepted_plan_reference,['revision','plan_hash']);
 check(input.schema_version===2&&input.mode==='accepted_revision'&&uuid(revision_binding.operation_id)&&['operation_hash','target_hash','input_hash'].every(k=>digest(revision_binding[k]))&&integer(revision_binding.accepted_plan_reference.revision,2)&&digest(revision_binding.accepted_plan_reference.plan_hash)&&revision_binding.input_hash===input.input_hash,422,'work_grant_schema_invalid');
 validateWorkGrantTerms({...fields,schema_version:1,contract:TASK_WORK_GRANT_CONTRACT,mode:'accepted_run'});sized(input);return clone(input);
}
/** Versioned immutable binding. The physical run/hash/tag is never rewritten.
 * Historical reads can validate old segments; dispatch additionally requires the
 * current pointer, plan and lease at every service boundary. */
export function validateRevisionWorkGrantRunBinding(input,run,{operation,plan,turn}={}){
 try{
  const terms=validateWorkGrantTerms(input),f=run?.frozen_request,b=terms.revision_binding,op=operation,r=op?.receipt,q=op?.frozen,w=q?.revision_work_intent,same=(a,c)=>a!==undefined&&c!==undefined&&hash(a)===hash(c),o=terms.origin;
  check(terms.schema_version===2&&f&&hash(f)===run.request_hash&&run.id===o.run_id&&run.operation_id===o.operation_id&&run.delegation_id===o.delegation_id&&run.task_id===o.task_id&&same(f.run_binding,o)&&integer(run.grant_epoch,1)&&integer(run.delegation_revision,1)&&f.work_grant_reference?.contract===TASK_WORK_GRANT_CONTRACT&&same(f.scope,terms.scope)&&f.subject_id===terms.subject_id&&f.conversation_id===terms.conversation_id&&hash(f.model_configuration)===terms.model_configuration_hash&&(f.public_sources?hash(f.public_sources):null)===terms.source_catalog_hash,409,'work_grant_run_binding_conflict');
  check(op?.id===b.operation_id&&op.run_id===run.id&&op.task_id===run.task_id&&hash(q)===op.operation_hash&&op.operation_hash===b.operation_hash&&r?.operation_id===op.id&&r.operation_hash===op.operation_hash&&r.run_id===run.id&&r.task_id===run.task_id&&taskRevisionReceiptHash(r)===op.receipt_hash&&same(op.work_grant_reference,workGrantReference(terms))&&same(r.accepted_plan_reference,b.accepted_plan_reference)&&same(r.base_reference,q.target.artifact_reference)&&same(r.base_plan_reference,{revision:q.target.expected_plan_revision,plan_hash:q.target.expected_plan_hash})&&b.accepted_plan_reference.revision===q.target.expected_plan_revision+1&&r.grant_epoch===run.grant_epoch&&q.target.expected_grant_epoch===run.grant_epoch&&r.call_id===q.call_id&&r.accepted_at===terms.accepted_at&&r.scope_id===terms.scope.scope_id&&r.subject_id===terms.subject_id&&r.conversation_id===terms.conversation_id,409,'work_grant_run_binding_conflict');
  check(q.target.intent==='revise_report'&&q.target.run_id===run.id&&q.target.task_id===run.task_id&&hash(q.target)===b.target_hash&&q.original_request_hash===run.request_hash&&same(q.original_source_auth,f.source_auth)&&same(q.fresh_source_auth,terms.source_auth)&&q.memory_generation===terms.memory_generation&&q.scope_id===terms.scope.scope_id&&q.subject_id===terms.subject_id&&q.conversation_id===terms.conversation_id&&q.instruction_hash===hash(q.raw_instruction)&&q.base_body_hash===hash(q.base_body)&&r.instruction_hash===q.instruction_hash&&r.source_auth_hash===hash(q.original_source_auth)&&r.fresh_source_auth_hash===hash(q.fresh_source_auth),409,'work_grant_run_binding_conflict');
  check(w?.schema_version===1&&w.contract==='catpaw.task-revision-work.v1'&&w.decision_id===terms.grant_id&&w.input_hash===terms.input_hash&&w.target_hash===b.target_hash&&w.route_hash===terms.route_hash&&w.subject_id===terms.subject_id&&w.scope_id===terms.scope.scope_id&&w.conversation_id===terms.conversation_id&&w.turn_id===q.turn_id&&w.turn_id===r.turn_id&&w.message_id===turn?.input?.message?.id&&w.conversation_epoch===f.conversation_epoch&&w.not_after===terms.not_after&&w.execution_budget_ms===terms.execution_budget_ms&&same(w.limits,terms.limits)&&w.tool_policy===(terms.source_catalog_hash===null?'local_output_v1':'public_sources_v1')&&workGrantInstant(w.admitted_at)&&Date.parse(w.admitted_at)<=Date.parse(terms.accepted_at)&&Date.parse(terms.not_after)-Date.parse(w.admitted_at)<=TASK_WORK_GRANT_LIMITS.lifetime_ms,409,'work_grant_run_binding_conflict');
  check(turn?.id===q.turn_id&&turn.conversation_id===terms.conversation_id&&!turn.content_redacted&&same(turn.source_auth,terms.source_auth)&&hash({turn:turn.input,target:q.target})===terms.input_hash&&hash(turn.input)===q.input_hash&&turn.input.message.text===q.raw_instruction&&same(turn.revision_work_intent,w),409,'work_grant_run_binding_conflict');
  check(plan?.id===run.id+':'+b.accepted_plan_reference.revision&&plan.run_id===run.id&&plan.revision===b.accepted_plan_reference.revision&&plan.plan_hash===b.accepted_plan_reference.plan_hash&&hash(plan.content)===plan.plan_hash&&hash(plan.content)===terms.args_hash&&plan.content.requirements===q.requirements,409,'work_grant_run_binding_conflict');
  return {operation_id:run.operation_id,run_id:run.id,delegation_id:run.delegation_id,task_id:run.task_id,run_request_hash:run.request_hash,grant_epoch:run.grant_epoch,delegation_revision:run.delegation_revision,revision_binding:clone(b)};
 }catch{check(false,409,'work_grant_run_binding_conflict');}
}

/** One canonical pure cross-binding for both HTTP admission and work-source
 * authorization. It confers no source, lease, dispatch or completion authority. */
export function validateWorkGrantRunBinding(input,run,context){
 if(input?.contract===TASK_REVISION_WORK_GRANT_CONTRACT)return validateRevisionWorkGrantRunBinding(input,run,context);
 try{
  const terms=validateWorkGrantTerms(input),f=run?.frozen_request,o=terms.origin,same=(a,b)=>a!==undefined&&b!==undefined&&hash(a)===hash(b);
  check(run&&Object.getPrototypeOf(run)===Object.prototype&&f&&Object.getPrototypeOf(f)===Object.prototype&&hash(f)===run.request_hash&&run.id===o.run_id&&run.operation_id===o.operation_id&&run.delegation_id===o.delegation_id&&run.task_id===o.task_id&&same(f.run_binding,o)&&integer(run.grant_epoch,1)&&integer(run.delegation_revision,1)&&same(f.scope,terms.scope)&&f.subject_id===terms.subject_id&&f.conversation_id===terms.conversation_id&&same(f.source_auth,terms.source_auth)&&f.current_input_hash===terms.input_hash&&hash(f.args)===terms.args_hash&&hash(f.model_configuration)===terms.model_configuration_hash&&f.memory_generation===terms.memory_generation&&(f.public_sources?hash(f.public_sources):null)===terms.source_catalog_hash&&same(f.work_grant_reference,workGrantReference(terms)),409,'work_grant_run_binding_conflict');
  return {operation_id:run.operation_id,run_id:run.id,delegation_id:run.delegation_id,task_id:run.task_id,run_request_hash:run.request_hash,grant_epoch:run.grant_epoch,delegation_revision:run.delegation_revision};
 }catch{check(false,409,'work_grant_run_binding_conflict');}
}
export function validateWorkGrantIdentity(input){
 exact(input,['owner','scope_id','subject_id','grant_id']);check(typeof input.owner==='string'&&/^catpaw:[a-f0-9]{64}$/.test(input.owner)&&uuid(input.scope_id)&&uuid(input.subject_id)&&uuid(input.grant_id),422,'work_grant_schema_invalid');return clone(input);
}
export function validateWorkGrantReservation(input){
 exact(input,['operation_id','operation_key','kind','request_hash','deadline_at']);
 check(workGrantOperationID(input.operation_id)&&digest(input.operation_key)&&['due','model','source'].includes(input.kind)&&digest(input.request_hash)&&workGrantInstant(input.deadline_at),422,'work_grant_schema_invalid');sized(input);return clone(input);
}
export function validateWorkGrantOutcome(input){
 exact(input,['operation_id','request_hash','outcome','receipt_reference']);
 check(workGrantOperationID(input.operation_id)&&digest(input.request_hash)&&['received','unknown'].includes(input.outcome),422,'work_grant_schema_invalid');
 if(input.outcome==='unknown')check(input.receipt_reference===null,422,'work_grant_schema_invalid');
 else{exact(input.receipt_reference,['receipt_id','receipt_hash']);check(workGrantOperationID(input.receipt_reference.receipt_id)&&digest(input.receipt_reference.receipt_hash),422,'work_grant_schema_invalid');}
 sized(input);return clone(input);
}
export function validateWorkGrantExecution(input){
 exact(input,['run_id','task_id','run_request_hash','lease_id','execution_revision']);check(uuid(input.run_id)&&digest(input.task_id)&&digest(input.run_request_hash)&&uuid(input.lease_id)&&integer(input.execution_revision,0),422,'work_grant_schema_invalid');return clone(input);
}
export function validateWorkGrantDispatch(input){
 exact(input,['original_reservation','execution','durable_checkpoint']);validateWorkGrantExecution(input.execution);
 const point=input.durable_checkpoint;exact(point,point?.kind==='source'?['kind','read_id','request_hash','checkpoint_hash']:['kind','request_hash','checkpoint_hash']);
 check(['model','source'].includes(point.kind)&&digest(point.request_hash)&&digest(point.checkpoint_hash)&&(point.kind!=='source'||uuid(point.read_id))&&input.original_reservation&&Object.getPrototypeOf(input.original_reservation)===Object.prototype,422,'work_grant_schema_invalid');return clone(input);
}
export function validateWorkGrantAttemptSettlement(input){
 exact(input,['previous_task','attempt_id','completion_receipt']);
 const task=input.previous_task;check(task&&Object.getPrototypeOf(task)===Object.prototype&&digest(task.id)&&task.status==='running'&&uuid(input.attempt_id)&&task.leaseId===input.attempt_id&&workGrantInstant(task.leaseUntil)&&task.state&&Object.getPrototypeOf(task.state)===Object.prototype,422,'work_grant_schema_invalid');
 if(input.completion_receipt!==null)validateWorkGrantCompletionReceipt(input.completion_receipt);return clone(input);
}
export function validateWorkGrantCompletionReceipt(input){
 exact(input,['artifact_reference','plan_reference','verification_receipt']);exact(input.artifact_reference,['artifact_id','version','content_hash']);exact(input.plan_reference,['revision','plan_hash']);exact(input.verification_receipt,['id','receipt_hash']);
 check(digest(input.artifact_reference.artifact_id)&&integer(input.artifact_reference.version,1)&&digest(input.artifact_reference.content_hash)&&integer(input.plan_reference.revision,1)&&digest(input.plan_reference.plan_hash)&&typeof input.verification_receipt.id==='string'&&input.verification_receipt.id.length<=128&&/^[a-f0-9-]{36}:[1-9][0-9]*:verify$/.test(input.verification_receipt.id)&&digest(input.verification_receipt.receipt_hash),422,'work_grant_schema_invalid');return clone(input);
}
export function workGrantReceiptHash(receipt){const {receipt_hash,...fields}=receipt;return hash(fields);}
