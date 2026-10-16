import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {APPROVAL_CONTRACT} from '../supabase/functions/_shared/core/src/approval.mjs';
import {createDeviceTools,DEVICE_CONTRACT} from '../supabase/functions/_shared/core/src/device-call.mjs';
import {UI_CONTRACT,RENDER_UI,createRenderUITool,validateBlock,validateResponse,parseUIKinds} from '../supabase/functions/_shared/core/src/generative-ui.mjs';
import {toolResultsFrom,groundUIArgs,autoPlaceBlock} from '../supabase/functions/_shared/core/src/grounded-ui.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const FIX=JSON.parse(readFileSync(new URL('../docs/fixtures/catpaw-ui-grounded.json',import.meta.url),'utf8'));
const H='https://memory-test.example.invalid';

test('contract fixture: every grounding case reproduces byte-for-byte (mirrored by the iOS portable runner)',()=>{
 const results=toolResultsFrom(FIX.messages);assert.ok(FIX.cases.length>=12);
 for(const c of FIX.cases){const g=groundUIArgs(c.args,results,c.uiKinds),got=g.block?{block:g.block}:g.error?{error:g.error}:{passthrough:true};assert.deepEqual(got,c.expect,c.name);}
 for(const c of FIX.auto)assert.deepEqual({block:autoPlaceBlock(c.callId,c.result)},c.expect,c.name);
});
test('grounded blocks: model-written POIs never survive; unsafe deep links dropped; display only; schema guards',()=>{
 const byName=Object.fromEntries(FIX.cases.map(c=>[c.name,c]));
 assert.equal(byName.place_model_written_pois_are_replaced.expect.block.places[0].name,'川味小馆');
 const all=byName.place_all_from_places_search.expect.block;assert.deepEqual(all.places.map(p=>p.id),['p1','p2','p3']);
 assert.deepEqual(all.places[2].actions,[],'javascript: and malformed tel: are dropped');
 for(const p of all.places)for(const a of p.actions)assert.match(a.url,/^(maps:\/\/|tel:)/);
 assert.throws(()=>validateBlock({block:{id:'x',kind:'place'}}),/invalid_tool_arguments/,'source required');
 assert.throws(()=>validateBlock({block:{id:'x',kind:'place',source:{callId:'c'},actions:[{id:'a',label:'b'}]}}),'no block actions');
 assert.throws(()=>validateBlock({block:{id:'x',kind:'card',source:{callId:'c'}}}),'source only on grounded kinds');
 assert.throws(()=>validateBlock({block:{id:'x',kind:'place',source:{callId:'c'},places:[{id:'p',name:'n',actions:[{id:'go',label:'去',url:'javascript:x'}]}]}}));
 assert.throws(()=>validateResponse(all,{type:'ui.response',blockId:'nearby',actionId:'navigate',respondedAt:'2026-10-16T00:00:00Z'}),/ui_response_invalid/);
 assert.deepEqual(parseUIKinds('card, place,bogus,event'),['card','place','event']);assert.equal(parseUIKinds(null),null);
});

