// catpaw.ui.v1 grounded kinds (`place`, `event`): content comes ONLY from a tool_result of the same turn.
// The model names a source ({callId, ids?}); the server rebuilds places/events from that result, dropping anything the
// model wrote. No matching result → the block is not shown and the model gets {status:'error',error:{code}}.
// Contract fixtures (mirrored by the iOS portable runner): services/edge/docs/fixtures/catpaw-ui-grounded.json
import {GROUNDED_KINDS,validateBlock} from './generative-ui.mjs';
const MODES=['driving','walking','transit'];
const num=v=>typeof v==='number'&&Number.isFinite(v)?v:undefined;
const text=(v,max)=>typeof v==='string'&&v.trim()?v.slice(0,max):undefined;
const defined=o=>Object.fromEntries(Object.entries(o).filter(([,v])=>v!==undefined));
const parseJSON=s=>{try{return typeof s==='string'?JSON.parse(s):s;}catch{return null;}};
/** callId → {name, args, result} from the OpenAI-style message list (assistant tool_calls + role:'tool'). */
export function toolResultsFrom(messages){
  const calls=new Map();
  for(const m of messages??[]){
    if(m?.role==='assistant'&&Array.isArray(m.tool_calls))for(const c of m.tool_calls)calls.set(c.id,{name:c.function?.name,args:parseJSON(c.function?.arguments)??{}});
    if(m?.role==='tool'&&calls.has(m.tool_call_id))calls.get(m.tool_call_id).result=parseJSON(m.content);
  }
  return calls;
}
const coordsFromMapsURL=u=>{const m=/daddr=(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/.exec(u??'');return m?{lat:Number(m[1]),lng:Number(m[2])}:{};};
const safeURL=(u,re)=>typeof u==='string'&&u.length<=2048&&re.test(u)?u:undefined;
/** places_search data.places row → place (ids p1… when the client sent none). */
export function placeFromRow(row,i,mode){
  const name=text(row?.name,80);if(!name)return null;
  const c=coordsFromMapsURL(row.maps_url),maps=safeURL(row.maps_url,/^(maps:\/\/|https:\/\/maps\.apple\.com\/)/),tel=safeURL(row.tel_url,/^tel:\+?\d{3,}$/);
  const actions=[...maps?[{id:'navigate',label:'导航',url:maps}]:[],...tel?[{id:'call',label:'打电话',url:tel}]:[]];
  return defined({id:text(row.id,64)??`p${i+1}`,name,address:text(row.address,200),lat:num(row.lat)??c.lat,lng:num(row.lng)??c.lng,
    distanceM:num(row.distance_m),etaMin:num(row.eta_min),mode:MODES.includes(mode)?mode:undefined,phone:text(row.phone,40),actions});
}
const REF=978307200; // calshow: takes seconds since 2001-01-01
const calshow=iso=>{const t=Date.parse(iso);return Number.isFinite(t)?`calshow:${Math.round(t/1000-REF)}`:undefined;};
export function eventFromRow(row,i){
  const start=typeof row?.start==='string'&&Number.isFinite(Date.parse(row.start))?row.start:null;if(!start)return null;
  const open=calshow(start);
  return defined({id:text(row.id,64)??`e${i+1}`,title:typeof row.title==='string'?row.title.slice(0,120):'',start,
    end:typeof row.end==='string'&&Number.isFinite(Date.parse(row.end))?row.end:undefined,allDay:typeof row.all_day==='boolean'?row.all_day:undefined,
    location:text(row.location,200),actions:open?[{id:'open',label:'打开日历',url:open}]:[]});
}
/** Rows a source tool call can supply, or an error code. */
function rowsFor(kind,src){
  if(!src)return {error:'source_not_found'};
  const r=src.result;if(!r||r.status!=='ok'||!r.data)return {error:'source_not_ok'};
  if(kind==='place'){if(src.name!=='places_search')return {error:'source_wrong_tool'};
    const rows=(Array.isArray(r.data.places)?r.data.places:[]).map((x,i)=>placeFromRow(x,i,r.data.mode)).filter(Boolean);return {rows,caption:text(r.data.why,200)};}
  if(src.name==='calendar_list')return {rows:(Array.isArray(r.data.events)?r.data.events:[]).map(eventFromRow).filter(Boolean)};
  if(src.name==='calendar_create'){const e=eventFromRow({...src.args,id:'e1'},0);return {rows:e?[e]:[]};}
  return {error:'source_wrong_tool'};
}
/**
 * Grounds render_ui arguments. Returns {} for non-grounded kinds, {block} for a grounded block (content rebuilt from the
 * tool result) or {error:code}. `uiKinds` = client-advertised kinds (X-Catpaw-UI-Kinds); null → grounded kinds unsupported.
 */
export function groundUIArgs(args,results,uiKinds){
  const b=args&&typeof args==='object'&&'block' in args&&Object.keys(args).length===1?args.block:args;
  if(!b||!GROUNDED_KINDS.includes(b.kind))return {};
  if(!Array.isArray(uiKinds)||!uiKinds.includes(b.kind))return {error:'kind_unsupported_by_client'};
  const got=rowsFor(b.kind,results.get(b.source?.callId));if(got.error)return got;
  let rows=got.rows;
  if(Array.isArray(b.source.ids)){const byID=new Map(rows.map(x=>[x.id,x]));if(!b.source.ids.every(id=>byID.has(id)))return {error:'source_id_unknown'};rows=b.source.ids.map(id=>byID.get(id));}
  rows=rows.slice(0,b.kind==='place'?5:8);if(!rows.length)return {error:'source_empty'};
  const {places,events,caption,...rest}=b;
  const block={...rest,...b.kind==='place'?{places:rows,...got.caption?{caption:got.caption}:{}}:{events:rows}};
  return {block:validateBlock(block)};
}
/** Display-only place block the server emits by itself after a successful places_search (no model involvement). */
export function autoPlaceBlock(callID,result){
  if(result?.status!=='ok')return null;
  const got=rowsFor('place',{name:'places_search',result});if(got.error||!got.rows.length)return null;
  const id=('places-'+String(callID).replace(/[^A-Za-z0-9_-]/g,'')).slice(0,64);
  return validateBlock({id,kind:'place',title:'附近',source:{callId:String(callID).slice(0,160)},places:got.rows.slice(0,5),...got.caption?{caption:got.caption}:{}});
}
export const ungroundedResult=code=>({status:'error',error:{code},hint:'place/event cards need a successful places_search / calendar_list / calendar_create result in this turn; pass its callId as source and do not invent content. Answer in text instead.'});
