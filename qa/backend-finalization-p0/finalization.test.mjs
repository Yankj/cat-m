import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {consentId} from '../supabase/functions/_shared/consent.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';

// Fresh QA-owned setup, not the owner's fixture. Manually seeded, admitted-shaped turn.
// No provider dispatch: even a single attempt is a fixture failure.
async function fixture() {
  const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
  const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://qa.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
  const config=readConfig(k=>({CATPAW_DATABASE_URL:'synthetic-offline',CATPAW_PRIVATE_MODEL_KEY:'synthetic-never-used',CATPAW_TICK_HMAC_KEY:'synthetic-never-used-thirty-two-characters',CATPAW_MEMORY_GUARD_KEY:'synthetic-qa-guard'}[k]));
  let sourceError=null,providerCalls=0;
  const provider={identity:{model:config.route.model},reality:'injected_synthetic_offline',assertReady(){},async *stream(){providerCalls++;throw Error('QA fixture must never dispatch a model');}};
  const runtime=await createCloudRuntime({repository,config,provider,autoKick:false,diagnostic:()=>{},authenticate:async()=>principal,sourceChecker:async()=>{if(sourceError)throw sourceError;}});
  await runtime.foundation.bootstrapScope(principal,scope.scope_id);
  const owner=runtime.facade.owner(scope),cid=randomUUID();
  await runtime.chat.createConversation('Bearer synthetic-only',scope.scope_id,{conversation_id:cid});
  await runtime.chat.integration.prepare({owner,scope,principal});
  const input={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'synthetic original question'},context:[]};
  const trusted=await runtime.chat.scoped('Bearer synthetic-only',scope.scope_id);
  let turn={id:input.turn_id,conversation_id:cid,scope_id:scope.scope_id,subject_id:principal.subject_id,grant_epoch:1,conversation_revision:1,state:'running',admission_hash:hash({input,conversation_id:cid,scope:trusted.scope,subject:principal.subject_id,model:runtime.chat.provider.identity}),history:[{role:'user',content:'synthetic durable history'}],model_history:[{role:'user',content:'synthetic model history'}],input,events:[],task_bindings:[],dispatch_checkpoint:{state:'dispatched'},source_auth:{subject_id:principal.subject_id,scope_id:scope.scope_id,session_id:principal.session_id,issuer:principal.issuer,issued_at:1,consent_revision:1},request_hash:'synthetic-request-hash'};
  await repository.transaction(async tx=>{
    await tx.put(owner,'provider-consents',{id:consentId(principal.subject_id,cid),scope_id:scope.scope_id,subject_id:principal.subject_id,decision:'allow',revision:1,route_hash:config.routeHash});
    turn=await runtime.chat.integration.stampTurn(tx,owner,turn);
    turn.events=[runtime.chat.event(turn,'turn_started',{request_hash:turn.request_hash}),runtime.chat.event({...turn,events:[{}]},'text_delta',{message_id:randomUUID(),text:'synthetic already committed partial'})];
    await tx.put(owner,'native-chat-turns',turn);
  });
  let notifications=0;runtime.chat.listeners.set(`${owner}:${turn.id}`,new Set([()=>notifications++]));
  const read=()=>repository.transaction(tx=>tx.get(owner,'native-chat-turns',turn.id));
  const env={owner,scope,principal,turn:{...structuredClone(turn),history:[{role:'assistant',content:'SYNTHETIC_STALE_BUFFER'}]},signal:new AbortController().signal,assertLive(){}};
  const mutate=fn=>repository.transaction(async tx=>{const t=await tx.get(owner,'native-chat-turns',turn.id);await tx.put(owner,'native-chat-turns',fn(t));});
  const close=async()=>{await runtime.worker.stop();assert.equal(providerCalls,0);};
  return {repository,runtime,scope,principal,owner,cid,turn,input,env,read,mutate,close,source:e=>{sourceError=e;},notifications:()=>notifications};
}
const sourceDenied=()=>new ApiError(409,'grant_conflict');
const interrupted=()=>new DOMException('synthetic aborted','AbortError');

