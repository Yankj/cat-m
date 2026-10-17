// chat-context-1522: multi-turn context across declined / failed / abandoned turns, and persisted interaction outcomes.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {APPROVAL_CONTRACT} from '../supabase/functions/_shared/core/src/approval.mjs';
import {ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {createDeviceTools,DEVICE_CONTRACT} from '../supabase/functions/_shared/core/src/device-call.mjs';
import {interruptedTurnNote,turnOutcomeNote,withInterruptedTurn,interruptOutcome} from '../supabase/functions/_shared/core/src/turn-outcome.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
const REMINDER={name:'reminder_create',arguments:{title:'下周上线清单',due:'2026-10-19T09:00:00+08:00'}};
// Scripted model. Round 1 of a "do" message calls the device tool; after a tool result it says a sentence and then either
// fails (failAfterTool, like prod turn 6497bf72 invalid_tool_index) or completes. Other messages answer with plain text.
function model(probe){
 return async function*(input){probe.inputs.push(input.messages);const last=input.messages.at(-1);
  if(last.role==='tool'){probe.results.push(JSON.parse(last.content));yield {type:'text_delta',text:'看起来创建提醒被取消了。我换一个方式：'};if(probe.failAfterTool){await new Promise(r=>setTimeout(r,400));throw new ApiError(503,'invalid_tool_index');}yield {type:'done',finish_reason:'stop'};return;}
  if(String(last.content).endsWith('帮我加个提醒')&&input.tools.some(t=>t.function.name===probe.call.name)){yield {type:'tool_call',id:'call-'+randomUUID(),name:probe.call.name,arguments:probe.call.arguments};yield {type:'done',finish_reason:'tool_calls'};return;}
  yield {type:'text_delta',text:'好的'};yield {type:'done',finish_reason:'stop'};};
}
async function setup(opts={}){
 const probe={inputs:[],results:[],call:REMINDER,...opts},f=await fixture({stream:model(probe)});f.runtime.chat.facade.gatedChatTools=createDeviceTools();
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 return {f,probe,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
}
const sse=async r=>(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));
const conversation=async s=>(await s.f.json(await s.f.req(s.path))).conversation;
async function post(s,text){
 const c=await conversation(s),tid=randomUUID();
 const r=await s.f.runtime.api(new Request(H+s.path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,'X-Catpaw-Device-Contract':DEVICE_CONTRACT},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text},context:[]})}));
 return {r,tid};
}
async function send(s,text){const {r,tid}=await post(s,text);assert.equal(r.status,200);const events=await sse(r);await s.f.runtime.chat.waitIdle();return {tid,events};}
const report=(s,tid,body)=>s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/device-result',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify(body)}));
const turn=async(s,tid)=>(await s.f.json(await s.f.req(s.path+'/turns/'+tid))).turn;
const lastUser=messages=>messages.filter(m=>m.role==='user').at(-1).content;

test('card 取消 → model gets explicit user_declined (not a failure); completed turn keeps the full trajectory in history',async()=>{
 const s=await setup(),{tid,events}=await send(s,'帮我加个提醒'),dc=events.find(e=>e.type==='device_call').data;
 await sse(await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'cancelled'}));await s.f.runtime.chat.waitIdle();
 const result=s.probe.results.at(-1);assert.equal(result.status,'user_declined');assert.match(result.message,/do not retry/);
 const c=await conversation(s);assert.deepEqual(c.model_messages.map(m=>m.role),['user','assistant','tool','assistant']);
 assert.deepEqual(c.interaction_outcomes.map(o=>[o.turn_id,o.tool,o.kind,o.outcome,o.device_status]),[[tid,'reminder_create','device','user_declined','cancelled']]);
 await send(s,'是我手动取消的');const next=s.probe.inputs.at(-1);assert.equal(next.at(-2).role,'assistant');assert.equal(lastUser(next),'是我手动取消的','no note needed: the turn completed');
});

test('prod 6497bf72: declined device call, then the resumed round fails → the next message still carries the call, the decline and the shown text',async()=>{
 const s=await setup({failAfterTool:true}),{tid,events}=await send(s,'帮我加个提醒'),dc=events.find(e=>e.type==='device_call').data;
 await sse(await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'cancelled'}));await s.f.runtime.chat.waitIdle();
 const failed=await turn(s,tid);assert.equal(failed.state,'failed');assert.equal(failed.error.code,'invalid_tool_index');
 let c=await conversation(s);assert.deepEqual(c.model_messages.map(m=>m.role),['user'],'a failed turn writes no assistant/tool messages');
 assert.equal(c.turn_outcome_notes.length,1);assert.equal(c.turn_outcome_notes[0].tools[0].outcome,'user_declined');
 assert.equal(c.interaction_outcomes[0].outcome,'user_declined');
 s.probe.failAfterTool=false;await send(s,'是我手动取消的');
 const note=lastUser(s.probe.inputs.at(-1));
 assert.match(note,/^（系统记录，不是用户的话：/);assert.match(note,/reminder_create（title=下周上线清单/);assert.match(note,/主动点了「取消\/拒绝」/);
 assert.match(note,/invalid_tool_index/);assert.match(note,/看起来创建提醒被取消了/);assert.match(note,/不要去排查/);assert.ok(note.endsWith('是我手动取消的'));
 c=await conversation(s);assert.deepEqual(c.turn_outcome_notes,[],'note is consumed by exactly one turn');
 await send(s,'谢谢');assert.equal(lastUser(s.probe.inputs.at(-1)),'谢谢');
 assert.ok(!c.messages.some(m=>String(m.content).includes('系统记录')),'visible history (client-checked) is unchanged');
});

