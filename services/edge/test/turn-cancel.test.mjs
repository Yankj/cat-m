import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
// A slow model: streams one chunk every 20ms for ~4s and records whether it was aborted.
function slowModel(){
 const probe={aborted:false,chunksAfterAbort:0,calls:0};
 probe.stream=async function*(input){probe.calls++;
  yield {type:'thinking_delta',text:'thinking'};
  for(let i=0;i<200;i++){await sleep(20);if(input.signal?.aborted){probe.aborted=true;throw input.signal.reason??Error('aborted');}yield {type:'text_delta',text:`chunk${i} `};}
  yield {type:'done',finish_reason:'stop'};};
 return probe;
}
async function start(f){
 const {scope,config,req,json}=f,cid=await f.newConversation();
 await json(await req(`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash}));
 const path=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations/${cid}`,c=(await json(await req(path))).conversation,tid=randomUUID();
 const response=await f.runtime.api(new Request('https://memory-test.example.invalid'+path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'long answer please'},context:[]})}));
 assert.equal(response.status,200);
 const events=(async()=>(await response.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6))))();
 return {path,tid,events};
}
const cancel=(f,path,tid,body='{}')=>f.runtime.api(new Request('https://memory-test.example.invalid'+path+'/turns/'+tid+'/cancel',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body}));
const turn=async(f,path,tid)=>(await f.json(await f.req(path+'/turns/'+tid))).turn;
async function waitText(f,path,tid){for(let i=0;i<200;i++){const t=await turn(f,path,tid);if(t.events.some(e=>e.type==='text_delta'))return t;await sleep(20);}throw Error('no text');}

for(const crossInstance of [false,true])test(`cancel mid-stream ends the turn with turn_failed cancelled and stops the model (${crossInstance?'cross-instance poll':'same instance'})`,async()=>{
 const model=slowModel(),f=await fixture({stream:model.stream});f.runtime.chat.cancelPollMs=20;
 const {path,tid,events}=await start(f);
 const before=await waitText(f,path,tid),kept=before.events.filter(e=>e.type==='text_delta').map(e=>e.data.text).join('');
 // Another instance holds the AbortController: only the durable marker can reach it.
 if(crossInstance)for(const [key,entry] of f.runtime.chat.active)if(key.endsWith(tid))f.runtime.chat.active.set(key,{...entry,controller:new AbortController()});
 const r=await cancel(f,path,tid);assert.equal(r.status,200);const body=await r.json();
 assert.deepEqual(body.cancel,{turn_id:tid,state:'failed',cancelled:true,already_terminal:false});
 const stream=await events;assert.equal(stream.at(-1).type,'turn_failed');assert.equal(stream.at(-1).data.code,'cancelled');
 await f.runtime.chat.waitIdle();
 assert.equal(model.aborted,true,'model call aborted');
 const after=await turn(f,path,tid);assert.equal(after.state,'failed');assert.equal(after.error.code,'cancelled');
 assert.equal(after.events.at(-1).type,'turn_failed','no writes after the cancel marker');
 const text=after.events.filter(e=>e.type==='text_delta').map(e=>e.data.text).join('');
 assert.ok(text.startsWith(kept)&&text.length>0,'generated content is kept');
 assert.equal(after.error.partial_text_length,text.length);
 // Idempotent repeat.
 const again=await (await cancel(f,path,tid,'')).json();assert.deepEqual(again.cancel,{turn_id:tid,state:'failed',cancelled:true,already_terminal:true});
 assert.equal((await turn(f,path,tid)).events.length,after.events.length);
});
test('cancel after completion is a no-op; foreign or unknown turns are 404; body must be empty',async()=>{
 const f=await fixture({stream:async function*(){yield {type:'text_delta',text:'done'};yield {type:'done',finish_reason:'stop'};}});
 const {path,tid,events}=await start(f);await events;await f.runtime.chat.waitIdle();
 const r=await (await cancel(f,path,tid)).json();assert.deepEqual(r.cancel,{turn_id:tid,state:'completed',cancelled:false,already_terminal:true});
 assert.equal((await cancel(f,path,randomUUID())).status,404);
 assert.equal((await cancel(f,path,tid,'{"x":1}')).status,422);
});
