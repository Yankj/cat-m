import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {APPROVAL_CONTRACT} from '../supabase/functions/_shared/core/src/approval.mjs';
import {UI_CONTRACT,RENDER_UI,createRenderUITool,validateBlock,validateResponse} from '../supabase/functions/_shared/core/src/generative-ui.mjs';
import {readFeatureGate,readAllowlist,featureAllows} from '../supabase/functions/_shared/config.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
const RA='2026-10-16T00:10:00Z';
const BLOCKS={
 card:{block:{id:'today',kind:'card',title:'今天',body:'**三件事**'}},
 list:{block:{id:'l1',kind:'list',items:[{id:'a',label:'喝水'},{id:'b',label:'散步'}]}},
 progress:{block:{id:'p1',kind:'progress',title:'整理',steps:[{id:'s1',label:'读取',state:'running'},{id:'s2',label:'写入',state:'pending'}]}},
 choices:{block:{id:'c1',kind:'choices',title:'选一个',selection:'single',allowOther:true,items:[{id:'a',label:'A'},{id:'b',label:'B'}]}},
 form:{block:{id:'f1',kind:'form',title:'登记',fields:[{id:'name',label:'名字',type:'text',required:true},{id:'age',label:'年龄',type:'number'},{id:'day',label:'日期',type:'date'},{id:'at',label:'时间',type:'time'},{id:'ok',label:'同意',type:'toggle'},{id:'size',label:'尺码',type:'select',options:['S','M']},{id:'n',label:'数量',type:'stepper',default:1}]}},
 confirm:{block:{id:'k1',kind:'confirm',title:'删除？',body:'不可恢复',actions:[{id:'approve',label:'删除',style:'destructive'},{id:'deny',label:'取消'}]}},
 sheet:{block:{id:'s1',kind:'sheet',title:'弹窗',body:'你好',actions:[{id:'ok',label:'好的'}]}}
};
const RESP={
 choices:{type:'ui.response',blockId:'c1',actionId:null,values:{},selected:['b'],respondedAt:RA},
 form:{type:'ui.response',blockId:'f1',actionId:null,values:{name:'小明',age:30,at:'09:30',size:'M',n:2},selected:[],respondedAt:RA},
 confirm:{type:'ui.response',blockId:'k1',actionId:'approve',values:{},selected:[],respondedAt:RA},
 sheet:{type:'ui.response',blockId:'s1',actionId:'ok',values:{},selected:[],respondedAt:RA}
};
function model(probe){
 return async function*(input){probe.tools.push(input.tools.map(t=>t.function.name));probe.prompts.push(input.system_prompt);
  const last=input.messages.at(-1);
  if(last.role==='tool'){probe.results.push(JSON.parse(last.content));yield {type:'text_delta',text:'收到'};yield {type:'done',finish_reason:'stop'};return;}
  if(!input.tools.some(t=>t.function.name===RENDER_UI)){yield {type:'text_delta',text:'<div>popup</div>'};yield {type:'done',finish_reason:'stop'};return;}
  yield {type:'tool_call',id:'call-'+randomUUID(),name:RENDER_UI,arguments:probe.block};yield {type:'done',finish_reason:'tool_calls'};};
}
async function setup(block,{allow=()=>true}={}){
 const probe={tools:[],prompts:[],results:[],block},f=await fixture({stream:model(probe)});f.runtime.chat.facade.gatedChatTools=new Map([[RENDER_UI,createRenderUITool({allow})]]);
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 return {f,probe,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
}
const sse=async r=>(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));
async function send(s,{ui=UI_CONTRACT,approval=true}={}){
 const c=(await s.f.json(await s.f.req(s.path))).conversation,tid=randomUUID();
 const r=await s.f.runtime.api(new Request(H+s.path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json',...approval?{'X-Catpaw-Approval-Contract':APPROVAL_CONTRACT}:{},...ui?{'X-Catpaw-UI-Contract':ui}:{}},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'给我弹个窗'},context:[]})}));
 if(r.status!==200)return {status:r.status,body:await r.json(),tid};
 const events=await sse(r);await s.f.runtime.chat.waitIdle();return {status:200,tid,events};
}
const decide=(s,tid,iid,body)=>s.f.runtime.api(new Request(H+s.path+'/turns/'+tid+'/interrupts/'+iid+'/decision',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify(body)}));
const turn=async(s,tid)=>(await s.f.json(await s.f.req(s.path+'/turns/'+tid))).turn;

test('schema: every kind validates ({block} or bare); bad blocks and bad responses are rejected',()=>{
 for(const b of Object.values(BLOCKS))assert.equal(validateBlock(b).schemaVersion,1);
 assert.equal(validateBlock(BLOCKS.card.block).id,'today');
 assert.throws(()=>validateBlock({block:{id:'x',kind:'popup'}}));assert.throws(()=>validateBlock({block:{id:'x',kind:'choices',items:[]}}),/invalid_tool_arguments/);
 assert.throws(()=>validateBlock({block:{id:'x',kind:'card',image:'http://x/y.png'}}));assert.throws(()=>validateBlock({block:{id:'x',kind:'card',schemaVersion:2}}));
 assert.throws(()=>validateBlock({block:{id:'x',kind:'card',title:'x'.repeat(61)}}));assert.throws(()=>validateBlock({block:{id:'x',kind:'progress'}}));
 assert.throws(()=>validateBlock({block:{id:'x',kind:'card',steps:[]}}));assert.throws(()=>validateBlock({block:{id:'x',kind:'card',content:'form'}}));
 const choices=validateBlock(BLOCKS.choices),form=validateBlock(BLOCKS.form),confirm=validateBlock(BLOCKS.confirm);
 assert.ok(validateResponse(choices,RESP.choices));assert.throws(()=>validateResponse(choices,{...RESP.choices,selected:['a','b']}));
 assert.ok(validateResponse(choices,{...RESP.choices,selected:[],other:'C',values:{other:'C'}}));assert.throws(()=>validateResponse(choices,{...RESP.choices,blockId:'zz'}));
 assert.throws(()=>validateResponse(form,{...RESP.form,values:{age:20}}),/ui_response_invalid/);assert.throws(()=>validateResponse(form,{...RESP.form,values:{name:'x',at:'25:00'}}));
 assert.throws(()=>validateResponse(form,{...RESP.form,values:{name:'x',size:'XL'}}));assert.throws(()=>validateResponse(form,{...RESP.form,extra:1}));
 assert.throws(()=>validateResponse(confirm,{...RESP.confirm,actionId:null}));assert.throws(()=>validateResponse(confirm,{...RESP.confirm,respondedAt:'yesterday'}));
});
test('negotiation: no UI header, no approval header or gate closed → render_ui not offered; wrong version 422',async()=>{
 let s=await setup(BLOCKS.card);await send(s,{ui:null});assert.ok(!s.probe.tools.at(-1).includes(RENDER_UI));
 s=await setup(BLOCKS.card);await send(s,{approval:false});assert.ok(!s.probe.tools.at(-1).includes(RENDER_UI));
 s=await setup(BLOCKS.card,{allow:()=>false});await send(s);assert.ok(!s.probe.tools.at(-1).includes(RENDER_UI));
 s=await setup(BLOCKS.card);const bad=await send(s,{ui:'catpaw.ui.v0'});assert.equal(bad.status,422);assert.equal(bad.body.error.code,'ui_contract_invalid');
});
test('card is display only: ui.block without interrupt, tool result shown, turn completes; prompt steers away from code',async()=>{
 const s=await setup(BLOCKS.card),{events}=await send(s);
 const block=events.find(e=>e.type==='ui.block');assert.equal(block.data.kind,'card');assert.equal(block.data.interruptId,undefined);assert.equal(block.data.id,'today');assert.equal(block.data.schemaVersion,1);
 assert.ok(!events.some(e=>e.type==='turn_suspended'));assert.equal(events.at(-1).type,'turn_completed');assert.deepEqual(s.probe.results[0],{status:'shown'});
 assert.match(s.probe.prompts[0],/render_ui/);assert.match(s.probe.prompts[0],/不要输出 HTML\/SwiftUI\/JSON 代码/);
});
for(const kind of ['choices','form','confirm','sheet']){
 test(`${kind}: ui.block + turn_suspended; ui.response validates, resumes the same turn, ui.block.resolve`,async()=>{
  const response=RESP[kind],s=await setup(BLOCKS[kind]),{tid,events}=await send(s);
  const block=events.find(e=>e.type==='ui.block').data;assert.equal(block.kind,kind);assert.ok(block.interruptId&&block.argsHash&&block.expiresAt);
  assert.ok(!events.some(e=>e.type==='approval_requested'));assert.equal(events.at(-1).type,'turn_suspended');
  const snap=await turn(s,tid);assert.equal(snap.state,'awaiting_approval');assert.equal(snap.pending_approvals[0].kind,'ui');assert.equal(snap.pending_approvals[0].block.id,block.id);
  const op=randomUUID(),bad=await decide(s,tid,block.interruptId,{operation_id:randomUUID(),decision:'submit',args_hash:block.argsHash,response:{nope:1}});assert.equal(bad.status,422);
  const wrong=await decide(s,tid,block.interruptId,{operation_id:randomUUID(),decision:'approve',args_hash:block.argsHash});assert.equal(wrong.status,422);
  const ok=await decide(s,tid,block.interruptId,{operation_id:op,decision:'submit',args_hash:block.argsHash,response});assert.equal(ok.status,200);
  const resumed=await sse(ok);await s.f.runtime.chat.waitIdle();
  const resolved=resumed.find(e=>e.type==='approval_resolved');assert.equal(resolved.data.decision,'submitted');assert.equal(resolved.data.kind,'ui');
  assert.deepEqual(resumed.find(e=>e.type==='ui.block.resolve').data,{id:block.id,status:'submitted'});
  assert.ok(resumed.some(e=>e.type==='turn_completed'));assert.deepEqual(s.probe.results.at(-1),{status:'submitted',response});
  const replay=await decide(s,tid,block.interruptId,{operation_id:op,decision:'submit',args_hash:block.argsHash,response});assert.equal(replay.status,200);await replay.text();
  const conflict=await decide(s,tid,block.interruptId,{operation_id:op,decision:'dismiss',args_hash:block.argsHash});assert.equal(conflict.status,409);
  const late=await decide(s,tid,block.interruptId,{operation_id:randomUUID(),decision:'dismiss',args_hash:block.argsHash});assert.equal(late.status,409);
 });
}
test('ui.error: report_error resumes with {status:error} so the model can fix the block',async()=>{
 const s=await setup(BLOCKS.choices),{tid,events}=await send(s),block=events.find(e=>e.type==='ui.block').data;
 const r=await decide(s,tid,block.interruptId,{operation_id:randomUUID(),decision:'report_error',args_hash:block.argsHash,response:{type:'ui.error',blockId:'c1',code:'too_long',path:'items[0].label'}});
 assert.equal(r.status,200);await r.text();await s.f.runtime.chat.waitIdle();assert.equal(s.probe.results.at(-1).status,'error');assert.equal(s.probe.results.at(-1).error.code,'too_long');
});
test('progress: display only; same block id in a later call of the turn becomes ui.block.update',async()=>{
 const probe={tools:[],prompts:[],results:[]},f=await fixture({stream:async function*(input){probe.tools.push(1);const last=input.messages.at(-1);
  const tools=input.messages.filter(m=>m.role==='tool').length;
  if(tools===0){yield {type:'tool_call',id:'call-'+randomUUID(),name:RENDER_UI,arguments:BLOCKS.progress};yield {type:'done',finish_reason:'tool_calls'};return;}
  if(tools===1){yield {type:'tool_call',id:'call-'+randomUUID(),name:RENDER_UI,arguments:{block:{...BLOCKS.progress.block,steps:[{id:'s1',label:'读取',state:'done'},{id:'s2',label:'写入',state:'running'}]}}};yield {type:'done',finish_reason:'tool_calls'};return;}
  probe.results.push(JSON.parse(last.content));yield {type:'text_delta',text:'好了'};yield {type:'done',finish_reason:'stop'};}});
 f.runtime.chat.facade.gatedChatTools=new Map([[RENDER_UI,createRenderUITool()]]);
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const s={f,probe,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`},{events}=await send(s);
 assert.equal(events.filter(e=>e.type==='ui.block').length,1);const update=events.find(e=>e.type==='ui.block.update').data;
 assert.equal(update.id,'p1');assert.equal(update.steps[0].state,'done');assert.equal(update.kind,undefined);assert.ok(!events.some(e=>e.type==='turn_suspended'));
 assert.deepEqual(probe.results.at(-1),{status:'shown'});
});
test('dismiss resumes with {status:dismissed}; expiry resumes with {status:expired}',async()=>{
 let s=await setup(BLOCKS.confirm),{tid,events}=await send(s);let block=events.find(e=>e.type==='ui.block').data;
 const r=await decide(s,tid,block.interruptId,{operation_id:randomUUID(),decision:'dismiss',args_hash:block.argsHash});assert.equal(r.status,200);await r.text();await s.f.runtime.chat.waitIdle();
 assert.deepEqual(s.probe.results.at(-1),{status:'dismissed'});
 s=await setup(BLOCKS.choices);({tid,events}=await send(s));block=events.find(e=>e.type==='ui.block').data;
 const base=Date.now();s.f.runtime.chat.now=()=>base+11*60*1000;
 const exp=await decide(s,tid,block.interruptId,{operation_id:randomUUID(),decision:'submit',args_hash:block.argsHash,response:{...RESP.choices,selected:['a']}});assert.equal(exp.status,409);
 await s.f.runtime.chat.waitIdle();assert.deepEqual(s.probe.results.at(-1),{status:'expired'});
});
test('feature gate parsing: on / allowlist / off',()=>{
 const id='11111111-2222-4333-8444-555555555555',list=readAllowlist(` ${id.toUpperCase()} ,bogus`);
 assert.equal(readFeatureGate('true'),'on');assert.equal(readFeatureGate('allowlist'),'allowlist');assert.equal(readFeatureGate(undefined),'off');
 assert.ok(featureAllows('allowlist',list,id));assert.ok(!featureAllows('allowlist',list,randomUUID()));assert.ok(featureAllows('on',list,null));assert.ok(!featureAllows('off',list,id));
});
test('ui.response actionId: omitted and null are both accepted without actions; confirm still requires one',()=>{
 const choices=validateBlock(BLOCKS.choices),form=validateBlock(BLOCKS.form),confirm=validateBlock(BLOCKS.confirm),sheet=validateBlock({block:{id:'s2',kind:'sheet',title:'登记',fields:[{id:'name',label:'名字',type:'text',required:true}]}});
 const {actionId:_c,...noAction}=RESP.choices,{actionId:_f,...formNoAction}=RESP.form;
 assert.ok(validateResponse(choices,noAction));assert.ok(validateResponse(choices,{...noAction,actionId:null}));
 assert.ok(validateResponse(form,formNoAction));assert.ok(validateResponse(form,{...formNoAction,actionId:null}));
 assert.ok(validateResponse(sheet,{type:'ui.response',blockId:'s2',values:{name:'x'},respondedAt:RA}),'values only; actionId and selected omitted');
 const {actionId:_k,...confirmNoAction}=RESP.confirm;
 assert.throws(()=>validateResponse(confirm,confirmNoAction),/ui_response_invalid/);assert.throws(()=>validateResponse(confirm,{...confirmNoAction,actionId:null}),/ui_response_invalid/);
 assert.throws(()=>validateResponse(choices,{...noAction,actionId:'nope'}),/ui_response_invalid/,'an actionId must name a real action');
});