test('revocation permits one static receipt but no text, tool, completion, or observation',async()=>{
  const f=await fixture();try {
    const before=await f.read();f.source(sourceDenied());
    await assert.rejects(f.runtime.chat.append(f.env,'text_delta',{text:'SYNTHETIC_LATE_TEXT'}),e=>e.code==='grant_conflict');
    await assert.rejects(f.runtime.chat.executeTool(f.env,{name:'agent_status',id:'synthetic-call',arguments:{}}),e=>e.code==='grant_conflict');
    await assert.rejects(f.runtime.chat.complete(f.env,randomUUID(),'SYNTHETIC_LATE_COMPLETION',[]),e=>e.code==='grant_conflict');
    await f.runtime.chat.fail(f.env,interrupted());
    const after=await f.read();assert.equal(after.state,'failed');assert.deepEqual(after.error,{code:'grant_conflict',retryable:false,reconciliation_required:false});
    assert.deepEqual(after.events.slice(0,-1),before.events);assert.equal(after.events.at(-1).type,'turn_failed');assert.deepEqual(after.events.at(-1).data,after.error);
    for(const key of ['history','model_history','input','task_bindings','source_auth','dispatch_checkpoint'])assert.deepEqual(after[key],before[key]);
    assert.doesNotMatch(JSON.stringify(after),/SYNTHETIC_(LATE|STALE)/);assert.equal(f.notifications(),1);
    await assert.rejects(f.runtime.chat.readTurn('Bearer synthetic-only',f.scope.scope_id,f.cid,f.turn.id),e=>e.code==='grant_conflict');
  }finally{await f.close();}
});

test('consent denial permits static failure and still forbids publication',async()=>{
  const f=await fixture();try {
    await f.repository.transaction(async tx=>{const row=await tx.get(f.owner,'provider-consents',consentId(f.principal.subject_id,f.cid));await tx.put(f.owner,'provider-consents',{...row,decision:'deny',revision:2});});
    const before=await f.read();await assert.rejects(f.runtime.chat.append(f.env,'text_delta',{text:'SYNTHETIC_LATE_TEXT'}),e=>e.code==='provider_consent_required');
    await f.runtime.chat.fail(f.env,interrupted());const after=await f.read();assert.equal(after.error.code,'provider_consent_required');assert.deepEqual(after.events.slice(0,-1),before.events);assert.equal(f.notifications(),1);
  }finally{await f.close();}
});

for(const mode of ['expired','new-holder','new-generation','new-turn-holder'])test(`revocation cannot bypass ${mode} fence`,async()=>{
  const f=await fixture();try {
    f.source(sourceDenied());
    if(mode==='expired'){
      const lease=await f.repository.transaction(tx=>tx.get(f.owner,'native-chat-runtime-leases','runtime'));f.runtime.fence.clock=()=>new Date(Date.parse(lease.lease_until)+1);
    }else if(mode==='new-turn-holder')await f.mutate(t=>({...t,runtime_holder_id:randomUUID()}));
    else await f.repository.transaction(async tx=>{const lease=await tx.get(f.owner,'native-chat-runtime-leases','runtime');await tx.put(f.owner,'native-chat-runtime-leases',{...lease,...(mode==='new-holder'?{holder_id:randomUUID()}:{generation:lease.generation+1})});});
    const before=await f.read();await assert.rejects(f.runtime.chat.fail(f.env,interrupted()),e=>e.code===(mode==='new-turn-holder'?'turn_runtime_fenced':'runtime_lease_lost'));
    assert.deepEqual(await f.read(),before);assert.equal(f.notifications(),0);
  }finally{await f.close();}
});

function intercept(f,decorate) {
  const original=f.repository.transaction.bind(f.repository);
  f.repository.transaction=(...args)=>{const fn=args.pop();return original(...args,async tx=>{decorate(tx);return fn(tx);});};
}
for(const mode of ['terminal','unknown','redacted','deleted'])test(`fresh ${mode} row after conversation lock is preserved`,async()=>{
  const f=await fixture();try {
    let expected,changed=false;
    intercept(f,tx=>{const lock=tx.lock.bind(tx);tx.lock=async(owner,kind,id)=>{await lock(owner,kind,id);if(!changed&&kind==='native-chat-conversations'){
      changed=true;const current=await tx.get(owner,'native-chat-turns',f.turn.id);
      if(mode==='deleted'){tx.records.delete(tx.key(owner,'native-chat-turns',f.turn.id));expected=null;}
      else {expected=mode==='redacted'?{...current,content_redacted:true,history:[],model_history:[],input:{},events:[]}: {...current,state:mode==='unknown'?'outcome_unknown':'completed',finished_at:'synthetic-terminal'};await tx.put(owner,'native-chat-turns',expected);}
    }};});
    await f.runtime.chat.fail(f.env,interrupted());assert.equal(changed,true);assert.deepEqual(await f.read(),expected);assert.equal(f.notifications(),0);
  }finally{await f.close();}
});

