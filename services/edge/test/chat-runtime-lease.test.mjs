// Runtime lease (chat_runtime_busy) — v48 prod finding: a turn rejected before the model call (403 consent) kept the
// per-owner 60 s lease, so send → 403 → re-consent → immediate resend on another isolate got 503 retryable:false.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ChatRecoveryFence} from '../supabase/functions/_shared/core/integration/server-foundation/src/chat-recovery.mjs';
import {ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';

const latch=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
const LEASE='native-chat-runtime-leases';

async function fixture({consent=true}={}){
  const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
  const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
  const config=readConfig(k=>({CATPAW_DATABASE_URL:'offline-only',CATPAW_PRIVATE_MODEL_KEY:'offline-only',CATPAW_TICK_HMAC_KEY:'offline-only-key-thirty-two-characters',CATPAW_MEMORY_GUARD_KEY:'offline-only-guard'}[k]));
  const control={mode:'ok',gate:null,calls:0};
  const provider={identity:{model:config.route.model},reality:'provider_unverified',assertReady(){},async *stream(){
    control.calls++;if(control.gate)await control.gate.promise;
    if(control.mode==='throw')throw new ApiError(502,'provider_unavailable');
    yield {type:'text_delta',text:'ok'};yield {type:'done',finish_reason:'stop'};
  }};
  const retained=[];
  const make=()=>createCloudRuntime({repository,config,provider,autoKick:false,diagnostic:()=>{},retain:p=>retained.push(p),authenticate:async()=>principal,sourceChecker:async()=>{}});
  // Two isolates of the same function: same database, different random holder ids.
  const a=await make(),b=await make();assert.notEqual(a.holderId,b.holderId);
  await a.foundation.bootstrapScope(principal,scope.scope_id);
  await repository.transaction(async tx=>{await tx.put(membershipOwner(principal.issuer),'app-sessions',{id:principal.session_id,subject_id:principal.subject_id,state:'active',expires_at:9999999999});});
  const cid=randomUUID(),path=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`;
  const request=(rt,p,body)=>rt.api(new Request('https://offline.example.invalid'+p,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer fixture','Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}}));
  assert.equal((await request(a,path,{conversation_id:cid})).status,201);
  const giveConsent=async rt=>assert.equal((await request(rt,`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash})).status,200);
  if(consent)await giveConsent(a);
  const turn=(rev=1)=>({turn_id:randomUUID(),expected_revision:rev,expected_grant_epoch:1,message:{id:randomUUID(),text:'hello'},context:[]});
  const post=(rt,input)=>request(rt,`${path}/${cid}/turns`,input);
  const owner=a.facade.owner(scope);
  const lease=()=>repository.transaction(tx=>tx.get(owner,LEASE,'runtime'));
  const leaseFree=async()=>{const l=await lease();return !l||Date.parse(l.lease_until)<=Date.now();};
  const idle=async()=>{for(const rt of [a,b])await rt.chat.waitIdle();await Promise.allSettled(retained);};
  const stop=async()=>{control.gate?.resolve();await idle();for(const rt of [a,b])await rt.worker.stop();};
  return {a,b,repository,config,control,post,turn,giveConsent,lease,leaseFree,idle,stop,owner};
}

test('403 consent → re-consent → immediate resend on another instance gets 200 (not 503 chat_runtime_busy)',async()=>{
  const f=await fixture({consent:false});
  const rejected=await f.post(f.a,f.turn());
  assert.equal(rejected.status,403);assert.equal((await rejected.json()).error.code,'provider_consent_required');
  assert.equal(f.control.calls,0,'rejected before any model call');
  assert.ok(await f.leaseFree(),'a turn rejected before the model call holds no runtime lease');
  await f.giveConsent(f.a);
  const resent=await f.post(f.b,f.turn());
  assert.equal(resent.status,200,'resend on the other instance is admitted immediately');
  await resent.body.cancel();await f.stop();
});

test('validation-style rejection inside admission (revision conflict) also leaves no lease',async()=>{
  const f=await fixture();
  const bad=await f.post(f.a,f.turn(99));assert.equal(bad.status,409);
  assert.ok(await f.leaseFree());
  const ok=await f.post(f.b,f.turn());assert.equal(ok.status,200);await ok.body.cancel();await f.stop();
});

