import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {ApiError,hash,clone} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {TASK_WORK_GRANT_CONTRACT,TASK_WORK_GRANT_KINDS,TASK_REVISION_WORK_GRANT_CONTRACT,TASK_REVISION_WORK_GRANT_KINDS,workGrantKinds,workGrantDueIdentity,validateWorkGrantReference,validateWorkGrantRunBinding,TASK_WORK_GRANT_LIMITS,validateWorkGrantTerms,workGrantReference,workGrantReceiptHash} from '../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {TaskWorkGrantService} from '../supabase/functions/_shared/core/src/task-work-grant-service.mjs';
import {LocalOutputFacade,LOCAL_POLICY} from '../supabase/functions/_shared/core/src/local-output-facade.mjs';
import {TaskExecutionStore} from '../supabase/functions/_shared/core/src/task-execution-store.mjs';
import {BoundedStore} from '../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-store.mjs';
import {createTaskPlan} from '../supabase/functions/_shared/core/src/task-plan-service.mjs';
import {sourceReadIdentity} from '../supabase/functions/_shared/core/src/public-source-contract.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};

import {freezeRevisionWorkIntent} from '../supabase/functions/_shared/core/src/task-revision-work-contract.mjs';
import {taskRevisionReceiptHash} from '../supabase/functions/_shared/core/src/task-revision-contract.mjs';
import {reopenTaskForRevisionInTransaction} from '../supabase/functions/_shared/core/src/task-plan-service.mjs';
import {resolveExecutionGrantInTransaction} from '../supabase/functions/_shared/core/src/task-work-execution-selector.mjs';
import {readTaskWorkGrantLifecycleInTransaction,transitionTaskWorkGrantInTransaction,revokeTaskWorkGrantsForSourceInTransaction,collectTaskWorkGrantPurgeRecordsInTransaction} from '../supabase/functions/_shared/core/src/task-work-grant-lifecycle.mjs';
async function fixture({limits={due:1,model:2,source:0},legacy=false,lifetime=60000}={}){
 let clock=Date.parse('2026-10-14T13:00:00.000Z'),authorized=true;
 const repository=new TestRepository(),subject=randomUUID(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),owner:'catpaw:'+hash(randomUUID())},principal={subject_id:subject,session_id:randomUUID(),issuer:'https://fictional-auth.example.com/auth/v1',issued_at:Math.floor(clock/1000),consent_revision:1};
 await repository.bootstrapScope(scope);
 const ids={operation_id:randomUUID(),run_id:randomUUID(),delegation_id:randomUUID(),task_id:hash(randomUUID())},cid=randomUUID(),args={title:'Fictional accepted report',goal:'Summarize supplied fictional data',requirements:'No external effects',stop_conditions:['Save the report']};
 const catalog=limits.source>0?{schema_version:1,contract:'catpaw.public-sources.v1',policy_hash:hash('fictional-source-policy'),sources:[{source_id:'source-1',requested_url:'https://public-fixture.example.com/one'}]}:null;
 const terms={schema_version:1,contract:TASK_WORK_GRANT_CONTRACT,mode:'accepted_run',grant_id:randomUUID(),scope,subject_id:subject,conversation_id:cid,source_auth:{...principal,scope_id:scope.scope_id},origin:ids,input_hash:hash({fictional:'explicit accepted user intention'}),args_hash:hash(args),model_configuration_hash:hash({provider:'fictional-offline',model:'fixture'}),route_hash:hash('fictional-zero-price-route'),source_catalog_hash:catalog?hash(catalog):null,memory_generation:1,accepted_at:new Date(clock).toISOString(),not_after:new Date(clock+lifetime).toISOString(),execution_budget_ms:Math.min(lifetime,60000),limits,allowed_tools:catalog?['read_public_sources_v1','save_sourced_report_v1','finish_task','ask_user']:['save_artifact','finish_task','ask_user']};
 const frozen={policy:LOCAL_POLICY,completion_contract:{schema_version:1,version:1,mode:'model_finish_local_artifact'},scope,subject_id:subject,conversation_id:cid,conversation_epoch:1,source_auth:clone(terms.source_auth),memory_generation:1,current_input_hash:terms.input_hash,args,model_configuration:{provider:'fictional-offline',model:'fixture'},run_binding:ids,...catalog?{public_sources:catalog}:{},...legacy?{}:{work_grant_reference:workGrantReference(terms)}};
 const requestHash=hash(frozen),tag={operation_id:ids.operation_id,run_id:ids.run_id,delegation_id:ids.delegation_id,request_hash:requestHash,grant_epoch:1,delegation_revision:1};
 await repository.transaction(async tx=>{
  await tx.put(scope.owner,'native-chat-conversations',{id:cid,subject_id:subject,scope_id:scope.scope_id,state:'active',grant_epoch:1});
  await tx.put(scope.owner,'catpaw-delegations',{id:ids.delegation_id,subject_id:subject,conversation_id:cid,state:'active',revision:1,grant_epoch:1,created_at:terms.accepted_at});
  await tx.put(scope.owner,'catpaw-operations',{id:ids.operation_id,run_id:ids.run_id,request_hash:requestHash});
  const run={id:ids.run_id,...tag,task_id:ids.task_id,frozen_request:frozen,artifact_references:[],approval_ids:[],created_at:terms.accepted_at};await tx.put(scope.owner,'catpaw-runs',run);
  const task=await createTaskPlan(tx,scope.owner,run,{id:ids.task_id,status:'queued',attempts:0,leaseId:null,leaseUntil:null,state:{catpaw:tag},createdAt:terms.accepted_at,artifactIds:[]});await tx.put(scope.owner,'tasks',task);
 });
 const authorize=async(_tx,ctx)=>{if(!authorized)throw new ApiError(403,'fictional_authority_revoked');if(['admission','read'].includes(ctx.phase))assert.equal(ctx.principal?.subject_id,subject);return {authorized:true};};
 const service=new TaskWorkGrantService({repository,authorize,now:()=>clock}),identity={owner:scope.owner,scope_id:scope.scope_id,subject_id:subject,grant_id:terms.grant_id};
 let execution;
 const claim=async(whole=false)=>{const lease=randomUUID(),facade=new LocalOutputFacade({repository,authenticate:()=>{throw Error('HTTP authentication unused');}}),store=whole?new TaskExecutionStore(facade,{now:()=>clock}):new BoundedStore({repository,owners:[scope.owner],admitTask:facade.admittedTask.bind(facade),now:()=>clock,invocation:{open:true,deadline:clock+60000},workGrantService:service});assert.ok(await store.compareAndSwap(scope.owner,'tasks',ids.task_id,{status:'queued'},{status:'running',leaseId:lease,leaseUntil:new Date(clock+60000).toISOString(),attempts:1}));execution={run_id:ids.run_id,task_id:ids.task_id,run_request_hash:requestHash,lease_id:lease,execution_revision:0};return execution;};
 return {repository,service,terms,principal,identity,ids,requestHash,claim,execution:()=>clone(execution),now:()=>clock,advance:ms=>{clock+=ms;},deny:()=>{authorized=false;},allow:()=>{authorized=true;}};
}

