import nodeTest from 'node:test';
import {existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {Buffer} from 'node:buffer';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import process from 'node:process';
import {hash,clone} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
globalThis.Buffer??=Buffer;
globalThis.fetch=()=>{throw Error('next_review_external_network_forbidden');};
// Explicit public source package only: never import the maintenance W40 config
// into the frozen r7 data contract, and never read an account/vault/credential.
const override=process.env.CATPAW_REVIEW_NEXT_PACKAGE_ROOT;
const root=override?pathToFileURL(resolve(override)+'/'):new URL('../build/model-route-review-20261015/packages-r8/catpaw-api-v21/_shared/',import.meta.url);
// The frozen r8 package lives under the gitignored services/edge/build/ (made by scripts/prepare-model-route-review-next.py).
// It is a build-artifact test: on a clean checkout (and in CI, issue #81 quarantine) it is skipped, never run against
// the live source modules (they are intentionally newer than the frozen package and fail its byte-level assertions).
const present=existsSync(fileURLToPath(new URL('model-route-review-probe-next.mjs',root)));
const SKIP='frozen review package not built (services/edge/build/… or CATPAW_REVIEW_NEXT_PACKAGE_ROOT)';
const test=present?nodeTest:(name)=>nodeTest(name,{skip:SKIP},()=>{});
const load=async n=>present?await import(new URL(n,root)):{};
const next=await load('model-route-review-probe-next.mjs');
const old=await load('model-route-review-probe.mjs');
const {readConfig}=await load('config.mjs');
const {membershipOwner}=await load('authority.mjs');
const {GEMMA_PRIVATE_REVIEW_ID}=await load('model-route-review.mjs');
const {GEMMA_NEXT_REVIEW_PREFIX:P,GEMMA_NEXT_REVIEW_ID:ID,GEMMA_NEXT_REVIEW_CONVERSATION_ID:C,GEMMA_NEXT_REVIEW_TURN_ID:T,GEMMA_NEXT_REVIEW_MESSAGE_ID:M,GEMMA_NEXT_REVIEW_TEXT:TEXT,GEMMA_NEXT_REVIEW_ROUTE_HASH:RH}=next;
const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-unused-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};
function repositoryWithSQL(snapshot){
 const repository=new TestRepository(snapshot),transaction=repository.transaction.bind(repository);
 // Same finite read-only SQL stand-in as the frozen r7 package tests. Calls use
 // the real authority functions; this is not PostgreSQL/concurrency evidence.
 repository.transaction=fn=>transaction(tx=>{tx.connection={query:async(sql,args)=>{if(sql.startsWith('SELECT pg_advisory_xact_lock'))return {rows:[]};const kind=/kind='([^']+)'/.exec(sql)?.[1];assert.ok(['app-sessions','scope-memberships'].includes(kind),'unexpected SQL: '+sql);const row=await tx.get(args[0],kind,args[1]);return {rows:row?[{data:row}]:[]};}};return fn(tx);});return repository;
}
function providerResponse(outcome){
 if(outcome==='429')return new Response(JSON.stringify({error:{code:429,message:'Synthetic rate limit'}}),{status:429,headers:{'Content-Type':'application/json'}});
 let first={choices:[{index:0,delta:{content:'received.'}}]},finish='stop';
 if(outcome==='tool'){first={choices:[{index:0,delta:{tool_calls:[{index:0,id:'forbidden-tool',type:'function',function:{name:'delegate_task',arguments:'{}'}}]}}]};finish='tool_calls';}
 if(outcome==='early-provider')first.provider='Other Provider';if(outcome==='early-model')first.model='google/gemma-4-31b-it';if(outcome==='early-id')first.id='early-id';
 const last={id:'synthetic-final-id',model:'google/gemma-4-31b-it:free',provider:'Google AI Studio',usage:{cost:0},choices:[{index:0,delta:{},finish_reason:finish}]};
 return new Response([first,last].map(x=>'data: '+JSON.stringify(x)+'\n\n').join('')+(outcome==='incomplete'?'':'data: [DONE]\n\n'),{headers:{'Content-Type':'text/event-stream'}});
}
async function fixture({outcome='success',snapshot,repository,scope,actor}={}){
 const fresh=!snapshot&&!repository;scope??={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};actor??={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://next-probe.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
 repository??=repositoryWithSQL(snapshot);const calls=[],retained=[],config=readConfig(k=>values[k]);
 const f=await next.createGemmaNextShortTextProbeRuntime({repository,authenticate:auth=>{assert.equal(auth,'Bearer synthetic-probe');return actor;},config,retain:p=>retained.push(p),subjectID:actor.subject_id,scopeID:scope.scope_id,liveNetworkEnabled:true,fetchImpl:async(url,init)=>{calls.push({url,body:JSON.parse(init.body),redirect:init.redirect});return providerResponse(outcome);}});
 if(fresh)await f.runtime.foundation.bootstrapScope(actor,scope.scope_id);
 if(fresh)await repository.transaction(async tx=>{await tx.put(membershipOwner(actor.issuer),'app-sessions',{id:actor.session_id,subject_id:actor.subject_id,state:'active',expires_at:Math.floor(Date.now()/1000)+600});await tx.put(membershipOwner(actor.issuer),'scope-memberships',{id:actor.subject_id,state:'active',tokens_valid_after:1,revoked_session_ids:[],scopes:[scope]});});
 const env={CATPAW_REVIEW_PROBE_ID:GEMMA_PRIVATE_REVIEW_ID,CATPAW_REVIEW_PROBE_SUBJECT_ID:actor.subject_id,CATPAW_REVIEW_PROBE_SCOPE_ID:scope.scope_id},path=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,conversation=path+'/'+C,turn=conversation+'/turns/'+T,consent=`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${C}/model-consent`,receipt=`/catpaw/review/v1/scopes/${scope.scope_id}/turns/${T}/provider-receipt`;
 const wire=(path,body,headers={})=>new Request('https://next-probe.example.invalid/functions/v1/catpaw-api'+P+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer synthetic-probe','Content-Type':'application/json',...headers},...body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)}});
 const req=(path,body,headers)=>f.api(next.selectGemmaNextReviewRequest(wire(path,body,headers),k=>env[k],'api').request);
 const input={turn_id:T,expected_revision:1,expected_grant_epoch:1,message:{id:M,text:TEXT},context:[]},prepare=async()=>{assert.equal((await req(path,{conversation_id:C})).status,201);assert.equal((await req(consent,{decision:'allow',expected_revision:0,route_hash:RH})).status,200);};
 return {...f,repository,scope,actor,config,calls,retained,path,conversation,turn,consent,receipt,input,env,req,wire,prepare,drain:()=>Promise.all(retained),stop:()=>f.runtime.worker.stop(),owner:()=>f.runtime.facade.owner(scope)};
}
const selectedRequest=(prefix,path='/readyz')=>new Request('https://next-probe.example.invalid/functions/v1/catpaw-api'+prefix+path);
function selectCombined(request,get,kind){const selected=next.selectGemmaNextReviewRequest(request,get,kind);return selected.review?selected:old.selectGemmaReviewRequest(request,get,kind);}

test('default/v1/v2/unknown/tick selection preserves the existing three binding values',()=>{
 const env={CATPAW_REVIEW_PROBE_ID:GEMMA_PRIVATE_REVIEW_ID,CATPAW_REVIEW_PROBE_SUBJECT_ID:randomUUID(),CATPAW_REVIEW_PROBE_SCOPE_ID:randomUUID()},get=k=>env[k];
 const normal=selectedRequest('');assert.equal(selectCombined(normal,()=>{throw Error('normal must not read probe env');},'api').request,normal);assert.equal(selectCombined(normal,get,'api').review,false);
 const previous=selectedRequest(old.GEMMA_REVIEW_PREFIX);assert.equal(next.selectGemmaNextReviewRequest(previous,get,'api').request,previous);assert.equal(selectCombined(previous,get,'api').review,true);
 const current=selectedRequest(P),selected=selectCombined(current,get,'api');assert.equal(selected.review,true);assert.equal(new URL(selected.request.url).pathname,'/functions/v1/catpaw-api/readyz');assert.equal(selected.subjectID,env.CATPAW_REVIEW_PROBE_SUBJECT_ID);
 assert.throws(()=>selectCombined(selectedRequest('/route-review/unknown'),get,'api'),e=>e.code==='review_candidate_not_found');for(const prefix of [P,old.GEMMA_REVIEW_PREFIX])assert.throws(()=>selectCombined(selectedRequest(prefix),get,'tick'),e=>e.code==='review_tick_not_authorized');
 assert.throws(()=>next.selectGemmaNextReviewRequest(current,k=>k==='CATPAW_REVIEW_PROBE_ID'?ID:env[k],'api'),e=>e.code==='review_probe_not_configured');assert.throws(()=>next.selectGemmaNextReviewRequest(current,()=>undefined,'api'),e=>e.code==='review_probe_not_configured');
});
test('new fixed identity retains the original frozen four-zero-price route and exact provider budget without mutating defaults',async()=>{
 const f=await fixture();try{assert.equal(ID,'catpaw-gemma-private-review-20261015-v2');assert.notEqual(C,old.GEMMA_REVIEW_CONVERSATION_ID);assert.equal(TEXT,'Reply only: received.');assert.equal(f.manifest.route_hash,RH);assert.equal(f.manifest.review_id,GEMMA_PRIVATE_REVIEW_ID);assert.equal(f.config.route.model,'apodex/apodex-1.1-mini:free');assert.equal(f.transport.maxTokens,512);assert.equal(f.transport.timeoutMs,30000);assert.deepEqual(f.manifest.route.routing_policy,{only:['google-ai-studio'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}});assert.equal(f.calls.length,0);}finally{await f.stop();}
});
test('actual packaged HTTP sends one fixed text with empty context/tools, persists original JSON/SSE and provider receipt, cold GET cannot resend',async()=>{
 const f=await fixture();let cold;try{await f.prepare();const notice=await (await f.req('/catpaw/privacy/v1/model-route')).json();assert.equal(notice.route_hash,RH);assert.ok(notice.ui.body.includes('Google AI Studio'));
  await (await f.req(f.conversation+'/turns',f.input)).text();await f.drain();const original=await (await f.req(f.turn)).json();assert.equal(original.turn.state,'completed');assert.equal(original.turn.events.filter(e=>e.type==='text_delta').map(e=>e.data.text).join(''),'received.');assert.equal(f.calls.length,1);const sent=f.calls[0];assert.equal(sent.body.max_tokens,512);assert.deepEqual(sent.body.tools??[],[]);assert.deepEqual(sent.body.provider,f.manifest.route.routing_policy);assert.equal(sent.redirect,'error');
  const receipt=await (await f.req(f.receipt)).json();assert.equal(receipt.review_id,ID);assert.equal(receipt.route_review_id,GEMMA_PRIVATE_REVIEW_ID);assert.equal(receipt.input_hash,hash(f.input));assert.equal(receipt.request_hash,original.turn.request_hash);assert.equal(receipt.terminal_validated,true);assert.equal(receipt.review_frame_validation.passed,true);assert.equal(receipt.review_frame_validation.review_id,GEMMA_PRIVATE_REVIEW_ID);assert.equal(receipt.attempts,1);assert.equal(receipt.cost,0);assert.deepEqual(receipt.limits,{max_completion_tokens:512,provider_timeout_ms:30000,tool_count:0});
  const eventResponse=await f.req(f.turn+'/events?after_sequence=0');assert.equal(eventResponse.status,200);assert.match(await eventResponse.text(),/turn_completed/);assert.equal((await f.req(f.conversation+'/turns',f.input)).status,409);
  cold=await fixture({snapshot:f.repository.snapshot(),scope:f.scope,actor:f.actor});const before=cold.repository.snapshot();assert.deepEqual(await (await cold.req(cold.turn)).json(),original);assert.deepEqual(await (await cold.req(cold.receipt)).json(),receipt);assert.deepEqual(cold.repository.snapshot(),before);assert.equal((await cold.req(cold.conversation+'/turns',cold.input)).status,409);assert.equal(cold.calls.length,0);
  for(const kind of ['tasks','catpaw-runs','catpaw-delegations'])assert.deepEqual(await f.repository.transaction(tx=>tx.list(f.owner(),kind)),[]);
 }finally{await cold?.stop();await f.stop();}
});
test('two separately constructed runtimes sharing the durable repository cannot dispatch two provider requests concurrently',async()=>{
 const f=await fixture();let second;try{await f.prepare();second=await fixture({repository:f.repository,scope:f.scope,actor:f.actor});const responses=await Promise.all([f.req(f.conversation+'/turns',f.input),second.req(second.conversation+'/turns',second.input)]);await Promise.all(responses.map(r=>r.text()));await Promise.all([f.drain(),second.drain()]);assert.ok(responses.some(r=>r.status===200));assert.ok(responses.every(r=>[200,409,503].includes(r.status)));assert.equal(f.calls.length+second.calls.length,1);const turns=await f.repository.transaction(tx=>tx.list(f.owner(),'native-chat-turns'));assert.equal(turns.length,1);assert.equal(turns[0].id,T);assert.equal(turns[0].state,'completed');}finally{await second?.stop();await f.stop();}
});
test('HTTP429 persists the original failed request and cold GET while neither retry POST nor another runtime dispatches again',async()=>{
 const f=await fixture({outcome:'429'});let cold;try{await f.prepare();await (await f.req(f.conversation+'/turns',f.input)).text();await f.drain();const original=await (await f.req(f.turn)).json();assert.notEqual(original.turn.state,'completed');const receipt=await (await f.req(f.receipt)).json();assert.equal(receipt.http_status,429);assert.equal(receipt.terminal_validated,false);assert.equal(receipt.attempts,1);assert.equal(f.calls.length,1);cold=await fixture({snapshot:f.repository.snapshot(),scope:f.scope,actor:f.actor});assert.deepEqual(await (await cold.req(cold.turn)).json(),original);assert.deepEqual(await (await cold.req(cold.receipt)).json(),receipt);assert.equal((await cold.req(cold.conversation+'/turns',cold.input)).status,409);assert.equal(cold.calls.length,0);}finally{await cold?.stop();await f.stop();}
});
test('old owned r7 and new fixed conversations coexist; new scope writes reject any other conversation or task, historical GET remains available',async()=>{
 const f=await fixture();try{await f.repository.transaction(tx=>tx.put(f.owner(),'native-chat-conversations',{id:old.GEMMA_REVIEW_CONVERSATION_ID,subject_id:f.actor.subject_id,scope_id:f.scope.scope_id}));await f.prepare();assert.equal((await f.req('/readyz')).status,200);
  const extra=randomUUID();await f.repository.transaction(tx=>tx.put(f.owner(),'native-chat-conversations',{id:extra,subject_id:f.actor.subject_id,scope_id:f.scope.scope_id}));assert.equal((await f.req(f.conversation)).status,200);assert.equal((await f.req(f.conversation+'/turns',f.input)).status,409);assert.equal(f.calls.length,0);
 }finally{await f.stop();}
});
test('nonempty tasks/runs/delegations or foreign ownership cannot expand the isolated scope',async()=>{
 for(const kind of ['tasks','catpaw-runs','catpaw-delegations','foreign-conversation']){const f=await fixture();try{await f.repository.transaction(tx=>tx.put(f.owner(),kind==='foreign-conversation'?'native-chat-conversations':kind,kind==='foreign-conversation'?{id:old.GEMMA_REVIEW_CONVERSATION_ID,subject_id:randomUUID(),scope_id:f.scope.scope_id}:{id:randomUUID()}));assert.equal((await f.req(f.path,{conversation_id:C})).status,409);assert.equal(f.calls.length,0);}finally{await f.stop();}}
});
test('wrong subject, scope, old r7 POST, image, task, memory and modified text/context/IDs are denied before dispatch',async()=>{
 const f=await fixture();try{await f.prepare();const subject=f.actor.subject_id;f.actor.subject_id=randomUUID();assert.equal((await f.req('/readyz')).status,403);f.actor.subject_id=subject;
  const bad=[x=>x.context.push({id:'private',text:'not approved'}),x=>x.message.attachments=[],x=>x.message.text+=' now',x=>x.message.id=randomUUID(),x=>x.turn_id=old.GEMMA_REVIEW_TURN_ID,x=>x.turn_id=randomUUID(),x=>x.work={single_run:true}];for(const change of bad){const input=clone(f.input);change(input);assert.equal((await f.req(f.conversation+'/turns',input)).status,422);}
  for(const path of [f.path+'/'+old.GEMMA_REVIEW_CONVERSATION_ID+'/turns','/catpaw/memory/v1/scopes/'+f.scope.scope_id+'/commands','/catpaw/accepted-work/v1/scopes/'+f.scope.scope_id+'/turns','/catpaw/image/v1/scopes/'+f.scope.scope_id+'/turns',f.path.replace(f.scope.scope_id,randomUUID())])assert.equal((await f.req(path,{})).status,403);
  assert.equal((await f.req(f.conversation+'/turns',f.input,{'X-Catpaw-Memory-Proposal-Contract':'catpaw.memory-proposal.v1'})).status,422);assert.equal(f.calls.length,0);
 }finally{await f.stop();}
});
test('duplicate and escaped duplicate JSON keys, bad length and oversize reject without changing original durable facts',async()=>{
 const f=await fixture();try{await f.prepare();const before=f.repository.snapshot(),body=JSON.stringify(f.input);for(const raw of [body.replace('"turn_id":','"turn_id":"00000000-0000-4000-8000-000000000000","turn_id":'),body.replace('"message":{','"message":{"text":"unapproved",'),body.replace('"message":{','"message":{"te\\u0078t":"unapproved",')]){const response=await f.req(f.conversation+'/turns',raw);assert.equal(response.status,422);assert.equal((await response.json()).error.code,'review_probe_duplicate_key');}
  assert.equal((await f.req(f.conversation+'/turns',' '.repeat(2049))).status,413);for(const length of ['-1','1e3','0001','2049'])assert.equal((await f.req(f.conversation+'/turns',body,{'Content-Length':length})).status,413);assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,0);
 }finally{await f.stop();}
});
for(const outcome of ['tool','early-provider','early-model','early-id','incomplete'])test('provider '+outcome+' cannot yield a task, a validated terminal or a replacement request',async()=>{
 const f=await fixture({outcome});try{await f.prepare();await (await f.req(f.conversation+'/turns',f.input)).text();await f.drain();const original=await (await f.req(f.turn)).json();assert.notEqual(original.turn.state,'completed');assert.deepEqual(original.turn.task_bindings,[]);const receipt=await (await f.req(f.receipt)).json();assert.equal(receipt.terminal_validated,false);assert.equal(f.calls.length,1);assert.equal((await f.req(f.conversation+'/turns',f.input)).status,409);for(const kind of ['tasks','catpaw-runs','catpaw-delegations'])assert.deepEqual(await f.repository.transaction(tx=>tx.list(f.owner(),kind)),[]);}finally{await f.stop();}
});

test('the real old r7 original JSON/receipt remains readable after creating and completing the new v2 conversation',async()=>{
 const f=await fixture();let previous;const oldCalls=[],retained=[];try{
  previous=await old.createGemmaShortTextProbeRuntime({repository:f.repository,authenticate:()=>f.actor,config:f.config,retain:p=>retained.push(p),subjectID:f.actor.subject_id,scopeID:f.scope.scope_id,liveNetworkEnabled:true,fetchImpl:async()=>{oldCalls.push(1);return providerResponse('429');}});
  const oldConversation=f.path+'/'+old.GEMMA_REVIEW_CONVERSATION_ID,oldTurn=oldConversation+'/turns/'+old.GEMMA_REVIEW_TURN_ID,oldConsent=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${old.GEMMA_REVIEW_CONVERSATION_ID}/model-consent`,oldReceipt=`/catpaw/review/v1/scopes/${f.scope.scope_id}/turns/${old.GEMMA_REVIEW_TURN_ID}/provider-receipt`;
  const oldReq=(path,body)=>{const request=new Request('https://next-probe.example.invalid/functions/v1/catpaw-api'+old.GEMMA_REVIEW_PREFIX+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer synthetic-probe','Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}});return previous.api(selectCombined(request,k=>f.env[k],'api').request);};
  assert.equal((await oldReq(f.path,{conversation_id:old.GEMMA_REVIEW_CONVERSATION_ID})).status,201);assert.equal((await oldReq(oldConsent,{decision:'allow',expected_revision:0,route_hash:RH})).status,200);
  const oldInput={turn_id:old.GEMMA_REVIEW_TURN_ID,expected_revision:1,expected_grant_epoch:1,message:{id:old.GEMMA_REVIEW_MESSAGE_ID,text:TEXT},context:[]};await (await oldReq(oldConversation+'/turns',oldInput)).text();await Promise.all(retained);const original=await (await oldReq(oldTurn)).json(),receipt=await (await oldReq(oldReceipt)).json();assert.equal(receipt.http_status,429);
  await f.prepare();await (await f.req(f.conversation+'/turns',f.input)).text();await f.drain();assert.equal(f.calls.length,1);assert.equal(oldCalls.length,1);assert.deepEqual(await (await oldReq(oldTurn)).json(),original);assert.deepEqual(await (await oldReq(oldReceipt)).json(),receipt);assert.equal((await oldReq(oldConversation+'/turns',oldInput)).status,409);assert.equal(oldCalls.length,1);
 }finally{await previous?.runtime.worker.stop();await f.stop();}
});
test('scope contamination committed after HTTP pre-read is rejected by the original turn admission transaction',async()=>{
 const f=await fixture();try{await f.prepare();const start=f.runtime.chat.startTurn.bind(f.runtime.chat);f.runtime.chat.startTurn=async(...args)=>{await f.repository.transaction(tx=>tx.put(f.owner(),'tasks',{id:randomUUID(),status:'queued'}));return start(...args);};const response=await f.req(f.conversation+'/turns',f.input);assert.equal(response.status,409);assert.equal((await response.json()).error.code,'review_probe_scope_not_empty');assert.equal(f.calls.length,0);assert.deepEqual(await f.repository.transaction(tx=>tx.list(f.owner(),'native-chat-turns')),[]);assert.equal((await f.repository.transaction(tx=>tx.list(f.owner(),'tasks'))).length,1);}finally{await f.stop();}
});
