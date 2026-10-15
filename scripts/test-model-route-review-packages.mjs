import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {Buffer} from 'node:buffer';
import {hash} from '../services/edge/supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../services/edge/supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
globalThis.Buffer??=Buffer;
globalThis.fetch=()=>{throw Error('review_package_external_network_forbidden');};
const root=new URL('../services/edge/build/model-route-review-20261015/packages-r7/',import.meta.url);
const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-unused-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};
for(const label of ['catpaw-api-v19','catpaw-tick-v7']){
 const base=new URL(label+'/_shared/',root),probe=await import(new URL('model-route-review-probe.mjs',base)),{readConfig}=await import(new URL('config.mjs',base)),{membershipOwner}=await import(new URL('authority.mjs',base));
 const {GEMMA_REVIEW_PREFIX:P,GEMMA_REVIEW_CONVERSATION_ID:C,GEMMA_REVIEW_TURN_ID:T,GEMMA_REVIEW_MESSAGE_ID:M,GEMMA_REVIEW_TEXT:TEXT}=probe;
 async function fixture({outcome='success',snapshot=null,subjectID=randomUUID(),scope=null}={}){
  scope??={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
  const actor={subject_id:subjectID,session_id:randomUUID(),issuer:'https://probe-package.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
  const repository=new TestRepository(snapshot??undefined),transaction=repository.transaction.bind(repository);
  repository.transaction=fn=>transaction(tx=>{tx.connection={query:async(sql,args)=>{if(sql.startsWith('SELECT pg_advisory_xact_lock'))return {rows:[]};const kind=/kind='([^']+)'/.exec(sql)?.[1];assert.ok(['app-sessions','scope-memberships'].includes(kind));const row=await tx.get(args[0],kind,args[1]);return {rows:row?[{data:row}]:[]};}};return fn(tx);});
  const calls=[],retained=[],config=readConfig(k=>values[k]);
  const f=await probe.createGemmaShortTextProbeRuntime({repository,authenticate:auth=>{assert.equal(auth,'Bearer synthetic-probe');return actor;},config,retain:p=>retained.push(p),subjectID,scopeID:scope.scope_id,liveNetworkEnabled:true,fetchImpl:async(url,init)=>{
   calls.push({url,body:JSON.parse(init.body)});assert.deepEqual(calls.at(-1).body.tools??[],[]);assert.equal(calls.at(-1).body.max_tokens,32);
   let first={choices:[{index:0,delta:{content:'received.'}}]},finish='stop';
   if(outcome==='tool'){first={choices:[{index:0,delta:{tool_calls:[{index:0,id:'forbidden-tool',type:'function',function:{name:'delegate_task',arguments:'{}'}}]}}]};finish='tool_calls';}
   if(outcome==='early-provider')first.provider='Other Provider';if(outcome==='early-model')first.model='google/gemma-4-31b-it';if(outcome==='early-id')first.id='early-id';
   const last={id:'final-id',model:'google/gemma-4-31b-it:free',provider:'Google AI Studio',usage:{cost:0},choices:[{index:0,delta:{},finish_reason:finish}]};
   const raw=[first,last].map(x=>'data: '+JSON.stringify(x)+'\n\n').join('')+(outcome==='unknown'?'':'data: [DONE]\n\n');
   return new Response(raw,{headers:{'Content-Type':'text/event-stream'}});
  }});
  if(!snapshot)await f.runtime.foundation.bootstrapScope(actor,scope.scope_id);
  await repository.transaction(async tx=>{await tx.put(membershipOwner(actor.issuer),'app-sessions',{id:actor.session_id,subject_id:subjectID,state:'active',expires_at:Math.floor(Date.now()/1000)+600});await tx.put(membershipOwner(actor.issuer),'scope-memberships',{id:subjectID,state:'active',tokens_valid_after:1,revoked_session_ids:[],scopes:[scope]});});
  const env={CATPAW_REVIEW_PROBE_ID:f.manifest.review_id,CATPAW_REVIEW_PROBE_SUBJECT_ID:subjectID,CATPAW_REVIEW_PROBE_SCOPE_ID:scope.scope_id};
  const path=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,conversation=path+'/'+C,turn=conversation+'/turns/'+T,consent=`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${C}/model-consent`;
  const req=(path,body)=>{const request=new Request('https://probe-package.example.invalid/functions/v1/catpaw-api'+P+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer synthetic-probe','Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}});return f.api(probe.selectGemmaReviewRequest(request,k=>env[k],'api').request);};
  const input={turn_id:T,expected_revision:1,expected_grant_epoch:1,message:{id:M,text:TEXT},context:[]};
  const prepare=async()=>{assert.equal((await req(path,{conversation_id:C})).status,201);assert.equal((await req(consent,{decision:'allow',expected_revision:0,route_hash:f.manifest.route_hash})).status,200);};
  return {...f,repository,scope,actor,env,calls,retained,path,conversation,turn,consent,input,req,prepare,drain:()=>Promise.all(retained),stop:()=>f.runtime.worker.stop()};
 }
 test(label+': default selection is byte-preserving; unconfigured or tick review cannot initialize',()=>{
  const request=new Request('https://probe-package.example.invalid/functions/v1/catpaw-api/readyz');const selected=probe.selectGemmaReviewRequest(request,()=>{throw Error('default_must_not_read_review_config');},'api');assert.equal(selected.review,false);assert.equal(selected.request,request);
  const review=new Request('https://probe-package.example.invalid/functions/v1/catpaw-api'+P+'/readyz');assert.throws(()=>probe.selectGemmaReviewRequest(review,()=>undefined,'api'),e=>e.code==='review_probe_not_configured');assert.throws(()=>probe.selectGemmaReviewRequest(review,()=>undefined,'tick'),e=>e.code==='review_tick_not_authorized');
 });
 test(label+': one fixed short text, no tools or kick, cold GET same original; repeat POST blocked',async()=>{
  const f=await fixture();let cold;try{await f.prepare();const notice=await (await f.req('/catpaw/privacy/v1/model-route')).json();assert.equal(notice.route_hash,f.manifest.route_hash);assert.ok(notice.ui.body.includes('Google AI Studio'));
   assert.equal((await f.req(f.conversation+'/turns',f.input)).status,200);await f.drain();const original=await (await f.req(f.turn)).json();assert.equal(original.turn.state,'completed');assert.equal(f.calls.length,1);assert.equal((await f.req(f.conversation+'/turns',f.input)).status,409);assert.equal(f.calls.length,1);
   const receiptPath=`/catpaw/review/v1/scopes/${f.scope.scope_id}/turns/${T}/provider-receipt`,receipt=await (await f.req(receiptPath)).json();assert.equal(receipt.input_hash,hash(f.input));assert.equal(receipt.request_hash,original.turn.request_hash);assert.equal(receipt.terminal_validated,true);assert.equal(receipt.review_frame_validation.passed,true);assert.equal(receipt.review_frame_validation.frames,2);assert.equal(receipt.cost,0);assert.equal(receipt.attempts,1);assert.deepEqual(receipt.limits,{max_completion_tokens:32,provider_timeout_ms:20000,tool_count:0});
   const owner=f.runtime.facade.owner(f.scope);for(const k of ['tasks','catpaw-runs','catpaw-delegations'])assert.deepEqual(await f.repository.transaction(tx=>tx.list(owner,k)),[]);
   cold=await fixture({snapshot:f.repository.snapshot(),subjectID:f.actor.subject_id,scope:f.scope});assert.deepEqual(await (await cold.req(cold.turn)).json(),original);assert.equal(cold.calls.length,0);assert.deepEqual(await (await cold.req(receiptPath)).json(),receipt);
  }finally{await cold?.stop();await f.stop();}
 });
 test(label+': contexts, attachments, alternate IDs and work/revision routes cannot expand the single probe',async()=>{
  const f=await fixture();try{await f.prepare();const variants=[x=>{x.context=[{id:'more',text:'not approved'}];},x=>{x.message.attachments=[];},x=>{x.turn_id=randomUUID();},x=>{x.message.text+=' now';},x=>{x.message.id=randomUUID();}];for(const change of variants){const input=structuredClone(f.input);change(input);assert.equal((await f.req(f.conversation+'/turns',input)).status,422);}
   for(const path of ['/catpaw/accepted-work/v1/scopes/'+f.scope.scope_id+'/conversations/'+C+'/turns','/catpaw/revisions/v1/scopes/'+f.scope.scope_id+'/conversations/'+C+'/turns','/catpaw/artifacts/v1/scopes/'+f.scope.scope_id+'/runs/'+T+'/artifacts/'+M])assert.equal((await f.req(path,{})).status,403);assert.equal(f.calls.length,0);
  }finally{await f.stop();}
 });
 test(label+': nonempty scope is rejected before model and wrong subject cannot observe',async()=>{
  const f=await fixture();try{const owner=f.runtime.facade.owner(f.scope);await f.repository.transaction(tx=>tx.put(owner,'tasks',{id:randomUUID(),status:'queued'}));assert.equal((await f.req('/catpaw/privacy/v1/model-route')).status,409);assert.equal(f.calls.length,0);
   const old=f.actor.subject_id;f.actor.subject_id=randomUUID();assert.equal((await f.req('/catpaw/privacy/v1/model-route')).status,403);f.actor.subject_id=old;
  }finally{await f.stop();}
 });
 test(label+': provider task suggestion fails before any tool or background task is committed',async()=>{
  const f=await fixture({outcome:'tool'});try{await f.prepare();await (await f.req(f.conversation+'/turns',f.input)).text();await f.drain();const original=await (await f.req(f.turn)).json();assert.notEqual(original.turn.state,'completed');assert.equal(original.turn.error.code,'tool_not_allowed');assert.equal(original.turn.task_bindings.length,0);assert.equal(f.calls.length,1);assert.deepEqual(await f.repository.transaction(tx=>tx.list(f.runtime.facade.owner(f.scope),'tasks')),[]);
  }finally{await f.stop();}
 });
 for(const outcome of ['early-provider','early-model','early-id'])test(label+': '+outcome+' cannot be laundered by a correct final receipt',async()=>{const f=await fixture({outcome});let cold;try{await f.prepare();await (await f.req(f.conversation+'/turns',f.input)).text();await f.drain();const original=await (await f.req(f.turn)).json();assert.notEqual(original.turn.state,'completed');const receiptPath=`/catpaw/review/v1/scopes/${f.scope.scope_id}/turns/${T}/provider-receipt`,receipt=await (await f.req(receiptPath)).json();assert.equal(receipt.terminal_validated,false);assert.equal(receipt.review_frame_validation.passed,false);assert.equal(f.calls.length,1);assert.equal((await f.req(f.conversation+'/turns',f.input)).status,409);cold=await fixture({snapshot:f.repository.snapshot(),subjectID:f.actor.subject_id,scope:f.scope});assert.deepEqual(await (await cold.req(cold.turn)).json(),original);assert.deepEqual(await (await cold.req(receiptPath)).json(),receipt);assert.equal(cold.calls.length,0);}finally{await cold?.stop();await f.stop();}});
 test(label+': incomplete original terminal remains same-ID readable and cannot resend',async()=>{
  const f=await fixture({outcome:'unknown'});let cold;try{await f.prepare();await (await f.req(f.conversation+'/turns',f.input)).text();await f.drain();const original=await (await f.req(f.turn)).json();assert.notEqual(original.turn.state,'completed');assert.equal(original.turn.error.code,'incomplete_provider_terminal');assert.equal((await f.req(f.conversation+'/turns',f.input)).status,409);assert.equal(f.calls.length,1);
   cold=await fixture({snapshot:f.repository.snapshot(),subjectID:f.actor.subject_id,scope:f.scope});assert.deepEqual(await (await cold.req(cold.turn)).json(),original);assert.equal(cold.calls.length,0);assert.equal((await cold.req(cold.conversation+'/turns',cold.input)).status,409);assert.equal(cold.calls.length,0);
  }finally{await cold?.stop();await f.stop();}
 });
}