async function maintainedStore(f,whole){
 const facade=new LocalOutputFacade({repository:f.repository,authenticate:()=>{throw Error('HTTP authentication unused');}}),base=facade.admittedTask.bind(facade);
 facade.workGrantService=f.service;
 facade.admittedTask=async(tx,owner,id,options)=>{
  const admitted=await base(tx,owner,id,options);
  await f.service.assertAcceptedGrantCurrentInTransaction(tx,f.identity);
  return admitted;
 };
 const store=whole?new TaskExecutionStore(facade,{now:f.now}):new BoundedStore({repository:f.repository,owners:[f.identity.owner],admitTask:facade.admittedTask.bind(facade),now:f.now,invocation:{open:true,deadline:f.now()+60000},workGrantService:f.service});
 return {facade,store};
}
async function completedReport(f,whole){
 await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));const {facade,store}=await maintainedStore(f,whole),lease=randomUUID();
 const claimed=await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'queued'},{status:'running',leaseId:lease,leaseUntil:new Date(f.now()+60000).toISOString(),attempts:1});assert.ok(claimed);
 const control={signal:new AbortController().signal,open:true,deadline:f.now()+5000};await store.beginModelDispatch(f.identity.owner,f.ids.task_id,lease,hash('synthetic already received model'),control);await store.receiveModel(f.identity.owner,f.ids.task_id,lease,{text:'Fictional supplied-data report',calls:[],next:0,results:[]},control);
 await facade.recordModelPlanReceipt(f.identity.owner,f.ids.task_id,lease);
 const artifact=await facade.publishArtifact(f.identity.owner,f.ids.task_id,{kind:'report',title:'Fictional result',summary:'Supplied data only',data:{content:'A useful synthetic report based exclusively on supplied fictional records.'}},lease);
 const current=await f.repository.transaction(tx=>tx.get(f.identity.owner,'tasks',f.ids.task_id));assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:lease},{state:{...current.state,local_model:{...current.state.local_model,artifact}}}));
 const validation=await facade.assertTaskCompletion(f.identity.owner,f.ids.task_id,artifact,lease);assert.equal(validation.valid,true);
 const previous=await f.repository.transaction(tx=>tx.get(f.identity.owner,'tasks',f.ids.task_id)),verify=await f.repository.transaction(tx=>tx.get(f.identity.owner,'catpaw-task-plan-receipts',f.ids.run_id+':1:verify'));
 const proof={artifact_reference:artifact,plan_reference:clone(previous.state.plan_binding),verification_receipt:{id:verify.id,receipt_hash:verify.receipt_hash}};
 return {facade,store,previous,proof};
}
const due=f=>({operation_id:f.ids.operation_id,operation_key:hash({accepted_run:f.ids.run_id}),kind:'due',request_hash:f.requestHash,deadline_at:new Date(Math.min(Date.parse(f.terms.not_after),Date.parse(f.terms.accepted_at)+f.terms.execution_budget_ms)).toISOString()});

