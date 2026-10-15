import test from 'node:test';
import assert from 'node:assert/strict';
import {clone,hash,canonical} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {TASK_WORK_GRANT_KINDS as K,workGrantReference,workGrantReceiptHash,validateWorkGrantRunBinding} from '../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {createNativeAcceptedWorkWireFixture,generateNativeAcceptedWorkWire,decodeFixtureSSE,nativeFixtureDomainSnapshot} from './fixtures/generate-native-accepted-work-wire.mjs';
import {parseNativeAcceptedWorkServerOptions,nativeLoopbackRouteNotice} from './fixtures/native-accepted-work-server.mjs';

test('actual native text wrapper binds exact current body to accepted intent, run, terms and original receipt',async()=>{
 const f=await createNativeAcceptedWorkWireFixture();try{
  const ready=await f.json('/readyz');assert.equal(ready.chat_capabilities.accepted_work.enabled,true);assert.equal(ready.chat_capabilities.accepted_work.native_producer,false);assert.equal(ready.chat_capabilities.accepted_work.execution,'bounded_single_step_v1');
  assert.deepEqual(Object.keys(f.turn).sort(),['context','expected_grant_epoch','expected_revision','message','turn_id']);
  const reordered={context:f.turn.context,message:{text:f.turn.message.text,id:f.turn.message.id},expected_grant_epoch:f.turn.expected_grant_epoch,expected_revision:f.turn.expected_revision,turn_id:f.turn.turn_id};
  assert.equal(canonical(reordered),canonical(f.turn));assert.equal(hash(reordered),f.work.input_hash);
  const response=await f.req(f.workPath,{...f.request,turn:reordered});assert.equal(response.status,200);await response.text();await f.drain();
  const [turn]=await f.rows('native-chat-turns'),[run]=await f.rows('catpaw-runs'),[record]=await f.rows(K.terms),binding=(await f.json(f.workPath+'/'+f.turn.turn_id)).turn.task_bindings[0];
  assert.deepEqual(turn.input,reordered);assert.equal(turn.work_intent.input_hash,hash(turn.input));assert.equal(record.terms.input_hash,hash(reordered));assert.equal(record.terms.scope.owner,f.owner);assert.equal(run.frozen_request.current_input_hash,f.work.input_hash);
  assert.deepEqual(run.frozen_request.work_grant_reference,workGrantReference(record.terms));assert.deepEqual(record.run_binding,validateWorkGrantRunBinding(record.terms,run));assert.equal(record.receipt.receipt_hash,workGrantReceiptHash(record.receipt));assert.equal(binding.run_id,run.id);assert.equal(record.receipt.task_completed,false);
 }finally{await f.stop();}
});

test('durable initial SSE is only turn acceptance; observation cancellation cannot cancel the original accepted work',async()=>{
 const f=await createNativeAcceptedWorkWireFixture({holdChat:true});try{
  const response=await f.req(f.workPath,f.request),reader=response.body.getReader(),first=await reader.read(),event=decodeFixtureSSE(new TextDecoder().decode(first.value))[0];assert.equal(event.type,'turn_started');assert.equal(event.contract,'catpaw.native-chat.v1');assert.equal(event.sequence,1);
  assert.deepEqual(await f.rows('catpaw-runs'),[]);assert.deepEqual(await f.rows(K.terms),[]);await reader.cancel();f.releaseChat();await f.drain();
  const snapshot=await f.json(f.workPath+'/'+f.turn.turn_id);assert.equal(snapshot.contract,'catpaw.accepted-work-intent.v1');assert.equal(snapshot.turn.task_bindings.length,1);assert.equal((await f.rows('tasks'))[0].status,'queued');assert.equal(f.calls.length,1);
 }finally{f.releaseChat();await f.drain();await f.stop();}
});

test('actual accepted-work GET and cursor SSE recover the same original events without another model or grant',async()=>{
 const f=await createNativeAcceptedWorkWireFixture();try{
  const response=await f.req(f.workPath,f.request),raw=await response.text();await f.drain();const before=nativeFixtureDomainSnapshot(f.repository),full=await f.json(f.workPath+'/'+f.turn.turn_id),tail=await f.json(`${f.chatPath}/turns/${f.turn.turn_id}?after_sequence=1`);
  const observed=decodeFixtureSSE(await (await f.req(`${f.chatPath}/turns/${f.turn.turn_id}/events?after_sequence=1`)).text());
  assert.deepEqual(decodeFixtureSSE(raw),full.turn.events);assert.deepEqual(observed,full.turn.events.slice(1));assert.deepEqual(tail.turn.events,observed);assert.equal(tail.turn.next_cursor,full.turn.next_cursor);assert.deepEqual(nativeFixtureDomainSnapshot(f.repository),before);assert.equal(f.calls.length,1);
  await f.restart();const cold=await f.json(f.workPath+'/'+f.turn.turn_id);assert.deepEqual(cold,full);const replay=await f.json(f.workPath,f.request);assert.equal(replay.replayed,true);assert.deepEqual(replay.turn,full.turn);assert.equal(f.calls.length,1);assert.deepEqual(nativeFixtureDomainSnapshot(f.repository),before);
 }finally{await f.stop();}
});