// End-to-end through the chat service: places_search (device) → auto place block; render_ui place grounded; ungrounded refused.
function model(probe){
 return async function*(input){probe.prompts.push(input.system_prompt);const last=input.messages.at(-1);
  if(last.role==='tool'){probe.results.push(JSON.parse(last.content));const step=probe.script[probe.results.length];
   if(step){yield {type:'tool_call',id:'call-'+randomUUID(),name:step.name,arguments:step.arguments(input.messages)};yield {type:'done',finish_reason:'tool_calls'};return;}
   yield {type:'text_delta',text:'好了'};yield {type:'done',finish_reason:'stop'};return;}
  const step=probe.script[0];yield {type:'tool_call',id:step.id??'call-'+randomUUID(),name:step.name,arguments:typeof step.arguments==='function'?step.arguments(input.messages):step.arguments};yield {type:'done',finish_reason:'tool_calls'};};
}
async function setup(script){
 const probe={prompts:[],results:[],script},f=await fixture({stream:model(probe)});
 f.runtime.chat.facade.gatedChatTools=new Map([...createDeviceTools(),[RENDER_UI,createRenderUITool()]]);
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 return {f,probe,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
}
const sse=async r=>(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));
async function send(s,{kinds='card,choices,confirm,form,sheet,list,progress,place,event'}={}){
 const c=(await s.f.json(await s.f.req(s.path))).conversation,tid=randomUUID();
 const r=await s.f.runtime.api(new Request(H+s.path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,'X-Catpaw-Device-Contract':DEVICE_CONTRACT,'X-Catpaw-UI-Contract':UI_CONTRACT,...kinds?{'X-Catpaw-UI-Kinds':kinds}:{}},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'附近川菜'},context:[]})}));
 assert.equal(r.status,200);const events=await sse(r);await s.f.runtime.chat.waitIdle();return {tid,events};
}
const report=(s,tid,body)=>s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/device-result',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify(body)}));
const PLACES=FIX.auto[0].result;

test('places_search result → server emits the place block itself; model render_ui place is rebuilt from that result',async()=>{
 const placesCall=msgs=>{const tc=msgs.flatMap(m=>m.tool_calls??[]).find(c=>c.function.name==='places_search');return tc.id;};
 const s=await setup([{name:'places_search',arguments:{query:'川菜'}},{name:RENDER_UI,arguments:msgs=>({block:{id:'pick',kind:'place',title:'挑两家',source:{callId:placesCall(msgs),ids:['p2','p1']},places:[{id:'p1',name:'编造的店',actions:[]}]}})}]);
 const {tid,events}=await send(s);const dc=events.find(e=>e.type==='device_call').data;assert.equal(dc.tool,'places_search');
 assert.match(s.probe.prompts[0],/source \{callId, ids\}/,'grounded prompt only for clients that render place/event');
 const r=await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'ok',data:PLACES.data});assert.equal(r.status,200);
 const resumed=await sse(r);await s.f.runtime.chat.waitIdle();
 const blocks=resumed.filter(e=>e.type==='ui.block').map(e=>e.data);assert.equal(blocks.length,2);
 assert.equal(blocks[0].id,'places-'+dc.call_id.replace(/[^A-Za-z0-9_-]/g,'').slice(0,57));assert.equal(blocks[0].kind,'place');assert.deepEqual(blocks[0].places.map(p=>p.name),['川味小馆','湘菜馆','粥铺']);
 assert.equal(blocks[1].id,'pick');assert.deepEqual(blocks[1].places.map(p=>p.name),['湘菜馆','川味小馆'],'model-written POI replaced by tool data');
 assert.equal(blocks[1].interruptId,undefined);assert.deepEqual(s.probe.results.at(-1),{status:'shown'});assert.equal(resumed.at(-1).type,'turn_completed');
});
test('render_ui place without a tool result → no ui.block, model told to answer in text; legacy client gets no grounded prompt/auto block',async()=>{
 let s=await setup([{name:RENDER_UI,arguments:{block:{id:'fake',kind:'place',source:{callId:'call-none'},places:[{id:'p1',name:'编造的店',actions:[]}]}}}]);
 let {events}=await send(s);assert.ok(!events.some(e=>e.type==='ui.block'));
 const tr=events.find(e=>e.type==='tool_result');assert.equal(tr.data.status,'error');assert.equal(s.probe.results[0].error.code,'source_not_found');assert.equal(events.at(-1).type,'turn_completed');
 s=await setup([{name:'places_search',arguments:{query:'川菜'}}]);const sent=await send(s,{kinds:null});assert.doesNotMatch(s.probe.prompts[0],/source \{callId, ids\}/);
 const dc=sent.events.find(e=>e.type==='device_call').data,r=await report(s,sent.tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'ok',data:PLACES.data});
 const resumed=await sse(r);await s.f.runtime.chat.waitIdle();assert.ok(!resumed.some(e=>e.type==='ui.block'),'legacy client keeps its receipt list');
});
