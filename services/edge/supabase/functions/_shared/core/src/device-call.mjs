// catpaw.device.v1 — device tools executed on the user's iPhone (Wave 2 §3).
// The server never executes these: a call suspends the turn as an approval.v1 interrupt of kind 'device',
// streams `device_call`, and resumes when the app posts …/turns/{t}/device-result (idempotent per operation_id,
// bound to args_hash, expires after ttl_sec → the model is told the device did not answer).
import {check} from '../facade-r2/src/common.mjs';
export const DEVICE_CONTRACT='catpaw.device.v1';
export const DEVICE_HEADER='X-Catpaw-Device-Contract';
/** NoBug P0-4: comma list of tools the phone actually executes; absent = legacy client (all offered). */
export const DEVICE_TOOLS_HEADER='X-Catpaw-Device-Tools';
export const DEVICE_TTL_SEC=600;
export const DEVICE_RESULT_STATUSES=Object.freeze(['ok','cancelled','denied','error']);
export const DEVICE_RESULT_MAX_BYTES=32768;
const S={type:'string'},SA={type:'array',items:{type:'string'},maxItems:20},N={type:'number'};
const fn=(name,description,properties,required,confirm)=>({confirm,definition:{type:'function',function:{name,description:description+(confirm==='none'?' Read-only; runs without a confirmation card.':' The user confirms on the phone before anything happens.'),parameters:{type:'object',properties,required,additionalProperties:false}}}});
// Plan §3.2. pay_apple (needs merchant entitlement, phase 2) and App Intents (reverse direction) are not cloud tools.
export const DEVICE_TOOLS=Object.freeze([
 fn('calendar_list','List calendar events in a time range on the user\'s phone (free/busy lookup).',{from:S,to:S},['from','to'],'none'),
 fn('calendar_create','Create a calendar event on the user\'s phone.',{title:S,start:S,end:S,location:S,notes:S,alarms:{type:'array',items:N,maxItems:5}},['title','start','end'],'card'),
 fn('reminder_create','Create a reminder in Apple Reminders.',{title:S,due:S,list:S,priority:{type:'integer',minimum:0,maximum:9}},['title'],'card'),
 fn('mail_compose','Open a prefilled email for the user to send (never sent silently).',{to:SA,cc:SA,subject:S,body:S},['to','subject','body'],'card'),
 fn('sms_compose','Open a prefilled SMS for the user to send (never sent silently).',{to:SA,body:S},['to','body'],'card'),
 fn('phone_call','Start a phone call (the system asks again).',{number:S,name:S},['number'],'card'),
 fn('contacts_search','Search the user\'s contacts.',{query:S},['query'],'none'),
 fn('maps_open','Open a place or route in Maps.',{query:S,lat:N,lng:N,mode:{type:'string',enum:['driving','walking','transit']}},[],'card'),
 fn('shop_open','Open a shopping app search or link (never places orders).',{platform:{type:'string',enum:['taobao','jd','meituan','pdd']},query:S,url:S},['platform'],'card'),
 fn('alarm_set','Set an alarm.',{time:S,label:S},['time'],'card'),
 fn('shortcut_run','Run a Shortcuts shortcut by name.',{name:S,input:S},['name'],'card'),
]);
export const DEVICE_TOOL_NAMES=Object.freeze(DEVICE_TOOLS.map(t=>t.definition.function.name));
/** Parses X-Catpaw-Device-Tools into known tool names (unknown dropped); null when the header is absent. */
export function parseDeviceTools(raw){if(raw===null||raw===undefined)return null;return [...new Set(String(raw).split(',').map(x=>x.trim()).filter(x=>DEVICE_TOOL_NAMES.includes(x)))];}
const typeOK=(v,s)=>s.type==='string'?typeof v==='string'&&v.length<=4000&&(!s.enum||s.enum.includes(v)):s.type==='number'?Number.isFinite(v):s.type==='integer'?Number.isInteger(v)&&v>=s.minimum&&v<=s.maximum:s.type==='array'?Array.isArray(v)&&v.length<=s.maxItems&&v.every(x=>typeOK(x,s.items)):false;
export function validateDeviceArgs(tool,args){
 const p=tool.definition.function.parameters;
 check(args&&typeof args==='object'&&!Array.isArray(args)&&Object.keys(args).every(k=>Object.hasOwn(p.properties,k)&&typeOK(args[k],p.properties[k]))&&p.required.every(k=>args[k]!==undefined),422,'invalid_tool_arguments');
 const name=tool.definition.function.name;
 if(name==='maps_open')check(typeof args.query==='string'||(Number.isFinite(args.lat)&&Number.isFinite(args.lng)),422,'invalid_tool_arguments');
 if(name==='shop_open')check(typeof args.query==='string'||typeof args.url==='string',422,'invalid_tool_arguments');
 for(const k of ['from','to','start','end','due','time'])if(typeof args[k]==='string')check(Number.isFinite(Date.parse(args[k]))||/^\d{1,2}:\d{2}$/.test(args[k]),422,'invalid_tool_arguments');
}
/** Gated-registry entries (facade.gatedChatTools). Offered only when the client negotiated device.v1 + approval.v1 and allow(turn). */
export function createDeviceTools({allow=()=>true}={}){
 return new Map(DEVICE_TOOLS.map(tool=>[tool.definition.function.name,{definition:tool.definition,contractOnly:true,device:true,confirm:tool.confirm,
  offer:turn=>turn?.device_contract===DEVICE_CONTRACT&&!!turn?.approval_contract&&(!Array.isArray(turn?.device_tools)||turn.device_tools.includes(tool.definition.function.name))&&allow(turn),
  validate:a=>validateDeviceArgs(tool,a),summarize:a=>`${tool.definition.function.name}: `+String(a.title??a.subject??a.query??a.name??a.number??a.time??'').slice(0,200),
  execute:async()=>{check(false,409,'device_call_not_reported');}}]));
}
/** Body of POST …/turns/{t}/device-result. */
export function validateDeviceResult(input){
 check(input&&typeof input==='object'&&!Array.isArray(input),422,'device_result_schema_invalid');
 const keys=Object.keys(input);check(['call_id','operation_id','args_hash','status'].every(k=>keys.includes(k))&&keys.every(k=>['call_id','operation_id','args_hash','status','data'].includes(k)),422,'device_result_schema_invalid');
 check(typeof input.call_id==='string'&&input.call_id.length>0&&input.call_id.length<=160&&DEVICE_RESULT_STATUSES.includes(input.status),422,'device_result_schema_invalid');
 check(input.data===undefined||input.data===null||typeof input.data==='object',422,'device_result_schema_invalid');
 return input;
}
export const deviceCallEvent=(it,args)=>({call_id:it.call_id,tool:it.tool,args,confirm:it.confirm,ttl_sec:it.ttl_sec,interrupt_id:it.interrupt_id,args_hash:it.args_hash,expires_at:it.expires_at});
/** Model-facing result of a device call. */
export function deviceResult(it){
 if(it.status==='expired')return {status:'pending_timeout',message:'The phone did not report back in time; the action\'s status is unknown (it may already have happened on the phone). Ask the user to verify on the phone before retrying; do not retry automatically.'};
 if(it.status==='cancelled')return {status:'cancelled',message:'The turn was cancelled before the phone reported back.'};
 return {status:it.response.status,...it.response.data!==undefined&&it.response.data!==null?{data:it.response.data}:{}};
}
