import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TASK_WORK_GRANT_KINDS as K1,TASK_REVISION_WORK_GRANT_KINDS as K2} from '../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {revisionWorkIntentHash,revisionWorkReceiptHash,validatePublicRevisionWorkReceipt,validateFrozenRevisionWorkIntent} from '../supabase/functions/_shared/core/src/task-revision-work-contract.mjs';
import {revisionWorkHTTPFixture,REVISION_RAW} from './fixtures/revision-work-http-fixture.mjs';

const ledger=async(f,kinds=K1,grantID)=>Object.fromEntries(await Promise.all(Object.entries(kinds).map(async([key,kind])=>[key,(await f.rows(kind)).filter(row=>!grantID||row.id===grantID||row.grant_id===grantID)])));
const envelopeOf=turn=>{assert.equal(turn.state,'completed');assert.equal(turn.continuations.length,1);assert.equal(turn.revision_work_receipts.length,1);const envelope=validatePublicRevisionWorkReceipt(turn.revision_work_receipts[0]);assert.equal(turn.continuations[0].receipt_hash,envelope.revision.receipt_hash);return envelope;};
const assertOriginalIntent=(f,request,turn)=>{const intent=validateFrozenRevisionWorkIntent(turn.revision_work_intent,{turn:{id:request.turn.turn_id,input:request.turn},target:request.target,scope:f.scope,conversation:{id:f.cid,scope_id:f.scope.scope_id,subject_id:f.fresh.subject_id,grant_epoch:request.turn.expected_grant_epoch},routeHash:f.config.routeHash,callName:'revise_current_report_work_v1'});assert.equal(revisionWorkIntentHash(intent),hash(request.work));};
const rejectHTTP=async(f,request,{auth='Bearer fresh',status=409,path=f.workPath}={})=>{const response=await f.req(path,request,auth);assert.equal(response.status,status,JSON.stringify(await response.clone().json()));return response.json();};
const noNewArtifacts=async f=>{const versions=await f.rows('catpaw-artifact-versions');assert.equal(versions.length,1);assert.equal(versions[0].content_hash,f.run.artifact_references[0].content_hash);assert.notEqual((await f.rows('tasks'))[0].status,'succeeded');};