test('metadata put crossing lease expiry rolls back the write and notification',async()=>{
  const f=await fixture();try {
    f.source(sourceDenied());const before=await f.read(),lease=await f.repository.transaction(tx=>tx.get(f.owner,'native-chat-runtime-leases','runtime'));let writes=0;
    intercept(f,tx=>{const put=tx.put.bind(tx);tx.put=async(owner,kind,value)=>{const saved=await put(owner,kind,value);if(kind==='native-chat-turns'){writes++;f.runtime.fence.clock=()=>new Date(Date.parse(lease.lease_until)+1);}return saved;};});
    await assert.rejects(f.runtime.chat.fail(f.env,interrupted()),e=>e.code==='runtime_lease_lost');assert.equal(writes,1);assert.deepEqual(await f.read(),before);assert.equal(f.notifications(),0);
  }finally{await f.close();}
});

for(const mode of ['foreign-owner','foreign-source-subject','foreign-source-scope'])test(`${mode} cannot use denial exception`,async()=>{
  const f=await fixture();try {
    f.source(sourceDenied());
    if(mode==='foreign-owner')await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,async scoped=>{const row=await scoped.scope();await scoped.saveScope({...row,identity:{...row.identity,owner:'catpaw:synthetic-foreign'}});}));
    else await f.mutate(t=>({...t,source_auth:{...t.source_auth,...(mode==='foreign-source-subject'?{subject_id:randomUUID()}:{scope_id:randomUUID()})}}));
    const before=await f.read();await assert.rejects(f.runtime.chat.fail(f.env,interrupted()),e=>e.code===(mode==='foreign-owner'?'scope_forbidden':'failure_source_mismatch'));assert.deepEqual(await f.read(),before);assert.equal(f.notifications(),0);
  }finally{await f.close();}
});

for(const error of [Object.assign(Error('synthetic shaped error'),{status:409,code:'grant_conflict'}),new ApiError(503,'grant_conflict'),new ApiError(409,'unexpected_code')])test(`only typed expected denial is exempt: ${error.name}/${error.status}/${error.code}`,async()=>{
  const f=await fixture();try {
    f.source(error);const before=await f.read();await assert.rejects(f.runtime.chat.fail(f.env,interrupted()),e=>e===error);assert.deepEqual(await f.read(),before);assert.equal(f.notifications(),0);
  }finally{await f.close();}
});

test('dispatched timeout remains unknown through repeated failure and duplicate POST',async()=>{
  const f=await fixture();try {
    f.source(sourceDenied());const before=await f.read();
    await f.runtime.chat.fail(f.env,new ApiError(503,'provider_timeout',{reconciliation:true}));const after=await f.read();assert.equal(after.state,'outcome_unknown');assert.deepEqual(after.error,{code:'provider_timeout',retryable:false,reconciliation_required:true});assert.deepEqual(after.events.slice(0,-1),before.events);
    await f.runtime.chat.fail(f.env,sourceDenied());assert.deepEqual(await f.read(),after);assert.equal(f.notifications(),1);
    // Exact same frozen admission replays the existing turn and never executes it.
    const replay=await f.runtime.chat.startTurn('Bearer synthetic-only',f.scope.scope_id,f.cid,f.input);assert.equal(replay.replayed,true);assert.equal(replay.turn.state,'outcome_unknown');assert.deepEqual(await f.read(),after);
    // The HTTP observation gate still rejects the revoked viewer before SSE output.
    const response=await f.runtime.api(new Request(`https://qa.example.invalid/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${f.cid}/turns`,{method:'POST',headers:{Authorization:'Bearer synthetic-only','Content-Type':'application/json'},body:JSON.stringify(f.input)}));
    assert.equal(response.status,409);assert.equal((await response.json()).error.code,'grant_conflict');assert.deepEqual(await f.read(),after);
  }finally{await f.close();}
});

test('concurrent and sequential fail produce one event and one notification',async()=>{
  const f=await fixture();try {
    f.source(sourceDenied());const before=await f.read();await Promise.all(Array.from({length:8},()=>f.runtime.chat.fail(f.env,interrupted())));const after=await f.read();
    assert.equal(after.events.length,before.events.length+1);assert.equal(after.events.filter(e=>e.type==='turn_failed').length,1);assert.equal(f.notifications(),1);
    await f.runtime.chat.fail(f.env,new ApiError(503,'provider_timeout',{reconciliation:true}));assert.deepEqual(await f.read(),after);assert.equal(f.notifications(),1);
  }finally{await f.close();}
});

test('integration without beforeFailure retains strict beforeWrite fallback',async()=>{
  const f=await fixture();try {
    delete f.runtime.chat.integration.beforeFailure;f.source(sourceDenied());const before=await f.read();await assert.rejects(f.runtime.chat.fail(f.env,interrupted()),e=>e.code==='grant_conflict');assert.deepEqual(await f.read(),before);assert.equal(f.notifications(),0);
  }finally{await f.close();}
});
