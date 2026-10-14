import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {boundedTick} from '../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-tick.mjs';
import {singleStepHandler} from '../supabase/functions/_shared/core/src/single-step-handler.mjs';
import {PublicWebReader} from '../supabase/functions/_shared/public-web-reader.mjs';
import {ApiError,hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {taskRevisionReceiptHash} from '../supabase/functions/_shared/core/src/task-revision-contract.mjs';

globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const PLAN={title:'Offline report',goal:'Compare supplied fictional findings',requirements:'Save and verify a useful report',stop_conditions:['Saved and verified'],steps:['compose','save','verify'].map(id=>({id,title:id,detail:''}))};
const RAW='Add risk to conclusion two; retain the other findings.\n\u4e2d\u6587 / \ufeff \u0085 exact raw';
const DOC='The fictional public document contains reviewed findings and current risk evidence.';
const POLICY={schema_version:1,contract:'catpaw.public-web-policy.v1',origins:[{origin:'https://docs.example.org',connect_ipv4:'93.184.216.34',path_prefixes:['/docs/']}]};
const call=(name,args)=>({type:'tool_call',id:randomUUID(),name,arguments:args}),done={type:'done',finish_reason:'tool_calls'};
async function fixture({sourced=false,autoKick=false,wholeWorker=false,correction=false}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}},fresh={...principal,session_id:randomUUID()},calls=[],retained=[];let reads=0,now=Date.now();
 const net={async connect({hostname}){return {remoteAddr:{hostname,port:443},close(){}};},async startTls(tcp){reads++;let offset=0;const raw=new TextEncoder().encode(`HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${DOC.length}\r\n\r\n${DOC}`);return {remoteAddr:tcp.remoteAddr,async handshake(){return {alpnProtocol:'http/1.1'};},async write(b){return b.length;},async read(b){if(offset===raw.length)return null;const n=Math.min(b.length,raw.length-offset);b.set(raw.subarray(offset,offset+n));offset+=n;return n;},close(){tcp.close();}};}};
 const provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',async *stream(input){
  calls.push(input);
  if(!input.tools.length){yield {type:'text_delta',text:'Read-only explanation of the selected report.'};yield {type:'done',finish_reason:'stop'};return;}
  if(input.tools.some(t=>t.function.name==='delegate_task')){yield call(sourced?'delegate_sources_v1':'delegate_plan_v1',{...PLAN,...sourced?{source_urls:['https://docs.example.org/docs/one']}:{}});yield done;return;}
  if(input.tools.some(t=>t.function.name==='revise_current_report_v1')){yield call('revise_current_report_v1',{requirements:'Revise conclusion two with risk'});yield done;return;}
  const initial=JSON.parse(input.messages[0].content),revision=initial.task_revision_context;
  if(sourced&&!input.messages.some(m=>m.role==='tool')){yield call('read_public_sources_v1',{});yield done;return;}
  if(revision){assert.equal(revision.raw_instruction,RAW);assert.equal(hash(revision.raw_instruction),revision.instruction_hash);assert.ok(revision.base_body.includes('Original conclusion two')||revision.base_body.includes('explicit risk'));assert.equal(initial.applied_plan.revision,revision.plan_reference.revision);assert.ok(initial.applied_plan.revision>=2);assert.deepEqual(input.provider_context.input_context.slice(-2),[{text:RAW},{text:revision.base_body}]);assert.equal(input.provider_context.revision_source_auth.session_id,fresh.session_id);assert.equal(input.provider_context.source_auth.session_id,principal.session_id);}
  const intermediate=revision&&correction&&!input.messages.some(m=>m.role==='tool'&&m.content.includes('"saved":true'));
  yield call(sourced?'save_sourced_report_v1':'save_artifact',{title:PLAN.title,summary:revision?'Revised conclusion with risk':'Original report',content:(intermediate?'Intermediate report awaiting a corrected risk section.':revision?'Conclusion two now includes explicit risk.':'Original conclusion two.')+' '+DOC,...sourced?{citations:[{source_id:'source-1',quote:DOC}]}:{}});if(!intermediate)yield call('finish_task',{summary:'Saved and verified'});yield done;
 }};
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard',...sourced?{CATPAW_PUBLIC_SOURCE_POLICY:JSON.stringify(POLICY)}:{}},config=readConfig(k=>values[k]);
 const sourceChecker=async(tx,source,identity)=>{assert.equal(source.scope_id,identity.scope_id);const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);if(row?.subject_id!==source.subject_id||row.state!=='active')throw new ApiError(409,'grant_conflict');};
 const runtime=await createCloudRuntime({repository,config,provider,sourceChecker,verifyToken:async auth=>{const p=auth==='Bearer fresh'?fresh:principal;return {iss:p.issuer,sub:p.subject_id,session_id:p.session_id,exp:9999999999};},authenticate:auth=>auth==='Bearer fresh'?fresh:principal,autoKick,retain:p=>retained.push(p),publicSourceReader:sourced?new PublicWebReader({policy:POLICY,net}):null,diagnostic:()=>{}});
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);await repository.transaction(async tx=>{await tx.put(membershipOwner(principal.issuer),'scope-memberships',{id:principal.subject_id,scopes:[scope]});for(const p of [principal,fresh])await tx.put(membershipOwner(p.issuer),'app-sessions',{id:p.session_id,subject_id:p.subject_id,state:'active',expires_at:9999999999});});
 const owner=runtime.facade.owner(scope),cid=randomUUID(),base=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,req=(path,body,auth='Bearer original')=>runtime.api(new Request('https://offline.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:auth,'Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}}));
 const json=async(r,status=200)=>{const v=await r.json();assert.equal(r.status,status,JSON.stringify(v));return v;};
 await json(await req(base,{conversation_id:cid}),201);await json(await req(`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash}));
 const originalTurn=randomUUID(),response=await req(`${base}/${cid}/turns`,{turn_id:originalTurn,expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'Save a report from supplied fictional information https://docs.example.org/docs/one'},context:[]});assert.equal(response.status,200);await response.body.getReader().cancel();await Promise.all(retained);
 const rows=kind=>repository.transaction(tx=>tx.list(owner,kind)),binding=(await json(await req(`${base}/${cid}/turns/${originalTurn}`))).turn.task_bindings[0];
 const tick=()=>boundedTick({repository,owners:[owner],admitTask:runtime.facade.admittedTask.bind(runtime.facade),runStep:singleStepHandler(runtime.facade,runtime.provider),now:()=>now,budgetMs:10000,settleReserveMs:500,leaseMs:20000});
 const settle=async()=>{for(let i=0;i<10;i++){now=Math.max(now,Date.now())+100;if(wholeWorker){const task=(await rows('tasks'))[0];if(['queued','scheduled'].includes(task?.status))await runtime.worker.run(owner,task);}else await tick();now+=10000;}};await settle();
 const run=(await rows('catpaw-runs'))[0],task=(await rows('tasks'))[0];assert.equal(task.status,'succeeded');const conversation=(await rows('native-chat-conversations'))[0];
 const input={turn:{turn_id:randomUUID(),expected_revision:conversation.revision,expected_grant_epoch:1,message:{id:randomUUID(),text:RAW},context:[]},target:{intent:'revise_report',run_id:run.id,task_id:task.id,artifact_reference:run.artifact_references[0],expected_grant_epoch:1,expected_plan_revision:1,expected_plan_hash:task.state.plan_binding.plan_hash}},path=`/catpaw/revisions/v1/scopes/${scope.scope_id}/conversations/${cid}/turns`;
 const revise=async(i=input)=>{const r=await req(path,i,'Bearer fresh');if(r.status!==200)return json(r);await r.body.getReader().cancel();await Promise.all(retained);return (await json(await req(path+'/'+i.turn.turn_id,undefined,'Bearer fresh'))).turn;};
 return {repository,runtime,scope,principal,fresh,owner,cid,rows,binding,run,task,input,path,req,json,revise,settle,calls,reads:()=>reads,stop:()=>runtime.worker.stop()};
}

test('maintenance HTTP revises the original Task through fresh worker compose/save/verify and immutable result',async()=>{
 for(const sourced of [false,true]){const f=await fixture({sourced});try{
  const old=(await f.rows('catpaw-artifact-versions'))[0],oldReceipts=await f.rows('catpaw-task-plan-receipts'),before=f.calls.length,reads=f.reads(),turn=await f.revise();
  assert.equal(turn.state,'completed');assert.deepEqual(turn.task_bindings,[]);const receipt=turn.continuations[0];assert.equal(receipt.receipt_hash,taskRevisionReceiptHash(receipt));
  assert.equal((await f.rows('tasks'))[0].status,'scheduled');assert.equal((await f.rows('catpaw-artifact-versions')).length,1);
  const history=await f.json(await f.req(`/catpaw/artifacts/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/artifacts/${old.artifact_id}/versions/1`));assert.equal(history.artifact.body,old.body);assert.equal(history.artifact.editable,false);
  await f.settle();const task=(await f.rows('tasks'))[0],run=(await f.rows('catpaw-runs'))[0],versions=await f.rows('catpaw-artifact-versions');
  assert.equal(task.status,'succeeded');assert.equal(task.id,f.task.id);assert.equal((await f.rows('tasks')).length,1);assert.equal(run.id,f.run.id);assert.deepEqual(run.frozen_request,f.run.frozen_request);assert.equal(run.request_hash,f.run.request_hash);assert.deepEqual(task.state.catpaw,f.task.state.catpaw);assert.equal(versions.length,2);assert.equal(versions[0].body,old.body);
  const current=versions.find(v=>v.version===2),body=JSON.parse(current.body);assert.match(body.data.content,/explicit risk/);assert.equal(body.data.model_revision.operation_id,receipt.operation_id);assert.equal(body.data.model_revision.instruction_hash,hash(RAW));assert.equal(current.content_hash,hash(current.body));
  const newReceipts=(await f.rows('catpaw-task-plan-receipts')).filter(r=>r.plan_revision===2);assert.deepEqual(newReceipts.map(r=>r.step_id).sort(),['compose','save','verify']);for(const r of oldReceipts)assert.deepEqual((await f.rows('catpaw-task-plan-receipts')).find(x=>x.id===r.id),r);
  assert.ok(f.calls.length>before+1);assert.equal(f.reads()-reads,sourced?1:0);
  const opPath=`/catpaw/revisions/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/operations/${receipt.operation_id}`,result=(await f.json(await f.req(opPath,undefined,'Bearer fresh'))).revision;
  assert.equal(result.state,'completed');assert.equal(result.result_reference.version,2);assert.equal(result.result_reference.content_hash,current.content_hash);const count=f.calls.length;await f.json(await f.req(opPath,undefined,'Bearer fresh'));await f.json(await f.req(f.path,f.input,'Bearer fresh'));assert.equal(f.calls.length,count);
 }finally{await f.stop();}}
});
test('real composition refuses new sensitive text, sensitive selected manual body and consent upgrades before model',async()=>{
 for(const reason of ['raw','body','consent']){const f=await fixture();try{const input=structuredClone(f.input);
  if(reason==='raw')input.turn.message.text='Please include this \u75c5\u5386 information in the report';
  if(reason==='body'){const ref=input.target.artifact_reference,edited=await f.json(await f.req(`/catpaw/artifacts/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/artifacts/${ref.artifact_id}/amendments`,{operation_id:randomUUID(),expected_version:1,expected_content_hash:ref.content_hash,expected_grant_epoch:1,expected_plan_revision:1,expected_plan_hash:input.target.expected_plan_hash,content:{title:'Manual sensitive body',summary:'Unconfirmed input',content:'\u75c5\u5386 content not approved for model'}}));input.target.artifact_reference={artifact_id:ref.artifact_id,version:2,content_hash:edited.artifact.content_hash};}
  if(reason==='consent')await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${f.cid}/model-consent`,{decision:'allow',expected_revision:1,route_hash:(await f.json(await f.req('/catpaw/privacy/v1/model-route'))).route_hash,sensitive_confirmed:true}));
  const before=f.calls.length,r=await f.req(f.path,input,'Bearer fresh');assert.equal(r.status,403);assert.equal(f.calls.length,before);assert.equal((await f.rows('catpaw-task-revision-operations')).length,0);
 }finally{await f.stop();}}
});
test('accepted fresh source revocation cannot dispatch an original Task revision or reuse old completion',async()=>{
 const f=await fixture();try{await f.revise();const count=f.calls.length;await f.repository.transaction(async tx=>{const o=membershipOwner(f.fresh.issuer),session=await tx.get(o,'app-sessions',f.fresh.session_id);await tx.put(o,'app-sessions',{...session,state:'revoked'});});await f.settle();assert.equal(f.calls.length,count);assert.equal((await f.rows('catpaw-artifact-versions')).length,1);assert.equal((await f.rows('catpaw-task-revision-results')).length,0);assert.notEqual((await f.rows('tasks'))[0].status,'succeeded');}finally{await f.stop();}
});

