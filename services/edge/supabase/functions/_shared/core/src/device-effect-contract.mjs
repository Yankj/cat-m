import {check,shape,hash,clone} from '../facade-r2/src/common.mjs';
import {Buffer} from 'node:buffer';
import {validateDeviceCalendarTarget,validateCalendarCreateParameters} from './task-action-contract.mjs';

// Isolated, versioned primitive. Nothing here registers or enables an executor.
export const DEVICE_EFFECT_CONTRACT='catpaw.device-effect.v1';
export const DEVICE_EFFECT_ACTION_CONTRACT='catpaw.task-action.v2';
export const DEVICE_EFFECT_ACTION_KIND='calendar.create.v2';
export const DEVICE_EFFECT_KINDS=Object.freeze({effects:'catpaw-device-effects',operations:'catpaw-device-effect-operations'});
export const DEVICE_EFFECT_LIMITS=Object.freeze({payload_bytes:32768,lease_ms:15000,write_budget_ms:15000});
export const DEVICE_EFFECT_POLICY=Object.freeze({contract:DEVICE_EFFECT_CONTRACT,version:1,action_kind:DEVICE_EFFECT_ACTION_KIND,notification_channel:'catpaw_local_notification',unknown_recovery:'original_only',execution_location:'registered_device'});
export const DEVICE_EFFECT_POLICY_REFERENCE=Object.freeze({contract:DEVICE_EFFECT_CONTRACT,version:1,policy_hash:hash(DEVICE_EFFECT_POLICY)});
export const deviceEffectUUID=value=>typeof value==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
export const deviceEffectHash=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
export const deviceEffectRevision=value=>Number.isSafeInteger(value)&&value>=0;
const positive=value=>deviceEffectRevision(value)&&value>0;
export function deviceEffectUTC(value){
 check(typeof value==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value),422,'device_effect_time_invalid');
 const n=Date.parse(value);check(Number.isFinite(n)&&new Date(n).toISOString()===value&&n>=0&&n<Date.UTC(2101,0,1),422,'device_effect_time_invalid');return n;
}
function bounded(value){check(Buffer.byteLength(JSON.stringify(value))<=DEVICE_EFFECT_LIMITS.payload_bytes,413,'device_effect_request_too_large');return clone(value);}
export function validateDeviceEffectPolicyReference(value){shape(value,['contract','version','policy_hash']);check(hash(value)===hash(DEVICE_EFFECT_POLICY_REFERENCE),422,'device_effect_policy_unsupported');return clone(value);}
function uuidFromHash(value){const h=hash(value);return `${h.slice(0,8)}-${h.slice(8,12)}-4${h.slice(13,16)}-8${h.slice(17,20)}-${h.slice(20,32)}`;}
// One record key per action, even if corrupt storage changes its decision/digest.
// Those immutable references belong in binding_hash, never in a new record key.
export function deviceEffectID(action){check(deviceEffectUUID(action?.id),422,'device_effect_schema_invalid');return uuidFromHash({contract:DEVICE_EFFECT_CONTRACT,action_id:action.id});}
export function deviceSubeffectID(effectID,kind){check(deviceEffectUUID(effectID)&&['calendar','notification'].includes(kind),422,'device_effect_schema_invalid');return uuidFromHash({contract:DEVICE_EFFECT_CONTRACT,effect_id:effectID,kind});}
export function deviceEffectLeaseID(effectID,operationID){check(deviceEffectUUID(effectID)&&deviceEffectUUID(operationID),422,'device_effect_schema_invalid');return uuidFromHash({contract:DEVICE_EFFECT_CONTRACT,effect_id:effectID,admission_operation_id:operationID,lease:1});}
export function validateDeviceEffectAction(action){
 const f=action?.frozen;
 // A v1 approval was explicitly review-only. Installing this primitive cannot expand it.
 check(f?.contract===DEVICE_EFFECT_ACTION_CONTRACT&&f.kind===DEVICE_EFFECT_ACTION_KIND&&f.tool_version===2,409,'device_effect_review_only_approval');
 shape(f,['contract','id','proposal_operation_id','scope_id','subject_id','conversation_id','turn_id','run_id','task_id','request_hash','delegation_id','delegation_revision','grant_epoch','plan_reference','kind','tool_version','target','parameters','parameters_hash','artifact_reference','execution_policy','created_at','expires_at']);
 check(['id','proposal_operation_id','scope_id','subject_id','conversation_id','turn_id','run_id','delegation_id'].every(k=>deviceEffectUUID(f[k]))&&['task_id','request_hash','parameters_hash'].every(k=>deviceEffectHash(f[k]))&&positive(f.grant_epoch)&&positive(f.delegation_revision),409,'device_effect_action_corrupt');
 shape(f.plan_reference,['revision','plan_hash']);check(positive(f.plan_reference.revision)&&deviceEffectHash(f.plan_reference.plan_hash),409,'device_effect_action_corrupt');
 validateDeviceEffectPolicyReference(f.execution_policy);validateDeviceCalendarTarget(f.target);validateCalendarCreateParameters(f.parameters);
 check(f.parameters.start_at.endsWith('.000Z')&&f.parameters.end_at.endsWith('.000Z'),422,'device_effect_precision_unsupported');
 if(f.artifact_reference!==null){shape(f.artifact_reference,['artifact_id','version','content_hash']);check(typeof f.artifact_reference.artifact_id==='string'&&/^[A-Za-z0-9._-]{1,256}$/.test(f.artifact_reference.artifact_id)&&positive(f.artifact_reference.version)&&deviceEffectHash(f.artifact_reference.content_hash),409,'device_effect_action_corrupt');}
 const created=deviceEffectUTC(f.created_at),expires=deviceEffectUTC(f.expires_at);
 check(expires-created===1800000&&action.id===f.id&&action.action_digest===hash(f)&&f.parameters_hash===hash(f.parameters)&&positive(action.revision)&&action.approval_status==='approved'&&deviceEffectUUID(action.decision_operation_id),409,'device_effect_action_corrupt');return bounded(action);
}
export function validateDeviceEffectAdmission(value){
 shape(value,['operation_id','action_id','decision_operation_id','expected_action_revision','action_digest','expected_grant_epoch','expected_plan_revision','expected_plan_hash','expected_execution_revision','device_id','calendar_snapshot_hash','policy_reference']);
 check(['operation_id','action_id','decision_operation_id','device_id'].every(k=>deviceEffectUUID(value[k]))&&['action_digest','expected_plan_hash','calendar_snapshot_hash'].every(k=>deviceEffectHash(value[k]))&&positive(value.expected_action_revision)&&positive(value.expected_grant_epoch)&&positive(value.expected_plan_revision)&&deviceEffectRevision(value.expected_execution_revision),422,'device_effect_schema_invalid');validateDeviceEffectPolicyReference(value.policy_reference);return bounded(value);
}
export function validateDeviceEffectDispatch(value){
 shape(value,['operation_id','subeffect','expected_effect_revision','binding_hash','lease_id']);
 check(deviceEffectUUID(value.operation_id)&&['calendar','notification'].includes(value.subeffect)&&positive(value.expected_effect_revision)&&deviceEffectHash(value.binding_hash)&&deviceEffectUUID(value.lease_id),422,'device_effect_schema_invalid');return bounded(value);
}
export function validateDeviceEffectResult(value){
 shape(value,['operation_id','subeffect','expected_effect_revision','binding_hash','lease_id','dispatch_operation_id','outcome','receipt']);
 check(deviceEffectUUID(value.operation_id)&&deviceEffectUUID(value.dispatch_operation_id)&&deviceEffectUUID(value.lease_id)&&['calendar','notification'].includes(value.subeffect)&&positive(value.expected_effect_revision)&&deviceEffectHash(value.binding_hash)&&['succeeded','unknown','not_executed'].includes(value.outcome),422,'device_effect_schema_invalid');
 if(value.outcome==='unknown')check(value.receipt===null,422,'device_effect_schema_invalid');
 else {
  shape(value.receipt,['contract','effect_id','subeffect_id','dispatch_operation_id','action_digest','binding_hash','device_id','device_generation','outcome','external_reference','observed_at']);
  const r=value.receipt;check(r.contract===DEVICE_EFFECT_CONTRACT&&[r.effect_id,r.subeffect_id,r.dispatch_operation_id,r.device_id].every(deviceEffectUUID)&&deviceEffectHash(r.action_digest)&&deviceEffectHash(r.binding_hash)&&positive(r.device_generation)&&r.outcome===value.outcome,422,'device_effect_receipt_invalid');deviceEffectUTC(r.observed_at);
  if(r.outcome==='not_executed')check(r.external_reference===null,422,'device_effect_receipt_invalid');
  else if(value.subeffect==='calendar'){
   shape(r.external_reference,['calendar_id','event_identifier','calendar_item_identifier','external_identifier','effect_marker','content_hash']);const e=r.external_reference;
   check(['calendar_id','event_identifier','calendar_item_identifier','effect_marker'].every(k=>typeof e[k]==='string'&&e[k].length>0&&e[k].length<=512&&!/[\u0000-\u001f\u007f]/.test(e[k]))&&(e.external_identifier===null||typeof e.external_identifier==='string'&&e.external_identifier.length<=512)&&deviceEffectHash(e.content_hash),422,'device_effect_receipt_invalid');
  }else{
   shape(r.external_reference,['request_identifier','schedule_hash','due_at','state']);const e=r.external_reference;
   check(deviceEffectUUID(e.request_identifier)&&deviceEffectHash(e.schedule_hash)&&['pending','delivered'].includes(e.state),422,'device_effect_receipt_invalid');deviceEffectUTC(e.due_at);
  }
 }
 return bounded(value);
}
export function validateDeviceEffectStop(value){shape(value,['operation_id','expected_effect_revision','binding_hash']);check(deviceEffectUUID(value.operation_id)&&positive(value.expected_effect_revision)&&deviceEffectHash(value.binding_hash),422,'device_effect_schema_invalid');return bounded(value);}
export function deviceEffectRecordHash(row){const {record_hash,...body}=row;return hash(body);}
export function sealDeviceEffectRecord(row){return {...clone(row),record_hash:deviceEffectRecordHash(row)};}
export function deviceEffectState(row){
 if(row.stop!==null)return 'stopped';const states=Object.values(row.subeffects).map(v=>v.state);
 if(states.every(v=>['succeeded','not_required'].includes(v)))return 'succeeded';
 if(states.includes('unknown'))return states.includes('succeeded')?'partial_unknown':'unknown';
 if(states.includes('not_executed'))return 'partial';if(states.includes('dispatched'))return 'dispatching';
 return states.includes('succeeded')?'partial':'admitted';
}
