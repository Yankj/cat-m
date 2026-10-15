import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner,revokeAppSession} from '../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {RecordTransaction,PostgresRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/postgres-repository.mjs';
import {createChatMetrics} from '../supabase/functions/_shared/core/src/chat-metrics.mjs';
import {ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {ChatService} from '../supabase/functions/_shared/core/src/chat-service.mjs';
import {ChatRecoveryFence} from '../supabase/functions/_shared/core/integration/server-foundation/src/chat-recovery.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const latch=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
const delay=ms=>new Promise(r=>setTimeout(r,ms));

async function fixture({slowMs=0,slowDbMs=0}={}){
  const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
  const transaction=repository.transaction.bind(repository);let dbOperations=0;
  repository.transaction=(...args)=>{const callback=args.pop();return transaction(...args,async tx=>{
    for(const name of ['get','put','lock','insertIfAbsent','compareAndSwap']){if(typeof tx[name]!=='function')continue;const method=tx[name].bind(tx);tx[name]=async(...values)=>{dbOperations++;if(slowDbMs)await delay(slowDbMs);return method(...values);};}
    return callback(tx);
  });};
  const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
  const config=readConfig(k=>({CATPAW_DATABASE_URL:'offline-only',CATPAW_PRIVATE_MODEL_KEY:'offline-only',CATPAW_TICK_HMAC_KEY:'offline-only-key-thirty-two-characters',CATPAW_MEMORY_GUARD_KEY:'offline-only-guard'}[k]));
  const second=latch(),finish=latch(),firstTextCommitted=latch(),retained=[],metrics=[];let authCalls=0,modelCalls=0,freshChecks=0,validSession=true,sourceFailure=null;
  const provider={identity:{model:config.route.model},reality:'provider_unverified',assertReady(){},async *stream(input){
    modelCalls++;assert.match(input.system_prompt,/No live weather, web search/);assert.match(input.system_prompt,/never answer from old knowledge/);
    yield {type:'text_delta',text:'x'.repeat(600)};await second.promise;
    yield {type:'text_delta',text:'y'.repeat(600)};await finish.promise;yield {type:'done',finish_reason:'stop'};
  }};
  const runtime=await createCloudRuntime({repository,config,provider,autoKick:false,diagnostic:e=>{metrics.push(e);if(e.phase==='text_commit'&&e.bytes>0)firstTextCommitted.resolve();},retain:p=>retained.push(p),authenticate:async()=>{authCalls++;await delay(slowMs);return principal;},sourceChecker:async(tx,source)=>{
    freshChecks++;await delay(slowMs);if(sourceFailure)throw sourceFailure;const session=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);
    if(!validSession||session?.state!=='active')throw new ApiError(409,'grant_conflict');
  }});
  await runtime.foundation.bootstrapScope(principal,scope.scope_id);
  await repository.transaction(async tx=>{await tx.put(membershipOwner(principal.issuer),'app-sessions',{id:principal.session_id,subject_id:principal.subject_id,state:'active',expires_at:9999999999});});
  const cid=randomUUID(),path=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,input={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'PRIVATE_FIXTURE_TEXT'},context:[]};
  const request=(p,body)=>runtime.api(new Request('https://offline.example.invalid'+p,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer PRIVATE_FIXTURE_AUTH','Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}}));
  assert.equal((await request(path,{conversation_id:cid})).status,201);
  assert.equal((await request(`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash})).status,200);
  runtime.chat.pollMs=10000;
  let snapshots=0;const read=runtime.chat.readTurn.bind(runtime.chat);runtime.chat.readTurn=(...a)=>{snapshots++;return read(...a);};
  const owner=runtime.facade.owner(scope),stop=async()=>{second.resolve();finish.resolve();await runtime.chat.waitIdle();await Promise.all(retained);await runtime.worker.stop();};
  const readRow=()=>repository.transaction(tx=>tx.get(owner,'native-chat-turns',input.turn_id));
  return {runtime,repository,principal,scope,cid,path,input,request,second,finish,firstTextCommitted,metrics,owner,stop,readRow,read,
    counters:()=>({authCalls,modelCalls,freshChecks,snapshots,dbOperations}),revokeSession:()=>{validSession=false;},setSourceFailure:e=>{sourceFailure=e;}};
}
async function frame(reader){const {done,value}=await reader.read();assert.equal(done,false);return JSON.parse(new TextDecoder().decode(value).slice(6).trim());}

test('slow auth/DB checks: one authentication per POST, durable acceptance before model terminal',async()=>{
  const f=await fixture({slowMs:15,slowDbMs:2}),before=f.counters(),started=performance.now();
  const response=await f.request(`${f.path}/${f.cid}/turns`,f.input),reader=response.body.getReader(),accepted=await frame(reader);
  assert.equal(accepted.type,'turn_started');assert.equal((await f.readRow()).events[0].type,'turn_started');
  assert.equal(f.counters().authCalls-before.authCalls,1);assert.ok(f.counters().modelCalls<=1);
  console.info(JSON.stringify({benchmark:'synthetic_slow_store',injected_auth_check_ms:15,injected_store_operation_ms:2,accept_elapsed_ms:Math.round(performance.now()-started),auth_calls_per_post:1,store_operations:f.counters().dbOperations-before.dbOperations}));
  await reader.cancel();await f.stop();
});
test('same-isolate committed delta notification avoids another turn snapshot and retains fresh authorization',async()=>{
  const f=await fixture({slowMs:5}),response=await f.request(`${f.path}/${f.cid}/turns`,f.input),reader=response.body.getReader();
  assert.equal((await frame(reader)).type,'turn_started');assert.equal((await frame(reader)).type,'text_delta');
  const before=f.counters();f.second.resolve();assert.equal((await frame(reader)).type,'text_delta');
  assert.equal(f.counters().snapshots,before.snapshots);assert.ok(f.counters().freshChecks>before.freshChecks);
  await reader.cancel();await f.stop();
});
test('SSE detach, GET cursor resume and duplicate POST never dispatch a second model request',async()=>{
  const f=await fixture(),response=await f.request(`${f.path}/${f.cid}/turns`,f.input),reader=response.body.getReader();
  await frame(reader);await frame(reader);await reader.cancel();await f.stop();
  const resumed=await f.request(`${f.path}/${f.cid}/turns/${f.input.turn_id}/events?after_sequence=2`),text=await resumed.text();
  const events=text.trim().split('\n\n').map(x=>JSON.parse(x.slice(6)));
  assert.deepEqual(events.map(x=>x.sequence),[3,4]);assert.equal(events.at(-1).type,'turn_completed');
  const replay=await f.request(`${f.path}/${f.cid}/turns`,f.input);assert.equal((await replay.json()).replayed,true);assert.equal(f.counters().modelCalls,1);
});
test('cursor beyond durable sequence and a foreign scope are rejected before SSE headers',async()=>{
  const f=await fixture(),r=await f.request(`${f.path}/${f.cid}/turns`,f.input);await r.body.cancel();await f.stop();
  const bad=await f.request(`${f.path}/${f.cid}/turns/${f.input.turn_id}/events?after_sequence=99`);assert.equal(bad.status,422);
  const other=await f.request(`/catpaw/chat/v1/scopes/${randomUUID()}/conversations/${f.cid}/turns/${f.input.turn_id}/events`);assert.equal(other.status,403);
});
test('cached commit notification cannot reveal late text after session revocation',async()=>{
  const f=await fixture(),started=await f.runtime.chat.startTurn('Bearer fixture',f.scope.scope_id,f.cid,f.input);
  const observer=f.runtime.chat.observe('Bearer fixture',f.scope.scope_id,f.cid,f.input.turn_id,{trusted:started.trusted});
  const first=await observer.next();assert.equal(first.value.type,'turn_started');await f.firstTextCommitted.promise;f.revokeSession();
  const row=await f.readRow();f.runtime.chat.notify(f.owner,row);
  await assert.rejects(observer.next(),e=>e.code==='grant_conflict');await observer.return();await f.stop();
  const final=await f.readRow();assert.equal(final.state,'failed');assert.equal(final.error.code,'grant_conflict');
  assert.deepEqual(final.events.map(e=>e.type),['turn_started','text_delta','turn_failed']);assert.equal(final.error.retryable,false);
  assert.equal(final.events.filter(e=>e.type==='text_delta').map(e=>e.data.text).join(''),'x'.repeat(600));assert.equal(f.counters().modelCalls,1);
});
test('cached notification cannot reveal late text after conversation epoch changes',async()=>{
  const f=await fixture(),started=await f.runtime.chat.startTurn('Bearer fixture',f.scope.scope_id,f.cid,f.input);
  const observer=f.runtime.chat.observe('Bearer fixture',f.scope.scope_id,f.cid,f.input.turn_id,{trusted:started.trusted});await observer.next();await f.firstTextCommitted.promise;
  await f.repository.transaction(async tx=>{const c=await tx.get(f.owner,'native-chat-conversations',f.cid);await tx.put(f.owner,'native-chat-conversations',{...c,state:'paused',grant_epoch:c.grant_epoch+1});});
  f.runtime.chat.notify(f.owner,await f.readRow());await assert.rejects(observer.next(),e=>e.code==='grant_conflict');await observer.return();await f.stop();
});
test('committed notification queued while snapshot yields closes read/subscribe race without duplicate events',async()=>{
  const f=await fixture(),started=await f.runtime.chat.startTurn('Bearer fixture',f.scope.scope_id,f.cid,f.input);
  const observer=f.runtime.chat.observe('Bearer fixture',f.scope.scope_id,f.cid,f.input.turn_id,{trusted:started.trusted});const events=[];
  events.push((await observer.next()).value);f.second.resolve();f.finish.resolve();await f.runtime.chat.waitIdle();
  for await(const e of observer)events.push(e);
  assert.deepEqual(events.map(e=>e.sequence),events.map((_,i)=>i+1));assert.equal(events.at(-1).type,'turn_completed');await f.stop();
});
test('metrics whitelist never accepts private values or leaks sink failures into business logic',()=>{
  const rows=[],metrics=createChatMetrics({now:()=>100,sink:e=>rows.push(e)});
  metrics.record('text_commit',50,{bytes:12,count:1,text:'PRIVATE',authorization:'Bearer PRIVATE',url:'PRIVATE',db_ms:10});metrics.record('PRIVATE',0);
  assert.deepEqual(rows,[{event:'catpaw_chat_phase',phase:'text_commit',elapsed_ms:50,count:1,bytes:12,db_ms:10}]);
  assert.doesNotThrow(()=>createChatMetrics({sink:()=>{throw Error('PRIVATE');}}).record('request_auth',0));
});
test('transaction scope reuse skips only duplicate row lock/GUC and remains scope-bound',async()=>{
  const queries=[],id=randomUUID(),other=randomUUID();const tx=new RecordTransaction({query:async(sql,args)=>{queries.push([sql,args]);return {rows:[{data:{identity:{scope_id:id}}}]};}});
  await tx.withScope(id,async()=>{});const count=queries.length;await tx.withScope(id,async()=>{},{reuseLockedScope:true});assert.equal(queries.length,count);
  await assert.rejects(tx.withScope(other,async()=>{},{reuseLockedScope:true}),e=>e.code==='one_scope_per_transaction');
  const newTx=new RecordTransaction(tx.connection);await newTx.withScope(id,async()=>{},{reuseLockedScope:true});assert.equal(queries.length,count+2);
});
test('production tail SQL projects away history/input/auth and binds cursor as a parameter',async()=>{
  const calls=[],tx=new RecordTransaction({query:async(sql,args)=>{calls.push({sql,args});return {rows:[{data:{events:[]},event_count:4,subject_id:'internal'}]};}});
  await tx.chatConversationHead('owner','cid');await tx.chatTurnTail('owner','tid',3);
  assert.match(calls[0].sql,/jsonb_build_object/);assert.doesNotMatch(calls[0].sql,/SELECT data FROM/);
  assert.match(calls[1].sql,/'input','history','model_history','subject_id','source_auth','dispatch_checkpoint','events'/);assert.match(calls[1].sql,/integer>\$3/);assert.deepEqual(calls[1].args,['owner','tid',3]);
});
test('DB telemetry reports aggregate query duration/count without SQL or arguments',async()=>{
  let tick=0;const rows=[],metrics=createChatMetrics({now:()=>tick,sink:r=>rows.push(r)}),repository=new PostgresRepository({connect:async()=>({query:async()=>{tick+=7;return {rows:[]};},release(){}})});repository.metrics=metrics;
  await repository.transaction(async tx=>{await tx.get('PRIVATE_OWNER','PRIVATE_KIND','PRIVATE_ID');});
  assert.equal(rows.at(-1).count,4);assert.equal(rows.at(-1).db_ms,28);assert.doesNotMatch(JSON.stringify(rows),/PRIVATE|SELECT|BEGIN/);
});
test('capability declaration keeps images/weather/web disabled and existing model route unchanged',async()=>{
  const f=await fixture(),ready=await (await f.request('/readyz')).json();
  assert.equal(ready.chat_capabilities.image_input,false);assert.equal(ready.chat_capabilities.live_weather,false);assert.equal(ready.chat_capabilities.web_search,false);assert.equal(ready.chat_capabilities.cursor_events,true);
  await f.stop();
});
test('failed admission transaction emits no durable receipt, user message or model request',async()=>{
  const f=await fixture(),capture=f.runtime.chat.integration.capture;f.runtime.chat.integration.capture=async(...a)=>{await capture(...a);throw new ApiError(503,'offline_commit_failure');};
  const r=await f.request(`${f.path}/${f.cid}/turns`,f.input);assert.equal(r.status,503);assert.equal(f.counters().modelCalls,0);assert.equal(await f.readRow(),null);
  const c=await f.repository.transaction(tx=>tx.get(f.owner,'native-chat-conversations',f.cid));assert.deepEqual(c.messages,[]);await f.stop();
});

// Deterministic transaction races on the serialized test double. These do not prove live PG concurrency.
async function runningFixture(){const f=await fixture();await f.runtime.chat.startTurn('Bearer fixture',f.scope.scope_id,f.cid,f.input);await f.firstTextCommitted.promise;return f;}
const failureEnv=f=>({owner:f.owner,turn:{id:f.input.turn_id,history:[{content:'STALE_BUFFER_MUST_NOT_REAPPEAR'}]}});
function countNotifications(f){let count=0;const key=`${f.owner}:${f.input.turn_id}`;f.runtime.chat.listeners.set(key,new Set([()=>count++]));return ()=>count;}
function interceptTransaction(f,decorate){const original=f.repository.transaction.bind(f.repository);f.repository.transaction=(...args)=>{const callback=args.pop();return original(...args,async tx=>{decorate(tx);return callback(tx);});};return ()=>{f.repository.transaction=original;};}
const failureEvents=t=>t.events.filter(e=>e.type==='turn_failed');

test('source revocation cleanup commits only one static failure receipt, including concurrent repeated cleanup',async()=>{
  const f=await runningFixture();try{
    const before=await f.readRow(),notify=countNotifications(f);f.revokeSession();
    await assert.rejects(f.runtime.chat.append({owner:f.owner,turn:before,scope:f.scope,signal:new AbortController().signal},'text_delta',{text:'LATE_BUFFER'}),e=>e.code==='grant_conflict');
    await Promise.all(Array.from({length:3},()=>f.runtime.chat.fail(failureEnv(f),new DOMException('Synthetic abort','AbortError'))));
    const after=await f.readRow();assert.equal(after.state,'failed');assert.deepEqual(after.error,{code:'grant_conflict',retryable:false,reconciliation_required:false});
    assert.deepEqual(after.events.slice(0,-1),before.events);assert.equal(failureEvents(after).length,1);assert.equal(after.events.at(-1).sequence,before.events.length+1);assert.equal(notify(),1);
    assert.deepEqual(after.history,before.history);assert.deepEqual(after.task_bindings,[]);assert.doesNotMatch(JSON.stringify(after),/LATE_BUFFER|STALE_BUFFER/);
    const c=await f.repository.transaction(tx=>tx.get(f.owner,'native-chat-conversations',f.cid));assert.deepEqual(c.messages.map(m=>m.role),['user']);
  }finally{await f.stop();}
});

test('fresh consent revision denial permits only failure metadata and still blocks normal publication',async()=>{
  const f=await runningFixture();try{
    await f.repository.transaction(async tx=>{const [consent]=await tx.list(f.owner,'provider-consents');await tx.put(f.owner,'provider-consents',{...consent,revision:consent.revision+1,decision:'deny'});});
    const before=await f.readRow();await assert.rejects(f.runtime.chat.append({owner:f.owner,turn:before,scope:f.scope,signal:new AbortController().signal},'text_delta',{text:'LATE_BUFFER'}),e=>e.code==='provider_consent_required');
    await f.runtime.chat.fail(failureEnv(f),new DOMException('Synthetic abort','AbortError'));
    const after=await f.readRow();assert.equal(after.state,'failed');assert.equal(after.error.code,'provider_consent_required');assert.equal(failureEvents(after).length,1);assert.deepEqual(after.events.slice(0,-1),before.events);
  }finally{await f.stop();}
});

test('logout reducer terminal wins over delayed cleanup with no extra event or terminal notification',async()=>{
  const f=await runningFixture();try{
    await f.repository.transaction(tx=>tx.put(membershipOwner(f.principal.issuer),'scope-memberships',{id:f.principal.subject_id,scopes:[f.scope]}));
    await revokeAppSession(f.repository,{iss:f.principal.issuer,sub:f.principal.subject_id,session_id:f.principal.session_id,exp:9999999999},f.runtime);
    for(const active of f.runtime.chat.active.values())active.controller.abort();
    const before=await f.readRow(),notify=countNotifications(f);await f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict'));
    await f.stop();assert.deepEqual(await f.readRow(),before);assert.equal(before.error.code,'app_session_revoked');assert.equal(failureEvents(before).length,1);assert.equal(notify(),0);
  }finally{await f.stop();}
});

for(const mode of ['expired lease','replacement holder','replacement turn generation'])test(`failure cleanup is fenced by ${mode}`,async()=>{
  const f=await runningFixture();try{
    const before=await f.readRow(),notify=countNotifications(f);
    if(mode==='expired lease'){
      const lease=await f.repository.transaction(tx=>tx.get(f.owner,'native-chat-runtime-leases','runtime'));f.runtime.fence.clock=()=>new Date(Date.parse(lease.lease_until)+1);
    }else await f.repository.transaction(async tx=>{
      if(mode==='replacement holder'){const lease=await tx.get(f.owner,'native-chat-runtime-leases','runtime');await tx.put(f.owner,'native-chat-runtime-leases',{...lease,holder_id:randomUUID(),generation:lease.generation+1});}
      else await tx.put(f.owner,'native-chat-turns',{...before,runtime_generation:before.runtime_generation+1});
    });
    const current=await f.readRow();await assert.rejects(f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict')),e=>e.code===(mode==='replacement turn generation'?'turn_runtime_fenced':'runtime_lease_lost'));
    assert.deepEqual(await f.readRow(),current);assert.equal(notify(),0);for(const active of f.runtime.chat.active.values())active.controller.abort();await f.stop();assert.deepEqual(await f.readRow(),current);assert.equal(f.counters().modelCalls,1);
  }finally{await f.stop();}
});

test('awaited failure metadata write crossing lease expiry rolls back and emits no notification',async()=>{
  const f=await runningFixture();try{
    const before=await f.readRow(),notify=countNotifications(f),lease=await f.repository.transaction(tx=>tx.get(f.owner,'native-chat-runtime-leases','runtime'));let attempted=0;
    interceptTransaction(f,tx=>{const put=tx.put.bind(tx);tx.put=async(owner,kind,value)=>{const saved=await put(owner,kind,value);if(kind==='native-chat-turns'&&value.events.at(-1)?.type==='turn_failed'){attempted++;await Promise.resolve();f.runtime.fence.clock=()=>new Date(Date.parse(lease.lease_until)+1);}return saved;};});
    await assert.rejects(f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict')),e=>e.code==='runtime_lease_lost');
    assert.equal(attempted,1);assert.deepEqual(await f.readRow(),before);assert.equal(notify(),0);await f.stop();assert.deepEqual(await f.readRow(),before);
  }finally{await f.stop();}
});

for(const mode of ['terminal','redacted','deleted'])test(`current ${mode} row after the conversation lock is preserved by stale cleanup`,async()=>{
  const f=await runningFixture();try{
    let expected,changed=false;const notify=countNotifications(f);
    interceptTransaction(f,tx=>{const lock=tx.lock.bind(tx);tx.lock=async(owner,kind,id)=>{await lock(owner,kind,id);if(!changed&&kind==='native-chat-conversations'&&id===f.cid){
      changed=true;const current=await tx.get(owner,'native-chat-turns',f.input.turn_id);
      if(mode==='deleted'){tx.records.delete(tx.key(owner,'native-chat-turns',f.input.turn_id));expected=null;}
      else{expected=mode==='terminal'?{...current,state:'failed',error:{code:'source_deleted'},events:[...current.events,f.runtime.chat.event(current,'turn_failed',{code:'source_deleted'})]}:{...current,content_redacted:true,input:{},history:[],model_history:[],events:[]};await tx.put(owner,'native-chat-turns',expected);}
    }};});
    await f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict'));assert.equal(changed,true);assert.deepEqual(await f.readRow(),expected);assert.equal(notify(),0);
    f.revokeSession();await f.stop();assert.deepEqual(await f.readRow(),expected);
  }finally{await f.stop();}
});

test('real source erasure stays erased and never receives stale text, history or a second terminal event',async()=>{
  const f=await runningFixture();try{
    await f.runtime.deleteChatSource('Bearer fixture',f.scope.scope_id,f.input.message.id);
    const before=await f.readRow(),notify=countNotifications(f);assert.equal(before.content_redacted,true);assert.equal(before.error.code,'source_deleted');
    await f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict'));await f.stop();const after=await f.readRow();
    assert.deepEqual(after,before);assert.equal(notify(),0);assert.equal(failureEvents(after).length,1);assert.doesNotMatch(JSON.stringify(after),/PRIVATE_FIXTURE_TEXT|STALE_BUFFER_MUST_NOT_REAPPEAR|x{600}/);
  }finally{await f.stop();}
});

for(const error of [Object.assign(Error('Synthetic DB failure'),{code:'grant_conflict',status:409}),new ApiError(503,'grant_conflict'),Object.assign(Error('Synthetic lock timeout'),{code:'55P03'})])test(`unexpected source failure ${error.name}/${error.status??error.code} rolls back and surfaces`,async()=>{
  const f=await runningFixture();try{
    const before=await f.readRow(),notify=countNotifications(f);f.setSourceFailure(error);
    await assert.rejects(f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict')),e=>e===error);assert.deepEqual(await f.readRow(),before);assert.equal(notify(),0);
    f.setSourceFailure(null);await f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict'));
  }finally{f.setSourceFailure(null);await f.stop();}
});

test('scope owner mismatch remains denied during revoked-source cleanup',async()=>{
  const f=await runningFixture();let identity;try{
    const before=await f.readRow(),notify=countNotifications(f);f.revokeSession();
    await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,async scoped=>{const row=await scoped.scope();identity=row.identity;await scoped.saveScope({...row,identity:{...row.identity,owner:'catpaw:foreign-synthetic-owner'}});}));
    await assert.rejects(f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict')),e=>e.code==='scope_forbidden');assert.deepEqual(await f.readRow(),before);assert.equal(notify(),0);
  }finally{
    if(identity)await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,async scoped=>{const row=await scoped.scope();await scoped.saveScope({...row,identity});}));await f.stop();
  }
});

test('provider timeout remains unknown after subsequent revocation with no transport resend',async()=>{
  const f=await runningFixture();try{
    const before=await f.readRow();assert.equal(before.dispatch_checkpoint.state,'dispatched');f.revokeSession();
    await f.runtime.chat.fail(failureEnv(f),new ApiError(503,'provider_timeout',{reconciliation:true}));await f.stop();const after=await f.readRow();
    assert.equal(after.state,'outcome_unknown');assert.deepEqual(after.error,{code:'provider_timeout',retryable:false,reconciliation_required:true});assert.equal(failureEvents(after).length,1);assert.deepEqual(after.events.slice(0,-1),before.events);
    const replay=await f.request(`${f.path}/${f.cid}/turns`,f.input);assert.equal(replay.status,409);assert.equal((await replay.json()).error.code,'grant_conflict');assert.equal(f.counters().modelCalls,1);assert.deepEqual(await f.readRow(),after);
  }finally{await f.stop();}
});

test('unexpected database failure during final metadata fence rolls back an awaited write without notifying',async()=>{
  const f=await runningFixture();try{
    const before=await f.readRow(),notify=countNotifications(f),error=Object.assign(Error('Synthetic database disconnect'),{code:'08006'});let writes=0;
    const restore=interceptTransaction(f,tx=>{const put=tx.put.bind(tx);tx.put=async(owner,kind,value)=>{const saved=await put(owner,kind,value);if(kind==='native-chat-turns'&&value.events.at(-1)?.type==='turn_failed'){writes++;await Promise.resolve();f.setSourceFailure(error);}return saved;};});
    await assert.rejects(f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict')),e=>e===error);assert.equal(writes,1);assert.deepEqual(await f.readRow(),before);assert.equal(notify(),0);
    restore();f.setSourceFailure(null);await f.runtime.chat.fail(failureEnv(f),new ApiError(409,'grant_conflict'));
  }finally{f.setSourceFailure(null);await f.stop();}
});

// Serialized fault injection at the last awaited write; not live PostgreSQL or provider evidence.
async function leaseCommitFixture(phase){
  const repository=new TestRepository(),owner='synthetic-commit-fence',scope={scope_id:randomUUID(),permissions:{local_output:true}},principal={subject_id:randomUUID()};
  const cid=randomUUID(),tid=randomUUID();let clock=Date.now(),notifications=0,dispatches=0;
  const fence=new ChatRecoveryFence(repository,{clock:()=>new Date(clock),lease_ms:1000}),token=await fence.acquire(owner,randomUUID());
  const turn={id:tid,conversation_id:cid,scope_id:scope.scope_id,subject_id:principal.subject_id,grant_epoch:1,conversation_revision:2,state:'running',events:[],task_bindings:[],model_history:[],input:{context:[]},runtime_holder_id:token.holder_id,runtime_generation:token.generation};
  const conversation={id:cid,subject_id:principal.subject_id,scope_id:scope.scope_id,grant_epoch:1,revision:phase==='admission'?1:2,state:'active',messages:[],last_turn_id:null};
  await repository.transaction(async tx=>{await tx.put(owner,'native-chat-conversations',conversation);if(phase!=='admission')await tx.put(owner,'native-chat-turns',turn);});
  const integration={prepare:async()=>{},beforeWrite:async(tx,ctx)=>ctx.turn?fence.assertTurnLive(tx,owner,token,ctx.turn):fence.assertLive(tx,owner,token),stampTurn:(tx,o,t)=>fence.stampTurn(tx,o,token,t),capture:async()=>{},renew:()=>fence.renew(owner,token)};
  const provider={identity:{model:'synthetic'},reality:'provider_unverified',async *stream(){dispatches++;yield {type:'text_delta',text:'LATE_SYNTHETIC_TEXT'};yield {type:'done',finish_reason:'stop'};}};
  const chat=new ChatService({facade:{repository,scoped:async()=>({owner,scope,principal})},provider,integration});chat.notify=()=>notifications++;
  const transaction=repository.transaction.bind(repository);repository.transaction=(...args)=>{const callback=args.pop();return transaction(...args,async tx=>{const put=tx.put.bind(tx);tx.put=async(o,kind,value)=>{
    const saved=await put(o,kind,value),event=value.events?.at(-1)?.type;
    if(kind==='native-chat-turns'&&(phase==='admission'&&event==='turn_started'||phase==='delta'&&event==='text_delta'||phase==='tool'&&event==='tool_result'||phase==='completion'&&event==='turn_completed'||phase==='dispatch'&&value.dispatch_checkpoint))clock=Date.parse(token.lease_until)+1;
    return saved;
  };return callback(tx);});};
  const env={owner,scope,principal,turn,signal:new AbortController().signal},read=()=>repository.transaction(async tx=>({turn:await tx.get(owner,'native-chat-turns',tid),conversation:await tx.get(owner,'native-chat-conversations',cid)}));
  return {repository,chat,env,read,cid,tid,scope,counts:()=>({notifications,dispatches})};
}
for(const phase of ['delta','tool','completion'])test(`normal ${phase} write crossing runtime lease expiry rolls back before commit and notification`,async()=>{
  const f=await leaseCommitFixture(phase),before=await f.read();
  const write=phase==='delta'?()=>f.chat.append(f.env,'text_delta',{text:'LATE_SYNTHETIC_TEXT'}):phase==='tool'?()=>f.chat.executeTool(f.env,{id:randomUUID(),name:'agent_status',arguments:{}}):()=>f.chat.complete(f.env,randomUUID(),'LATE_SYNTHETIC_TEXT',[{role:'assistant',content:'LATE_SYNTHETIC_TEXT'}]);
  await assert.rejects(write(),e=>e.code==='runtime_lease_lost');assert.deepEqual(await f.read(),before);assert.deepEqual(f.counts(),{notifications:0,dispatches:0});
});
test('admission crossing runtime lease expiry rolls back the original intent and never starts execution',async()=>{
  const f=await leaseCommitFixture('admission'),before=await f.read();let executions=0;f.chat.execute=async()=>{executions++;};
  const input={turn_id:f.tid,expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'Synthetic original intent'},context:[]};
  await assert.rejects(f.chat.startTurn('Bearer synthetic',f.scope.scope_id,f.cid,input),e=>e.code==='runtime_lease_lost');
  assert.deepEqual(await f.read(),before);assert.equal(executions,0);assert.equal(f.chat.active.size,0);assert.deepEqual(f.counts(),{notifications:0,dispatches:0});
});
test('dispatch checkpoint crossing runtime lease expiry rolls back before model transport',async()=>{
  const f=await leaseCommitFixture('dispatch'),before=await f.read(),controller=new AbortController();
  f.env.turn.events=[f.chat.event(f.env.turn,'turn_started',{})];
  await f.chat.execute({...f.env,signal:controller.signal,controller});
  assert.deepEqual(await f.read(),before);assert.deepEqual(f.counts(),{notifications:0,dispatches:0});
});