test('the existing whole TaskWorker also creates new-plan receipts and a same-task model revision',async()=>{
 const f=await fixture({wholeWorker:true});try{const before=f.calls.length,turn=await f.revise();await f.settle();const task=(await f.rows('tasks'))[0],run=(await f.rows('catpaw-runs'))[0];assert.equal(task.id,f.task.id);assert.equal(task.status,'succeeded');assert.deepEqual(run.frozen_request,f.run.frozen_request);assert.equal(run.artifact_references[0].version,2);assert.ok(f.calls.length>before+1);const result=(await f.json(await f.req(`/catpaw/revisions/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/operations/${turn.continuations[0].operation_id}`,undefined,'Bearer fresh'))).revision;assert.equal(result.state,'completed');assert.equal(result.result_reference.version,2);}finally{await f.stop();}
});

test('verification receipt cannot declare completion before actual Task settlement',async()=>{
 const f=await fixture();try{const turn=await f.revise();await f.settle();const receipt=turn.continuations[0],task=(await f.rows('tasks'))[0],path=`/catpaw/revisions/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/operations/${receipt.operation_id}`;await f.repository.transaction(tx=>tx.put(f.owner,'tasks',{...task,status:'running',leaseId:randomUUID(),leaseUntil:new Date(Date.now()+10000).toISOString()}));const count=f.calls.length,waiting=(await f.json(await f.req(path,undefined,'Bearer fresh'))).revision;assert.equal(waiting.state,'accepted');assert.equal(waiting.result_reference,undefined);assert.equal(f.calls.length,count);await f.repository.transaction(tx=>tx.put(f.owner,'tasks',task));assert.equal((await f.json(await f.req(path,undefined,'Bearer fresh'))).revision.state,'completed');}finally{await f.stop();}
});