const K=TASK_WORK_GRANT_KINDS,R=TASK_REVISION_WORK_GRANT_KINDS;
async function prepareRevision({beforeAdmit=()=>{},advance=0,generation=1}={}){
 const f=await fixture(),{store,previous}=await completedReport(f,false);
 assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:previous.leaseId},{status:'succeeded',leaseId:null,leaseUntil:null,state:{...previous.state,local_model:{...previous.state.local_model,finished:true}}}));
 f.advance(advance);const original=f.repository.snapshot();
 const principal={...f.principal,session_id:randomUUID(),issued_at:Math.floor(f.now()/1000)},source={...principal,scope_id:f.identity.scope_id},turnID=randomUUID();
 let terms,identity,operation;
 const setup=async tx=>{
  await tx.withScope(f.identity.scope_id,async scoped=>{const row=await scoped.scope();await scoped.saveScope({...row,generation});});
  const run=await tx.get(f.identity.owner,'catpaw-runs',f.ids.run_id),task=await tx.get(f.identity.owner,'tasks',f.ids.task_id),head=await tx.get(f.identity.owner,'catpaw-task-plan-heads',run.id),base=await tx.get(f.identity.owner,'catpaw-artifact-versions',run.artifact_references[0].artifact_id+':1');
  const input={turn_id:turnID,expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'Add risk to conclusion two.\n Keep the exact user input.'},context:[]},target={intent:'revise_report',run_id:run.id,task_id:task.id,artifact_reference:run.artifact_references[0],expected_grant_epoch:1,expected_plan_revision:task.state.plan_binding.revision,expected_plan_hash:task.state.plan_binding.plan_hash},turn={id:turnID,conversation_id:f.terms.conversation_id,input,source_auth:source};
  const conversation=await tx.get(f.identity.owner,'native-chat-conversations',f.terms.conversation_id),work={decision_id:randomUUID(),input_hash:hash({turn:input,target}),route_hash:f.terms.route_hash,tool_policy:'local_output_v1',not_after:new Date(f.now()+60000).toISOString(),execution_budget_ms:60000,limits:{due:1,model:2,source:0}};
  const intent=freezeRevisionWorkIntent(work,{turn,target,scope:f.terms.scope,principal,conversation,routeHash:f.terms.route_hash,now:f.now()});turn.revision_work_intent=intent;
  const frozen={schema_version:1,contract:'catpaw.task-revision.v1',target,scope_id:f.identity.scope_id,subject_id:f.identity.subject_id,conversation_id:f.terms.conversation_id,turn_id:turnID,input_hash:hash(input),raw_instruction:input.message.text,instruction_hash:hash(input.message.text),base_body:base.body,base_body_hash:hash(base.body),original_request_hash:run.request_hash,original_source_auth:run.frozen_request.source_auth,fresh_source_auth:source,memory_generation:generation,revision_work_intent:intent,call_id:randomUUID(),requirements:'Add explicit risks'};
  const opid=randomUUID(),operationHash=hash(frozen),plan=await reopenTaskForRevisionInTransaction(tx,f.identity.owner,run,task,head,frozen.requirements,{operation_id:opid,operation_hash:operationHash,base_reference:target.artifact_reference});
  const planrow=await tx.get(f.identity.owner,'catpaw-task-plan-versions',run.id+':'+plan.plan_reference.revision);
  terms={...clone(f.terms),schema_version:2,contract:TASK_REVISION_WORK_GRANT_CONTRACT,mode:'accepted_revision',grant_id:work.decision_id,source_auth:source,memory_generation:generation,input_hash:work.input_hash,args_hash:hash(planrow.content),accepted_at:new Date(f.now()).toISOString(),not_after:work.not_after,execution_budget_ms:work.execution_budget_ms,limits:work.limits,revision_binding:{operation_id:opid,operation_hash:operationHash,accepted_plan_reference:plan.plan_reference,target_hash:hash(target),input_hash:work.input_hash}};
  identity={...f.identity,grant_id:terms.grant_id};
  const receipt={operation_id:opid,operation_hash:operationHash,scope_id:f.identity.scope_id,subject_id:f.identity.subject_id,conversation_id:f.terms.conversation_id,turn_id:turnID,call_id:frozen.call_id,run_id:run.id,task_id:task.id,base_reference:target.artifact_reference,base_plan_reference:task.state.plan_binding,accepted_plan_reference:plan.plan_reference,instruction_hash:frozen.instruction_hash,source_auth_hash:hash(frozen.original_source_auth),fresh_source_auth_hash:hash(source),grant_epoch:run.grant_epoch,accepted_at:terms.accepted_at};
  operation={id:opid,conversation_id:f.terms.conversation_id,run_id:run.id,task_id:task.id,frozen,operation_hash:operationHash,receipt,receipt_hash:taskRevisionReceiptHash(receipt),work_grant_reference:workGrantReference(terms)};
  await tx.put(f.identity.owner,'native-chat-turns',turn);await tx.put(f.identity.owner,'catpaw-task-revision-operations',operation);await tx.put(f.identity.owner,'tasks',{...plan.task,state:{...plan.task.state,task_revision:{...plan.task.state.task_revision,work_grant_reference:workGrantReference(terms)}}});
  await beforeAdmit(tx,{f,terms,identity,operation,turn});
  return f.service.admitRevisionInTransaction(tx,{identity,principal,terms});
 };
 const admitted=await f.repository.transaction(setup);
 const run=()=>f.repository.transaction(tx=>tx.get(f.identity.owner,'catpaw-runs',f.ids.run_id)),task=()=>f.repository.transaction(tx=>tx.get(f.identity.owner,'tasks',f.ids.task_id));
 return {...f,oldIdentity:f.identity,oldTerms:f.terms,identity,terms,principal,operation,original,admitted,run,task};
}
async function selected(f){return f.repository.transaction(async tx=>resolveExecutionGrantInTransaction(tx,f.identity.owner,await tx.get(f.identity.owner,'catpaw-runs',f.ids.run_id),await tx.get(f.identity.owner,'tasks',f.ids.task_id)));}
async function reserveDue(f){const s=await selected(f);return f.service.reserve(f.identity,{...s.due,kind:'due',deadline_at:f.terms.not_after});}
async function lease(f){const id=randomUUID();await f.repository.transaction(async tx=>{const task=await tx.get(f.identity.owner,'tasks',f.ids.task_id);await tx.put(f.identity.owner,'tasks',{...task,status:'running',leaseId:id,leaseUntil:f.terms.not_after,attempts:task.attempts+1});await tx.put(f.identity.owner,'runs',{id,taskId:task.id,status:'running',slice:{acknowledged:false,authority_hash:hash(task.state.catpaw),execution_revision:0}});await tx.put(f.identity.owner,'catpaw-run-links',{id,run_id:f.ids.run_id,task_id:task.id,operation_id:f.ids.operation_id,grant_epoch:1});});return {run_id:f.ids.run_id,task_id:f.ids.task_id,run_request_hash:f.requestHash,lease_id:id,execution_revision:0};}
const request=f=>({operation_id:randomUUID(),operation_key:hash('one new segment request'),kind:'model',request_hash:hash('new revision model input'),deadline_at:new Date(f.now()+30000).toISOString()});
test('v2 explicit revision keeps the same physical Task/run, immutable original grant and a separate exact reference',async()=>{
 const f=await prepareRevision(),s=await selected(f);assert.equal(f.admitted.created,true);assert.deepEqual(validateWorkGrantReference(s.reference),{schema_version:2,contract:TASK_REVISION_WORK_GRANT_CONTRACT,grant_id:f.terms.grant_id,terms_hash:hash(f.terms)});assert.deepEqual(s.kinds,R);assert.equal(s.run_binding.run_id,f.ids.run_id);assert.deepEqual(s.source_auth,f.terms.source_auth);assert.deepEqual(s.revision_binding,f.terms.revision_binding);assert.deepEqual(s.due,workGrantDueIdentity(f.terms,await f.run()));
 const oldRecords=f.original.records.filter(([k])=>[...Object.values(K),'catpaw-runs'].includes(JSON.parse(k)[1]));for(const [key,value] of oldRecords)assert.deepEqual(f.repository.records.get(key),value);
 assert.equal((await f.repository.transaction(tx=>tx.list(f.identity.owner,'catpaw-runs'))).length,1);assert.equal((await f.repository.transaction(tx=>tx.list(f.identity.owner,'tasks'))).length,1);
 const replay=await f.repository.transaction(tx=>f.service.admitRevisionInTransaction(tx,{identity:f.identity,principal:f.principal,terms:f.terms}));assert.equal(replay.created,false);assert.deepEqual(replay.receipt,f.admitted.receipt);
});
test('a new explicit revision may outlive the old finite grant without renewing its counters or deadline',async()=>{
 const f=await prepareRevision({advance:61000});assert.ok(Date.parse(f.oldTerms.not_after)<f.now());await reserveDue(f);const old=await f.service.read(f.oldIdentity,{principal:f.principal});assert.equal(old.grant.expired,true);assert.deepEqual(old.grant.consumed,{due:1,model:1,source:0});assert.equal(old.grant.terms.not_after,f.oldTerms.not_after);assert.deepEqual((await selected(f)).terms.limits,{due:1,model:2,source:0});
});
test('new due cannot use original operation/hash/key and replay never grants a second dispatch',async()=>{
 const f=await prepareRevision();await assert.rejects(f.service.reserve(f.identity,due({...f,terms:f.oldTerms})),e=>e.code==='work_grant_due_binding_conflict');const first=await reserveDue(f);assert.equal(first.created,true);assert.notEqual(first.reservation.id,f.ids.operation_id);const s=await selected(f),again=await f.service.reserve(f.identity,{...s.due,kind:'due',deadline_at:f.terms.not_after});assert.equal(again.may_dispatch,false);assert.deepEqual((await f.service.read(f.identity,{principal:f.principal})).grant.consumed,{due:1,model:0,source:0});
});
test('v2 immutable bindings reject substituted target, op hash, plan, fresh source, input, route and original snapshot',async()=>{
 for(const field of ['target','operation','plan','source','input','route','original'])await assert.rejects(prepareRevision({beforeAdmit:async(tx,{f,terms,operation})=>{if(field==='target')terms.revision_binding.target_hash=hash('other target');if(field==='operation')terms.revision_binding.operation_hash=hash('other operation');if(field==='plan')terms.args_hash=hash('other plan');if(field==='source')terms.source_auth={...terms.source_auth,session_id:randomUUID()};if(field==='input'){terms.input_hash=hash('other input');terms.revision_binding.input_hash=terms.input_hash;}if(field==='route')terms.route_hash=hash('other route');if(field==='original'){const run=await tx.get(f.identity.owner,'catpaw-runs',f.ids.run_id);await tx.put(f.identity.owner,'catpaw-runs',{...run,frozen_request:{...run.frozen_request,memory_generation:2}});}}}),e=>['work_grant_run_binding_conflict','work_grant_admission_principal_conflict'].includes(e.code),field);
});
test('a pending or missing original due cannot be laundered into a new bounded revision budget',async()=>{
 for(const mode of ['missing','unknown','pending'])await assert.rejects(prepareRevision({beforeAdmit:async(tx,{f})=>{const rows=await tx.list(f.identity.owner,K.reservations),old=rows.find(r=>r.frozen.input.kind==='due');if(mode==='missing'){tx.records.delete(tx.key(f.identity.owner,K.reservations,old.id));}else await tx.put(f.identity.owner,K.reservations,{...old,state:mode==='unknown'?'unknown':'reserved',outcome:mode==='unknown'?old.outcome:null});}}));
});
test('selector and execution fail closed on a missing or superseded pointer while historical old receipt stays readable',async()=>{
 for(const change of ['pointer','plan','opref','redact']){const f=await prepareRevision();await f.repository.transaction(async tx=>{const task=await tx.get(f.identity.owner,'tasks',f.ids.task_id);if(change==='pointer')await tx.put(f.identity.owner,'tasks',{...task,state:{...task.state,task_revision:{...task.state.task_revision,operation_id:randomUUID()}}});if(change==='plan')await tx.put(f.identity.owner,'tasks',{...task,state:{...task.state,plan_binding:{revision:3,plan_hash:hash('different plan')}}});if(change==='opref')await tx.put(f.identity.owner,'catpaw-task-revision-operations',{...f.operation,work_grant_reference:workGrantReference({...f.terms,grant_id:randomUUID()})});if(change==='redact'){const turn=await tx.get(f.identity.owner,'native-chat-turns',f.operation.frozen.turn_id);await tx.put(f.identity.owner,'native-chat-turns',{...turn,content_redacted:true});}});await assert.rejects(selected(f));await assert.rejects(reserveDue(f));const old=await f.service.read(f.oldIdentity,{principal:f.principal});assert.equal(old.receipt.contract,TASK_WORK_GRANT_CONTRACT);}
});
test('old grant execution cannot borrow a current revision even though its historical receipt is intact',async()=>{
 const f=await prepareRevision();await assert.rejects(f.repository.transaction(tx=>f.service.assertAcceptedGrantCurrentInTransaction(tx,f.oldIdentity)),e=>e.code==='work_grant_revision_superseded');assert.equal((await f.service.read(f.oldIdentity,{principal:f.principal})).grant.consumed.due,1);
});
test('v2 model reservation persists once, received continuation preserves one budget, unknown never resends',async()=>{
 for(const outcome of ['received','unknown']){const f=await prepareRevision();await reserveDue(f);const execution=await lease(f),input=request(f),res=await f.service.reserve(f.identity,input,{execution});assert.equal(res.may_dispatch,true);await f.repository.transaction(async tx=>{const task=await tx.get(f.identity.owner,'tasks',f.ids.task_id);await tx.put(f.identity.owner,'tasks',{...task,state:{...task.state,local_model:{round:{state:outcome==='received'?'received':'unknown',request_hash:input.request_hash,text:'Bounded revision received',calls:[],next:0,results:[]}}}});});const task=await f.task(),round=task.state.local_model.round;await f.service.settle(f.identity,{operation_id:input.operation_id,request_hash:input.request_hash,outcome,receipt_reference:outcome==='received'?{receipt_id:input.operation_id,receipt_hash:hash(round)}:null},{execution});const replay=await f.service.reserve(f.identity,input,{execution});assert.equal(replay.may_dispatch,false);if(outcome==='received')await f.repository.transaction(tx=>f.service.commitReceivedContinuationInTransaction(tx,f.identity,input.operation_id,async record=>record.put(f.identity.owner,'fictional-local-results',{id:input.operation_id,text:'same received result'}),{execution,currentSliceDeadline:f.now()+5000}));else await assert.rejects(f.service.reserve(f.identity,{...request(f),operation_key:hash('do not retry')},{execution}),e=>e.code==='work_grant_original_outcome_unknown');assert.deepEqual((await f.service.read(f.identity,{principal:f.principal})).grant.consumed,{due:1,model:1,source:0});}
});
test('current v2 lifecycle controls, withdrawal and purge use the same ledger without mutating original history',async()=>{
 const f=await prepareRevision();await reserveDue(f);const oldBefore=await f.service.read(f.oldIdentity,{principal:f.principal});let run=await f.run();const read=()=>f.repository.transaction(tx=>readTaskWorkGrantLifecycleInTransaction(tx,f.identity.owner,run,{now:f.now}));assert.deepEqual((await read()).reference,workGrantReference(f.terms));await f.repository.transaction(tx=>transitionTaskWorkGrantInTransaction(tx,f.identity.owner,run,{action:'pause',now:f.now}));assert.equal((await read()).state.state,'paused');await f.repository.transaction(tx=>transitionTaskWorkGrantInTransaction(tx,f.identity.owner,run,{action:'resume',now:f.now}));assert.equal((await read()).state.state,'active');assert.deepEqual((await f.service.read(f.oldIdentity,{principal:f.principal})).receipt,oldBefore.receipt);
 const plan=await f.repository.transaction(tx=>collectTaskWorkGrantPurgeRecordsInTransaction(tx,{owner:f.identity.owner,scope_id:f.identity.scope_id,subject_id:f.identity.subject_id,conversation_id:f.terms.conversation_id,runs:[run]}));assert.ok(plan.records.some(r=>r.kind===R.terms&&r.id===f.terms.grant_id));assert.ok(plan.records.some(r=>r.kind===K.terms&&r.id===f.oldTerms.grant_id));assert.ok(plan.blocked.includes('settle_original_work_attempt_before_purge'));
 await f.repository.transaction(tx=>revokeTaskWorkGrantsForSourceInTransaction(tx,{owner:f.identity.owner,scope_id:f.identity.scope_id,subject_id:f.identity.subject_id,session_id:f.terms.source_auth.session_id}));assert.equal((await read()).state.state,'revoked');await assert.rejects(f.repository.transaction(tx=>f.service.assertAcceptedGrantCurrentInTransaction(tx,f.identity)));
});
test('v2 fresh generation is explicit and final authority or generation changes roll back a new reservation',async()=>{
 const f=await prepareRevision();await reserveDue(f);f.deny();const before=f.repository.snapshot();await assert.rejects(f.service.reserve(f.identity,{...request(f)},{execution:{run_id:f.ids.run_id,task_id:f.ids.task_id,run_request_hash:f.requestHash,lease_id:randomUUID(),execution_revision:0}}));assert.deepEqual(f.repository.snapshot(),before);f.allow();await f.repository.transaction(tx=>tx.withScope(f.identity.scope_id,async s=>{const row=await s.scope();await s.saveScope({...row,generation:2});}));await assert.rejects(f.repository.transaction(tx=>f.service.assertAcceptedGrantCurrentInTransaction(tx,f.identity)),e=>e.code==='work_grant_generation_conflict');
});

