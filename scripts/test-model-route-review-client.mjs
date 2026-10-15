import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {stat,readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {ModelRouteReviewClient,ProbeFileStore,newProbeJournal,reviewProbePlan,REVIEW_APPROVAL,REVIEW_ORIGIN,REVIEW_API} from './model-route-review-client.mjs';
import {createGemmaShortTextProbeRuntime,selectGemmaReviewRequest,GEMMA_REVIEW_PREFIX} from '../services/edge/supabase/functions/_shared/model-route-review-probe.mjs';
import {readConfig} from '../services/edge/supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../services/edge/supabase/functions/_shared/authority.mjs';
import {hash,clone} from '../services/edge/supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../services/edge/supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
globalThis.fetch=()=>{throw Error('review_client_test_external_network_forbidden');};
class MemoryStore {
 constructor(){this.data=null;this.secret=null;this.serial=Promise.resolve();this.failTurn=false;}
 async load(){return clone(this.data);}
 async vault(){return clone(this.secret);}
 async saveVault(v){this.secret=clone(v);}
 async update(fn){const run=async()=>{const next=await fn(clone(this.data??newProbeJournal()));if(this.failTurn&&next.turn.attempted)throw Error('synthetic_storage_failure');this.data=clone(next);return clone(next);};const result=this.serial.then(run,run);this.serial=result.catch(()=>{});return result;}
}
const publicKey='sb_publishable_synthetic01';
const configValues={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-unused-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};
function atURL(response,url){Object.defineProperty(response,'url',{value:url});return response;}
async function fixture({store=new MemoryStore(),outcome='success',loseTurnResponse=false,loseAuthResponse=false,nonAnonymous=false,legacyReceipt=false}={}){
 const scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true},actor={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://client-fixture.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}},calls={signup:0,authGet:0,scope:0,turnPost:0,model:0,total:0},retained=[];let repository=new TestRepository(),server,binding=null,lost=false;
 const make=async()=>{
  const transaction=repository.transaction.bind(repository);repository.transaction=fn=>transaction(tx=>{tx.connection={query:async(sql,args)=>{if(sql.startsWith('SELECT pg_advisory_xact_lock'))return {rows:[]};const kind=/kind='([^']+)'/.exec(sql)?.[1];assert.ok(['app-sessions','scope-memberships'].includes(kind));const row=await tx.get(args[0],kind,args[1]);return {rows:row?[{data:row}]:[]};}};return fn(tx);});
  server=await createGemmaShortTextProbeRuntime({repository,authenticate:authorization=>{assert.equal(authorization,'Bearer synthetic-new-probe-access');return actor;},config:readConfig(k=>configValues[k]),retain:p=>retained.push(p),subjectID:actor.subject_id,scopeID:scope.scope_id,liveNetworkEnabled:true,fetchImpl:async(_url,init)=>{
   calls.model++;const p=JSON.parse(init.body);assert.equal(p.max_tokens,32);assert.deepEqual(p.tools,[]);assert.equal(p.provider.data_collection,'deny');assert.deepEqual(p.provider.max_price,{prompt:0,completion:0,request:0,image:0});
   let first={choices:[{index:0,delta:{content:'received.'}}]},finish='stop';if(outcome==='tool'){first={choices:[{index:0,delta:{tool_calls:[{index:0,id:'synthetic-forbidden',type:'function',function:{name:'delegate_task',arguments:'{}'}}]}}]};finish='tool_calls';}
   if(outcome==='early-provider')first.provider='Other Provider';
   const last={model:'google/gemma-4-31b-it:free',provider:outcome==='wrong-provider'?'Novita':'Google AI Studio',usage:{cost:0},choices:[{index:0,delta:{},finish_reason:finish}]};const raw=[first,last].map(e=>'data: '+JSON.stringify(e)+'\n\n').join('')+(outcome==='unknown'?'':'data: [DONE]\n\n');return new Response(raw,{headers:{'Content-Type':'text/event-stream'}});
  }});
 };
 await make();await server.runtime.foundation.bootstrapScope(actor,scope.scope_id);await repository.transaction(async tx=>{await tx.put(membershipOwner(actor.issuer),'app-sessions',{id:actor.session_id,subject_id:actor.subject_id,state:'active',expires_at:Math.floor(Date.now()/1000)+600});await tx.put(membershipOwner(actor.issuer),'scope-memberships',{id:actor.subject_id,state:'active',tokens_valid_after:1,revoked_session_ids:[],scopes:[scope]});});
 const fetchImpl=async(url,init)=>{
  calls.total++;const path=new URL(url).pathname;
  if(url===REVIEW_ORIGIN+'/auth/v1/signup'){
   calls.signup++;assert.equal(init.method,'POST');assert.deepEqual(JSON.parse(init.body),{});assert.equal((await store.load()).auth.attempted,true);if(loseAuthResponse)throw Error('synthetic_auth_response_lost');return atURL(Response.json({access_token:'synthetic-new-probe-access',refresh_token:'synthetic-new-probe-refresh',token_type:'bearer',expires_in:3600,user:{id:actor.subject_id,is_anonymous:!nonAnonymous}}),url);
  }
  if(url===REVIEW_ORIGIN+'/auth/v1/user'){calls.authGet++;assert.equal(init.method,'GET');return atURL(Response.json({id:actor.subject_id,is_anonymous:!nonAnonymous}),url);}
  if(url===REVIEW_API+'/catpaw/account/v1/session'){calls.scope++;assert.equal(init.method,'GET');return atURL(Response.json({schema_version:1,subject_id:actor.subject_id,scopes:[{...scope,permissions:{local_output:true}}]}),url);}
  assert.ok(url.startsWith(REVIEW_API+GEMMA_REVIEW_PREFIX+'/'));assert.equal(init.redirect,'error');const selected=selectGemmaReviewRequest(new Request(url,init),key=>binding?.[key],'api');
  if(init.method==='POST'&&path.endsWith('/turns')){calls.turnPost++;const j=await store.load();assert.equal(j.turn.attempted,true);assert.equal(j.turn.input_hash,hash(JSON.parse(init.body)));assert.deepEqual(j.turn.request,JSON.parse(init.body));}
  const response=await server.api(selected.request);
  if(loseTurnResponse&&!lost&&init.method==='POST'&&path.endsWith('/turns')){lost=true;await response.body?.cancel();await Promise.all(retained);throw Error('synthetic_durable_response_lost');}
  if(legacyReceipt&&path.endsWith('/provider-receipt')){const value=await response.json();delete value.review_frame_validation;return atURL(Response.json(value),url);}
  return atURL(response,url);
 };
 const client=()=>new ModelRouteReviewClient({store,fetchImpl,execute:true,approval:REVIEW_APPROVAL});
 const prepare=async()=>{const c=client();await c.bootstrapIdentity({publishableKey:publicKey});await c.bootstrapScope();binding=(await c.binding()).nonsecret_fields;await c.prepareConversation();await c.consent({allowRouteHash:reviewProbePlan().route_hash});return c;};
 return {store,calls,client,fetchImpl,prepare,get server(){return server;},restart:async()=>{await server.runtime.worker.stop();repository=new TestRepository(repository.snapshot());await make();},stop:()=>server.runtime.worker.stop()};
}

test('probe client defaults disabled and cannot access credential or network stages without explicit approval',async()=>{
 const store=new MemoryStore();let calls=0;const c=new ModelRouteReviewClient({store,fetchImpl:()=>{calls++;throw Error('must not execute');}});for(const fn of [()=>c.bootstrapIdentity({publishableKey:publicKey}),()=>c.bootstrapScope(),()=>c.send(),()=>c.observe()])await assert.rejects(fn(),e=>e.code==='probe_execution_not_approved');assert.equal(c.request,undefined);assert.equal(calls,0);assert.equal(store.data,null);assert.equal(reviewProbePlan().max_model_attempts,1);
});
test('new anonymous identity, scope, normal consent and fixed original SSE/JSON/provider receipt complete once',async()=>{
 const f=await fixture();try{const c=await f.prepare(),result=await c.send();assert.equal(result.state,'bounded_short_text_probe_pass');assert.equal(result.cost,0);assert.equal(result.product_acceptance,false);assert.deepEqual({signup:f.calls.signup,scope:f.calls.scope,turn:f.calls.turnPost,model:f.calls.model},{signup:1,scope:1,turn:1,model:1});const j=await f.store.load();assert.equal(j.turn.state,'completed');assert.equal(j.turn.first_delta_seen,true);assert.equal(j.turn.provider_receipt.terminal_validated,true);assert.equal(JSON.stringify(j).includes('synthetic-new-probe-access'),false);await assert.rejects(c.send(),e=>e.code==='probe_original_GET_only');assert.equal(f.calls.model,1);
 }finally{await f.stop();}
});
test('lost Auth response never automatically creates another identity',async()=>{
 const f=await fixture({loseAuthResponse:true});try{const c=f.client();await assert.rejects(c.bootstrapIdentity({publishableKey:publicKey}),e=>e.code==='probe_transport_unknown_no_retry');await assert.rejects(c.bootstrapIdentity({publishableKey:publicKey}),e=>e.code==='probe_identity_already_attempted_no_signup_retry');assert.equal(f.calls.signup,1);assert.equal(f.calls.model,0);assert.equal((await f.store.load()).auth.state,'unknown');
 }finally{await f.stop();}
});
test('vault/journal Auth attempt mismatch refuses every session request',async()=>{const f=await fixture();try{const c=await f.prepare();f.store.secret.attempt_id=randomUUID();const before=f.calls.total;await assert.rejects(c.send(),e=>e.code==='probe_new_session_unavailable_no_auto_refresh');assert.equal(f.calls.total,before);assert.equal(f.calls.model,0);}finally{await f.stop();}});
test('Auth vault saved before journal outcome can recover with GET only',async()=>{const f=await fixture();try{const c=f.client();await c.bootstrapIdentity({publishableKey:publicKey});f.store.data.auth.known=false;f.store.data.auth.state='unknown';assert.equal((await f.client().recoverIdentity()).state,'original_new_identity_recovered_GET_only');assert.equal(f.calls.signup,1);assert.equal(f.calls.authGet,1);assert.equal(f.calls.model,0);}finally{await f.stop();}});
test('disk failure before durable original write makes zero turn POST or model calls',async()=>{
 const f=await fixture();try{const c=await f.prepare();f.store.failTurn=true;await assert.rejects(c.send(),/synthetic_storage_failure/);assert.equal(f.calls.turnPost,0);assert.equal(f.calls.model,0);assert.equal((await f.store.load()).turn.attempted,false);
 }finally{await f.stop();}
});
test('response loss and reconstructed client/server recover only the original persisted receipt and ID',async()=>{
 const f=await fixture({loseTurnResponse:true});try{const c=await f.prepare(),lost=await c.send();assert.equal(lost.state,'unknown_or_failed_stop_POST');assert.equal(f.calls.turnPost,1);assert.equal(f.calls.model,1);await f.restart();const cold=f.client(),result=await cold.observe();assert.equal(result.state,'bounded_short_text_probe_pass');assert.equal(f.calls.signup,1);assert.equal(f.calls.turnPost,1);assert.equal(f.calls.model,1);await assert.rejects(cold.send(),e=>e.code==='probe_original_GET_only');assert.equal(f.calls.model,1);
 }finally{await f.stop();}
});
test('incomplete provider terminal stays FAIL/unknown with original GET recovery and no resend',async()=>{
 const f=await fixture({outcome:'unknown'});try{const c=await f.prepare(),result=await c.send();assert.notEqual(result.state,'bounded_short_text_probe_pass');await f.restart();const recovered=await f.client().observe();assert.notEqual(recovered.state,'bounded_short_text_probe_pass');assert.equal(f.calls.signup,1);assert.equal(f.calls.turnPost,1);assert.equal(f.calls.model,1);const j=await f.store.load();assert.equal(j.turn.provider_receipt.terminal_validated,false);assert.equal(j.turn.provider_receipt.error,'incomplete_provider_terminal');
 }finally{await f.stop();}
});
test('unexpected provider task suggestion fails before domain work and cannot trigger a second request',async()=>{
 const f=await fixture({outcome:'tool'});try{const c=await f.prepare(),result=await c.send();assert.notEqual(result.state,'bounded_short_text_probe_pass');const j=await f.store.load();assert.equal(j.turn.snapshot.turn.task_bindings.length,0);await assert.rejects(c.send(),e=>e.code==='probe_original_GET_only');assert.equal(f.calls.model,1);
 }finally{await f.stop();}
});
test('client rejects a completed final-only legacy receipt without all-frame validation',async()=>{const f=await fixture({legacyReceipt:true});try{const c=await f.prepare(),result=await c.send();assert.equal(result.state,'probe_FAIL_or_unknown_stop');assert.equal(result.terminal_validated,true);assert.equal(f.calls.model,1);await assert.rejects(c.send(),e=>e.code==='probe_original_GET_only');}finally{await f.stop();}});
test('client cannot pass an early wrong provider later overwritten by the expected final metadata',async()=>{const f=await fixture({outcome:'early-provider'});try{const c=await f.prepare(),result=await c.send();assert.notEqual(result.state,'bounded_short_text_probe_pass');const j=await f.store.load();assert.equal(j.turn.provider_receipt.review_frame_validation.passed,false);assert.equal(j.turn.provider_receipt.terminal_validated,false);assert.equal(f.calls.model,1);await f.restart();assert.notEqual((await f.client().observe()).state,'bounded_short_text_probe_pass');assert.equal(f.calls.model,1);}finally{await f.stop();}});
test('nonanonymous account, modified input journal and arbitrary private directory are refused',async()=>{
 const f=await fixture({nonAnonymous:true});try{await assert.rejects(f.client().bootstrapIdentity({publishableKey:publicKey}),e=>e.code==='probe_anonymous_response_invalid');assert.equal(f.calls.signup,1);assert.equal(f.calls.scope,0);assert.equal(f.calls.model,0);
 }finally{await f.stop();}
 const g=await fixture();try{const c=await g.prepare();g.store.data.operation.text='Read private calendar';const before=g.calls.total;await assert.rejects(c.send(),e=>e.code==='probe_journal_binding_invalid');assert.equal(g.calls.total,before);assert.equal(g.calls.model,0);assert.throws(()=>new ProbeFileStore('/private/tmp/user-keychain'),e=>e.code==='probe_private_directory_denied');
 }finally{await g.stop();}
});
test('real private file journal is atomic, mode0600, separate from session, and cold reload never resends',async()=>{
 const directory=fileURLToPath(new URL('../services/edge/build/model-route-review-20261015/private-probe/client-test-'+randomUUID(),import.meta.url)),store=new ProbeFileStore(directory),f=await fixture({store});try{const c=await f.prepare();assert.equal((await c.send()).state,'bounded_short_text_probe_pass');const text=await readFile(directory+'/journal.json','utf8');assert.equal(text.includes('synthetic-new-probe-access'),false);assert.equal((await stat(directory+'/journal.json')).mode&0o077,0);assert.equal((await stat(directory+'/session-private.json')).mode&0o077,0);await f.restart();const cold=new ModelRouteReviewClient({store:new ProbeFileStore(directory),fetchImpl:f.fetchImpl,execute:true,approval:REVIEW_APPROVAL});assert.equal((await cold.observe()).state,'bounded_short_text_probe_pass');assert.equal(f.calls.signup,1);assert.equal(f.calls.turnPost,1);assert.equal(f.calls.model,1);
 }finally{await f.stop();}
});