test('a corrected intermediate model report retains exact publication proofs and final result on the same operation',async()=>{
 const f=await fixture({correction:true});try{const turn=await f.revise();await f.settle();const task=(await f.rows('tasks'))[0],versions=await f.rows('catpaw-artifact-versions'),publications=await f.rows('catpaw-task-revision-artifact-receipts');assert.equal(task.status,'succeeded');assert.deepEqual(versions.map(v=>v.version).sort(),[1,2,3]);assert.equal(publications.length,2);assert.deepEqual(publications.map(p=>p.artifact_reference.version).sort(),[2,3]);assert.notEqual(publications[0].arguments_hash,publications[1].arguments_hash);assert.notEqual(publications[0].round_hash,publications[1].round_hash);const result=(await f.rows('catpaw-task-revision-results'))[0],final=publications.find(p=>p.artifact_reference.version===3);assert.equal(result.artifact_receipt_reference.id,final.id);assert.equal(result.artifact_receipt_reference.receipt_hash,final.receipt_hash);const read=(await f.json(await f.req(`/catpaw/revisions/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/operations/${turn.continuations[0].operation_id}`,undefined,'Bearer fresh'))).revision;assert.equal(read.state,'completed');assert.equal(read.result_reference.version,3);assert.equal((await f.rows('tasks')).length,1);}finally{await f.stop();}
});