test('a fresh explicitly frozen generation can revise a delivered report without rewriting its old generation',async()=>{
 const f=await prepareRevision({generation:2});await reserveDue(f);assert.equal((await selected(f)).terms.memory_generation,2);assert.equal((await f.run()).frozen_request.memory_generation,1);assert.equal((await f.service.read(f.oldIdentity,{principal:f.principal})).grant.terms.memory_generation,1);
});

test('old session logout leaves an explicitly fresh revision grant intact; fresh logout fences only that segment',async()=>{
 const f=await prepareRevision();await reserveDue(f);await f.repository.transaction(tx=>revokeTaskWorkGrantsForSourceInTransaction(tx,{owner:f.identity.owner,scope_id:f.identity.scope_id,subject_id:f.identity.subject_id,session_id:f.oldTerms.source_auth.session_id}));assert.equal((await f.service.read(f.oldIdentity,{principal:f.principal})).grant.state,'revoked');assert.equal((await f.service.read(f.identity,{principal:f.principal})).grant.state,'active');await f.repository.transaction(tx=>revokeTaskWorkGrantsForSourceInTransaction(tx,{owner:f.identity.owner,scope_id:f.identity.scope_id,subject_id:f.identity.subject_id,session_id:f.terms.source_auth.session_id}));assert.equal((await f.service.read(f.identity,{principal:f.principal})).grant.state,'revoked');
});