test('a suspended turn no longer blocks the conversation: the next message closes it as superseded and tells the model',async()=>{
 const s=await setup(),{tid,events}=await send(s,'帮我加个提醒'),dc=events.find(e=>e.type==='device_call').data;
 assert.equal((await turn(s,tid)).state,'awaiting_approval');
 const {r,tid:next}=await post(s,'算了，先不加了');assert.equal(r.status,200);await sse(r);await s.f.runtime.chat.waitIdle();
 const old=await turn(s,tid);assert.equal(old.state,'failed');assert.equal(old.error.code,'superseded_by_new_message');
 assert.deepEqual(old.events.slice(-2).map(e=>[e.type,e.data.decision??e.data.code]),[['approval_resolved','cancelled'],['turn_failed','superseded_by_new_message']]);
 assert.equal(old.pending_approvals.length,0);
 assert.equal((await report(s,tid,{call_id:dc.call_id,operation_id:randomUUID(),args_hash:dc.args_hash,status:'ok'})).status,409,'a late phone report cannot resume it');
 const note=lastUser(s.probe.inputs.at(-1));assert.match(note,/没有回应确认卡片/);assert.match(note,/reminder_create/);assert.match(note,/没有在卡片上作答/);assert.ok(note.endsWith('算了，先不加了'));
 assert.equal((await turn(s,next)).state,'completed');
 const c=await conversation(s);assert.equal(c.interaction_outcomes[0].outcome,'abandoned');assert.equal(c.last_turn_id,next);
});

test('a running turn still answers 409 conversation_busy',async()=>{
 let release;const gate=new Promise(r=>{release=r;});
 const f=await fixture({stream:async function*(){await gate;yield {type:'text_delta',text:'慢'};yield {type:'done',finish_reason:'stop'};}});
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const s={f,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
 const first=await post(s,'第一条');assert.equal(first.r.status,200);const firstEvents=sse(first.r);
 const second=await post(s,'第二条');assert.equal(second.r.status,409);assert.equal((await second.r.json()).error.code,'conversation_busy');
 release();await firstEvents;await f.runtime.chat.waitIdle();
});

test('user stop of a suspended turn → next message carries the cancelled call',async()=>{
 const s=await setup(),{tid}=await send(s,'帮我加个提醒');
 await s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/cancel',{method:'POST',headers:{Authorization:'Bearer memory-fixture'},body:'{}'}));
 const c=await conversation(s);assert.equal(c.turn_outcome_notes[0].code,'cancelled');assert.equal(c.interaction_outcomes[0].outcome,'cancelled');
 await send(s,'继续');const note=lastUser(s.probe.inputs.at(-1));assert.match(note,/用户主动停止了这一轮/);assert.match(note,/reminder_create/);
});

test('pure helpers: outcome labels, empty turns produce no note, bounded queue',()=>{
 assert.equal(interruptOutcome({status:'reported',response:{status:'cancelled'}}),'user_declined');
 assert.equal(interruptOutcome({status:'denied'}),'user_declined');assert.equal(interruptOutcome({status:'expired'}),'expired');
 assert.equal(interruptOutcome({status:'cancelled',cancel_reason:'superseded'}),'abandoned');assert.equal(interruptOutcome({status:'reported',response:{status:'ok'}}),'ok');
 assert.equal(interruptedTurnNote({id:'t',events:[{type:'turn_started'}]},'provider_timeout'),null,'nothing happened beyond the user message');
 assert.equal(turnOutcomeNote([]),'');
 let c={};for(let i=0;i<7;i++)c=withInterruptedTurn(c,{id:'t'+i,events:[{type:'text_delta',data:{text:'x'.repeat(500)}}]},'provider_timeout');
 assert.equal(c.turn_outcome_notes.length,4);assert.equal(c.turn_outcome_notes.at(-1).turn_id,'t6');assert.ok(c.turn_outcome_notes[0].shown_text.length<=301);
 const t={id:'t',events:[{type:'tool_call',data:{call_id:'a',name:'create_task',arguments:{title:'喝水'}}},{type:'tool_result',data:{call_id:'a',name:'create_task',status:'ok',result:{}}},{type:'tool_call',data:{call_id:'b',name:'create_task',arguments:{title:'吃饭'}}}]};
 assert.deepEqual(interruptedTurnNote(t,'invalid_tool_index').tools.map(x=>x.outcome),['ok','not_executed']);
});
