// catpaw.ui.v1 — generative UI / HITL blocks (r10 spec §4.1 + PR #35 Codable draft).
// render_ui({block}) → SSE `ui.block` (+ `ui.block.update` shallow patch by id, `ui.block.resolve`).
// Interactive blocks suspend the SAME turn as a catpaw.approval.v1 interrupt (kind:'ui'); the client answers with
// a `ui.response` (or `ui.error`) through …/interrupts/{i}/decision and the model receives it as the tool result.
import { ApiError,clone } from '../facade-r2/src/common.mjs';
export const UI_CONTRACT='catpaw.ui.v1';
export const UI_HEADER='X-Catpaw-UI-Contract';
export const RENDER_UI='render_ui';
export const UI_SCHEMA_VERSION=1;
export const UI_KINDS=Object.freeze(['card','choices','confirm','form','sheet','list','progress']);
export const UI_DECISIONS=Object.freeze(['submit','dismiss','report_error']);
export const FIELD_TYPES=Object.freeze(['text','multiline','number','date','time','datetime','toggle','select','stepper']);
export const UI_ERROR_CODES=Object.freeze(['schema_invalid','payload_too_large','schema_version_unsupported','too_long','too_many','duplicate_id','items_missing','fields_missing','steps_missing','options_missing','image_not_https','id_missing']);
const LIMITS=Object.freeze({title:60,body:600,items:8,itemLabel:40,detail:120,fields:8,fieldLabel:40,options:20,option:40,actions:3,actionLabel:16,steps:12,stepLabel:60,id:64,payload:32*1024});
const str=(v,max,min=1)=>typeof v==='string'&&v.trim().length>=min&&v.length<=max;
const isID=v=>str(v,LIMITS.id);
const bad=detail=>{throw new ApiError(422,'invalid_tool_arguments',detail);};
const only=(o,allowed,required=[])=>{if(!o||typeof o!=='object'||Array.isArray(o))bad('object');for(const k of Object.keys(o))if(!allowed.includes(k))bad('unknown:'+k);for(const k of required)if(!(k in o))bad('missing:'+k);};
const opt=(o,k,f)=>{if(k in o&&!f(o[k]))bad('invalid:'+k);};
const unique=list=>new Set(list.map(x=>x.id)).size===list.length;
const ISO=v=>typeof v==='string'&&v.length<=40&&!Number.isNaN(Date.parse(v));
const item={type:'object',required:['id','label'],additionalProperties:false,properties:{id:{type:'string',maxLength:64},label:{type:'string',maxLength:40},detail:{type:'string',maxLength:120},icon:{type:'string',description:'SF Symbol'}}};
const block={type:'object',required:['id','kind'],additionalProperties:false,properties:{
  schemaVersion:{type:'integer',enum:[1]},id:{type:'string',maxLength:64,description:'stable id; reuse it to update a progress/card block'},
  kind:{enum:[...UI_KINDS]},title:{type:'string',maxLength:60},body:{type:'string',description:'markdown, ≤ 600 chars'},
  presentation:{enum:['inline','sheet'],default:'inline'},image:{type:'string',format:'uri',description:'https only'},
  items:{type:'array',maxItems:8,items:item},selection:{enum:['single','multiple','none']},allowOther:{type:'boolean',description:'adds free-text 其他'},
  fields:{type:'array',maxItems:8,items:{type:'object',required:['id','type','label'],additionalProperties:false,properties:{id:{type:'string',maxLength:64},
    type:{enum:[...FIELD_TYPES]},label:{type:'string',maxLength:40},placeholder:{type:'string',maxLength:80},required:{type:'boolean'},
    options:{type:'array',maxItems:20,items:{type:'string',maxLength:40}},default:{}}}},
  actions:{type:'array',maxItems:3,items:{type:'object',required:['id','label'],additionalProperties:false,properties:{id:{type:'string',maxLength:64},label:{type:'string',maxLength:16},style:{enum:['primary','secondary','destructive']}}}},
  steps:{type:'array',maxItems:12,items:{type:'object',required:['id','label','state'],additionalProperties:false,properties:{id:{type:'string',maxLength:64},label:{type:'string',maxLength:60},state:{enum:['pending','running','done','failed']}}},description:'progress only'},
  content:{enum:['card','choices','confirm','form','list'],description:'sheet only: the kind shown inside the sheet'},
  expiresAt:{type:'string',format:'date-time'}}};