test('another accepted revision preserves the completed original operation while resetting only current execution',async()=>{
 const f=await fixture();try{
  const first=await f.revise();await f.settle();const receipt=first.continuations[0],oldRun=(await f.rows('catpaw-runs'))[0],oldTask=(await f.rows('tasks'))[0],oldPlanReceipts=await f.rows('catpaw-task-plan-receipts'),oldResult=(await f.rows('catpaw-task-revision-results'))[0];
  const next=structuredClone(f.input),conversation=(await f.rows('native-chat-conversations'))[0];next.turn.turn_id=randomUUID();next.turn.message.id=randomUUID();next.turn.expected_revision=conversation.revision;next.target.artifact_reference=oldRun.artifact_references[0];next.target.expected_plan_revision=oldTask.state.plan_binding.revision;next.target.expected_plan_hash=oldTask.state.plan_binding.plan_hash;
  const second=await f.revise(next),newReceipt=second.continuations[0],count=f.calls.length,path=id=>`/catpaw/revisions/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/operations/${id}`;
  assert.notEqual(newReceipt.operation_id,receipt.operation_id);assert.equal(newReceipt.base_reference.version,2);assert.equal(newReceipt.accepted_plan_reference.revision,3);assert.equal((await f.rows('tasks'))[0].status,'scheduled');
  const old=(await f.json(await f.req(path(receipt.operation_id),undefined,'Bearer fresh'))).revision,current=(await f.json(await f.req(path(newReceipt.operation_id),undefined,'Bearer fresh'))).revision;
  assert.equal(old.state,'completed');assert.deepEqual(old.result_reference,oldResult.result_reference);assert.equal(current.state,'accepted');assert.equal(current.result_reference,undefined);assert.equal(f.calls.length,count);
  await f.settle();assert.equal((await f.rows('tasks'))[0].status,'succeeded');assert.equal((await f.rows('tasks')).length,1);assert.equal((await f.rows('catpaw-runs'))[0].id,f.run.id);assert.deepEqual((await f.rows('catpaw-runs'))[0].frozen_request,f.run.frozen_request);
  const later=(await f.json(await f.req(path(newReceipt.operation_id),undefined,'Bearer fresh'))).revision;assert.equal(later.state,'completed');assert.equal(later.result_reference.version,3);
  for(const prior of oldPlanReceipts)assert.deepEqual((await f.rows('catpaw-task-plan-receipts')).find(r=>r.id===prior.id),prior);
  assert.deepEqual((await f.rows('catpaw-task-revision-results')).find(r=>r.id===oldResult.id),oldResult);
 }finally{await f.stop();}
});

