import {check,shape,clone,UUID,hash,immutableBody} from '../facade-r2/src/common.mjs';

export const TASK_ARTIFACT_CONTRACT='catpaw.task-artifact.v1';
export const TASK_ARTIFACT_KINDS=Object.freeze({operations:'catpaw-task-artifact-operations',receipts:'catpaw-task-artifact-receipts'});
export const TASK_ARTIFACT_LIMITS=Object.freeze({title:160,summary:8000,content:16000,payload_bytes:96000,body_bytes:256000,write_budget_ms:5000});
export const taskArtifactUUID=value=>{check(typeof value==='string'&&UUID.test(value),422,'artifact_schema_invalid');return value.toLowerCase();};
export const taskArtifactID=value=>{check(typeof value==='string'&&/^[a-f0-9]{64}$/.test(value),422,'artifact_schema_invalid');return value;};
export const taskArtifactVersion=value=>{check(Number.isSafeInteger(value)&&value>0,422,'artifact_schema_invalid');return value;};
const text=(value,max)=>typeof value==='string'&&value.trim().length>0&&value.length<=max&&!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value);
export function validateArtifactEditContent(content){
 shape(content,['title','summary','content']);
 check(text(content.title,TASK_ARTIFACT_LIMITS.title)&&text(content.summary,TASK_ARTIFACT_LIMITS.summary)&&text(content.content,TASK_ARTIFACT_LIMITS.content),422,'artifact_content_invalid');return clone(content);
}
export function validateArtifactAmendment(input){
 shape(input,['operation_id','expected_version','expected_content_hash','expected_grant_epoch','expected_plan_revision','expected_plan_hash','content']);
 const result={...clone(input),operation_id:taskArtifactUUID(input.operation_id),content:validateArtifactEditContent(input.content)};
 taskArtifactVersion(input.expected_version);taskArtifactVersion(input.expected_grant_epoch);taskArtifactVersion(input.expected_plan_revision);taskArtifactID(input.expected_content_hash);taskArtifactID(input.expected_plan_hash);
 check(new TextEncoder().encode(JSON.stringify(result)).length<=TASK_ARTIFACT_LIMITS.payload_bytes,413,'artifact_payload_limit');return result;
}
export function artifactReceiptHash(receipt){const {receipt_hash,...fields}=receipt;return hash(fields);}
export function artifactReference(row){return {artifact_id:row.artifact_id,version:row.version,content_hash:row.content_hash};}
export function userRevisionBody(original,input,{operation_id,base_reference,plan_reference,grant_epoch,committed_at,source_evidence_boundary}){
 const data={...clone(original.data),content:input.content,source:'user_revision',updated_at:committed_at,
  user_revision:{author:'user',operation_id,base_reference:clone(base_reference),plan_reference:clone(plan_reference),grant_epoch,source_evidence_boundary,claims_verification:'not_rechecked'}};
 if(source_evidence_boundary==='original_snapshot_only'){
  if(!data.original_citations)data.original_citations=clone(data.citations??[]);
  delete data.citations;
 }
 const body=immutableBody({kind:'report',title:input.title,summary:input.summary,data});
 check(new TextEncoder().encode(body).length<=TASK_ARTIFACT_LIMITS.body_bytes,413,'artifact_body_limit');return body;
}
