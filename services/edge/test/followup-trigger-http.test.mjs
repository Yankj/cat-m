import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {revisionWorkHTTPFixture} from './fixtures/revision-work-http-fixture.mjs';

const base=f=>`/catpaw/followups/v1/scopes/${f.scope.scope_id}`;
const input=f=>({schema_version:1,contract:'catpaw.followup-trigger.v1',operation_id:randomUUID(),trigger_id:randomUUID(),configuration:{title:'Follow the fictional report',origin:{conversation_id:f.cid,run_id:f.run.id,task_id:f.run.task_id,request_hash:f.run.request_hash},schedule:{kind:'fixed_interval',time_zone:'Asia/Shanghai',first_due_at:new Date(f.now()+60000).toISOString(),interval_seconds:3600},end:{not_after:new Date(f.now()+86400000).toISOString(),max_occurrences:2},budget:{per_due_execution_ms:10000,total_execution_ms:20000,model_calls:2,source_reads:2},quiet_hours:{start_minute:1320,end_minute:480}}});
const denied=async(response,status,code)=>{const value=await response.json();assert.equal(response.status,status,JSON.stringify(value));if(code)assert.equal(value.error.code,code);assert.equal(value.error.retryable,false);};
const get=async(f,path,auth)=>f.json(await f.req(path,undefined,auth));

test('actual maintained HTTP persists followup configuration, original receipt and scoped list without dispatch or grant expansion',async()=>{
 const f=await revisionWorkHTTPFixture();try {
  const before={calls:f.calls.length,ticks:f.ticks(),reads:f.reads()},oldGrant=await f.rows('catpaw-work-grants'),request=input(f),url=base(f)+'/triggers';
  const created=await f.json(await f.req(url,request));assert.equal(created.trigger.id,request.trigger_id);assert.equal(created.trigger.status,'configured');assert.equal(created.trigger.capability.execution_authorized,false);assert.equal(created.trigger.capability.scheduler_connected,false);
  const original=await get(f,base(f)+'/operations/'+request.operation_id);assert.deepEqual(original.receipt,created.receipt);
  const snapshot=f.repository.snapshot(),detail=await get(f,url+'/'+request.trigger_id),list=await get(f,url);assert.deepEqual(detail.trigger,created.trigger);assert.deepEqual(detail.dues,[]);assert.equal(list.triggers.length,1);assert.equal(list.triggers[0].id,request.trigger_id);assert.deepEqual(f.repository.snapshot(),snapshot);
  assert.deepEqual(await f.rows('catpaw-work-grants'),oldGrant);assert.deepEqual({calls:f.calls.length,ticks:f.ticks(),reads:f.reads()},before);
  const ready=await get(f,'/readyz');assert.equal(ready.chat_capabilities.followups.configure,true);assert.equal(ready.chat_capabilities.followups.independent_scheduler,false);assert.equal(ready.chat_capabilities.accepted_work.single_run,true);
 } finally {f.stop();}
});

test('same original create is idempotent; changed original body and stale commands cannot mutate configuration',async()=>{
 const f=await revisionWorkHTTPFixture();try {
  const request=input(f),url=base(f)+'/triggers',first=await f.json(await f.req(url,request));
  const second=await f.json(await f.req(url,request));assert.equal(second.created,false);assert.deepEqual(second.receipt,first.receipt);
  const changed=structuredClone(request);changed.configuration.title='Changed same operation';await denied(await f.req(url,changed),409,'followup_operation_conflict');
  const command={schema_version:1,contract:request.contract,operation_id:randomUUID(),action:'pause',expected_revision:1};const pause=await f.json(await f.req(url+'/'+request.trigger_id+'/commands',command));assert.equal(pause.trigger.status,'paused');
  const original=await get(f,base(f)+'/operations/'+command.operation_id);assert.deepEqual(original.receipt,pause.receipt);
  await denied(await f.req(url+'/'+request.trigger_id+'/commands',{...command,operation_id:randomUUID(),action:'resume'}),409);
 } finally {f.stop();}
});

test('followup origin is bound to the actual maintained run and actor; no forged task or foreign lookup',async()=>{
 const f=await revisionWorkHTTPFixture();try {
  const request=input(f),url=base(f)+'/triggers';await f.json(await f.req(url,request));
  const foreign=await get(f,url,'Bearer foreign');assert.deepEqual(foreign.triggers,[]);
  await denied(await f.req(url+'/'+request.trigger_id,undefined,'Bearer foreign'),404);
  await denied(await f.req(base(f)+'/operations/'+request.operation_id,undefined,'Bearer foreign'),404);
  const forged=input(f);forged.configuration.origin.task_id='a'.repeat(64);await denied(await f.req(url,forged),409,'followup_origin_mismatch');
  await denied(await f.req(url.replace(f.scope.scope_id,randomUUID())),403,'scope_forbidden');
 } finally {f.stop();}
});

test('followup HTTP rejects duplicate JSON, oversized bodies, unknown fields and user materialize endpoints',async()=>{
 const f=await revisionWorkHTTPFixture();try {
  const request=input(f),url=base(f)+'/triggers',before=f.repository.snapshot();
  const raw=JSON.stringify(request).replace('"operation_id":','"operation_id":"'+randomUUID()+'","operation_id":');await denied(await f.rawReq(url,raw),422,'followup_duplicate_key');
  await denied(await f.rawReq(url,' '.repeat(12001)),413,'followup_request_too_large');
  await denied(await f.req(url,{...request,execution_authorized:true}),422,'followup_schema_invalid');
  await denied(await f.req(url+'?schedule=now'),422,'followup_query_invalid');
  await denied(await f.req(url+'/'+request.trigger_id+'/materialize',{}),404,'route_not_supported');
  assert.deepEqual(f.repository.snapshot(),before);
 } finally {f.stop();}
});

test('revoked origin remains readable and stoppable, while resuming cannot restore source authority',async()=>{
 const f=await revisionWorkHTTPFixture();try {
  const request=input(f),url=base(f)+'/triggers';await f.json(await f.req(url,request));await f.invalidate('conversation');
  const detail=await get(f,url+'/'+request.trigger_id);assert.equal(detail.trigger.source_current,false);
  const command={schema_version:1,contract:request.contract,operation_id:randomUUID(),action:'pause',expected_revision:1};const pause=await f.json(await f.req(url+'/'+request.trigger_id+'/commands',command));assert.equal(pause.trigger.status,'paused');
  await denied(await f.req(url+'/'+request.trigger_id+'/commands',{...command,operation_id:randomUUID(),action:'resume',expected_revision:pause.trigger.revision}),403);
  const stopped=await f.json(await f.req(url+'/'+request.trigger_id+'/commands',{...command,operation_id:randomUUID(),action:'revoke',expected_revision:pause.trigger.revision}));assert.equal(stopped.trigger.status,'revoked');
 } finally {f.stop();}
});

test('even an empty followup catalog requires fresh current viewer authority',async()=>{
 const f=await revisionWorkHTTPFixture();try {
  const url=base(f)+'/triggers';assert.deepEqual((await get(f,url)).triggers,[]);
  await f.mutateSession(f.principal,{state:'revoked'});
  await denied(await f.req(url),409,'grant_conflict');
 } finally {f.stop();}
});