test('native frozen input hash covers message, contexts and server revisions; changed wire cannot create a turn',async()=>{
 for(const change of [turn=>{turn.message.text+=' changed';},turn=>{turn.context[0].text+=' changed';},turn=>{turn.expected_revision++;},turn=>{turn.expected_grant_epoch++;},turn=>{turn.message.id=turn.turn_id;}]){
  const f=await createNativeAcceptedWorkWireFixture();try{const request=clone(f.request);change(request.turn);const before=f.repository.snapshot(),response=await f.req(f.workPath,request);assert.equal(response.status,409);assert.equal((await response.json()).error.code,'work_intent_input_conflict');assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,0);}finally{await f.stop();}
 }
});

test('a renewed viewer can recover original grant after origin expiry; neither old HTTP nor readiness extends it',async()=>{
 const f=await createNativeAcceptedWorkWireFixture();try{
  await (await f.req(f.workPath,f.request)).text();await f.drain();const initial=await f.json(f.workPath+'/'+f.turn.turn_id),binding=initial.turn.task_bindings[0],path=`/catpaw/work-grants/v1/scopes/${f.scope.scope_id}/runs/${binding.run_id}/grant`,grant=await f.json(path);await f.expireOrigin();
  for(const p of [path,f.workPath+'/'+f.turn.turn_id]){const denied=await f.req(p);assert.equal(denied.status,409);assert.equal((await denied.json()).error.code,'grant_conflict');}
  await f.freshViewer();await f.restart();assert.deepEqual(await f.json(path),grant);assert.deepEqual(await f.json(f.workPath+'/'+f.turn.turn_id),initial);assert.equal(f.calls.length,1);
  const prior=await f.repository.transaction(tx=>tx.get(membershipOwner(f.actor.issuer),'app-sessions',f.actor.session_id));assert.equal(prior.expires_at,0);
 }finally{await f.stop();}
});

test('generated actual Cloud wires separate original grant receipt, successful ack and unknown original outcome',async()=>{
 const wire=await generateNativeAcceptedWorkWire();assert.equal(wire.input_hash,hash(wire.request.turn));assert.equal(wire.input_hash,hash(wire.canonical_turn));assert.equal(wire.readyz.chat_capabilities.accepted_work.native_producer,false);assert.equal(wire.model_route.route_hash,wire.request.work.route_hash);
 assert.equal(wire.grant_accepted.receipt.task_completed,false);assert.equal(wire.final_grant.receipt.task_completed,false);assert.deepEqual(wire.grant_accepted.receipt,wire.final_grant.receipt);assert.deepEqual(wire.final_grant.grant.consumed,{due:1,model:1,source:0});assert.equal(wire.final_grant.grant.remaining.model,0);
 const due=wire.final_grant.reservations.find(row=>row.frozen.input.kind==='due');assert.equal(due.state,'received');assert.equal(due.outcome.acknowledgement.contract,'catpaw.work-attempt-ack.v1');assert.equal(due.outcome.acknowledgement.task_status,'succeeded');assert.ok(due.outcome.acknowledgement.completion_receipt);
 const unknown=wire.unknown.grant;assert.deepEqual(unknown.grant.consumed,{due:1,model:1,source:0});assert.equal(unknown.reservations.find(row=>row.frozen.input.kind==='model').state,'reserved');assert.equal(unknown.reservations.find(row=>row.frozen.input.kind==='due').state,'unknown');assert.equal(wire.unknown.control.control.can_resume,false);assert.equal(wire.unknown.control.control.blocked_reason,'original_outcome_unknown');
});

test('accepted-work recovery has no cursor or events extension; native cursor reads stay on the original chat contract',async()=>{
 const f=await createNativeAcceptedWorkWireFixture();try{
  await (await f.req(f.workPath,f.request)).text();await f.drain();const binding=(await f.json(f.workPath+'/'+f.turn.turn_id)).turn.task_bindings[0],path=`/catpaw/work-grants/v1/scopes/${f.scope.scope_id}/runs/${binding.run_id}/grant`,before=nativeFixtureDomainSnapshot(f.repository);
  for(const [url,body,status,code] of [[f.workPath+'/'+f.turn.turn_id+'?after_sequence=1',undefined,422,'work_intent_schema_invalid'],[f.workPath+'/'+f.turn.turn_id+'/events',undefined,404,'not_found'],[path+'?after_sequence=1',undefined,422,'work_intent_schema_invalid'],[path,{},405,'method_not_allowed']]){
   const response=await f.req(url,body);assert.equal(response.status,status);assert.equal((await response.json()).error.code,code);
  }
  const cursor=await f.json(`${f.chatPath}/turns/${f.turn.turn_id}?after_sequence=1`);assert.equal(cursor.contract,'catpaw.native-chat.v1');assert.deepEqual(nativeFixtureDomainSnapshot(f.repository),before);assert.equal(f.calls.length,1);
 }finally{await f.stop();}
});