test('finite accepted local and sourced reports revise through explicit new work on the same Task with original grant bytes intact',async()=>{
 for(const sourced of [false,true]){const f=await revisionWorkHTTPFixture({sourced});try{
  const before={run:structuredClone(f.run),task:structuredClone(f.task),ledger:await ledger(f),versions:await f.rows('catpaw-artifact-versions')};
  const denied=await f.req(f.path,f.input,'Bearer fresh');assert.equal(denied.status,409);assert.equal((await denied.json()).error.code,'revision_new_work_intent_required');
  const request=await f.makeRequest(),turn=await f.accept(request),accepted=envelopeOf(turn),reads=f.reads();assertOriginalIntent(f,request,turn);
  assert.equal(accepted.decision_id,request.work.decision_id);assert.equal(accepted.input_hash,hash({turn:request.turn,target:request.target}));assert.equal(accepted.target_hash,hash(request.target));assert.equal(accepted.work_intent_hash,revisionWorkIntentHash(request.work));assert.equal(accepted.revision.state,'accepted');
  const operation=(await f.rows('catpaw-task-revision-operations'))[0];assert.equal(operation.id,accepted.revision.operation_id);assert.equal(operation.frozen.revision_work_intent.decision_id,request.work.decision_id);
  await f.settle();const [task]=await f.rows('tasks'),[run]=await f.rows('catpaw-runs'),versions=await f.rows('catpaw-artifact-versions');
  assert.equal(task.status,'succeeded');assert.equal(task.id,before.task.id);assert.equal(run.id,before.run.id);assert.equal((await f.rows('tasks')).length,1);assert.deepEqual(run.frozen_request,before.run.frozen_request);assert.equal(run.request_hash,before.run.request_hash);assert.deepEqual(task.state.catpaw,before.task.state.catpaw);
  assert.deepEqual(await ledger(f),before.ledger);assert.equal(versions.length,2);assert.deepEqual(versions[0],before.versions[0]);assert.equal(run.artifact_references[0].version,2);
  assert.equal(versions[1].artifact_id,versions[0].artifact_id);assert.equal(versions[1].content_hash,hash(versions[1].body));assert.match(JSON.parse(versions[1].body).data.content,/explicit risk/);assert.equal(f.reads()-reads,sourced?1:0);
  const completed=await f.readOperation(accepted.revision.operation_id);assert.equal(completed.revision.state,'completed');assert.deepEqual(completed.revision.result_reference,run.artifact_references[0]);assert.equal(completed.receipt_hash,accepted.receipt_hash);
  const grants=await ledger(f,K2);assert.equal(grants.terms.length,1);assert.equal(grants.terms[0].terms.source_auth.session_id,f.fresh.session_id);assert.equal(grants.grants[0].consumed.due,1);assert.ok(grants.grants[0].consumed.model>0);assert.equal(grants.grants[0].consumed.source,sourced?1:0);
 }finally{await f.stop();}}
});
test('a fresh finite revision does not depend on the original session or grant expiry and never extends them',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const original=await ledger(f);await f.mutateSession(f.principal,{expires_at:Math.floor(f.now()/1000)-1});f.advance(Date.parse(f.originalWork.not_after)-f.now()+1);
  const request=await f.makeRequest(),accepted=envelopeOf(await f.accept(request));await f.settle();
  assert.equal((await f.rows('tasks'))[0].status,'succeeded');assert.equal((await f.readOperation(accepted.revision.operation_id)).revision.state,'completed');assert.deepEqual(await ledger(f),original);
 }finally{await f.stop();}
});
test('a second fresh revision gets an isolated grant and preserves both older operation outcomes and all earlier grant ledgers',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const original=await ledger(f),firstRequest=await f.makeRequest(),first=envelopeOf(await f.accept(firstRequest));await f.settle();
  const firstLedger=await ledger(f,K2,firstRequest.work.decision_id),firstResult=await f.readOperation(first.revision.operation_id),version2=(await f.rows('catpaw-artifact-versions'))[1];
  const secondRequest=await f.makeRequest({text:REVISION_RAW+'\nKeep the risk explicit.'}),second=envelopeOf(await f.accept(secondRequest));assert.notEqual(second.decision_id,first.decision_id);assert.notEqual(second.revision.operation_id,first.revision.operation_id);await f.settle();
  assert.equal((await f.rows('tasks')).length,1);assert.equal((await f.rows('tasks'))[0].id,f.task.id);assert.equal((await f.rows('catpaw-runs'))[0].id,f.run.id);assert.equal((await f.rows('catpaw-runs'))[0].artifact_references[0].version,3);
  assert.deepEqual(await ledger(f),original);assert.deepEqual(await ledger(f,K2,firstRequest.work.decision_id),firstLedger);assert.deepEqual((await f.rows('catpaw-artifact-versions'))[1],version2);assert.deepEqual(await f.readOperation(first.revision.operation_id),firstResult);
  assert.equal((await f.readOperation(second.revision.operation_id)).revision.result_reference.version,3);
  const due=(await f.rows(K2.reservations)).filter(row=>row.frozen.input.kind==='due');assert.equal(due.length,2);assert.deepEqual(new Set(due.map(row=>row.id)),new Set([first.revision.operation_id,second.revision.operation_id]));
 }finally{await f.stop();}
});
test('exact original POST and cold-style GET replay return the same operation with zero new provider/source sends or budget',async()=>{
 const f=await revisionWorkHTTPFixture({sourced:true});try{
  const request=await f.makeRequest(),accepted=envelopeOf(await f.accept(request));await f.settle();
  const before={calls:f.calls.length,reads:f.reads(),ledger:await ledger(f,K2),versions:await f.rows('catpaw-artifact-versions')},completed=await f.readOperation(accepted.revision.operation_id);
  f.advance(Date.parse(request.work.not_after)-f.now()+1);
  for(let i=0;i<2;i++){assert.deepEqual(await f.readOperation(accepted.revision.operation_id),completed);const replay=await f.req(f.workPath,request,'Bearer fresh');assert.equal(replay.status,200);await replay.body.getReader().cancel();await f.runtime.chat.waitIdle();assertOriginalIntent(f,request,await f.readTurn(request));}
  assert.equal(f.calls.length,before.calls);assert.equal(f.reads(),before.reads);assert.deepEqual(await ledger(f,K2),before.ledger);assert.deepEqual(await f.rows('catpaw-artifact-versions'),before.versions);assert.equal(completed.receipt_hash,revisionWorkReceiptHash(completed));
 }finally{await f.stop();}
});
test('changed raw input or target under an old work hash is refused before any model or task mutation',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const baseline={calls:f.calls.length,ledger:await ledger(f),tasks:await f.rows('tasks')};
  for(const mutate of [r=>r.turn.message.text+=' ',r=>r.target.artifact_reference.version++,r=>r.target.artifact_reference.content_hash=hash('wrong'),r=>r.target.expected_plan_hash=hash('wrong plan')]){
   const request=await f.makeRequest();mutate(request);const error=await rejectHTTP(f,request);assert.equal(error.error.code,'revision_work_input_conflict');
  }
  assert.equal(f.calls.length,baseline.calls);assert.deepEqual(await ledger(f),baseline.ledger);assert.deepEqual(await f.rows('tasks'),baseline.tasks);assert.deepEqual(await f.rows(K2.terms),[]);
 }finally{await f.stop();}
});
test('same turn with a changed explicit work decision cannot replay as the original accepted operation',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const request=await f.makeRequest(),first=envelopeOf(await f.accept(request)),before=f.calls.length,changed=structuredClone(request);changed.work.decision_id=randomUUID();
  await rejectHTTP(f,changed);assert.equal(f.calls.length,before);assert.equal((await f.rows(K2.terms)).length,1);assert.equal((await f.readOperation(first.revision.operation_id)).decision_id,request.work.decision_id);
 }finally{await f.stop();}
});
test('a foreign current subject or wrong scope cannot start or read another user revision even with all known IDs',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const request=await f.makeRequest(),before=f.calls.length;await rejectHTTP(f,request,{auth:'Bearer foreign',status:404});await rejectHTTP(f,request,{auth:'Bearer outside',status:403});await rejectHTTP(f,request,{path:f.workPath.replace(f.scope.scope_id,randomUUID()),status:403});
  assert.equal(f.calls.length,before);assert.deepEqual(await f.rows(K2.terms),[]);
  const accepted=envelopeOf(await f.accept(request)),count=f.calls.length;
  assert.equal((await f.req(f.operationPath(accepted.revision.operation_id),undefined,'Bearer foreign')).status,404);
  assert.equal((await f.req(f.operationPath(accepted.revision.operation_id),undefined,'Bearer outside')).status,403);assert.equal(f.calls.length,count);
 }finally{await f.stop();}
});
test('strict HTTP parsing refuses duplicate authority keys and schema expansion with zero model calls',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const request=await f.makeRequest(),raw=JSON.stringify(request),before=f.calls.length;
  for(const changed of [raw.replace('"decision_id":','"decision_id":"'+request.work.decision_id+'","decision_id":'),raw.replace('"version":1','"version":1,"\\u0076ersion":1')]){
   const response=await f.rawReq(f.workPath,changed);assert.equal(response.status,422);assert.equal((await response.json()).error.code,'revision_work_duplicate_key');
  }
  const extra=structuredClone(request);extra.work.allow_expired=true;assert.equal((await f.req(f.workPath,extra,'Bearer fresh')).status,422);assert.equal(f.calls.length,before);assert.deepEqual(await f.rows(K2.terms),[]);
 }finally{await f.stop();}
});
test('late revision chat result loses fresh source or generation before any new operation/grant can commit',async()=>{
 for(const reason of ['fresh-source','generation']){const f=await revisionWorkHTTPFixture();try{
  const request=await f.makeRequest(),original=await ledger(f);f.hooks.beforeRevisionChatResult=()=>f.invalidate(reason,request);
  const response=await f.req(f.workPath,request,'Bearer fresh');assert.equal(response.status,200);await response.body.getReader().cancel();await f.runtime.chat.waitIdle();
  assert.deepEqual(await f.rows(K2.terms),[]);assert.deepEqual(await f.rows('catpaw-task-revision-operations'),[]);assert.equal((await f.rows('catpaw-artifact-versions')).length,1);assert.deepEqual(await ledger(f),original);
 }finally{await f.stop();}}
});
test('late revision worker result cannot commit after source deletion, revocation, generation, conversation, delegation or lease change',async()=>{
 for(const reason of ['fresh-source','generation','revision-source','conversation','delegation','lease']){const f=await revisionWorkHTTPFixture();try{
  const request=await f.makeRequest();envelopeOf(await f.accept(request));const original=await ledger(f),before=f.calls.length;
  f.hooks.beforeRevisionWorkerResult=()=>f.invalidate(reason,request);await f.settle();
  await noNewArtifacts(f);assert.equal(f.calls.length,before+1);await f.settle(2);assert.equal(f.calls.length,before+1);assert.deepEqual(await ledger(f),original);assert.deepEqual(await f.rows('catpaw-task-revision-results'),[]);
 }finally{await f.stop();}}
});
test('late public source transport result cannot be saved or composed after the revision authority is lost',async()=>{
 for(const reason of ['fresh-source','generation','lease']){const f=await revisionWorkHTTPFixture({sourced:true});try{
  const request=await f.makeRequest();envelopeOf(await f.accept(request));const before=f.calls.length,reads=f.reads();
  f.hooks.beforeSourceResult=()=>f.invalidate(reason,request);await f.settle();await noNewArtifacts(f);
  assert.equal(f.reads(),reads+1);assert.equal(f.calls.length,before+1,'only the original read-request round, no compose after a fenced read');
  assert.deepEqual(await f.rows('catpaw-task-revision-results'),[]);
 }finally{await f.stop();}}
});
test('lost original model or source outcomes consume their original reservation and never resend on GET or worker ticks',async()=>{
 for(const sourced of [false,true]){const f=await revisionWorkHTTPFixture({sourced});try{
  const request=await f.makeRequest(),accepted=envelopeOf(await f.accept(request));if(sourced)f.mode.sourceUnknown=true;else f.mode.modelUnknown=true;
  await f.settle();assert.equal((await f.rows('tasks'))[0].status,'outcome_unknown');await noNewArtifacts(f);
  const before={calls:f.calls.length,reads:f.reads(),ledger:await ledger(f,K2)},result=await f.readOperation(accepted.revision.operation_id);assert.equal(result.revision.state,'blocked_unknown');
  for(let i=0;i<2;i++){await f.readOperation(accepted.revision.operation_id);await f.readTurn(request);await f.tick();}
  const newRequest=await f.makeRequest();await rejectHTTP(f,newRequest);
  assert.equal(f.calls.length,before.calls);assert.equal(f.reads(),before.reads);assert.deepEqual(await ledger(f,K2),before.ledger);
  const state=(await f.rows(K2.grants))[0];assert.equal(state.consumed.model,1);assert.equal(state.consumed.source,sourced?1:0);assert.equal((await f.rows(K2.reservations)).find(row=>row.frozen.input.kind==='due').state,'unknown');
 }finally{await f.stop();}}
});
test('zero model/source budget stops before the unauthorized send without borrowing the original grant budget',async()=>{
 for(const sourced of [false,true]){const f=await revisionWorkHTTPFixture({sourced});try{
  const request=await f.makeRequest({work:{limits:{due:1,model:sourced?2:0,source:0}}});envelopeOf(await f.accept(request));const before={calls:f.calls.length,reads:f.reads(),original:await ledger(f)};
  await f.settle();await noNewArtifacts(f);assert.equal((await f.rows('tasks'))[0].status,'failed');assert.equal((await f.rows('tasks'))[0].error,'work_grant_budget_exhausted');
  assert.equal(f.calls.length-before.calls,sourced?1:0);assert.equal(f.reads(),before.reads);assert.deepEqual(await ledger(f),before.original);
 }finally{await f.stop();}}
});
test('an expired new revision window cannot be claimed or extended by polling, while its accepted operation remains readable',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const request=await f.makeRequest(),accepted=envelopeOf(await f.accept(request)),before={calls:f.calls.length,ledger:await ledger(f,K2)};
  f.advance(Date.parse(request.work.not_after)-f.now()+1);for(let i=0;i<2;i++)assert.equal((await f.tick()).claimed,0);
  assert.equal(f.calls.length,before.calls);assert.deepEqual(await ledger(f,K2),before.ledger);const read=await f.readOperation(accepted.revision.operation_id);assert.equal(read.revision.state,'accepted');assert.equal(read.receipt_hash,accepted.receipt_hash);
 }finally{await f.stop();}
});
test('a model callback after the finite deadline cannot create an artifact, refund budget or dispatch another attempt',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const request=await f.makeRequest(),accepted=envelopeOf(await f.accept(request)),before=f.calls.length;
  f.hooks.beforeRevisionWorkerResult=()=>f.advance(Date.parse(request.work.not_after)-f.now()+1);await f.settle();await noNewArtifacts(f);
  assert.equal(f.calls.length,before+1);assert.equal((await f.rows(K2.grants))[0].consumed.model,1);const row=(await f.rows(K2.reservations)).find(r=>r.frozen.input.kind==='model');assert.equal(row.state,'reserved');
  const snapshot=await ledger(f,K2);await f.readOperation(accepted.revision.operation_id);await f.tick();assert.deepEqual(await ledger(f,K2),snapshot);assert.equal(f.calls.length,before+1);
 }finally{await f.stop();}
});
test('a sourced original task cannot receive a local-only revision grant that silently bypasses its frozen sources',async()=>{
 const f=await revisionWorkHTTPFixture({sourced:true});try{
  const request=await f.makeRequest({work:{tool_policy:'local_output_v1',limits:{due:1,model:3,source:0}}}),before=f.calls.length;
  await rejectHTTP(f,request);assert.equal(f.calls.length,before);assert.deepEqual(await f.rows(K2.terms),[]);assert.equal((await f.rows('tasks'))[0].status,'succeeded');
 }finally{await f.stop();}
});

