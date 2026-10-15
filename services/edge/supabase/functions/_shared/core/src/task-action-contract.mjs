import {check,shape,hash,clone} from '../facade-r2/src/common.mjs';
import {Buffer} from 'node:buffer';

export const TASK_ACTION_CONTRACT='catpaw.task-action.v1';
export const CALENDAR_CREATE_KIND='calendar.create.v1';
export const TASK_ACTION_KINDS=Object.freeze({actions:'catpaw-task-actions',proposals:'catpaw-task-action-proposals',decisions:'catpaw-task-action-decisions'});
export const TASK_ACTION_LIFETIME_MS=30*60*1000;
export const TASK_ACTION_LIMITS=Object.freeze({payload_bytes:16384,title_characters:200,calendar_name_characters:200,calendar_id_characters:256,max_duration_seconds:7*86400,max_reminder_seconds:7*86400});
// Compiled operator data only. This is deliberately not an executor, endpoint, schema interpreter or scheduler.
export const TASK_ACTION_REGISTRY=Object.freeze({[CALENDAR_CREATE_KIND]:Object.freeze({kind:CALENDAR_CREATE_KIND,tool_version:1,effect_class:'device_calendar_write',execution_location:'registered_device',registered:true,executable:false,unavailable_reason:'device_executor_not_configured'})});
const canonicalUUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SHA=/^[a-f0-9]{64}$/;
const integer=(value,min=1,max=Number.MAX_SAFE_INTEGER)=>Number.isSafeInteger(value)&&value>=min&&value<=max;
const text=(value,max)=>typeof value==='string'&&value.trim().length>0&&value.length<=max&&!/[\u0000-\u001f\u007f]/.test(value);
export function taskActionUUID(value){check(typeof value==='string'&&canonicalUUID.test(value),422,'action_schema_invalid');return value;}
export function taskActionHash(value){check(typeof value==='string'&&SHA.test(value),422,'action_schema_invalid');return value;}
export function taskActionID(runID,operationID){taskActionUUID(runID);taskActionUUID(operationID);const h=hash({contract:TASK_ACTION_CONTRACT,run_id:runID,proposal_operation_id:operationID});return `${h.slice(0,8)}-${h.slice(8,12)}-4${h.slice(13,16)}-8${h.slice(17,20)}-${h.slice(20,32)}`;}
function utc(value){
 check(typeof value==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value),422,'action_time_invalid');
 const milliseconds=Date.parse(value);check(Number.isFinite(milliseconds)&&new Date(milliseconds).toISOString()===value&&milliseconds>=0&&milliseconds<Date.UTC(2101,0,1),422,'action_time_invalid');return milliseconds;
}
export function validateCalendarCreateParameters(value){
 shape(value,['title','start_at','end_at','time_zone','reminder_offset_seconds']);
 check(text(value.title,TASK_ACTION_LIMITS.title_characters),422,'action_schema_invalid');
 const start=utc(value.start_at),end=utc(value.end_at);
 check(end>start&&end-start<=TASK_ACTION_LIMITS.max_duration_seconds*1000,422,'action_time_invalid');
 // Only actual IANA identifiers or UTC; offsets, locale names and arbitrary strings are not zones.
 check(typeof value.time_zone==='string'&&value.time_zone.length<=80&&(value.time_zone==='UTC'||/^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)+$/.test(value.time_zone)),422,'action_time_zone_invalid');
 try{new Intl.DateTimeFormat('en-US',{timeZone:value.time_zone}).format(0);}catch{check(false,422,'action_time_zone_invalid');}
 check(value.reminder_offset_seconds===null||integer(value.reminder_offset_seconds,-TASK_ACTION_LIMITS.max_reminder_seconds,0),422,'action_reminder_invalid');
 return clone(value);
}
export function validateDeviceCalendarTarget(value){
 shape(value,['device_id','environment_id','calendar_id','calendar_display_name','calendar_snapshot_hash']);
 taskActionUUID(value.device_id);taskActionUUID(value.environment_id);taskActionHash(value.calendar_snapshot_hash);
 check(text(value.calendar_id,TASK_ACTION_LIMITS.calendar_id_characters)&&text(value.calendar_display_name,TASK_ACTION_LIMITS.calendar_name_characters),422,'action_target_invalid');
 return clone(value);
}
export function validateTaskActionArtifactReference(value){
 if(value===null)return null;
 shape(value,['artifact_id','version','content_hash']);
 check(typeof value.artifact_id==='string'&&/^[A-Za-z0-9._-]{1,256}$/.test(value.artifact_id)&&integer(value.version),422,'action_artifact_invalid');taskActionHash(value.content_hash);return clone(value);
}
export function validateTaskActionProposal(value){
 shape(value,['operation_id','kind','expected_plan_revision','expected_plan_hash','expected_grant_epoch','target','parameters','artifact_reference','replaces_action_id']);
 taskActionUUID(value.operation_id);if(value.replaces_action_id!==null)taskActionUUID(value.replaces_action_id);
 check(value.kind===CALENDAR_CREATE_KIND&&integer(value.expected_plan_revision)&&integer(value.expected_grant_epoch),422,'action_kind_unsupported');taskActionHash(value.expected_plan_hash);
 validateDeviceCalendarTarget(value.target);validateCalendarCreateParameters(value.parameters);validateTaskActionArtifactReference(value.artifact_reference);
 check(Buffer.byteLength(JSON.stringify(value))<=TASK_ACTION_LIMITS.payload_bytes,413,'action_request_too_large');return clone(value);
}
export function validateTaskActionDecision(value){
 shape(value,['operation_id','decision','expected_revision','action_digest','expected_grant_epoch']);
 taskActionUUID(value.operation_id);taskActionHash(value.action_digest);
 check(['approve','deny'].includes(value.decision)&&integer(value.expected_revision)&&integer(value.expected_grant_epoch),422,'action_schema_invalid');return clone(value);
}
export const taskActionParametersHash=parameters=>hash(validateCalendarCreateParameters(parameters));
