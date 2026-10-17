import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {APPROVAL_CONTRACT} from '../supabase/functions/_shared/core/src/approval.mjs';
import {timeContext} from '../supabase/functions/_shared/core/src/chat-service.mjs';
import {createTaskChatTools} from '../supabase/functions/_shared/proactive/chat-tools.mjs';
import {createProactiveService} from '../supabase/functions/_shared/proactive/service.mjs';
import {createMemoryStore} from '../supabase/functions/_shared/proactive/memory-store.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
function model(probe){
 return async function*(input){probe.tools.push(input.tools.map(t=>t.function.name));probe.inputs.push(input.messages);probe.prompts.push(JSON.stringify(input));
  const last=input.messages.at(-1);
  if(last.role==='tool'){probe.results.push(JSON.parse(last.content));yield {type:'text_delta',text:'好的'};yield {type:'done',finish_reason:'stop'};return;}
  if(!input.tools.some(t=>t.function.name===probe.call.name)){yield {type:'text_delta',text:'无工具'};yield {type:'done',finish_reason:'stop'};return;}
  yield {type:'tool_call',id:'call-'+randomUUID(),name:probe.call.name,arguments:probe.call.arguments};yield {type:'done',finish_reason:'tool_calls'};};
}
async function setup(call){
 const probe={tools:[],inputs:[],prompts:[],results:[],call},store=createMemoryStore(),service=createProactiveService({store,verifyUser:async()=>{throw Error('unused');}}),f=await fixture({stream:model(probe)});
 f.runtime.facade.gatedChatTools=createTaskChatTools({service});assert.equal(f.runtime.chat.facade,f.runtime.facade);
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 return {f,probe,store,service,cid,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
}
const sse=async r=>(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));
async function send(s,headers={}){
 const c=(await s.f.json(await s.f.req(s.path))).conversation,tid=randomUUID();
 const r=await s.f.runtime.api(new Request(H+s.path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json',...headers},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'明早九点提醒我喝水'},context:[]})}));
 assert.equal(r.status,200);const events=await sse(r);await s.f.runtime.chat.waitIdle();return {tid,events};
}
const decide=(s,tid,iid,body)=>s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/interrupts/'+iid+'/decision',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify(body)}));
const negotiated={'X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,'X-Catpaw-Time-Zone':'Asia/Shanghai'};
const systemText=msgs=>msgs.filter(m=>m.role==='system').map(m=>m.content).join('\n');

test('create_task asks first, then runs in-process with a stable operation_id; tool_result carries status ok',async()=>{
 const s=await setup({name:'create_task',arguments:{title:'喝水',due_at:'2026-10-16T09:00:00+08:00'}}),{tid,events}=await send(s,negotiated);
 assert.deepEqual(events.slice(-3).map(e=>e.type),['tool_call','approval_requested','turn_suspended']);
 const req=events.at(-2).data;assert.equal(req.risk,'local_write');assert.equal(req.remember_allowed,true);assert.match(req.summary,/新建：喝水/);
 assert.equal((await s.store.listTasks(await subjectOf(s),{status:'all',limit:50})).length,0,'nothing written before approval');
 const r=await decide(s,tid,req.interrupt_id,{operation_id:randomUUID(),decision:'approve',args_hash:req.args_hash});assert.equal(r.status,200);
 const resumed=await sse(r);await s.f.runtime.chat.waitIdle();
 const result=resumed.find(e=>e.type==='tool_result');assert.equal(result.data.status,'ok');assert.equal(result.data.result.ok,true);assert.equal(result.data.result.created,true);
 assert.equal(resumed.at(-1).type,'turn_completed');assert.equal(s.probe.results.at(-1).ok,true);
 // Replaying the same (turn, call) — retry-busy / resume / recovery — returns the same task, never a duplicate.
 const call=events.find(e=>e.type==='tool_call').data;
 const opId=(await import('../supabase/functions/_shared/core/src/local-output-facade.mjs')).stableUUID(`${tid}:${call.call_id}:operation`);
 const again=await s.service.executeTool(await subjectOf(s),{name:'create_task',arguments:call.arguments},{conversation_id:s.cid,turn_id:tid,operation_id:opId});
 assert.equal(again.ok,true);assert.equal(again.created,false);assert.equal(again.task.id,result.data.result.task.id);
 // Prompt carries the user time zone and current local time.
 assert.match(s.probe.prompts[0],/User time zone: Asia\/Shanghai\. Current local time: \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+08:00/);
});
async function subjectOf(s){const r=await s.f.json(await s.f.req(s.path));return r.conversation.subject_id;}

test('list_tasks is read-only and runs without asking',async()=>{
 const s=await setup({name:'list_tasks',arguments:{status:'all'}}),{events}=await send(s,negotiated);
 assert.ok(!events.some(e=>e.type==='approval_requested'));const r=events.find(e=>e.type==='tool_result');assert.equal(r.data.status,'ok');assert.deepEqual(r.data.result,{ok:true,tasks:[]});assert.equal(events.at(-1).type,'turn_completed');
});

test('update_task failure from the service is a tool_result status error, not a turn failure',async()=>{
 const s=await setup({name:'update_task',arguments:{task_id:randomUUID(),status:'done'}}),{tid,events}=await send(s,negotiated);
 const req=events.at(-2).data;assert.equal(events.at(-1).type,'turn_suspended');
 const resumed=await sse(await decide(s,tid,req.interrupt_id,{operation_id:randomUUID(),decision:'approve',args_hash:req.args_hash}));await s.f.runtime.chat.waitIdle();
 const r=resumed.find(e=>e.type==='tool_result');assert.equal(r.data.status,'error');assert.equal(resumed.at(-1).type,'turn_completed');
});

test('old clients (no approval contract) are offered no task tools at all; missing time zone falls back to labelled UTC',async()=>{
 const s=await setup({name:'list_tasks',arguments:{}}),{events}=await send(s);
 for(const n of ['create_task','update_task','list_tasks'])assert.ok(!s.probe.tools[0].includes(n));assert.equal(events.at(-1).type,'turn_completed');
 const t=await setup({name:'list_tasks',arguments:{}});await send(t,{'X-Catpaw-Approval-Contract':APPROVAL_CONTRACT});
 assert.match(t.probe.prompts[0],/User time zone: UTC \(fallback/);
 assert.match(timeContext('Bogus/Zone',Date.parse('2026-10-15T14:00:00Z')),/UTC \(fallback.*2026-10-15T14:00:00\+00:00/);
 assert.match(timeContext('America/New_York',Date.parse('2026-10-15T14:00:00Z')),/America\/New_York\. Current local time: 2026-10-15T10:00:00-04:00 \(Thursday\)/);
});
