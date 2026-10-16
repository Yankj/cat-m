import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {APPROVAL_CONTRACT} from '../supabase/functions/_shared/core/src/approval.mjs';
import {createDeviceTools,DEVICE_CONTRACT,DEVICE_TOOL_NAMES,validateDeviceResult} from '../supabase/functions/_shared/core/src/device-call.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
function model(probe){
 return async function*(input){probe.tools.push(input.tools.map(t=>t.function.name));const last=input.messages.at(-1);
  if(last.role==='tool'){probe.results.push(JSON.parse(last.content));yield {type:'text_delta',text:'完成'};yield {type:'done',finish_reason:'stop'};return;}
  if(!input.tools.some(t=>t.function.name===probe.call.name)){yield {type:'text_delta',text:'无工具'};yield {type:'done',finish_reason:'stop'};return;}
  yield {type:'tool_call',id:'call-'+randomUUID(),name:probe.call.name,arguments:probe.call.arguments};yield {type:'done',finish_reason:'tool_calls'};};
}
async function setup(call,{allow=()=>true}={}){
 const probe={tools:[],results:[],call},f=await fixture({stream:model(probe)});f.runtime.chat.facade.gatedChatTools=createDeviceTools({allow});
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 return {f,probe,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
}
const sse=async r=>(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));
async function send(s,{device=true}={}){
 const c=(await s.f.json(await s.f.req(s.path))).conversation,tid=randomUUID();
 const r=await s.f.runtime.api(new Request(H+s.path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,...device?{'X-Catpaw-Device-Contract':DEVICE_CONTRACT}:{}},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'帮我加个日程'},context:[]})}));
 assert.equal(r.status,200);const events=await sse(r);await s.f.runtime.chat.waitIdle();return {tid,events};
}
const report=(s,tid,body)=>s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/device-result',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify(body)}));
const turn=async(s,tid)=>(await s.f.json(await s.f.req(s.path+'/turns/'+tid))).turn;
const CREATE={name:'calendar_create',arguments:{title:'牙医',start:'2026-10-20T09:00:00+08:00',end:'2026-10-20T10:00:00+08:00'}};

test('gate default off; tool list follows plan §3.2; read-only tools need no card; result schema',()=>{
 assert.equal(readConfig(()=>undefined).deviceTools,'allowlist');
 assert.deepEqual(DEVICE_TOOL_NAMES,['calendar_list','calendar_create','reminder_create','mail_compose','sms_compose','phone_call','contacts_search','maps_open','shop_open','alarm_set','shortcut_run','places_search']);
 const tools=createDeviceTools();assert.equal(tools.get('calendar_list').confirm,'none');assert.equal(tools.get('contacts_search').confirm,'card');assert.equal(tools.get('calendar_create').confirm,'card');
 assert.throws(()=>tools.get('calendar_create').validate({title:'x'}));assert.throws(()=>tools.get('maps_open').validate({}));
 assert.throws(()=>validateDeviceResult({call_id:'c',operation_id:randomUUID(),args_hash:'a',status:'done'}));
});

test('no device header → no device tools offered; allowlist gate respected',async()=>{
 const s=await setup(CREATE);await send(s,{device:false});assert.equal(s.probe.tools[0].includes('calendar_create'),false);
 const g=await setup(CREATE,{allow:()=>false});await send(g);assert.equal(g.probe.tools[0].includes('calendar_create'),false);
});

test('device_call suspends; device-result resumes the same turn; idempotent per operation_id; args_hash bound',async()=>{
 const s=await setup(CREATE),{tid,events}=await send(s);
 assert.deepEqual(events.slice(-3).map(e=>e.type),['tool_call','device_call','turn_suspended']);
 const dc=events.at(-2).data;assert.equal(dc.tool,'calendar_create');assert.deepEqual(dc.args,CREATE.arguments);assert.equal(dc.confirm,'card');assert.equal(dc.ttl_sec,600);assert.match(dc.args_hash,/^[a-f0-9]{64}$/);
 assert.equal(events.at(-2).turn_id,tid);assert.ok(events.at(-2).conversation_id);
 const snap=await turn(s,tid);assert.equal(snap.state,'awaiting_approval');assert.equal(snap.pending_approvals[0].kind,'device');assert.equal(snap.pending_approvals[0].device_call.call_id,dc.call_id);
 assert.equal((await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:'0'.repeat(64),status:'ok'})).status,409,'stale args_hash');
 assert.equal((await report(s,tid,{call_id:'nope',operation_id:randomUUID(),args_hash:dc.args_hash,status:'ok'})).status,404);
 const op=randomUUID(),body={call_id:dc.call_id,operation_id:op,args_hash:dc.args_hash,status:'ok',data:{event_id:'EK-1'}};
 const r=await report(s,tid,body);assert.equal(r.status,200);const resumed=await sse(r);await s.f.runtime.chat.waitIdle();
 assert.deepEqual(resumed.map(e=>e.type),['approval_resolved','tool_result','text_delta','turn_completed']);assert.equal(resumed[0].sequence,events.at(-1).sequence+1);
 assert.equal(resumed[0].data.kind,'device');assert.equal(resumed[0].data.device_status,'ok');assert.deepEqual(s.probe.results.at(-1),{status:'ok',data:{event_id:'EK-1'}});
 assert.equal((await report(s,tid,body)).status,200,'replay of the same operation is accepted');
 assert.equal((await report(s,tid,{...body,status:'error'})).status,409,'same operation, different body');
 assert.equal((await report(s,tid,{...body,operation_id:randomUUID()})).status,409,'already consumed');
});