test('wrong native scope or run path cannot recover the original turn or grant or trigger execution',async()=>{
 const f=await createNativeAcceptedWorkWireFixture();try{
  await (await f.req(f.workPath,f.request)).text();await f.drain();const binding=(await f.json(f.workPath+'/'+f.turn.turn_id)).turn.task_bindings[0],path=`/catpaw/work-grants/v1/scopes/${f.scope.scope_id}/runs/${binding.run_id}/grant`,before=nativeFixtureDomainSnapshot(f.repository),other='59000000-0000-4000-8000-000000000001';
  for(const url of [f.workPath.replace(f.scope.scope_id,other)+'/'+f.turn.turn_id,path.replace(f.scope.scope_id,other),path.replace(binding.run_id,other)]){const response=await f.req(url);assert.ok([403,404].includes(response.status));assert.equal('grant' in await response.json(),false);}
  assert.deepEqual(nativeFixtureDomainSnapshot(f.repository),before);assert.equal(f.calls.length,1);assert.equal((await f.rows(K.terms)).length,1);
 }finally{await f.stop();}
});

test('synthetic server fixture uses the actual retained worker kick; reads neither start nor replace execution',async()=>{
 const f=await createNativeAcceptedWorkWireFixture({autoKick:true,providerReality:'injected_test_provider'});try{
  await (await f.req(f.workPath,f.request)).text();await f.drain();const [task]=await f.rows('tasks');assert.equal(task.status,'succeeded');assert.equal(f.calls.length,2);
  const snapshot=await f.json(f.workPath+'/'+f.turn.turn_id),binding=snapshot.turn.task_bindings[0],before=nativeFixtureDomainSnapshot(f.repository);assert.ok(snapshot.turn.events.every(event=>event.model_reality==='injected_test_provider'));await f.json(binding.projection_url);await f.json(`/catpaw/work-grants/v1/scopes/${f.scope.scope_id}/runs/${binding.run_id}/grant`);assert.deepEqual(nativeFixtureDomainSnapshot(f.repository),before);assert.equal(f.calls.length,2);
  const beforeNotice=clone(f.model_route),notice=nativeLoopbackRouteNotice(f.model_route);assert.deepEqual(f.model_route,beforeNotice);assert.deepEqual(notice.route,beforeNotice.route);assert.equal(notice.route_hash,beforeNotice.route_hash);assert.equal(notice.consent_default,'deny');assert.equal(notice.ui.allow,beforeNotice.ui.allow);assert.notEqual(notice.ui.body,beforeNotice.ui.body);assert.ok(notice.ui.body.includes('合成测试'));
 }finally{await f.stop();}
});

test('named synthetic server options bind only loopback and ignored state without an external host override',()=>{
 const parsed=parseNativeAcceptedWorkServerOptions(['--port=8767','--mode=lose-first-accepted-response']);assert.equal(parsed.hostname,'127.0.0.1');assert.equal(parsed.mode,'lose-first-accepted-response');assert.ok(parsed.state.endsWith('/services/edge/build/native-accepted-work-20261015/server-state.json'));
 for(const args of [['--host=0.0.0.0'],['--port=0'],['--mode=model'],['--state=/private/tmp/native-server.json']])assert.throws(()=>parseNativeAcceptedWorkServerOptions(args));
});

test('synthetic viewer lifetime is bounded and changes only new rows; restore preserves expired viewer and original work terms',async()=>{
 for(const value of [0,-1,21601,600.5,'21600',true,NaN,Infinity])await assert.rejects(createNativeAcceptedWorkWireFixture({sessionLifetimeSeconds:value}),/synthetic_fixture_session_lifetime_invalid/);
 const f=await createNativeAcceptedWorkWireFixture(),long=await createNativeAcceptedWorkWireFixture({sessionLifetimeSeconds:21600});let restored;
 try{
  for(const [fixture,seconds] of [[f,600],[long,21600]]){const row=await fixture.repository.transaction(tx=>tx.get(membershipOwner(fixture.actor.issuer),'app-sessions',fixture.actor.session_id)),remaining=row.expires_at-Math.floor(Date.now()/1000);assert.ok(remaining>=seconds-2&&remaining<=seconds);}
  await (await f.req(f.workPath,f.request)).text();await f.drain();const terms=await f.rows(K.terms),state=await f.rows(K.grants);await f.expireOrigin();const snapshot=f.repository.snapshot();
  restored=await createNativeAcceptedWorkWireFixture({snapshot,sessionLifetimeSeconds:21600});assert.deepEqual(restored.repository.snapshot(),snapshot);assert.deepEqual(await restored.rows(K.terms),terms);assert.deepEqual(await restored.rows(K.grants),state);
  const original=await restored.repository.transaction(tx=>tx.get(membershipOwner(f.actor.issuer),'app-sessions',f.actor.session_id));assert.equal(original.expires_at,0);const denied=await restored.req(restored.workPath+'/'+f.turn.turn_id);assert.equal(denied.status,409);assert.equal((await denied.json()).error.code,'grant_conflict');assert.equal(restored.calls.length,0);
 }finally{await restored?.stop();await long.stop();await f.stop();}
});