test('a newly admitted revision cannot reuse the original or a previous revision decision, while exact original replay remains separate',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const originalDecision=await f.makeRequest({work:{decision_id:f.originalWork.decision_id}}),before=f.calls.length;
  const rejected=await rejectHTTP(f,originalDecision);assert.equal(rejected.error.code,'revision_work_decision_reused');assert.equal(f.calls.length,before);assert.deepEqual(await f.rows(K2.terms),[]);
  const firstRequest=await f.makeRequest(),first=envelopeOf(await f.accept(firstRequest));await f.settle();
  const second=await f.makeRequest({work:{decision_id:first.decision_id}}),count=f.calls.length,ledgerBefore=await ledger(f,K2);
  const denied=await rejectHTTP(f,second);assert.equal(denied.error.code,'revision_work_decision_reused');assert.equal(f.calls.length,count);assert.deepEqual(await ledger(f,K2),ledgerBefore);
 }finally{await f.stop();}
});
test('a fresh correctly hashed request still cannot substitute stale artifact or plan targets or a different run',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const before={calls:f.calls.length,tasks:await f.rows('tasks'),original:await ledger(f)};
  for(const mutate of [r=>r.target.artifact_reference.version++,r=>r.target.artifact_reference.content_hash=hash('unowned body'),r=>r.target.expected_plan_revision++,r=>r.target.run_id=randomUUID()]){
   const request=await f.makeRequest();mutate(request);request.work.input_hash=hash({turn:request.turn,target:request.target});
   const response=await f.req(f.workPath,request,'Bearer fresh');assert.ok([404,409].includes(response.status),JSON.stringify(await response.clone().json()));
  }
  assert.equal(f.calls.length,before.calls);assert.deepEqual(await f.rows('tasks'),before.tasks);assert.deepEqual(await ledger(f),before.original);assert.deepEqual(await f.rows(K2.terms),[]);
 }finally{await f.stop();}
});

