import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {OpenRouterProvider} from '../supabase/functions/_shared/core/src/openrouter-provider.mjs';
import {ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const latch=()=>{let resolve;return {promise:new Promise(r=>{resolve=r;}),resolve:(...a)=>resolve(...a)};};
const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-unused-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};
function frames(parts,{delegate=false}={}){
 const data=parts.map(text=>({choices:[{index:0,delta:{content:text}}]}));
 if(delegate)data.push({choices:[{index:0,delta:{tool_calls:[{index:0,id:randomUUID(),type:'function',function:{name:'delegate_task',arguments:JSON.stringify({title:'Offline task',goal:'Produce a synthetic report',requirements:'Synthetic fixture only',stop_conditions:['Save then finish']})}}]}}]});
 data.push({id:'offline-response',model:'apodex/apodex-1.1-mini:free',provider:'Novita',usage:{cost:0},choices:[{index:0,delta:{},finish_reason:delegate?'tool_calls':'stop'}]});
 return [...data.map(x=>'data: '+JSON.stringify(x)+'\n\n'),'data: [DONE]\n\n'];
}
async function fixture({parts=['O','F','F','L','I','N','E'],preludeMs=0,latePreludeMs=0,writeMs=0,holdTerminal=null,holdWrite=null,delegate=false,transportTimeoutMs=20000}={}){
 const repository=new TestRepository(),config=readConfig(k=>values[k]),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
 let clock=Date.now(),requests=0,readCount=0,deltaWrites=0;const retained=[],textSeen=latch(),terminalSeen=latch(),writerSeen=latch();
 const provider=new OpenRouterProvider({model:config.route.model,secret:'offline-unused-key',liveNetworkEnabled:true,privateRoutingPolicy:config.route.routing_policy,beforeStream:async()=>{clock+=latePreludeMs;},expectedProviderDisplay:'Novita',timeoutMs:transportTimeoutMs,fetchImpl:async(_url,{signal})=>{
  requests++;const chunks=frames(parts,{delegate});let stopped=false;
  const body=new ReadableStream({start(controller){
   signal.addEventListener('abort',()=>{stopped=true;try{controller.error(new DOMException('Offline aborted','AbortError'));}catch{}},{once:true});
   (async()=>{for(let i=0;i<chunks.length;i++){if(holdTerminal&&i===parts.length)await holdTerminal.promise;if(stopped)return;controller.enqueue(new TextEncoder().encode(chunks[i]));await Promise.resolve();}if(!stopped)controller.close();})().catch(e=>{if(!stopped)controller.error(e);});
  }});
  return new Response(body,{headers:{'Content-Type':'text/event-stream'}});
 }});
 const stream=provider.stream.bind(provider);provider.stream=async function*(input){for await(const e of stream(input)){if(e.type==='text_delta'){readCount++;if(readCount===parts.length)textSeen.resolve();}if(e.type==='done')terminalSeen.resolve();yield e;}};
 const sourceChecker=async(tx,source)=>{const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);if(row?.subject_id!==source.subject_id||row.state!=='active')throw new ApiError(409,'grant_conflict');};
 const runtime=await createCloudRuntime({repository,config,provider,autoKick:false,sourceChecker,authenticate:()=>principal,verifyToken:async()=>({iss:principal.issuer,sub:principal.subject_id,session_id:principal.session_id,exp:9999999999}),retain:p=>retained.push(p)});
 runtime.chat.clockNow=()=>clock;const renew=runtime.chat.integration.renew;runtime.chat.integration.renew=async owner=>{clock+=preludeMs;return renew(owner);};
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);
 await repository.transaction(async tx=>{await tx.put(membershipOwner(principal.issuer),'scope-memberships',{id:principal.subject_id,scopes:[scope]});await tx.put(membershipOwner(principal.issuer),'app-sessions',{id:principal.session_id,subject_id:principal.subject_id,state:'active',expires_at:9999999999});});
 const original=repository.transaction.bind(repository);
 repository.transaction=(...args)=>{
  const callback=args.pop();return original(...args,async tx=>{const put=tx.put.bind(tx);tx.put=async(owner,kind,value)=>{
   if(kind==='native-chat-turns'&&value.events?.at(-1)?.type==='text_delta'){deltaWrites++;writerSeen.resolve();if(holdWrite&&deltaWrites===1)await holdWrite.promise;clock+=writeMs;}
   return put(owner,kind,value);
  };return callback(tx);});
 };
 const cid=randomUUID(),base=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,input={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'Reply using this synthetic offline fixture only'},context:[]};
 const req=(path,body)=>runtime.api(new Request('https://offline.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer offline','Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}}));
 assert.equal((await req(base,{conversation_id:cid})).status,201);assert.equal((await req(`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash})).status,200);
 const start=()=>runtime.chat.startTurn('Bearer offline',scope.scope_id,cid,input),read=()=>runtime.chat.readTurn('Bearer offline',scope.scope_id,cid,input.turn_id);
 return {runtime,repository,scope,cid,base,input,req,start,read,retained,textSeen,terminalSeen,writerSeen,get requests(){return requests;},get deltaWrites(){return deltaWrites;},get readCount(){return readCount;},advance:ms=>{clock+=ms;}};
}
const deltas=t=>t.events.filter(e=>e.type==='text_delta').map(e=>e.data.text).join('');

test('slow pre-dispatch work and tiny tokens finish with one ordered final text flush',async()=>{
 const parts=['S','Y','N','T','H','E','T','I','C'],f=await fixture({parts,preludeMs:12000,writeMs:3000});await f.start();await f.runtime.chat.waitIdle();const t=await f.read();
 assert.equal(t.state,'completed');assert.equal(deltas(t),parts.join(''));assert.equal(f.requests,1);assert.equal(f.deltaWrites,1);assert.equal(t.events.at(-1).type,'turn_completed');assert.deepEqual(t.events.map(e=>e.sequence),[1,2,3]);await f.runtime.worker.stop();
});
test('remaining provider window is rechecked after slow dispatch admission; no model fetch starts',async()=>{
 const f=await fixture({preludeMs:30000});await f.start();await f.runtime.chat.waitIdle();const t=await f.read();assert.equal(t.state,'outcome_unknown');assert.equal(t.error.code,'chat_dispatch_budget_exhausted');assert.equal(f.requests,0);await f.runtime.worker.stop();
});
test('slow first text transaction does not block provider terminal; serialized final flush preserves all tokens',async()=>{
 const gate=latch(),parts=Array.from({length:900},(_,i)=>String(i%10)),f=await fixture({parts,holdWrite:gate});await f.start();await f.writerSeen.promise;await f.terminalSeen.promise;
 assert.equal(f.readCount,parts.length);gate.resolve();await f.runtime.chat.waitIdle();const t=await f.read();assert.equal(t.state,'completed');assert.equal(deltas(t),parts.join(''));assert.equal(f.deltaWrites,2);assert.deepEqual(t.events.map(e=>e.sequence),[1,2,3,4]);await f.runtime.worker.stop();
});
test('normal validated tool finish flushes text before tool call/result and preserves task binding',async()=>{
 const f=await fixture({parts:['A','B','C'],delegate:true});await f.start();await f.runtime.chat.waitIdle();const t=await f.read();assert.equal(t.state,'completed');assert.equal(t.task_bindings.length,1);assert.deepEqual(t.events.map(e=>e.type),['turn_started','text_delta','tool_call','tool_result','turn_completed']);await f.runtime.worker.stop();
});
test('deadline during a slow text write rolls back late text and persists an explicit unknown without replay',async()=>{
 const gate=latch(),f=await fixture({parts:Array(600).fill('x'),holdWrite:gate});await f.start();await f.writerSeen.promise;await f.terminalSeen.promise;f.advance(50001);gate.resolve();await f.runtime.chat.waitIdle();const t=await f.read();
 assert.equal(t.state,'outcome_unknown');assert.equal(t.error.code,'chat_deadline_exceeded');assert.equal(deltas(t),'');assert.equal(t.task_bindings.length,0);
 const replay=await f.req(`${f.base}/${f.cid}/turns`,f.input);assert.equal((await replay.json()).replayed,true);assert.equal(f.requests,1);await f.runtime.worker.stop();
});
test('logout discards buffered text; delayed upstream terminal cannot commit a reply or task',async()=>{
 const gate=latch(),f=await fixture({parts:['l','a','t','e'],holdTerminal:gate});await f.start();await f.textSeen.promise;
 assert.equal((await f.req('/catpaw/account/v1/logout',{})).status,200);gate.resolve();await f.runtime.chat.waitIdle();
 const owner=f.runtime.facade.owner(f.scope),t=await f.repository.transaction(tx=>tx.get(owner,'native-chat-turns',f.input.turn_id));assert.equal(t.state,'failed');assert.equal(t.error.code,'app_session_revoked');assert.equal(deltas(t),'');assert.equal(t.task_bindings.length,0);assert.equal(f.requests,1);await f.runtime.worker.stop();
});
test('SSE detach and reconnect use the same durable turn; duplicate POST and snapshot do not resend',async()=>{
 const gate=latch(),f=await fixture({parts:['R','E','S','T','O','R','E'],holdTerminal:gate});const response=await f.req(`${f.base}/${f.cid}/turns`,f.input);assert.equal(response.status,200);await response.body.getReader().cancel();await f.textSeen.promise;
 const before=await f.read();assert.equal(before.state,'running');const replay=await f.req(`${f.base}/${f.cid}/turns`,f.input);assert.equal((await replay.json()).replayed,true);assert.equal(f.requests,1);
 gate.resolve();await Promise.all(f.retained);const t=await f.read();assert.equal(t.state,'completed');assert.equal(deltas(t),'RESTORE');assert.equal(f.requests,1);await f.runtime.worker.stop();
});
test('provider timeout has its own safe unknown cause and never automatically retries the transport',async()=>{
 const gate=latch(),f=await fixture({holdTerminal:gate,transportTimeoutMs:20});await f.start();await f.runtime.chat.waitIdle();gate.resolve();const t=await f.read();assert.equal(t.state,'outcome_unknown');assert.equal(t.error.code,'provider_timeout');assert.equal(f.requests,1);assert.equal(t.task_bindings.length,0);await f.runtime.worker.stop();
});
test('last preflight await must still leave the provider window; transport is not started after it expires',async()=>{
 const f=await fixture({latePreludeMs:30000});await f.start();await f.runtime.chat.waitIdle();const t=await f.read();assert.equal(t.state,'outcome_unknown');assert.equal(t.error.code,'chat_dispatch_budget_exhausted');assert.equal(f.requests,0);await f.runtime.worker.stop();
});
test('periodic coalesced prefix is durable and readable while the upstream terminal is still pending',async()=>{
 const gate=latch(),f=await fixture({parts:['P','A','R','T','I','A','L'],holdTerminal:gate});await f.start();await f.writerSeen.promise;const prefix=await f.read();assert.equal(prefix.state,'running');assert.equal(deltas(prefix),'PARTIAL');assert.equal(f.deltaWrites,1);
 gate.resolve();await f.runtime.chat.waitIdle();const t=await f.read();assert.equal(t.state,'completed');assert.equal(deltas(t),'PARTIAL');assert.equal(f.requests,1);await f.runtime.worker.stop();
});
test('logout queued behind an in-flight write prevents every later batch and completion after logout commits',async()=>{
 const gate=latch(),f=await fixture({parts:Array(600).fill('x'),holdWrite:gate});await f.start();await f.writerSeen.promise;await f.terminalSeen.promise;const logout=f.req('/catpaw/account/v1/logout',{});await Promise.resolve();gate.resolve();assert.equal((await logout).status,200);
 const owner=f.runtime.facade.owner(f.scope),row=()=>f.repository.transaction(tx=>tx.get(owner,'native-chat-turns',f.input.turn_id)),after=await row();await f.runtime.chat.waitIdle();assert.deepEqual(await row(),after);assert.equal(after.state,'failed');assert.equal(after.error.code,'app_session_revoked');assert.equal(after.task_bindings.length,0);assert.equal(f.requests,1);await f.runtime.worker.stop();
});
