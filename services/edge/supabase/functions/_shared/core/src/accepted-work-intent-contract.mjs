import {Buffer} from 'node:buffer';
import {check,shape,UUID,hash,clone} from '../facade-r2/src/common.mjs';
import {TASK_WORK_GRANT_LIMITS as L,workGrantInstant} from './task-work-grant-contract.mjs';
import {parseStrictObjectJSON} from './strict-json.mjs';

export const ACCEPTED_WORK_INTENT_CONTRACT='catpaw.accepted-work-intent.v1';
export const ACCEPTED_WORK_INTENT_BYTES=42000;
const uuid=v=>typeof v==='string'&&UUID.test(v)&&v===v.toLowerCase();
const digest=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const integer=(v,min,max)=>Number.isSafeInteger(v)&&v>=min&&v<=max;
const exact=(v,keys)=>{try{shape(v,keys);}catch{check(false,422,'work_intent_schema_invalid');}};

/** All limits are user-selected explicit values, never inferred from prose/model
 * output, a render state, installation, readiness or existing model consent. */
export function validateAcceptedWorkIntent(input){
 exact(input,['decision_id','input_hash','route_hash','tool_policy','not_after','execution_budget_ms','limits']);exact(input.limits,['due','model','source']);
 check(uuid(input.decision_id)&&digest(input.input_hash)&&digest(input.route_hash)&&['local_output_v1','public_sources_v1'].includes(input.tool_policy)&&workGrantInstant(input.not_after)&&integer(input.execution_budget_ms,1,L.execution_budget_ms)&&input.limits.due===1&&integer(input.limits.model,0,L.model)&&integer(input.limits.source,0,L.source)&&(input.tool_policy!=='local_output_v1'||input.limits.source===0),422,'work_intent_schema_invalid');
 return clone(input);
}
export function validateAcceptedWorkRequest(input){
 exact(input,['schema_version','contract','turn','work']);check(input.schema_version===1&&input.contract===ACCEPTED_WORK_INTENT_CONTRACT,422,'work_intent_schema_invalid');
 const work=validateAcceptedWorkIntent(input.work);check(input.turn&&Object.getPrototypeOf(input.turn)===Object.prototype&&work.input_hash===hash(input.turn),409,'work_intent_input_conflict');
 check(Buffer.byteLength(JSON.stringify(input))<=ACCEPTED_WORK_INTENT_BYTES,413,'work_intent_request_too_large');return {...clone(input),work};
}
export function parseAcceptedWorkJSON(raw){return parseStrictObjectJSON(raw,{maxBytes:ACCEPTED_WORK_INTENT_BYTES,schemaCode:'work_intent_schema_invalid',duplicateCode:'work_intent_duplicate_key',sizeCode:'work_intent_request_too_large'});}
export function freezeAcceptedWorkIntent(input,{turn,scope,principal,conversation,routeHash,now}){
 const work=validateAcceptedWorkIntent(input);
 check(work.input_hash===hash(turn.input)&&work.route_hash===routeHash,409,'work_intent_input_or_route_conflict');
 check(Number.isSafeInteger(now)&&Date.parse(work.not_after)>now&&Date.parse(work.not_after)-now<=L.lifetime_ms&&work.execution_budget_ms<=Date.parse(work.not_after)-now,409,'work_intent_expired');
 check(uuid(principal.subject_id)&&scope.scope_id===conversation.scope_id&&conversation.subject_id===principal.subject_id,403,'work_intent_subject_conflict');
 return {schema_version:1,contract:ACCEPTED_WORK_INTENT_CONTRACT,...work,subject_id:principal.subject_id,scope_id:scope.scope_id,conversation_id:conversation.id,conversation_epoch:conversation.grant_epoch,turn_id:turn.id,message_id:turn.input.message.id,admitted_at:new Date(now).toISOString()};
}
export function validateFrozenAcceptedWorkIntent(input,{turn,scope,conversation,routeHash,callName}){
 exact(input,['schema_version','contract','decision_id','input_hash','route_hash','tool_policy','not_after','execution_budget_ms','limits','subject_id','scope_id','conversation_id','conversation_epoch','turn_id','message_id','admitted_at']);
 const {schema_version,contract,subject_id,scope_id,conversation_id,conversation_epoch,turn_id,message_id,admitted_at,...fields}=input;
 const work=validateAcceptedWorkIntent(fields),allowed=work.tool_policy==='public_sources_v1'?['delegate_sources_v1']:['delegate_task','delegate_plan_v1'];
 check(schema_version===1&&contract===ACCEPTED_WORK_INTENT_CONTRACT&&subject_id===conversation.subject_id&&scope_id===scope.scope_id&&conversation_id===conversation.id&&conversation_epoch===conversation.grant_epoch&&turn_id===turn.id&&message_id===turn.input.message.id&&work.input_hash===hash(turn.input)&&work.route_hash===routeHash&&workGrantInstant(admitted_at)&&Date.parse(work.not_after)>Date.parse(admitted_at)&&Date.parse(work.not_after)-Date.parse(admitted_at)<=L.lifetime_ms&&work.execution_budget_ms<=Date.parse(work.not_after)-Date.parse(admitted_at),409,'work_intent_binding_conflict');
 check(allowed.includes(callName),403,'work_intent_tool_policy_conflict');return clone(input);
}

/** A new admission must still fit the user's original absolute window. This is
 * separate from immutable binding checks so prior receipt replay cannot renew
 * or be confused with accepting a new run. */
export function assertAcceptedWorkNewRunWindow(intent,now){
 check(Number.isSafeInteger(now)&&now>=Date.parse(intent.admitted_at)&&Date.parse(intent.not_after)>now&&intent.execution_budget_ms<=Date.parse(intent.not_after)-now,409,'work_intent_expired');
}
