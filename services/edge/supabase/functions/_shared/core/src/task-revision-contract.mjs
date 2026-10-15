import {check,shape,UUID,hash,clone} from '../facade-r2/src/common.mjs';
export const TASK_REVISION_CONTRACT='catpaw.task-revision.v1';
export const TASK_REVISION_KINDS=Object.freeze({operations:'catpaw-task-revision-operations',results:'catpaw-task-revision-results',artifact_receipts:'catpaw-task-revision-artifact-receipts'});
export const TASK_REVISION_LIMITS=Object.freeze({payload_bytes:48000,body_bytes:512000,requirements:4000,write_budget_ms:15000,max_versions:32});
const digest=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v),positive=v=>Number.isSafeInteger(v)&&v>0;
export function validateTaskRevisionTarget(input){
 shape(input,['intent','run_id','task_id','artifact_reference','expected_grant_epoch','expected_plan_revision','expected_plan_hash']);
 check(['revise_report','explain_report'].includes(input.intent)&&UUID.test(input.run_id)&&digest(input.task_id)&&positive(input.expected_grant_epoch)&&positive(input.expected_plan_revision)&&digest(input.expected_plan_hash),422,'revision_schema_invalid');
 shape(input.artifact_reference,['artifact_id','version','content_hash']);const a=input.artifact_reference;check(digest(a.artifact_id)&&positive(a.version)&&digest(a.content_hash),422,'revision_schema_invalid');
 return {...clone(input),run_id:input.run_id.toLowerCase()};
}
export function validateTaskRevisionRequest(input){shape(input,['turn','target']);check(Buffer.byteLength(JSON.stringify(input))<=TASK_REVISION_LIMITS.payload_bytes,413,'revision_request_too_large');return {turn:clone(input.turn),target:validateTaskRevisionTarget(input.target)};}
export function validateTaskRevisionTool(input){shape(input,['requirements']);check(typeof input.requirements==='string'&&input.requirements.length<=TASK_REVISION_LIMITS.requirements,422,'invalid_tool_arguments');return clone(input);}
export function taskRevisionReceiptHash(receipt){const {state,result_reference,result_receipt_hash,receipt_hash,...immutable}=receipt;return hash(immutable);}
export function publicTaskRevisionReceipt(operation){return {...clone(operation.receipt),receipt_hash:operation.receipt_hash,state:'accepted'};}