export const renderUISchema={type:'object',required:['block'],additionalProperties:false,properties:{block}};
export const renderUITool={type:'function',function:{name:RENDER_UI,description:'Render a native UI block in the chat instead of writing code or long text. Use for choices, confirmations, forms, cards, lists, progress and sheets (popups). Interactive blocks wait for the user; the tool result is then the user\'s ui.response ({status:"submitted",response}) or {status:"dismissed"|"expired"|"cancelled"|"error"}. Display-only blocks return {status:"shown"}. Reuse the same block id to update a progress or card block.',parameters:renderUISchema}};
export const uiPrompt='\n需要用户选择、确认、填写或查看结构化结果时调用 render_ui；不要输出 HTML/SwiftUI/JSON 代码来表示界面，除非用户明确要代码。When the user asks for a popup/dialog use kind "sheet". One interactive block per reply; continue from the tool result.';
const sheetContent=b=>b.content??(b.fields?.length?'form':b.items?.length?'choices':'card');
/** true when the block waits for a user answer (suspends the turn). */
export function requiresResponse(b){
  const kind=b.kind==='sheet'?sheetContent(b):b.kind;
  if(['choices','confirm','form'].includes(kind))return !(kind==='choices'&&b.selection==='none'&&!b.actions?.length);
  if(kind==='progress')return false;
  return (b.actions?.length??0)>0; // card / list with actions
}
/** Validates render_ui arguments ({block} or a bare block) and returns the normalized block. */
export function validateBlock(args){
  const b=args&&typeof args==='object'&&'block' in args&&Object.keys(args).length===1?args.block:args;
  if(JSON.stringify(b??null).length>LIMITS.payload)bad('payload_too_large');
  only(b,Object.keys(block.properties),['id','kind']);
  if(!isID(b.id))bad('id_missing');if(!UI_KINDS.includes(b.kind))bad('kind');
  opt(b,'schemaVersion',v=>v===UI_SCHEMA_VERSION);opt(b,'title',v=>str(v,LIMITS.title));opt(b,'body',v=>typeof v==='string'&&v.length<=LIMITS.body);
  opt(b,'presentation',v=>['inline','sheet'].includes(v));opt(b,'image',v=>typeof v==='string'&&v.length<=2048&&/^https:\/\/[^\s]+$/.test(v));
  opt(b,'selection',v=>['single','multiple','none'].includes(v));opt(b,'allowOther',v=>typeof v==='boolean');opt(b,'expiresAt',ISO);
  opt(b,'content',v=>['card','choices','confirm','form','list'].includes(v));if(b.kind!=='sheet'&&'content' in b)bad('content');
  if('items' in b){if(!Array.isArray(b.items)||b.items.length>LIMITS.items)bad('too_many');for(const i of b.items){only(i,['id','label','detail','icon'],['id','label']);if(!isID(i.id)||!str(i.label,LIMITS.itemLabel))bad('item');opt(i,'detail',v=>typeof v==='string'&&v.length<=LIMITS.detail);opt(i,'icon',v=>str(v,60));}if(!unique(b.items))bad('duplicate_id');}
  if('fields' in b){if(!Array.isArray(b.fields)||b.fields.length>LIMITS.fields)bad('too_many');for(const f of b.fields){only(f,['id','type','label','placeholder','required','options','default'],['id','type','label']);
    if(!isID(f.id)||!FIELD_TYPES.includes(f.type)||!str(f.label,LIMITS.fieldLabel))bad('field');opt(f,'placeholder',v=>typeof v==='string'&&v.length<=80);opt(f,'required',v=>typeof v==='boolean');
    if(f.type==='select'){if(!Array.isArray(f.options)||!f.options.length||f.options.length>LIMITS.options||!f.options.every(o=>str(o,LIMITS.option))||new Set(f.options).size!==f.options.length)bad('options_missing');}else if('options' in f)bad('options');
    if('default' in f&&!fieldValueOK(f,f.default))bad('default');}if(!unique(b.fields))bad('duplicate_id');}
  if('actions' in b){if(!Array.isArray(b.actions)||b.actions.length>LIMITS.actions)bad('too_many');for(const a of b.actions){only(a,['id','label','style'],['id','label']);if(!isID(a.id)||!str(a.label,LIMITS.actionLabel))bad('action');opt(a,'style',v=>['primary','secondary','destructive'].includes(v));}if(!unique(b.actions))bad('duplicate_id');}
  if('steps' in b){if(b.kind!=='progress'||!Array.isArray(b.steps)||b.steps.length>LIMITS.steps)bad('steps');for(const s of b.steps){only(s,['id','label','state'],['id','label','state']);if(!isID(s.id)||!str(s.label,LIMITS.stepLabel)||!['pending','running','done','failed'].includes(s.state))bad('step');}if(!unique(b.steps))bad('duplicate_id');}
  const kind=b.kind==='sheet'?sheetContent(b):b.kind;
  if(kind==='choices'&&!b.items?.length)bad('items_missing');if(kind==='form'&&!b.fields?.length)bad('fields_missing');if(b.kind==='progress'&&!b.steps?.length)bad('steps_missing');
  if(kind==='list'&&!b.items?.length)bad('items_missing');
  return clone({schemaVersion:UI_SCHEMA_VERSION,...b});
}
function fieldValueOK(f,x){
  switch(f.type){
    case 'text':return typeof x==='string'&&x.length<=200;case 'multiline':return typeof x==='string'&&x.length<=2000;
    case 'number':return typeof x==='number'&&Number.isFinite(x);case 'stepper':return Number.isInteger(x)&&Math.abs(x)<=1e6;
    case 'date':return typeof x==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(x)&&!Number.isNaN(Date.parse(x+'T00:00:00Z'));
    case 'time':return typeof x==='string'&&/^([01]\d|2[0-3]):[0-5]\d$/.test(x);
    case 'datetime':return ISO(x)&&/T/.test(x);case 'toggle':return typeof x==='boolean';case 'select':return f.options.includes(x);
    default:return false;
  }
}
const rbad=()=>{throw new ApiError(422,'ui_response_invalid');};
/** Validates a client `ui.response` against its block (exact keys; `other` only with allowOther). */
export function validateResponse(b,r){
  if(!r||typeof r!=='object'||Array.isArray(r))rbad();
  for(const k of Object.keys(r))if(!['type','blockId','actionId','values','selected','other','respondedAt'].includes(k))rbad();
  if(r.type!=='ui.response'||r.blockId!==b.id||!ISO(r.respondedAt))rbad();
  const kind=b.kind==='sheet'?sheetContent(b):b.kind;
  if(r.actionId!==undefined&&r.actionId!==null){if(kind==='confirm'?!['approve','deny',...(b.actions??[]).map(a=>a.id)].includes(r.actionId):!(b.actions??[]).some(a=>a.id===r.actionId))rbad();}
  const values=r.values??{};if(!values||typeof values!=='object'||Array.isArray(values))rbad();
  const fields=b.fields??[];
  for(const k of Object.keys(values))if(!fields.some(f=>f.id===k)&&!(k==='other'&&b.allowOther))rbad();
  for(const f of fields){const x=values[f.id];if(x===undefined||x===null||x===''){if(f.required&&kind==='form')rbad();continue;}if(!fieldValueOK(f,x))rbad();}
  const selected=r.selected??[];if(!Array.isArray(selected)||new Set(selected).size!==selected.length||!selected.every(id=>(b.items??[]).some(i=>i.id===id)))rbad();
  if(kind==='choices'){const sel=b.selection??'single',n=selected.length+(r.other?1:0);if(sel==='single'&&n!==1&&!r.actionId)rbad();if(sel==='multiple'&&n<1&&!r.actionId)rbad();}
  if('other' in r){if(!b.allowOther||typeof r.other!=='string'||!str(r.other,200))rbad();if('other' in values&&values.other!==r.other)rbad();}
  if(kind==='confirm'&&!r.actionId)rbad();
  if(['card','list'].includes(kind)&&!r.actionId&&!selected.length)rbad();
  return clone(r);
}
/** Client-reported invalid block (`ui.error`). */
export function validateUIError(b,e){
  if(!e||typeof e!=='object'||Array.isArray(e))rbad();for(const k of Object.keys(e))if(!['type','blockId','code','path'].includes(k))rbad();
  if(e.type!=='ui.error'||!UI_ERROR_CODES.includes(e.code)||('blockId' in e&&e.blockId!==b.id)||('path' in e&&!str(e.path,200)))rbad();
  return clone(e);
}
/** Model-facing tool result. */
export function uiResult(it){
  if(!it)return {status:'shown'};
  if(it.status==='submitted')return {status:'submitted',response:clone(it.response)};
  if(it.status==='errored')return {status:'error',error:clone(it.response),hint:'The client could not render this block; fix it per the error code and call render_ui again.'};
  return {status:it.status==='dismissed'?'dismissed':it.status==='expired'?'expired':'cancelled'};
}
const pick=(b,keys)=>Object.fromEntries(keys.filter(k=>k in b).map(k=>[k,clone(b[k])]));
/** `ui.block` data: the block itself plus server linkage for interactive blocks. */
export const uiBlockEvent=(b,it=null)=>({...clone(b),...it?{interruptId:it.interrupt_id,argsHash:it.args_hash,expiresAt:b.expiresAt&&Date.parse(b.expiresAt)<Date.parse(it.expires_at)?b.expiresAt:it.expires_at}:{}});
/** `ui.block.update` data: shallow patch by id (only fields the PR #35 draft allows to change). */
export const uiBlockUpdate=b=>({id:b.id,...pick(b,['title','body','items','actions','steps','expiresAt'])});
export const uiBlockResolve=(id,status)=>({id,status});
/** Gated-registry entry (facade.gatedChatTools). Offered only when both contracts were negotiated and allow(turn). */
export function createRenderUITool({allow=()=>true}={}){
  return {definition:renderUITool,contractOnly:true,offer:turn=>turn?.ui_contract===UI_CONTRACT&&!!turn?.approval_contract&&allow(turn),
    validate:a=>{validateBlock(a);},summarize:a=>String((a?.block??a)?.title??'').slice(0,240),execute:async()=>({status:'shown'})};
}
export const blockOf=args=>validateBlock(args);
