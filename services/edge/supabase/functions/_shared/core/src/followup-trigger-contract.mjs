import {check,shape,UUID,hash,clone} from '../facade-r2/src/common.mjs';

export const FOLLOWUP_TRIGGER_CONTRACT='catpaw.followup-trigger.v1';
export const FOLLOWUP_DUE_CONTRACT='catpaw.followup-due.v1';
export const FOLLOWUP_TRIGGER_KINDS=Object.freeze({triggers:'catpaw-followup-triggers',operations:'catpaw-followup-operations',dues:'catpaw-followup-dues'});
export const FOLLOWUP_TRIGGER_LIMITS=Object.freeze({payload_bytes:12000,lifetime_ms:31*86400000,interval_seconds:604800,occurrences:1000,execution_ms:300000,total_execution_ms:86400000,model_calls:2000,source_reads:2000,materialize:20,write_ms:15000});
export const FOLLOWUP_TRIGGER_PURPOSES=Object.freeze(['create','read','read_operation','list','pause','resume','revoke','materialize']);
const fail=()=>check(false,422,'followup_schema_invalid');
const exact=(v,keys)=>{try{shape(v,keys);}catch{fail();}};
export const followupUUID=v=>typeof v==='string'&&UUID.test(v)&&v===v.toLowerCase();
export const followupHash=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
export const followupInstant=v=>typeof v==='string'&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString()===v;
const integer=(v,min,max=Number.MAX_SAFE_INTEGER)=>Number.isSafeInteger(v)&&v>=min&&v<=max;
export function validateFollowupIdentity(v){exact(v,['owner','scope_id','subject_id']);check(typeof v.owner==='string'&&/^catpaw:[a-f0-9]{64}$/.test(v.owner)&&followupUUID(v.scope_id)&&followupUUID(v.subject_id),422,'followup_schema_invalid');return clone(v);}
export function validateFollowupOrigin(v){exact(v,['conversation_id','run_id','task_id','request_hash']);check(followupUUID(v.conversation_id)&&followupUUID(v.run_id)&&followupHash(v.task_id)&&followupHash(v.request_hash),422,'followup_schema_invalid');return clone(v);}
export function validateFollowupTimeZone(v){
 check(typeof v==='string'&&v.length<=100&&(v==='UTC'||/^[A-Za-z_]+(?:\/[A-Za-z0-9_+.-]+)+$/.test(v)),422,'followup_time_zone_invalid');
 try{new Intl.DateTimeFormat('en-US',{timeZone:v}).format(0);}catch{check(false,422,'followup_time_zone_invalid');}return v;
}
export function validateFollowupConfiguration(v){
 exact(v,['title','origin','schedule','end','budget','quiet_hours']);validateFollowupOrigin(v.origin);
 exact(v.schedule,['kind','time_zone','first_due_at','interval_seconds']);exact(v.end,['not_after','max_occurrences']);exact(v.budget,['per_due_execution_ms','total_execution_ms','model_calls','source_reads']);
 const s=v.schedule,e=v.end,b=v.budget;validateFollowupTimeZone(s.time_zone);
 check(typeof v.title==='string'&&v.title.trim().length>0&&new TextEncoder().encode(v.title).length<=512&&!/[\u0000-\u001f\u007f-\u009f]/.test(v.title)&&s.kind==='fixed_interval'&&followupInstant(s.first_due_at)&&integer(s.interval_seconds,60,FOLLOWUP_TRIGGER_LIMITS.interval_seconds)&&followupInstant(e.not_after)&&Date.parse(e.not_after)>Date.parse(s.first_due_at)&&Date.parse(e.not_after)-Date.parse(s.first_due_at)<=FOLLOWUP_TRIGGER_LIMITS.lifetime_ms&&integer(e.max_occurrences,1,FOLLOWUP_TRIGGER_LIMITS.occurrences)&&integer(b.per_due_execution_ms,1,FOLLOWUP_TRIGGER_LIMITS.execution_ms)&&integer(b.total_execution_ms,b.per_due_execution_ms,FOLLOWUP_TRIGGER_LIMITS.total_execution_ms)&&integer(b.model_calls,0,FOLLOWUP_TRIGGER_LIMITS.model_calls)&&integer(b.source_reads,0,FOLLOWUP_TRIGGER_LIMITS.source_reads),422,'followup_schema_invalid');
 if(v.quiet_hours!==null){exact(v.quiet_hours,['start_minute','end_minute']);check(integer(v.quiet_hours.start_minute,0,1439)&&integer(v.quiet_hours.end_minute,0,1439)&&v.quiet_hours.start_minute!==v.quiet_hours.end_minute,422,'followup_schema_invalid');}
 check(new TextEncoder().encode(JSON.stringify(v)).length<=FOLLOWUP_TRIGGER_LIMITS.payload_bytes,413,'followup_request_too_large');return clone(v);
}
export function validateFollowupCreate(v){
 exact(v,['schema_version','contract','operation_id','trigger_id','configuration']);check(v.schema_version===1&&v.contract===FOLLOWUP_TRIGGER_CONTRACT&&followupUUID(v.operation_id)&&followupUUID(v.trigger_id)&&v.operation_id!==v.trigger_id,422,'followup_schema_invalid');validateFollowupConfiguration(v.configuration);return clone(v);
}
export function validateFollowupCommand(v){exact(v,['schema_version','contract','operation_id','action','expected_revision']);check(v.schema_version===1&&v.contract===FOLLOWUP_TRIGGER_CONTRACT&&followupUUID(v.operation_id)&&['pause','resume','revoke'].includes(v.action)&&integer(v.expected_revision,1),422,'followup_schema_invalid');return clone(v);}
export function followupDueID(triggerID,scheduleRevision,scheduledAt){check(followupUUID(triggerID)&&integer(scheduleRevision,1)&&followupInstant(scheduledAt),422,'followup_schema_invalid');return hash({trigger_id:triggerID,schedule_revision:scheduleRevision,scheduled_at:scheduledAt});}
/** Fixed UTC intervals retain an IANA display/quiet policy. They are deliberately
 * not daily wall-clock recurrences: a DST transition cannot duplicate a due. */
export function followupQuietAt(instant,timeZone,quietHours){
 check(followupInstant(instant),422,'followup_schema_invalid');validateFollowupTimeZone(timeZone);if(quietHours===null)return false;
 exact(quietHours,['start_minute','end_minute']);check(integer(quietHours.start_minute,0,1439)&&integer(quietHours.end_minute,0,1439)&&quietHours.start_minute!==quietHours.end_minute,422,'followup_schema_invalid');
 const parts=new Intl.DateTimeFormat('en-US',{timeZone,hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(instant)),minute=Number(parts.find(p=>p.type==='hour').value)*60+Number(parts.find(p=>p.type==='minute').value),{start_minute:start,end_minute:end}=quietHours;
 return start<end?minute>=start&&minute<end:minute>=start||minute<end;
}
export function followupReceiptHash(receipt){const {receipt_hash,...fields}=receipt;return hash(fields);}
