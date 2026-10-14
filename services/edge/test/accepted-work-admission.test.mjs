import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner,assertAcceptedWorkSourceAuthority,assertAcceptedWorkControlSourceAuthority} from '../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,check,hash,clone} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {ACCEPTED_WORK_INTENT_CONTRACT,validateAcceptedWorkRequest,parseAcceptedWorkJSON} from '../supabase/functions/_shared/core/src/accepted-work-intent-contract.mjs';
import {TASK_WORK_GRANT_KINDS as K,workGrantReference} from '../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {parseTaskControlJSON} from '../supabase/functions/_shared/core/src/task-control-contract.mjs';
import {boundedTick} from '../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-tick.mjs';
import {singleStepHandler} from '../supabase/functions/_shared/core/src/single-step-handler.mjs';

globalThis.fetch=()=>{throw Error('accepted_work_admission_external_network_forbidden');};
const PLAN={title:'有限工作报告',goal:'整理明确提供的虚构材料',requirements:'仅使用原对话资料',stop_conditions:['保存并核对成果'],steps:[{id:'compose',title:'整理',detail:''},{id:'save',title:'保存',detail:''},{id:'verify',title:'核对',detail:''}]};
async function fixture({ordinary=false,callName='delegate_plan_v1'}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const subject=randomUUID(),issuer='https://offline.example.invalid/auth/v1',actor={subject_id:subject,session_id:randomUUID(),issuer,issued_at:1,scopes:[scope],permissions:{local_output:true}};
 let principal=actor,clock=Date.now(),f;const calls=[],retained=[],queryKinds=[];
 // Actual source-authority SQL boundary executed against serialized synthetic rows.
 // This is no Auth endpoint, actual PostgreSQL, multi-instance or lock proof.
 const transaction=repository.transaction.bind(repository);
 repository.transaction=fn=>transaction(tx=>{
  tx.connection={query:async(sql,params)=>{
   if(sql.startsWith('SELECT pg_advisory_xact_lock')){queryKinds.push('source-subject-lock');return {rows:[]};}
   const kind=/kind='([^']+)'/.exec(sql)?.[1];assert.ok(['app-sessions','scope-memberships'].includes(kind));queryKinds.push(kind);
   const value=await tx.get(params[0],kind,params[1]);return {rows:value?[{data:value}]:[]};
  }};return fn(tx);
 });
 const provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',assertReady(){},async *stream(input){
  calls.push(clone({messages:input.messages,system_prompt:input.system_prompt,tools:input.tools,provider_context:input.provider_context}));
  if(ordinary){yield {type:'text_delta',text:'An ordinary offline answer'};yield {type:'done',finish_reason:'stop'};return;}
  if(input.tools.some(t=>t.function.name==='delegate_plan_v1')){
   yield {type:'tool_call',id:'offline-original-call',name:callName,arguments:PLAN};yield {type:'done',finish_reason:'tool_calls'};return;
  }
  yield {type:'tool_call',id:'offline-save',name:'save_artifact',arguments:{title:'有限工作成果',summary:'合成资料报告',content:'A useful report based only on the original, explicitly supplied fictional records.'}};
  yield {type:'tool_call',id:'offline-finish',name:'finish_task',arguments:{summary:'Saved and verified original report'}};
  yield {type:'done',finish_reason:'tool_calls'};
 }};
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'},config=readConfig(name=>values[name]);
 const runtime=await createCloudRuntime({repository,config,provider,authenticate:auth=>{check(auth==='Bearer offline-work',401,'session_required');return principal;},autoKick:false,retain:p=>retained.push(p),diagnostic:()=>{},acceptedSourceChecker:(tx,source,identity,ref)=>assertAcceptedWorkSourceAuthority(tx,source,identity,ref,{now:()=>Math.max(clock,Date.now())}),acceptedControlSourceChecker:(tx,source,identity,ref)=>assertAcceptedWorkControlSourceAuthority(tx,source,identity,ref,{now:()=>Math.max(clock,Date.now())})});
 runtime.facade.workGrantService.now=()=>Math.max(clock,Date.now());
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);const owner=runtime.facade.owner(scope);
 await repository.transaction(async tx=>{
  await tx.put(membershipOwner(issuer),'app-sessions',{id:actor.session_id,subject_id:subject,state:'active',expires_at:Math.floor(Date.now()/1000)+600});
  await tx.put(membershipOwner(issuer),'scope-memberships',{id:subject,state:'active',tokens_valid_after:1,revoked_session_ids:[],scopes:[scope]});
 });
 const req=(path,body)=>runtime.api(new Request('https://offline.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer offline-work','Content-Type':'application/json'},...body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)}}));
 const cid=randomUUID(),chat=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,workPath=`/catpaw/accepted-work/v1/scopes/${scope.scope_id}/conversations/${cid}/turns`;
 assert.equal((await req(chat,{conversation_id:cid})).status,201);
 const consentPath=`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`;
 assert.equal((await req(consentPath,{decision:'allow',expected_revision:0,route_hash:config.routeHash})).status,200);
 const turn={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'请整理给定虚构资料为本地报告。'},context:[]};
 const work={decision_id:randomUUID(),input_hash:hash(turn),route_hash:config.routeHash,tool_policy:'local_output_v1',not_after:new Date(clock+90000).toISOString(),execution_budget_ms:60000,limits:{due:1,model:1,source:0}};
 const request={schema_version:1,contract:ACCEPTED_WORK_INTENT_CONTRACT,turn,work};
 // Use the maintained Cloud composition's actual readiness switch. These
 // injected transports/serialized SQL rows remain offline evidence only.
 assert.equal(runtime.facade.acceptedWorkExecutionReady,true);
 const readTurn=async()=>{const r=await req(`${chat}/${cid}/turns/${turn.turn_id}`);assert.equal(r.status,200);return (await r.json()).turn;};
 const start=async input=>{const response=await req(workPath,input??request);if(response.headers.get('content-type')==='text/event-stream')await response.body.getReader().cancel();await Promise.all(retained);return response;};
 const rows=kind=>repository.transaction(tx=>tx.list(owner,kind));
 f={repository,runtime,config,scope,actor,owner,cid,chat,workPath,consentPath,turn,work,request,req,start,readTurn,rows,calls,queryKinds,now:()=>Math.max(clock,Date.now()),advance:ms=>{clock=Math.max(clock,Date.now())+ms;},stop:()=>runtime.worker.stop(),expireOrigin:()=>repository.transaction(async tx=>{const row=await tx.get(membershipOwner(issuer),'app-sessions',actor.session_id);await tx.put(membershipOwner(issuer),'app-sessions',{...row,expires_at:0});}),freshViewer:async()=>{
  principal={...actor,session_id:randomUUID()};await repository.transaction(tx=>tx.put(membershipOwner(issuer),'app-sessions',{id:principal.session_id,subject_id:subject,state:'active',expires_at:Math.floor(Date.now()/1000)+600}));return principal;
 }};return f;
}
const domainSnapshot=repository=>{const snapshot=repository.snapshot();return {...snapshot,records:snapshot.records.filter(([key])=>JSON.parse(key)[1]!=='native-chat-runtime-leases')};};
const error=async(response,code,status=409)=>{assert.equal(response.status,status);assert.equal((await response.json()).error.code,code);};
test('explicit work wrapper rejects ambiguous intent JSON and preserves control parser error identities',()=>{
 const turn={turn_id:randomUUID()},work={decision_id:randomUUID(),input_hash:hash(turn),route_hash:hash('offline-route'),tool_policy:'local_output_v1',not_after:new Date(Date.now()+60000).toISOString(),execution_budget_ms:1000,limits:{due:1,model:1,source:0}},request={schema_version:1,contract:ACCEPTED_WORK_INTENT_CONTRACT,turn,work},raw=JSON.stringify(request);
 assert.deepEqual(parseAcceptedWorkJSON(raw),request);assert.deepEqual(validateAcceptedWorkRequest(request),request);
 for(const bad of [raw.replace('"decision_id":','"decision_id":"'+randomUUID()+'","decision_id":'),raw.replace('"model":','"m\\u006fdel":0,"model":')])assert.throws(()=>parseAcceptedWorkJSON(bad),e=>e.code==='work_intent_duplicate_key');
 for(const [field,value] of [['model',true],['model',-1],['model',21],['source',1],['due',2]])assert.throws(()=>validateAcceptedWorkRequest({...request,work:{...work,limits:{...work.limits,[field]:value}}}),e=>e.code==='work_intent_schema_invalid');
 assert.throws(()=>parseTaskControlJSON('{"action":"pause","action":"resume"}'),e=>e.code==='control_duplicate_key');
 assert.throws(()=>parseTaskControlJSON('null'),e=>e.code==='control_schema_invalid');
});
test('existing consent/readiness cannot manufacture accepted work; disabled execution mutates no chat or grant',async()=>{
 const f=await fixture(),before=f.repository.snapshot();f.runtime.facade.acceptedWorkExecutionReady=false;
 await error(await f.start(),'accepted_work_execution_not_configured',503);assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,0);await f.stop();
});
test('normal HTTP work acceptance freezes explicit terms with canonical owner in the same initial run transaction',async()=>{
 const f=await fixture();assert.equal((await f.start()).status,200);const turn=await f.readTurn();assert.equal(turn.state,'completed');assert.equal(turn.task_bindings.length,1);
 const [run]=await f.rows('catpaw-runs'),[terms]=await f.rows(K.terms),[state]=await f.rows(K.grants),[task]=await f.rows('tasks');
 assert.equal(run.id,turn.task_bindings[0].run_id);assert.equal(run.task_id,task.id);assert.equal(terms.terms.grant_id,f.work.decision_id);assert.equal(terms.terms.scope.owner,f.owner);assert.equal('local_output' in terms.terms.scope,false);
 assert.equal(terms.terms.input_hash,hash(f.turn));assert.equal(terms.terms.not_after,f.work.not_after);assert.deepEqual(terms.terms.limits,f.work.limits);assert.deepEqual(run.frozen_request.work_grant_reference,workGrantReference(terms.terms));
 assert.equal(hash(run.frozen_request),run.request_hash);assert.equal(terms.receipt.task_completed,false);assert.deepEqual(state.consumed,{due:0,model:0,source:0});assert.equal(task.status,'queued');assert.equal(f.calls.length,1);
 const response=await f.req(`/catpaw/work-grants/v1/scopes/${f.scope.scope_id}/runs/${run.id}/grant`);assert.equal(response.status,200);const wire=await response.json();assert.equal(wire.grant.reference.grant_id,terms.id);assert.equal(wire.grant.task_completed,false);assert.ok(f.queryKinds.includes('scope-memberships'));await f.stop();
});
test('original work POST replay preserves domain data, original grant, deadline and model count',async()=>{
 const f=await fixture();await f.start();const before=domainSnapshot(f.repository),response=await f.start();assert.equal(response.status,200);assert.equal((await response.json()).replayed,true);assert.equal(f.calls.length,1);assert.deepEqual(domainSnapshot(f.repository),before);
 await error(await f.start({...f.request,work:{...f.work,not_after:new Date(Date.parse(f.work.not_after)+1000).toISOString()}}),'turn_conflict');assert.deepEqual(domainSnapshot(f.repository),before);await f.stop();
});
test('trusted original tool replay after its initial budget window shrinks returns the same binding without renewing grant',async()=>{
 const f=await fixture();await f.start();const before=domainSnapshot(f.repository),[run]=await f.rows('catpaw-runs');f.advance(31000);
 const result=await f.repository.transaction(async tx=>{
  const turn=await tx.get(f.owner,'native-chat-turns',f.turn.turn_id),conversation=await tx.get(f.owner,'native-chat-conversations',f.cid);
  return f.runtime.facade.admitChatTask(tx,{owner:f.owner,scope:f.scope,principal:f.actor,turn,conversation,call:{id:'offline-original-call',name:'delegate_plan_v1',arguments:PLAN}});
 });
 assert.equal(result.run_id,run.id);assert.equal(result.request_hash,run.request_hash);assert.deepEqual(domainSnapshot(f.repository),before);assert.equal(f.calls.length,1);await f.stop();
});
test('input/route/deadline and command identity cannot be broadened after explicit user work decision',async()=>{
 for(const options of ['input','route','deadline','fields']){
  const f=await fixture(),request=clone(f.request);if(options==='input')request.turn.message.text+=' changed';if(options==='route')request.work.route_hash=hash('other-route');if(options==='deadline')request.work.not_after=new Date(Date.now()-1000).toISOString();if(options==='fields')request.work.allow_expired=true;
  const response=await f.start(request);assert.ok([409,422].includes(response.status));assert.equal(f.calls.length,0);assert.deepEqual(await f.rows(K.terms),[]);assert.deepEqual(await f.rows('catpaw-runs'),[]);await f.stop();
 }
});
test('ordinary v1 turn cannot import work intent and the same normal delegation stays legacy strict',async()=>{
 const f=await fixture();const response=await f.req(`${f.chat}/${f.cid}/turns`,{...f.turn,work_intent:f.work});assert.equal(response.status,422);assert.equal(f.calls.length,0);
 const legacy=await f.req(`${f.chat}/${f.cid}/turns`,f.turn);assert.equal(legacy.status,200);await legacy.body.getReader().cancel();await Promise.all([...f.runtime.chat.active.values()].map(x=>x.promise));
 const [run]=await f.rows('catpaw-runs');assert.equal(run.frozen_request.work_grant_reference,undefined);assert.deepEqual(await f.rows(K.terms),[]);await f.expireOrigin();await assert.rejects(f.repository.transaction(tx=>f.runtime.facade.admittedTask(tx,f.owner,run.task_id)),e=>e.code==='grant_conflict');await f.stop();
});
test('denial at final grant admission rolls back the initial run/task/plan/terms and receipt atomically',async()=>{
 const f=await fixture(),hook=f.runtime.facade.beforeWorkGrantAdmission;let checks=0;f.runtime.facade.beforeWorkGrantAdmission=async(tx,ctx)=>{await hook(tx,ctx);if(++checks===2)throw new ApiError(403,'offline_withdrawn_before_grant_commit');};
 await f.start();const turn=await f.readTurn();assert.equal(turn.state,'failed');assert.deepEqual(turn.task_bindings,[]);
 for(const kind of [K.terms,K.grants,K.reservations,'catpaw-runs','catpaw-operations','catpaw-delegations','tasks','catpaw-task-plan-heads'])assert.deepEqual(await f.rows(kind),[]);assert.equal(f.calls.length,1);await f.stop();
});
test('expired origin rejects new commands while the exact finite grant remains a fact with no session renewal',async()=>{
 const f=await fixture();await f.start();const [run]=await f.rows('catpaw-runs');await f.expireOrigin();const before=f.repository.snapshot();
 await f.repository.transaction(tx=>f.runtime.facade.admittedTask(tx,f.owner,run.task_id));assert.deepEqual(f.repository.snapshot(),before);
 const conversation=await f.repository.transaction(tx=>tx.get(f.owner,'native-chat-conversations',f.cid));
 const freshTurn={...f.turn,turn_id:randomUUID(),message:{id:randomUUID(),text:'Start another job'},expected_revision:conversation.revision,expected_grant_epoch:conversation.grant_epoch},request={...f.request,turn:freshTurn,work:{...f.work,decision_id:randomUUID(),input_hash:hash(freshTurn)}};
 await error(await f.start(request),'grant_conflict');assert.equal((await f.rows(K.terms)).length,1);assert.equal(f.calls.length,1);
 await error(await f.req(`/catpaw/work-grants/v1/scopes/${f.scope.scope_id}/runs/${run.id}/grant`),'grant_conflict');await f.freshViewer();assert.equal((await f.req(`/catpaw/work-grants/v1/scopes/${f.scope.scope_id}/runs/${run.id}/grant`)).status,200);await f.stop();
});
test('actual consent denial revokes finite grant in the existing atomic barrier without changing frozen terms',async()=>{
 const f=await fixture();await f.start();const [terms]=await f.rows(K.terms),response=await f.req(f.consentPath,{decision:'deny',expected_revision:1,route_hash:f.config.routeHash});assert.equal(response.status,200);
 const [state]=await f.rows(K.grants);assert.equal(state.state,'revoked');assert.deepEqual(await f.rows(K.terms),[terms]);assert.deepEqual(state.consumed,{due:0,model:0,source:0});const [task]=await f.rows('tasks');assert.equal(task.status,'cancelled');await f.stop();
});
test('fresh viewer pauses and resumes the same finite grant after origin expiry, preserving limits and deadlines',async()=>{
 const f=await fixture();await f.start();const [run]=await f.rows('catpaw-runs'),[terms]=await f.rows(K.terms);await f.expireOrigin();await f.freshViewer();
 const path=`/catpaw/controls/v1/scopes/${f.scope.scope_id}/runs/${run.id}/control`;
 const submit=async action=>{const response=await f.req(path);assert.equal(response.status,200);const c=(await response.json()).control;assert.equal(c[{pause:'can_pause',resume:'can_resume'}[action]],true);return f.req(path+'/operations',{operation_id:randomUUID(),action,expected_execution_revision:c.execution_revision,expected_snapshot_hash:c.snapshot_hash,expected_grant_epoch:c.authority_reference.grant_epoch,expected_plan_revision:c.plan_reference.revision,expected_plan_hash:c.plan_reference.plan_hash});};
 assert.equal((await submit('pause')).status,200);assert.equal((await f.rows(K.grants))[0].state,'paused');assert.deepEqual(await f.rows(K.terms),[terms]);
 assert.equal((await submit('resume')).status,200);assert.equal((await f.rows(K.grants))[0].state,'active');assert.deepEqual(await f.rows(K.terms),[terms]);assert.deepEqual((await f.rows(K.grants))[0].consumed,{due:0,model:0,source:0});assert.equal(f.calls.length,1);await f.stop();
});
test('actual cloud admission and bounded worker finish the original report after origin expiry with one model budget',async()=>{
 const f=await fixture();await f.start();const [original]=await f.rows('catpaw-runs'),[terms]=await f.rows(K.terms);await f.expireOrigin();
 const settled=[];
 for(let index=0;index<4;index++){
  f.advance(1500);
  const result=await boundedTick({repository:f.repository,owners:[f.owner],workGrantService:f.runtime.facade.workGrantService,admitTask:f.runtime.facade.admittedTask.bind(f.runtime.facade),runStep:singleStepHandler(f.runtime.facade,f.runtime.provider),now:f.now,budgetMs:1000,settleReserveMs:200,leaseMs:5000});
  settled.push(...result.settled);
  if((await f.rows('tasks'))[0].status==='succeeded')break;
 }
 const [run]=await f.rows('catpaw-runs'),[task]=await f.rows('tasks'),[state]=await f.rows(K.grants),reservations=await f.rows(K.reservations);
 assert.equal(task.status,'succeeded');assert.equal(task.id,original.task_id);assert.equal(run.id,original.id);assert.equal(run.request_hash,original.request_hash);assert.deepEqual(run.frozen_request,original.frozen_request);assert.deepEqual(await f.rows(K.terms),[terms]);
 assert.deepEqual(state.consumed,{due:1,model:1,source:0});assert.equal(reservations.length,2);assert.ok(reservations.every(r=>r.state==='received'));assert.equal(f.calls.length,2);assert.equal(settled.at(-1).status,'succeeded');
 assert.equal(f.calls[1].provider_context.work_grant_reference.grant_id,f.work.decision_id);assert.equal((await f.rows('catpaw-artifact-versions')).length,1);
 const session=await f.repository.transaction(tx=>tx.get(membershipOwner(f.actor.issuer),'app-sessions',f.actor.session_id));assert.equal(session.expires_at,0);await f.stop();
});
