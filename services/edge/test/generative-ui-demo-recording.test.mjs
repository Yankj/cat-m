// Records / verifies the catpaw.ui.v1 demo SSE (docs/fixtures/catpaw-ui-demo.jsonl) against the REAL edge chat service.
// Re-record: CATPAW_RECORD_UI_DEMO=1 deno test --allow-write ... test/generative-ui-demo-recording.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {APPROVAL_CONTRACT} from '../supabase/functions/_shared/core/src/approval.mjs';
import {UI_CONTRACT,RENDER_UI,createRenderUITool} from '../supabase/functions/_shared/core/src/generative-ui.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid',RA='2026-10-16T00:10:00Z';
const FILE=new URL('../docs/fixtures/catpaw-ui-demo.jsonl',import.meta.url);
const P1={block:{id:'demo-progress',kind:'progress',title:'整理今天',steps:[{id:'read',label:'读取日程',state:'running'},{id:'plan',label:'排优先级',state:'pending'}]}};
export const DEMO_CALLS=[
 {block:{id:'demo-card',kind:'card',title:'今天',body:'**三件事**：写周报、买菜、跑步'}},
 {block:{id:'demo-list',kind:'list',title:'待办',items:[{id:'a',label:'写周报'},{id:'b',label:'买菜'},{id:'c',label:'跑步'}]}},
 P1,
 {block:{...P1.block,steps:[{id:'read',label:'读取日程',state:'done'},{id:'plan',label:'排优先级',state:'running'}]}},
 {block:{id:'demo-choices',kind:'choices',title:'先做哪件？',selection:'single',allowOther:true,items:[{id:'a',label:'写周报'},{id:'b',label:'买菜'}]}},
 {block:{id:'demo-form',kind:'form',title:'跑步计划',fields:[{id:'km',label:'公里',type:'number',required:true},{id:'at',label:'时间',type:'time'}]}},
 {block:{id:'demo-confirm',kind:'confirm',title:'创建提醒？',body:'18:30 提醒跑步',actions:[{id:'approve',label:'创建'},{id:'deny',label:'取消'}]}},
 {block:{id:'demo-sheet',kind:'sheet',title:'弹窗',body:'这是一个原生弹窗（不是代码）',actions:[{id:'ok',label:'好的'}]}}
];
const ROUNDS=[[0,1,2,4],[3,5,6,7]];
export const DEMO_RESPONSES={
 'demo-choices':{decision:'submit',response:{type:'ui.response',blockId:'demo-choices',actionId:null,values:{},selected:['a'],respondedAt:RA}},
 'demo-form':{decision:'submit',response:{type:'ui.response',blockId:'demo-form',actionId:null,values:{km:5,at:'18:30'},selected:[],respondedAt:RA}},
 'demo-confirm':{decision:'submit',response:{type:'ui.response',blockId:'demo-confirm',actionId:'approve',values:{},selected:[],respondedAt:RA}},
 'demo-sheet':{decision:'dismiss'}
};
const sse=async r=>(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));
function normalize(events){
 const ids=new Map(),uuid=/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;
 const text=JSON.stringify(events).replace(uuid,u=>{if(!ids.has(u))ids.set(u,`00000000-0000-4000-8000-${String(ids.size+1).padStart(12,'0')}`);return ids.get(u);})
  .replace(/"(expiresAt|respondedAt|[a-z_]*_at|at)":"\d{4}-[^"]+"/g,'"$1":"2026-10-16T00:20:00.000Z"')
  .replace(/"(argsHash|args_hash|request_hash|final_text_hash|hash)":"[0-9a-f]{64}"/g,(m,k)=>`"${k}":"${'0'.repeat(64)}"`)
  .replace(/"call-(\d+)-[0-9a-f]{8}"/g,'"call-demo-$1"');
 return JSON.parse(text);
}
async function record(){
 let n=0;const f=await fixture({stream:async function*(input){
  // The server caps a turn at 3 model rounds and 4 tool calls per round: round 1 = card/list/progress/choices, round 2 = progress update + form/confirm/sheet, round 3 = text.
  const round=ROUNDS[n++];if(round){for(const i of round)yield {type:'tool_call',id:'call-'+i+'-'+randomUUID().slice(0,8),name:RENDER_UI,arguments:DEMO_CALLS[i]};yield {type:'done',finish_reason:'tool_calls'};return;}
  yield {type:'text_delta',text:'都安排好了。'};yield {type:'done',finish_reason:'stop'};}});
 f.runtime.chat.facade.gatedChatTools=new Map([[RENDER_UI,createRenderUITool()]]);
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const path=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`,c=(await f.json(await f.req(path))).conversation,tid=randomUUID();
 const auth={Authorization:'Bearer memory-fixture','Content-Type':'application/json'};
 let events=await sse(await f.runtime.api(new Request(H+path+'/turns',{method:'POST',headers:{...auth,'X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,'X-Catpaw-UI-Contract':UI_CONTRACT},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'帮我安排今天，给我弹个窗'},context:[]})})));
 const all=[{direction:'server',events}];
 for(let i=0;i<8&&!all.flatMap(x=>x.events??[]).some(e=>e.type==='turn_completed'||e.type==='turn_failed');i++){
  const done=new Set(all.filter(x=>x.direction==='client').map(x=>x.blockId)),block=all.flatMap(x=>x.events??[]).find(e=>e.type==='ui.block'&&e.data.interruptId&&!done.has(e.data.id)).data,answer=DEMO_RESPONSES[block.id];
  await f.runtime.chat.waitIdle();const body={operation_id:randomUUID(),args_hash:block.argsHash,...answer},last=events.at(-1).sequence;
  all.push({direction:'client',blockId:block.id,method:'POST',path:`…/turns/{turn_id}/interrupts/${block.interruptId}/decision?after_sequence=${last}`,body});
  const r=await f.runtime.api(new Request(H+path+'/turns/'+tid+'/interrupts/'+block.interruptId+'/decision?after_sequence='+last,{method:'POST',headers:auth,body:JSON.stringify(body)}));
  if(r.status!==200)throw Error(block.id+' '+r.status+' '+await r.text());events=await sse(r);all.push({direction:'server',events});
 }
 await f.runtime.chat.waitIdle();return all;
}
test('demo recording: real server emits every ui kind, update, resolve and resumes after each ui.response',async()=>{
 const steps=normalize(await record()),events=steps.filter(s=>s.direction==='server').flatMap(s=>s.events),types=events.map(e=>e.type);
 assert.deepEqual(new Set(events.filter(e=>e.type==='ui.block').map(e=>e.data.kind)),new Set(['card','list','progress','choices','form','confirm','sheet']));
 const first=steps[0].events.map(e=>e.type);assert.deepEqual(first.slice(-5),['ui.block','ui.block','ui.block','ui.block','turn_suspended'],'display blocks of a suspended round are shown before the suspend');
 assert.equal(steps.filter(s=>s.direction==='client').length,4,'partial decisions (other interrupts still pending) are accepted');
 assert.ok(types.includes('ui.block.update'));assert.equal(types.filter(t=>t==='ui.block.resolve').length,4);assert.equal(types.at(-1),'turn_completed');
 const text=steps.map(s=>JSON.stringify(s)).join('\n')+'\n';
 if(Deno.env.get('CATPAW_RECORD_UI_DEMO')==='1'){await Deno.writeTextFile(FILE,text);return;}
 assert.deepEqual((await Deno.readTextFile(FILE)).trim().split('\n').map(l=>JSON.parse(l)),steps,'recording drifted: re-record with CATPAW_RECORD_UI_DEMO=1');
});
