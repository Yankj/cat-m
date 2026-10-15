import {Buffer} from 'node:buffer';
import {check,shape,UUID,hash,clone} from '../facade-r2/src/common.mjs';
import {validateAcceptedWorkIntent} from './accepted-work-intent-contract.mjs';
import {TASK_WORK_GRANT_LIMITS as L,workGrantInstant,validateWorkGrantReference,TASK_REVISION_WORK_GRANT_CONTRACT} from './task-work-grant-contract.mjs';
import {validateTaskRevisionTarget,taskRevisionReceiptHash} from './task-revision-contract.mjs';
import {parseStrictObjectJSON} from './strict-json.mjs';

export const TASK_REVISION_WORK_CONTRACT='catpaw.task-revision-work.v1';
export const TASK_REVISION_WORK_BYTES=48000;
const uuid=v=>typeof v==='string'&&UUID.test(v);
const integer=v=>Number.isSafeInteger(v)&&v>0;
const exact=(value,keys)=>{try{shape(value,keys);}catch{check(false,422,'revision_work_schema_invalid');}};
const frozenKeys=['schema_version','contract','decision_id','input_hash','route_hash','tool_policy','not_after','execution_budget_ms','limits','subject_id','scope_id','conversation_id','conversation_epoch','turn_id','message_id','target_hash','admitted_at'];

function targetFor(input){
 const target=validateTaskRevisionTarget(input);
 check(target.intent==='revise_report',422,'revision_work_schema_invalid');
 // Hash exactly the bytes represented by the submitted data, never silently
 // normalize an already approved target into another authorization input.
 check(hash(target)===hash(input),422,'revision_work_target_not_canonical');
 return target;
}
function turnFor(input){
 exact(input,['turn_id','expected_revision','expected_grant_epoch','message','context']);exact(input.message,['id','text']);
 check(uuid(input.turn_id)&&uuid(input.message.id)&&input.turn_id!==input.message.id&&integer(input.expected_revision)&&integer(input.expected_grant_epoch)&&typeof input.message.text==='string'&&input.message.text.trim().length>0&&Array.isArray(input.context),422,'revision_work_schema_invalid');
 return input;
}
function boundInput(turn,target){return {turn:turnFor(turn),target:targetFor(target)};}
function window(work,admitted){
 return workGrantInstant(admitted)&&Date.parse(work.not_after)>Date.parse(admitted)&&Date.parse(work.not_after)-Date.parse(admitted)<=L.lifetime_ms&&work.execution_budget_ms<=Date.parse(work.not_after)-Date.parse(admitted);
}

/** New explicit bounded authority for this one fresh revision. No field is
 * inherited from the original work grant, model output or presentation state. */
export function validateTaskRevisionWorkRequest(input){
 exact(input,['schema_version','contract','turn','target','work']);
 check(input.schema_version===1&&input.contract===TASK_REVISION_WORK_CONTRACT,422,'revision_work_schema_invalid');
 let bytes;try{bytes=Buffer.byteLength(JSON.stringify(input));}catch{check(false,422,'revision_work_schema_invalid');}
 check(bytes<=TASK_REVISION_WORK_BYTES,413,'revision_work_request_too_large');
 const binding=boundInput(input.turn,input.target),work=validateAcceptedWorkIntent(input.work);
 check(work.input_hash===hash(binding),409,'revision_work_input_conflict');
 return {...clone(input),target:clone(binding.target),work};
}
export function parseTaskRevisionWorkJSON(raw){
 return parseStrictObjectJSON(raw,{maxBytes:TASK_REVISION_WORK_BYTES,schemaCode:'revision_work_schema_invalid',duplicateCode:'revision_work_duplicate_key',sizeCode:'revision_work_request_too_large'});
}
export function freezeRevisionWorkIntent(input,{turn,target,scope,principal,conversation,routeHash,now}){
 const work=validateAcceptedWorkIntent(input),binding=boundInput(turn?.input,target);
 check(work.input_hash===hash(binding)&&work.route_hash===routeHash,409,'revision_work_input_or_route_conflict');
 check(Number.isSafeInteger(now)&&window(work,new Date(now).toISOString()),409,'revision_work_expired');
 check(uuid(principal?.subject_id)&&uuid(scope?.scope_id)&&uuid(conversation?.id)&&scope.scope_id===conversation.scope_id&&conversation.subject_id===principal.subject_id&&integer(conversation.grant_epoch)&&conversation.grant_epoch===binding.turn.expected_grant_epoch&&turn.id===binding.turn.turn_id,403,'revision_work_subject_conflict');
 return {schema_version:1,contract:TASK_REVISION_WORK_CONTRACT,...work,subject_id:principal.subject_id,scope_id:scope.scope_id,conversation_id:conversation.id,conversation_epoch:conversation.grant_epoch,turn_id:turn.id,message_id:binding.turn.message.id,target_hash:hash(binding.target),admitted_at:new Date(now).toISOString()};
}
export function validateFrozenRevisionWorkIntent(input,{turn,target,scope,conversation,routeHash,callName}){
 exact(input,frozenKeys);
 const {schema_version,contract,subject_id,scope_id,conversation_id,conversation_epoch,turn_id,message_id,target_hash,admitted_at,...fields}=input;
 const work=validateAcceptedWorkIntent(fields),binding=boundInput(turn?.input,target);
 check(schema_version===1&&contract===TASK_REVISION_WORK_CONTRACT&&uuid(subject_id)&&subject_id===conversation?.subject_id&&scope_id===scope?.scope_id&&scope_id===conversation?.scope_id&&conversation_id===conversation?.id&&integer(conversation_epoch)&&conversation_epoch===conversation?.grant_epoch&&conversation_epoch===binding.turn.expected_grant_epoch&&turn_id===turn?.id&&turn_id===binding.turn.turn_id&&message_id===binding.turn.message.id&&target_hash===hash(binding.target)&&work.input_hash===hash(binding)&&work.route_hash===routeHash&&window(work,admitted_at),409,'revision_work_binding_conflict');
 check(callName==='revise_current_report_work_v1',403,'revision_work_tool_policy_conflict');
 return clone(input);
}
/** Receipt reads/replays may validate immutable terms after expiry. A NEW
 * execution still has to fit the same original absolute window; never renew it. */