test('actual autoKick composition completes the fresh revision after POST without a manual tick or another question',async()=>{
 for(const sourced of [false,true]){const f=await revisionWorkHTTPFixture({sourced,autoKick:true});try{
  const request=await f.makeRequest(),ticks=f.ticks(),original=await ledger(f),before=f.calls.length,accepted=envelopeOf(await f.accept(request));
  assert.equal(f.ticks(),ticks,'revision must run through the actual retained wake composition');
  const [task]=await f.rows('tasks'),[run]=await f.rows('catpaw-runs');assert.equal(task.status,'succeeded');assert.equal(task.id,f.task.id);assert.equal(run.id,f.run.id);assert.equal(run.artifact_references[0].version,2);
  assert.ok(f.calls.length>=before+2,'fresh revision chat and original bounded worker must both execute');
  assert.equal((await f.readOperation(accepted.revision.operation_id)).revision.state,'completed');assert.deepEqual(await ledger(f),original);
 }finally{await f.stop();}}
});

test('new explicit context replaces old application context in the revision provider input without mutating original frozen work',async()=>{
 for(const sourced of [false,true]){const oldContext=[{id:'old-context',text:'OLD_CONTEXT_MARKER_NOT_AUTHORIZED_FOR_NEW_REVISION'}],newContext=[{id:'fresh-context',text:'FRESH_CONTEXT_MARKER_EXPLICIT_FOR_THIS_REVISION'}],f=await revisionWorkHTTPFixture({sourced,originalContext:oldContext});try{
  const request=await f.makeRequest({context:newContext}),before=f.calls.length,old=structuredClone(f.run.frozen_request);envelopeOf(await f.accept(request));await f.settle();
  const worker=f.calls.slice(before).filter(input=>input.provider_context?.task_execution);
  assert.ok(worker.length>0);for(const input of worker){const initial=JSON.parse(input.messages[0].content);assert.deepEqual(initial.context,newContext);assert.ok(JSON.stringify(input).includes(newContext[0].text));assert.ok(!JSON.stringify(input).includes(oldContext[0].text));}
  assert.deepEqual((await f.rows('catpaw-runs'))[0].frozen_request,old);assert.deepEqual(old.context,oldContext);
 }finally{await f.stop();}}
});