test('explicit report question never acquires model revision authority from modification wording',async()=>{
 const f=await fixture();try{
  const input=structuredClone(f.input);input.target.intent='explain_report';input.turn.message.text='Explain the risk; modify and replace all conclusions if you like';
  const before={tasks:await f.rows('tasks'),runs:await f.rows('catpaw-runs'),plans:await f.rows('catpaw-task-plan-heads'),versions:await f.rows('catpaw-artifact-versions')},calls=f.calls.length,turn=await f.revise(input);
  assert.equal(turn.state,'completed');assert.deepEqual(turn.continuations,[]);assert.deepEqual(turn.task_bindings,[]);assert.equal(f.calls.length,calls+1);assert.deepEqual(f.calls.at(-1).tools,[]);
  assert.deepEqual(await f.rows('tasks'),before.tasks);assert.deepEqual(await f.rows('catpaw-runs'),before.runs);assert.deepEqual(await f.rows('catpaw-task-plan-heads'),before.plans);assert.deepEqual(await f.rows('catpaw-artifact-versions'),before.versions);assert.deepEqual(await f.rows('catpaw-task-revision-operations'),[]);
  const count=f.calls.length;await f.json(await f.req(f.path+'/'+input.turn.turn_id,undefined,'Bearer fresh'));await f.json(await f.req(f.path,input,'Bearer fresh'));assert.equal(f.calls.length,count);
 }finally{await f.stop();}
});