export function assertRevisionWorkNewExecutionWindow(intent,now){
 check(Number.isSafeInteger(now)&&workGrantInstant(intent?.admitted_at)&&workGrantInstant(intent?.not_after)&&integer(intent.execution_budget_ms)&&now>=Date.parse(intent.admitted_at)&&now<Date.parse(intent.not_after)&&intent.execution_budget_ms<=Date.parse(intent.not_after)-now,409,'revision_work_expired');
}

/** Only the immutable inner revision receipt participates. Its original GET may
 * later expose completed/result fields without changing this outer identity. */
export function revisionWorkReceiptHash(envelope){
 const {receipt_hash,revision,...fields}=envelope??{};
 return hash({...fields,revision_receipt_hash:revision?.receipt_hash});
}

const digest=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const workFields=['decision_id','input_hash','route_hash','tool_policy','not_after','execution_budget_ms','limits'];
/** Hash the seven explicitly submitted work fields, excluding trusted admission
 * metadata so the native client can verify its own original authorization. */
export function revisionWorkIntentHash(frozen){
 const work=Object.fromEntries(workFields.map(key=>[key,frozen?.[key]]));
 return hash(validateAcceptedWorkIntent(work));
}
function artifactReference(value){
 exact(value,['artifact_id','version','content_hash']);
 check(digest(value.artifact_id)&&integer(value.version)&&digest(value.content_hash),422,'revision_work_receipt_invalid');
}
function planReference(value){
 exact(value,['revision','plan_hash']);check(integer(value.revision)&&digest(value.plan_hash),422,'revision_work_receipt_invalid');
}
/** Data validation only, never source or execution authority. Dynamic completion
 * remains owned by the existing original revision operation and its verifier. */
export function validatePublicRevisionWorkReceipt(input){
 exact(input,['schema_version','contract','decision_id','input_hash','target_hash','work_intent_hash','revision','grant_reference','grant_receipt_hash','receipt_hash']);
 const r=input.revision,g=input.grant_reference;
 check(input.schema_version===1&&input.contract===TASK_REVISION_WORK_CONTRACT&&uuid(input.decision_id)&&['input_hash','target_hash','work_intent_hash','grant_receipt_hash','receipt_hash'].every(key=>digest(input[key])),422,'revision_work_receipt_invalid');
 validateWorkGrantReference(g);
 check(g.contract===TASK_REVISION_WORK_GRANT_CONTRACT&&g.grant_id===input.decision_id,422,'revision_work_receipt_invalid');
 const keys=['operation_id','operation_hash','scope_id','subject_id','conversation_id','turn_id','call_id','run_id','task_id','base_reference','base_plan_reference','accepted_plan_reference','instruction_hash','source_auth_hash','fresh_source_auth_hash','grant_epoch','accepted_at','receipt_hash','state'];
 const extra=r?.state==='completed'?['result_reference','result_receipt_hash']:[];
 exact(r,[...keys,...extra]);
 check(['operation_id','scope_id','subject_id','conversation_id','turn_id','run_id'].every(key=>uuid(r[key]))&&['operation_hash','task_id','instruction_hash','source_auth_hash','fresh_source_auth_hash','receipt_hash'].every(key=>digest(r[key]))&&typeof r.call_id==='string'&&r.call_id.trim().length>0&&r.call_id.length<=160&&integer(r.grant_epoch)&&workGrantInstant(r.accepted_at)&&['accepted','completed','blocked_unknown'].includes(r.state),422,'revision_work_receipt_invalid');
 artifactReference(r.base_reference);planReference(r.base_plan_reference);planReference(r.accepted_plan_reference);
 check(r.accepted_plan_reference.revision>r.base_plan_reference.revision&&r.receipt_hash===taskRevisionReceiptHash(r),409,'revision_work_inner_receipt_conflict');
 if(r.state==='completed'){artifactReference(r.result_reference);check(r.result_reference.artifact_id===r.base_reference.artifact_id&&r.result_reference.version>r.base_reference.version&&digest(r.result_receipt_hash),409,'revision_work_result_reference_conflict');}
 check(input.receipt_hash===revisionWorkReceiptHash(input),409,'revision_work_receipt_conflict');
 return clone(input);
}