test('user cancel on the phone and read-only confirm:none are reported back to the model',async()=>{
 const s=await setup(CREATE),{tid,events}=await send(s),dc=events.at(-2).data;
 const r=await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'cancelled'});await sse(r);await s.f.runtime.chat.waitIdle();
 assert.deepEqual(s.probe.results.at(-1),{status:'cancelled'});
 const l=await setup({name:'calendar_list',arguments:{from:'2026-10-20T00:00:00+08:00',to:'2026-10-21T00:00:00+08:00'}}),a=await send(l);assert.equal(a.events.at(-2).data.confirm,'none');
});

test('ttl: no result before expires_at → expired, the model hears pending_timeout',async()=>{
 const s=await setup(CREATE),{tid,events}=await send(s),dc=events.at(-2).data;
 const real=s.f.runtime.chat.now.bind(s.f.runtime.chat);s.f.runtime.chat.now=()=>real()+601000;
 const r=await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'ok'});assert.equal(r.status,409);assert.match(await r.text(),/approval_expired/);
 await s.f.runtime.chat.waitIdle();assert.equal(s.probe.results.at(-1).status,'pending_timeout');
});

test('chat-ux #7: contacts_search needs a tap — device_call confirm:card, turn waits, nothing reaches the model before the report',async()=>{
 const s=await setup({name:'contacts_search',arguments:{query:'张三'}}),{tid,events}=await send(s);
 const dc=events.find(e=>e.type==='device_call').data;assert.equal(dc.confirm,'card');assert.equal(events.at(-1).type,'turn_suspended');
 assert.equal(s.probe.results.length,0,'no contact data before the user taps');
 assert.equal((await turn(s,tid)).pending_approvals[0].device_call.confirm,'card');
 const r=await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'cancelled'});assert.equal(r.status,200);await sse(r);await s.f.runtime.chat.waitIdle();
 assert.deepEqual(s.probe.results.at(-1),{status:'cancelled'},'user declined → model gets no contact fields');
 assert.doesNotThrow(()=>createDeviceTools().get('contacts_search').validate({query:'张三',include_email:true}));
 assert.throws(()=>createDeviceTools().get('contacts_search').validate({query:'张三',include_email:'yes'}));
});

test('chat-ux #6: device-undo records the outcome by call_id; the model learns it with the next message; idempotent; only ok writes',async()=>{
 const s=await setup(CREATE),{tid,events}=await send(s);const dc=events.find(e=>e.type==='device_call').data;
 const undo=body=>s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/device-undo',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify(body)}));
 const op=randomUUID();
 assert.equal((await undo({call_id:dc.call_id,operation_id:op,status:'undone'})).status,409,'not reported yet → not applicable');
 const r=await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'ok',data:{event_id:'EK-1'}});await sse(r);await s.f.runtime.chat.waitIdle();
 assert.equal((await undo({call_id:'nope',operation_id:op,status:'undone'})).status,404);
 assert.equal((await undo({call_id:dc.call_id,operation_id:op,status:'gone'})).status,422);
 const ok=await undo({call_id:dc.call_id,operation_id:op,status:'undone'});assert.equal(ok.status,200);assert.deepEqual((await ok.json()).undo,{call_id:dc.call_id,status:'undone',replayed:false});
 assert.equal((await (await undo({call_id:dc.call_id,operation_id:op,status:'undone'})).json()).undo.replayed,true,'replay accepted');
 assert.equal((await undo({call_id:dc.call_id,operation_id:randomUUID(),status:'failed'})).status,409,'different outcome for the same call');
 const seen=[];s.f.runtime.chat.provider.stream=async function*(input){seen.push(input.messages.at(-1).content);yield {type:'text_delta',text:'好'};yield {type:'done',finish_reason:'stop'};};
 await send(s);assert.match(seen[0],/用户在手机上撤销了你创建的日程「牙医」/);assert.match(seen[0],/已删除/);assert.match(seen[0],/帮我加个日程$/);
 await send(s);assert.doesNotMatch(seen[1],/撤销/,'note delivered once');
});