test('ordinary plan amendment cannot replace an in-progress frozen report-revision plan',async()=>{
 const f=await fixture();try{
  await f.revise();const task=(await f.rows('tasks'))[0],head=(await f.rows('catpaw-task-plan-heads'))[0],versions=await f.rows('catpaw-task-plan-versions'),calls=f.calls.length;
  const body={operation_id:randomUUID(),expected_revision:head.accepted_revision,expected_plan_hash:head.accepted_plan_hash,expected_grant_epoch:1,content:{...PLAN,requirements:'A competing ordinary amendment'}};
  const response=await f.req(`/catpaw/plans/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/plan/amendments`,body,'Bearer fresh'),error=await f.json(response,409);assert.equal(error.error.code,'plan_revision_in_progress');
  assert.deepEqual((await f.rows('tasks'))[0],task);assert.deepEqual((await f.rows('catpaw-task-plan-heads'))[0],head);assert.deepEqual(await f.rows('catpaw-task-plan-versions'),versions);assert.equal(f.calls.length,calls);assert.deepEqual(await f.rows('catpaw-task-plan-operations'),[]);
  await f.settle();assert.equal((await f.rows('tasks'))[0].status,'succeeded');assert.equal((await f.rows('catpaw-runs'))[0].artifact_references[0].version,2);
 }finally{await f.stop();}
});


test('normal logout durably fences fresh revision authority without replacing the original grant or losing unknown identity',async()=>{
 for(const wholeWorker of [false,true])for(const dispatched of [false,true]){
  const f=await fixture({wholeWorker});try{
   const turn=await f.revise(),operation=turn.continuations[0],count=f.calls.length;
   const originalDelegation=(await f.rows('catpaw-delegations'))[0],unknownHash=hash({fictional:'original dispatched request'});
   if(dispatched)await f.repository.transaction(async tx=>{const task=await tx.get(f.owner,'tasks',f.task.id);await tx.put(f.owner,'tasks',{...task,status:'running',leaseId:randomUUID(),leaseUntil:new Date(Date.now()+20000).toISOString(),state:{...task.state,local_model:{...task.state.local_model,round:{state:'dispatched',request_hash:unknownHash}}}});});
   const stopped=await f.json(await f.req('/catpaw/account/v1/logout',{},'Bearer fresh'));assert.equal(stopped.revoked,true);
   const task=(await f.rows('tasks'))[0];assert.equal(task.status,'paused');assert.equal(task.leaseId,null);assert.equal(task.state.task_control.reason,'revision_source_not_current');
   assert.deepEqual((await f.rows('catpaw-delegations'))[0],originalDelegation);assert.deepEqual((await f.rows('catpaw-runs'))[0].frozen_request,f.run.frozen_request);
   const path=`/catpaw/controls/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/control`,control=(await f.json(await f.req(path))).control;
   assert.equal(control.source_authorization_current,false);assert.equal(control.can_resume,false);assert.equal(control.can_revoke,true);assert.equal(control.blocked_reason,'revision_source_not_current');
   assert.deepEqual(control.unresolved_operations,dispatched?[{kind:'model',operation_id:unknownHash,state:'dispatched',can_retry:false}]:[]);
   const denied=await f.json(await f.req(path+'/operations',{operation_id:randomUUID(),action:'resume',expected_execution_revision:control.execution_revision,expected_snapshot_hash:control.snapshot_hash,expected_grant_epoch:control.grant_epoch,expected_plan_revision:control.plan_reference.revision,expected_plan_hash:control.plan_reference.plan_hash}),403);assert.equal(denied.error.code,'control_source_not_current');
   await f.settle();assert.equal(f.calls.length,count);assert.equal((await f.rows('catpaw-artifact-versions')).length,1);assert.equal((await f.rows('tasks'))[0].status,'paused');
   const read=(await f.json(await f.req(`/catpaw/revisions/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/operations/${operation.operation_id}`))).revision;assert.equal(read.state,dispatched?'blocked_unknown':'accepted');assert.equal(read.result_reference,undefined);assert.equal(f.calls.length,count);
   await f.repository.transaction(async tx=>{assert.equal((await tx.get(membershipOwner(f.fresh.issuer),'app-sessions',f.fresh.session_id)).state,'revoked');assert.equal((await tx.get(membershipOwner(f.principal.issuer),'app-sessions',f.principal.session_id)).state,'active');});
  }finally{await f.stop();}
 }
});


