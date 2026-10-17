// v1.1 (a): read-only device calls (confirm:'none') suspend the turn for the phone's result but never signal "waiting for
// your confirmation": turn_suspended carries requires_approval:false / waiting_for:'device'.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {APPROVAL_CONTRACT} from '../supabase/functions/_shared/core/src/approval.mjs';
import {createDeviceTools,DEVICE_CONTRACT} from '../supabase/functions/_shared/core/src/device-call.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
function model(probe){return async function*(input){const last=input.messages.at(-1);
 if(last.role==='tool'){probe.results.push(JSON.parse(last.content));yield {type:'text_delta',text:'好'};yield {type:'done',finish_reason:'stop'};return;}
 for(const [i,c] of probe.calls.entries())yield {type:'tool_call',id:'c'+i+'-'+randomUUID(),name:c.name,arguments:c.arguments};yield {type:'done',finish_reason:'tool_calls'};};}
async function run(calls){
 const probe={calls,results:[]},f=await fixture({stream:model(probe)});f.runtime.chat.facade.gatedChatTools=createDeviceTools();
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const path=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`,c=(await f.json(await f.req(path))).conversation,tid=randomUUID();
 const r=await f.runtime.api(new Request(H+path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,'X-Catpaw-Device-Contract':DEVICE_CONTRACT},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'查一下'},context:[]})}));
 const events=(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));await f.runtime.chat.waitIdle();
 return {f,probe,path,tid,events};
}
test('read-only device call (calendar_list, confirm none): device_call is dispatched, turn waits, turn_suspended says no approval needed',async()=>{
 const {f,probe,path,tid,events}=await run([{name:'calendar_list',arguments:{from:'2026-10-17T00:00:00+08:00',to:'2026-10-18T00:00:00+08:00'}}]);
 const dc=events.find(e=>e.type==='device_call').data;assert.equal(dc.confirm,'none');
 assert.ok(!events.some(e=>e.type==='approval_requested'));
 const s=events.at(-1);assert.equal(s.type,'turn_suspended');assert.equal(s.data.requires_approval,false);assert.equal(s.data.waiting_for,'device');
 assert.deepEqual(s.data.interrupt_ids,[dc.interrupt_id]);
 const r=await f.runtime.api(new Request(H+path+'/turns/'+tid+'/device-result',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify({call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'ok',data:{events:[]}})}));
 assert.equal(r.status,200);await r.text();await f.runtime.chat.waitIdle();assert.equal(probe.results.at(-1).status,'ok','still dispatched to the phone and resumed with its result');
 assert.equal((await f.json(await f.req(path+'/turns/'+tid))).turn.state,'completed');
});
test('card device call (reminder_create): turn_suspended requires_approval:true, waiting_for user',async()=>{
 const {events}=await run([{name:'reminder_create',arguments:{title:'上线',due:'2026-10-19T09:00:00+08:00'}}]);
 const s=events.at(-1);assert.equal(s.type,'turn_suspended');assert.deepEqual([s.data.requires_approval,s.data.waiting_for],[true,'user']);
});
test('a round with a read-only and a card call needs approval',async()=>{
 const {events}=await run([{name:'calendar_list',arguments:{from:'2026-10-17T00:00:00+08:00',to:'2026-10-18T00:00:00+08:00'}},{name:'reminder_create',arguments:{title:'上线'}}]);
 const s=events.at(-1);assert.equal(s.data.interrupt_ids.length,2);assert.equal(s.data.requires_approval,true);
});
test('old-client shape kept: interrupt_ids (UUIDs) and expires_at still present',async()=>{
 const {events}=await run([{name:'calendar_list',arguments:{from:'2026-10-17T00:00:00+08:00',to:'2026-10-18T00:00:00+08:00'}}]);
 const d=events.at(-1).data;assert.ok(d.interrupt_ids.every(i=>/^[0-9a-f-]{36}$/.test(i)));assert.equal(typeof d.expires_at,'string');
});