test('lease is released after a turn completes normally (not only by 60 s expiry)',async()=>{
  const f=await fixture();
  const r=await f.post(f.a,f.turn());assert.equal(r.status,200);await r.text();await f.idle();
  const l=await f.lease();assert.equal(l.holder_id,f.a.holderId);assert.ok(Date.parse(l.lease_until)<=Date.now(),'expired on completion');
  const next=await f.post(f.b,f.turn(2));assert.equal(next.status,200);await next.text();await f.stop();
});

test('lease is released after the turn throws (provider failure)',async()=>{
  const f=await fixture();f.control.mode='throw';
  const r=await f.post(f.a,f.turn());assert.equal(r.status,200);const text=await r.text();assert.match(text,/turn_failed/);await f.idle();
  assert.ok(await f.leaseFree(),'released in finally after a thrown turn');
  f.control.mode='ok';const next=await f.post(f.b,f.turn(1));assert.notEqual(next.status,503);await next.body?.cancel();await f.stop();
});

test('busy: 503 chat_runtime_busy is retryable:true with Retry-After (seconds to lease expiry, ≥1)',async()=>{
  const f=await fixture();f.control.gate=latch();
  const running=await f.post(f.a,f.turn());assert.equal(running.status,200);const reader=running.body.getReader();await reader.read();
  const busy=await f.post(f.b,f.turn());
  assert.equal(busy.status,503);
  const body=await busy.json();assert.equal(body.error.code,'chat_runtime_busy');assert.equal(body.error.retryable,true);assert.equal(body.error.reconciliation_required,false);
  const ra=Number(busy.headers.get('retry-after'));assert.ok(Number.isInteger(ra)&&ra>=1&&ra<=60,`Retry-After=${ra}`);
  assert.ok(await f.lease().then(l=>l.holder_id===f.a.holderId&&Date.parse(l.lease_until)>Date.now()),'busy rejection does not disturb the holder');
  f.control.gate.resolve();await reader.cancel();await f.idle();
  const after=await f.post(f.b,f.turn(2));assert.equal(after.status,200);await after.body.cancel();await f.stop();
});

test('owner-checked release: a stale or foreign token never frees the live lease',async()=>{
  const repository=new TestRepository();let now=Date.parse('2026-10-17T00:00:00Z');
  const fence=new ChatRecoveryFence(repository,{clock:()=>new Date(now),lease_ms:60000});
  const owner='owner-1',A=randomUUID(),B=randomUUID();
  const tA=await fence.acquire(owner,A);assert.ok(tA);
  assert.equal(await fence.release(owner,{holder_id:B,generation:tA.generation}),false,'foreign holder');
  assert.equal(await fence.release(owner,{holder_id:A,generation:tA.generation+1}),false,'wrong generation');
  assert.equal(await fence.release(owner,null),false);
  assert.equal(await fence.acquire(owner,B),null,'still held by A');
  assert.equal(await fence.remainingMs(owner),60000);
  // A's lease expires, B takes a new generation; A's old token must not free B's lease.
  now+=61000;const tB=await fence.acquire(owner,B);assert.ok(tB&&tB.generation===tA.generation+1);
  assert.equal(await fence.release(owner,tA),false);assert.equal(await fence.acquire(owner,A),null);
  assert.equal(await fence.release(owner,tB),true);assert.equal(await fence.remainingMs(owner),0);
  assert.ok(await fence.acquire(owner,A),'free after owner release');
});

test('same instance, overlapping holds: first turn finishing does not drop the lease of a still-running turn',async()=>{
  const f=await fixture();f.control.gate=latch();
  const first=await f.post(f.a,f.turn());assert.equal(first.status,200);const reader=first.body.getReader();await reader.read();
  // A rejected request on the same instance must not release the lease the running turn still needs.
  assert.equal((await f.post(f.a,f.turn(99))).status,409);
  assert.ok(await f.lease().then(l=>l.holder_id===f.a.holderId&&Date.parse(l.lease_until)>Date.now()),'running turn keeps the lease');
  f.control.gate.resolve();await reader.cancel();await f.idle();assert.ok(await f.leaseFree());await f.stop();
});