test('source purge accounts for durable task controls even after parent execution records are missing',async()=>{
 const f=await fixture();try{
  await f.revise();const path=`/catpaw/controls/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/control`,snapshot=(await f.json(await f.req(path))).control;
  const input={operation_id:randomUUID(),action:'pause',expected_execution_revision:snapshot.execution_revision,expected_snapshot_hash:snapshot.snapshot_hash,expected_grant_epoch:snapshot.grant_epoch,expected_plan_revision:snapshot.plan_reference.revision,expected_plan_hash:snapshot.plan_reference.plan_hash};
  const paused=await f.json(await f.req(path+'/operations',input));assert.equal(paused.control.task_status,'paused');
  const sources=await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,scoped=>scoped.list('sources'))),source=sources.find(s=>s.conversation_id===f.cid)??sources[0];assert.ok(source);
  const base=`/catpaw/memory/v1/scopes/${f.scope.scope_id}/sources/${source.id}`,preview=(await f.json(await f.req(base+'/purge-plan'))).plan;
  assert.equal(preview.execute_supported,false);assert.ok(preview.blocked.includes('revoke_and_fence_active_execution_before_purge'));
  const ledger=preview.owner_records.find(r=>r.kind==='catpaw-task-control-operations'&&r.id===input.operation_id);assert.ok(ledger);assert.match(ledger.expected_record_hash,/^[a-f0-9]{64}$/);
  const original=(await f.rows('native-chat-conversations'))[0].messages,count=f.calls.length;
  // Simulate missing parent/other retained ledgers. This is only a damaged-store fixture,
  // not a purge implementation or authorized production deletion.
  const removedKinds=new Set(['catpaw-runs','catpaw-task-plan-heads','catpaw-task-source-reads','catpaw-task-source-receipts','catpaw-task-actions','catpaw-task-action-proposals','catpaw-task-action-decisions','catpaw-task-artifact-operations','catpaw-task-artifact-receipts','catpaw-task-revision-operations','catpaw-task-revision-results','catpaw-task-revision-artifact-receipts']);
  for(const key of [...f.repository.records.keys()]){const [owner,kind]=JSON.parse(key);if(owner===f.owner&&removedKinds.has(kind))f.repository.records.delete(key);}
  const orphan=(await f.json(await f.req(base+'/purge-plan'))).plan;assert.ok(orphan.owner_records.some(r=>r.kind==='catpaw-task-control-operations'&&r.id===input.operation_id));
  const denied=await f.json(await f.req(base+'/delete',{}),409);assert.equal(denied.error.code,'source_eraser_requires_execution_purge');
  assert.deepEqual((await f.rows('native-chat-conversations'))[0].messages,original);assert.equal((await f.rows('catpaw-task-control-operations')).length,1);assert.equal(f.calls.length,count);
 }finally{await f.stop();}
});
