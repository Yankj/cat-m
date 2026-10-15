import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {check,shape} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {APPROVAL_CONTRACT,APPROVAL_PREFERENCES,preferenceID} from '../supabase/functions/_shared/core/src/approval.mjs';
import {TOOL_APPROVAL,toolApprovalPolicy} from '../supabase/functions/_shared/core/src/tools.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
const def=name=>({type:'function',function:{name,description:`synthetic ${name}`,parameters:{type:'object',properties:{title:{type:'string'}},required:['title'],additionalProperties:false}}});
function gated(executed){
 const tool=name=>[name,{definition:def(name),validate(a){shape(a,['title']);check(typeof a.title==='string'&&a.title.length>0,422,'invalid_tool_arguments');},summarize:a=>`${name}: ${a.title}`,
  async execute(tx,ctx){executed.push({name,operation_id:ctx.operation_id,turn:ctx.turn.id});return {task_id:'synthetic-task',title:ctx.call.arguments.title};}}];
 return new Map([tool('create_task'),tool('update_task'),tool('create_reminder'),['list_tasks',{definition:{type:'function',function:{name:'list_tasks',description:'read',parameters:{type:'object',properties:{},additionalProperties:false}}},validate(a){shape(a,[]);},async execute(){executed.push({name:'list_tasks'});return {tasks:[]};}}]]);
}
// Model: first round calls `tool` (title 喝水); after any tool message, answers with text that quotes the tool status.
function model(probe){
 return async function*(input){probe.tools.push(input.tools.map(t=>t.function.name));probe.inputs.push(input.messages);
  const last=input.messages.at(-1);
  if(last.role==='tool'){const r=JSON.parse(last.content);yield {type:'text_delta',text:`结果:${r.status??'ok'}`};yield {type:'done',finish_reason:'stop'};return;}
  if(!input.tools.some(t=>t.function.name===probe.tool)){yield {type:'text_delta',text:'无工具'};yield {type:'done',finish_reason:'stop'};return;}
  yield {type:'text_delta',text:'好的。'};yield {type:'tool_call',id:'call-'+randomUUID(),name:probe.tool,arguments:{title:'喝水'}};yield {type:'done',finish_reason:'tool_calls'};};
}
async function setup(tool='create_task'){
 const probe={tools:[],inputs:[],tool},executed=[],f=await fixture({stream:model(probe)});f.runtime.chat.facade.gatedChatTools=gated(executed);
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const path=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;return {f,probe,executed,path};
}
const sse=async r=>(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));
async function send(s,{approval=true,text='每天九点提醒我喝水'}={}){
 const c=(await s.f.json(await s.f.req(s.path))).conversation,tid=randomUUID();
 const r=await s.f.runtime.api(new Request(H+s.path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json',...approval?{'X-Catpaw-Approval-Contract':APPROVAL_CONTRACT}:{}},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text},context:[]})}));
 assert.equal(r.status,200);const events=await sse(r);await s.f.runtime.chat.waitIdle();return {tid,events};
}
const turn=async(s,tid)=>(await s.f.json(await s.f.req(s.path+'/turns/'+tid))).turn;
const decide=(s,tid,iid,body,query='')=>s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/interrupts/'+iid+'/decision'+query,{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify(body)}));
const seqOK=events=>events.every((e,i)=>i===0||e.sequence===events[i-1].sequence+1);

test('registry declarations: read-only never, task writes first use, device/external every time, unknown always',()=>{
 assert.equal(toolApprovalPolicy('agent_status').approval,'never');assert.equal(toolApprovalPolicy('list_tasks').approval,'never');
 assert.equal(TOOL_APPROVAL.create_task.approval,'first_use');assert.equal(TOOL_APPROVAL.update_task.class,TOOL_APPROVAL.create_task.class);
 for(const n of ['create_calendar_event','create_reminder','external_write'])assert.equal(toolApprovalPolicy(n).approval,'always');
 assert.equal(toolApprovalPolicy('anything_new').approval,'always');
});

test('gated call suspends the turn; approve resumes the SAME turn in place with continuous sequence',async()=>{
 const s=await setup(),{tid,events}=await send(s);
 assert.deepEqual(events.slice(-3).map(e=>e.type),['tool_call','approval_requested','turn_suspended']);assert.ok(seqOK(events));
 const req=events.at(-2).data;assert.equal(req.tool,'create_task');assert.equal(req.summary,'create_task: 喝水');assert.equal(req.risk,'local_write');assert.equal(req.remember_allowed,true);assert.match(req.args_hash,/^[a-f0-9]{64}$/);
 assert.ok(Date.parse(req.expires_at)-Date.now()>9*60000);assert.deepEqual(events.at(-1).data.interrupt_ids,[req.interrupt_id]);
 assert.equal(s.executed.length,0,'nothing executed before the decision');
 const snap=await turn(s,tid);assert.equal(snap.state,'awaiting_approval');assert.equal(snap.pending_approvals.length,1);assert.equal(snap.pending_approvals[0].args_hash,req.args_hash);assert.deepEqual(snap.pending_approvals[0].arguments,{title:'喝水'});
 assert.equal(snap.approval_checkpoint,undefined);assert.equal(snap.interrupts,undefined);
 const op=randomUUID(),r=await decide(s,tid,req.interrupt_id,{operation_id:op,decision:'approve',args_hash:req.args_hash});assert.equal(r.status,200);
 const resumed=await sse(r);await s.f.runtime.chat.waitIdle();
 assert.equal(resumed[0].sequence,events.at(-1).sequence+1);assert.ok(seqOK(resumed));
 assert.deepEqual(resumed.map(e=>e.type),['approval_resolved','tool_result','text_delta','turn_completed']);
 assert.equal(resumed[0].data.decision,'approved');assert.equal(resumed[1].data.status,'ok');assert.equal(resumed[2].data.text,'结果:ok');
 assert.equal(s.executed.length,1);
 const done=await turn(s,tid);assert.equal(done.state,'completed');assert.deepEqual(done.pending_approvals,[]);
 const text=done.events.filter(e=>e.type==='text_delta').map(e=>e.data.text).join('');assert.equal(text,'好的。结果:ok');
 // Idempotent replay: same operation id streams the same events, executes nothing new.
 const again=await sse(await decide(s,tid,req.interrupt_id,{operation_id:op,decision:'approve',args_hash:req.args_hash}));
 assert.deepEqual(again.map(e=>e.sequence),resumed.map(e=>e.sequence));assert.equal(s.executed.length,1);
 const conflict=await decide(s,tid,req.interrupt_id,{operation_id:op,decision:'deny',args_hash:req.args_hash});assert.equal(conflict.status,409);assert.equal((await conflict.json()).error.code,'approval_operation_conflict');
 const consumed=await decide(s,tid,req.interrupt_id,{operation_id:randomUUID(),decision:'deny',args_hash:req.args_hash});assert.equal(consumed.status,409);assert.equal((await consumed.json()).error.code,'approval_consumed');
});

test('deny returns a denied tool_result to the model; stale hash, unknown interrupt and bad body are rejected',async()=>{
 const s=await setup(),{tid,events}=await send(s),req=events.at(-2).data;
 const stale=await decide(s,tid,req.interrupt_id,{operation_id:randomUUID(),decision:'approve',args_hash:'0'.repeat(64)});assert.equal(stale.status,409);assert.equal((await stale.json()).error.code,'approval_stale');
 assert.equal((await decide(s,tid,randomUUID(),{operation_id:randomUUID(),decision:'approve',args_hash:req.args_hash})).status,404);
 const bad=await decide(s,tid,req.interrupt_id,{operation_id:'x',decision:'maybe',args_hash:req.args_hash});assert.equal(bad.status,422);assert.equal((await bad.json()).error.code,'approval_schema_invalid');
 const out=await sse(await decide(s,tid,req.interrupt_id,{operation_id:randomUUID(),decision:'deny',args_hash:req.args_hash}));await s.f.runtime.chat.waitIdle();
 assert.equal(out[0].data.decision,'denied');assert.equal(out[1].data.status,'denied');assert.equal(out[1].data.result.reason,'user_denied');assert.equal(out.at(-1).type,'turn_completed');
 assert.equal(s.executed.length,0);const toolMsg=s.probe.inputs.at(-1).at(-1);assert.equal(JSON.parse(toolMsg.content).status,'denied');
});

test('approve_always remembers the class; same-class calls then run without asking; always-tools keep asking',async()=>{
 const s=await setup(),{tid,events}=await send(s),req=events.at(-2).data;
 await sse(await decide(s,tid,req.interrupt_id,{operation_id:randomUUID(),decision:'approve_always',args_hash:req.args_hash}));await s.f.runtime.chat.waitIdle();
 const pref=await s.f.repository.transaction(async tx=>{for(const owner of Object.keys(s.f.repository.snapshot?.()??{}))void owner;return null;});void pref;
 s.probe.tool='update_task';const second=await send(s);assert.ok(!second.events.some(e=>e.type==='approval_requested'));assert.equal(second.events.at(-1).type,'turn_completed');
 assert.equal(second.events.find(e=>e.type==='tool_result').data.status,'ok');assert.equal(s.executed.at(-1).name,'update_task');
 s.probe.tool='create_reminder';const third=await send(s),r3=third.events.at(-2).data;assert.equal(r3.risk,'device_write');assert.equal(r3.remember_allowed,false);
 const refused=await decide(s,third.tid,r3.interrupt_id,{operation_id:randomUUID(),decision:'approve_always',args_hash:r3.args_hash});assert.equal(refused.status,422);assert.equal((await refused.json()).error.code,'approval_remember_not_allowed');
});

test('expiry after 10 minutes is applied lazily on read and resumes with a denied result; later decisions get approval_expired',async()=>{
 const s=await setup(),{tid,events}=await send(s),req=events.at(-2).data;
 s.f.runtime.chat.clockNow=()=>Date.now()+11*60000;
 const read=await turn(s,tid);assert.ok(['running','completed'].includes(read.state));await s.f.runtime.chat.waitIdle();
 const done=await turn(s,tid);assert.equal(done.state,'completed');
 const resolved=done.events.find(e=>e.type==='approval_resolved');assert.equal(resolved.data.decision,'expired');
 const result=done.events.find(e=>e.type==='tool_result');assert.equal(result.data.status,'denied');assert.equal(result.data.result.reason,'approval_expired');assert.ok(seqOK(done.events));
 const late=await decide(s,tid,req.interrupt_id,{operation_id:randomUUID(),decision:'approve',args_hash:req.args_hash});assert.equal(late.status,409);assert.equal((await late.json()).error.code,'approval_expired');
 assert.equal(s.executed.length,0);
});

test('cancel ends a suspended turn: pending approvals resolve as cancelled, then turn_failed cancelled; busy until then',async()=>{
 const s=await setup(),{tid,events}=await send(s),req=events.at(-2).data;
 const c=(await s.f.json(await s.f.req(s.path))).conversation;
 const busy=await s.f.req(s.path+'/turns',{turn_id:randomUUID(),expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'另一条'},context:[]});assert.equal(busy.status,409);assert.equal((await busy.json()).error.code,'conversation_busy');
 const r=await (await s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/cancel',{method:'POST',headers:{Authorization:'Bearer memory-fixture'},body:'{}'}))).json();
 assert.deepEqual(r.cancel,{turn_id:tid,state:'failed',cancelled:true,already_terminal:false});
 const t=await turn(s,tid);assert.deepEqual(t.events.slice(-2).map(e=>[e.type,e.data.decision??e.data.code]),[['approval_resolved','cancelled'],['turn_failed','cancelled']]);
 const late=await decide(s,tid,req.interrupt_id,{operation_id:randomUUID(),decision:'approve',args_hash:req.args_hash});assert.equal(late.status,409);assert.equal(s.executed.length,0);
});

test('a client without the approval contract never receives approval-gated tools; read-only gated tools stay available',async()=>{
 const s=await setup(),{events}=await send(s,{approval:false});
 assert.ok(!s.probe.tools[0].includes('create_task')&&!s.probe.tools[0].includes('create_reminder'));assert.ok(s.probe.tools[0].includes('list_tasks'));
 assert.equal(events.at(-1).type,'turn_completed');assert.ok(!events.some(e=>e.type==='approval_requested'));
 const bad=await s.f.runtime.api(new Request(H+s.path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Approval-Contract':'v0'},body:JSON.stringify({turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'x'},context:[]})}));
 assert.equal(bad.status,422);
});
