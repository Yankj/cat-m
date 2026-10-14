import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {ApiError,hash,clone} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {TASK_WORK_GRANT_CONTRACT,TASK_WORK_GRANT_KINDS,TASK_WORK_GRANT_LIMITS,validateWorkGrantTerms,workGrantReference,workGrantReceiptHash} from '../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {TaskWorkGrantService} from '../supabase/functions/_shared/core/src/task-work-grant-service.mjs';
import {LocalOutputFacade,LOCAL_POLICY} from '../supabase/functions/_shared/core/src/local-output-facade.mjs';
import {TaskExecutionStore} from '../supabase/functions/_shared/core/src/task-execution-store.mjs';
import {BoundedStore} from '../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-store.mjs';
import {createTaskPlan} from '../supabase/functions/_shared/core/src/task-plan-service.mjs';
import {sourceReadIdentity} from '../supabase/functions/_shared/core/src/public-source-contract.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};

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
 const claim=async(whole=true)=>{const lease=randomUUID(),facade=new LocalOutputFacade({repository,authenticate:()=>{throw Error('HTTP authentication unused');}}),store=whole?new TaskExecutionStore(facade,{now:()=>clock}):new BoundedStore({repository,owners:[scope.owner],admitTask:facade.admittedTask.bind(facade),now:()=>clock,invocation:{open:true,deadline:clock+60000}});assert.ok(await store.compareAndSwap(scope.owner,'tasks',ids.task_id,{status:'queued'},{status:'running',leaseId:lease,leaseUntil:new Date(clock+60000).toISOString(),attempts:1}));execution={run_id:ids.run_id,task_id:ids.task_id,run_request_hash:requestHash,lease_id:lease,execution_revision:0};return execution;};
 return {repository,service,terms,principal,identity,ids,requestHash,claim,execution:()=>clone(execution),now:()=>clock,advance:ms=>{clock+=ms;},deny:()=>{authorized=false;},allow:()=>{authorized=true;}};
}

test('a newly frozen accepted run receives immutable finite terms and the same admission receipt on replay',async()=>{
 const f=await fixture(),accepted=await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});
 assert.equal(accepted.created,true);assert.equal(accepted.grant.reference.terms_hash,workGrantReference(f.terms).terms_hash);assert.deepEqual(accepted.grant.consumed,{due:0,model:0,source:0});
 const original=clone(accepted.receipt),replay=await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});
 assert.equal(replay.created,false);assert.deepEqual(replay.receipt,original);
 const restored=new TaskWorkGrantService({repository:new TestRepository(f.repository.snapshot()),authorize:async()=>({authorized:true}),now:f.now});
 const read=await restored.read(f.identity,{principal:f.principal});assert.deepEqual(read.receipt,original);assert.equal(read.grant.run_binding.run_id,f.ids.run_id);assert.equal(read.grant.run_binding.task_id,f.ids.task_id);assert.equal(read.grant.task_completed,false);
});
test('a grant-current boundary uses one instant for both lower and upper limits',async()=>{
 const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});const start=Date.parse(f.terms.accepted_at),end=Date.parse(f.terms.not_after),values=[start+1,end+1,start+1],service=new TaskWorkGrantService({repository:f.repository,now:()=>values.shift()});
 // Deliberately isolate the grant fact check. This is an internal clock-boundary
 // regression, not a claim that a public API bypassed its permission callback.
 await assert.rejects(f.repository.transaction(async tx=>{const ctx=await service.current(tx,f.identity,()=>{});await service.grantCurrent(tx,ctx,()=>{});}),e=>e.code==='work_grant_expired');
});
test('a write permission rejects backward clocks and invalid initial instants without renewing its budget',()=>{
 const start=Date.parse('2026-10-15T00:00:00.000Z'),values=[start,start+5,start+3],service=new TaskWorkGrantService({now:()=>values.shift()}),live=service.permission();live();assert.throws(live,e=>e.code==='work_grant_write_deadline');
 for(const value of [NaN,Infinity,start+0.5])assert.throws(()=>new TaskWorkGrantService({now:()=>value}).permission(),e=>e.code==='work_grant_write_deadline');
});

// Test-only composition of the actual maintenance facade/store ports. This is
// store/domain integration evidence, not a claim that API/production is wired.
async function maintainedStore(f,whole){
 const facade=new LocalOutputFacade({repository:f.repository,authenticate:()=>{throw Error('HTTP authentication unused');}}),base=facade.admittedTask.bind(facade);
 facade.admittedTask=async(tx,owner,id,options)=>{
  const admitted=await base(tx,owner,id,options);
  await f.service.assertAcceptedGrantCurrentInTransaction(tx,f.identity);
  return admitted;
 };
 const store=whole?new TaskExecutionStore(facade,{now:f.now}):new BoundedStore({repository:f.repository,owners:[f.identity.owner],admitTask:facade.admittedTask.bind(facade),now:f.now,invocation:{open:true,deadline:f.now()+60000}});
 return {facade,store};
}
async function completedReport(f,whole){
 await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));const {facade,store}=await maintainedStore(f,whole),lease=randomUUID();
 const claimed=await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'queued'},{status:'running',leaseId:lease,leaseUntil:new Date(f.now()+60000).toISOString(),attempts:1});assert.ok(claimed);
 const state={...claimed.state,local_model:{step:0,messages:[],round:{state:'received',request_hash:hash('synthetic already received model'),text:'Fictional supplied-data report',calls:[],next:0,results:[]}}};
 assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:lease},{state}));
 await facade.recordModelPlanReceipt(f.identity.owner,f.ids.task_id,lease);
 const artifact=await facade.publishArtifact(f.identity.owner,f.ids.task_id,{kind:'report',title:'Fictional result',summary:'Supplied data only',data:{content:'A useful synthetic report based exclusively on supplied fictional records.'}},lease);
 const validation=await facade.assertTaskCompletion(f.identity.owner,f.ids.task_id,artifact,lease);assert.equal(validation.valid,true);
 const previous=await f.repository.transaction(tx=>tx.get(f.identity.owner,'tasks',f.ids.task_id)),verify=await f.repository.transaction(tx=>tx.get(f.identity.owner,'catpaw-task-plan-receipts',f.ids.run_id+':1:verify'));
 const proof={artifact_reference:artifact,plan_reference:clone(previous.state.plan_binding),verification_receipt:{id:verify.id,receipt_hash:verify.receipt_hash}};
 return {facade,store,previous,proof};
}
for(const whole of [true,false])test(`maintained ${whole?'whole':'bounded'} store commits a validated terminal CAS and its original acknowledgement`,async()=>{
 const f=await fixture(),{store,previous}=await completedReport(f,whole),next=await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:previous.leaseId},{status:'succeeded',leaseId:null,leaseUntil:null,state:{...previous.state,local_model:{...previous.state.local_model,finished:true}}});
 assert.ok(next,'valid terminal CAS must commit');assert.equal(next.status,'succeeded');
 const attempt=await f.repository.transaction(tx=>tx.get(f.identity.owner,'runs',previous.leaseId));assert.equal(attempt.status,'succeeded');assert.equal(whole?attempt.execution.acknowledged:attempt.slice.acknowledged,true);
});
for(const whole of [true,false])test(`the original due settles against the maintained ${whole?'whole':'bounded'} attempt acknowledgement after terminal lease cleanup`,async()=>{
 const f=await fixture(),{store,previous,proof}=await completedReport(f,whole);assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:previous.leaseId},{status:'succeeded',leaseId:null,leaseUntil:null,state:{...previous.state,local_model:{...previous.state.local_model,finished:true}}}));
 const input={previous_task:previous,attempt_id:previous.leaseId,completion_receipt:proof};
 const settled=await f.repository.transaction(tx=>f.service.settleOriginalAttemptInTransaction(tx,f.identity,input));
 assert.equal(settled.created,true);assert.equal(settled.reservation.state,'received');assert.equal(settled.reservation.outcome.acknowledgement.task_status,'succeeded');
 const read=await f.service.read(f.identity,{principal:f.principal});assert.equal(read.grant.task_completed,false);assert.equal(read.grant.consumed.due,1);
 assert.equal((await f.repository.transaction(tx=>f.service.settleOriginalAttemptInTransaction(tx,f.identity,input))).created,false);
});
function attachAttemptAcknowledgement(f,store,proof,options={}){
 const close=(tx,previous,task)=>f.service.settleOriginalAttemptInTransaction(tx,f.identity,{previous_task:previous,attempt_id:previous.leaseId,completion_receipt:task.status==='succeeded'?proof:null},options);
 if(store instanceof TaskExecutionStore){const original=store.acknowledge.bind(store);store.acknowledge=async(tx,owner,previous,next)=>{await original(tx,owner,previous,next);await close(tx,previous,next);};}
 else store.onCommit=async(tx,{previous,task})=>close(tx,previous,task);
}
for(const whole of [true,false])test(`actual ${whole?'whole':'bounded'} ack port atomically commits domain-validated Task, attempt and original due`,async()=>{
 const f=await fixture(),{store,previous,proof}=await completedReport(f,whole);attachAttemptAcknowledgement(f,store,proof);
 assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:previous.leaseId},{status:'succeeded',leaseId:null,leaseUntil:null}));
 const read=await f.service.read(f.identity,{principal:f.principal});assert.equal(read.reservations.find(r=>r.id===f.ids.operation_id).state,'received');assert.equal(read.grant.task_completed,false);
});
for(const whole of [true,false])test(`actual ${whole?'whole':'bounded'} final ack write rolls back Task, attempt and due together on cancel, timeout or source withdrawal`,async()=>{
 for(const boundary of ['cancel','deadline','authority']){
  const f=await fixture(),{store,previous,proof}=await completedReport(f,whole),controller=new AbortController();attachAttemptAcknowledgement(f,store,proof,{signal:controller.signal});
  const before=f.repository.snapshot(),transaction=f.repository.transaction.bind(f.repository);let injected=false;
  f.repository.transaction=fn=>transaction(async tx=>{const put=tx.put.bind(tx);tx.put=async(owner,kind,row)=>{const result=await put(owner,kind,row);if(!injected&&kind===TASK_WORK_GRANT_KINDS.reservations&&row.id===f.ids.operation_id&&row.state==='received'){injected=true;if(boundary==='cancel')controller.abort();if(boundary==='deadline')f.advance(TASK_WORK_GRANT_LIMITS.write_budget_ms);if(boundary==='authority')f.deny();}return result;};return fn(tx);});
  const action=()=>store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:previous.leaseId},{status:'succeeded',leaseId:null,leaseUntil:null});
  if(whole)assert.equal(await action(),null);else await assert.rejects(action(),e=>e.code==='commit_hook_failed');assert.equal(injected,true,boundary);assert.deepEqual(f.repository.snapshot(),before,boundary);
 }
});

test('a durable received result finishes in a fresh maintained bounded slice after its original network deadline',async()=>{
 const f=await fixture({limits:{due:1,model:1,source:0}});await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));
 let {facade,store}=await maintainedStore(f,false);const lease=randomUUID(),claimed=await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'queued'},{status:'running',leaseId:lease,leaseUntil:new Date(f.now()+60000).toISOString(),attempts:1});
 const execution={run_id:f.ids.run_id,task_id:f.ids.task_id,run_request_hash:f.requestHash,lease_id:lease,execution_revision:0},request=model(f);await f.service.reserve(f.identity,request,{execution});
 const state={...claimed.state,local_model:{step:0,messages:[],round:{state:'received',request_hash:request.request_hash,text:'Offline received result',calls:[],next:0,results:[]}}};
 await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:lease},{state});await f.service.settle(f.identity,received(request,state.local_model.round),{execution});await facade.recordModelPlanReceipt(f.identity.owner,f.ids.task_id,lease);
 await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:lease},{status:'scheduled',nextRunAt:new Date(f.now()+1000).toISOString(),leaseId:null,leaseUntil:null});
 f.advance(31000);({facade,store}=await maintainedStore(f,false));const nextLease=randomUUID();assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'scheduled',leaseId:null},{status:'running',leaseId:nextLease,leaseUntil:new Date(f.now()+60000).toISOString(),attempts:2}));
 const nextExecution={...execution,lease_id:nextLease},commit=f.service.commitReceivedContinuationInTransaction.bind(f.service);
 const reference=await f.repository.transaction(tx=>commit(tx,f.identity,request.operation_id,record=>facade.publishArtifactInTransaction(record,f.identity.owner,f.ids.task_id,{kind:'report',title:'Late slice result',summary:'Durable response reused',data:{content:'The original received fictional response is saved without asking a model again.'}},nextLease),{execution:nextExecution,currentSliceDeadline:f.now()+5000}));
 assert.equal((await facade.assertTaskCompletion(f.identity.owner,f.ids.task_id,reference,nextLease)).valid,true);
 const read=await f.service.read(f.identity,{principal:f.principal});assert.equal(read.grant.remaining.model,0);assert.equal(read.reservations.find(r=>r.id===request.operation_id).state,'received');assert.equal((await f.service.reserve(f.identity,request)).may_dispatch,false);
});
test('a longer live grant and lease cannot extend the original accepted due execution deadline',async()=>{
 const f=await fixture({lifetime:120000});await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();const request=model(f);await f.service.reserve(f.identity,request,{execution:f.execution()});await checkpointReceived(f,request);await f.service.settle(f.identity,received(request),{execution:f.execution()});
 const {store}=await maintainedStore(f,true);assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:f.execution().lease_id},{leaseUntil:new Date(f.now()+120000).toISOString()}));f.advance(60000);assert.equal((await f.service.read(f.identity,{principal:f.principal})).grant.expired,false);const before=f.repository.snapshot();let mutated=false;
 await assert.rejects(f.repository.transaction(tx=>f.service.commitReceivedContinuationInTransaction(tx,f.identity,request.operation_id,async record=>{mutated=true;await record.put(f.identity.owner,'fictional-work-results',{id:request.operation_id,text:'Beyond original due'});},{execution:f.execution(),currentSliceDeadline:f.now()+5000})),e=>e.code==='work_grant_continuation_deadline');assert.equal(mutated,false);assert.deepEqual(f.repository.snapshot(),before);
});
test('fresh received continuation final awaits fence slice time, payload, source, control, takeover and generation',async()=>{
 for(const boundary of ['slice','payload','authority','control','takeover','generation']){const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();const request=model(f);await f.service.reserve(f.identity,request,{execution:f.execution()});await checkpointReceived(f,request);await f.service.settle(f.identity,received(request),{execution:f.execution()});const before=f.repository.snapshot();
  await assert.rejects(f.repository.transaction(tx=>f.service.commitReceivedContinuationInTransaction(tx,f.identity,request.operation_id,async record=>{
   await record.put(f.identity.owner,'fictional-work-results',{id:request.operation_id,text:'Atomic bounded local result'});
   if(boundary==='slice')f.advance(5000);if(boundary==='authority')f.deny();
   if(['payload','control','takeover'].includes(boundary)){const task=await record.get(f.identity.owner,'tasks',f.ids.task_id);await record.put(f.identity.owner,'tasks',boundary==='takeover'?{...task,leaseId:randomUUID()}:boundary==='control'?{...task,state:{...task.state,task_control:{revision:1}}}:{...task,state:{...task.state,local_model:{...task.state.local_model,round:{...task.state.local_model.round,text:'Unreceived payload'}}}});}
   if(boundary==='generation')await record.withScope(f.identity.scope_id,async scoped=>{const scope=await scoped.scope();await scoped.saveScope({...scope,generation:scope.generation+1});});
  },{execution:f.execution(),currentSliceDeadline:f.now()+5000})),e=>e.code===({slice:'work_grant_continuation_deadline',payload:'work_grant_received_checkpoint_required',authority:'fictional_authority_revoked',control:'work_grant_execution_conflict',takeover:'work_grant_execution_conflict',generation:'work_grant_generation_conflict'}[boundary]));assert.deepEqual(f.repository.snapshot(),before,boundary);
 }
});

const due=f=>({operation_id:f.ids.operation_id,operation_key:hash({accepted_run:f.ids.run_id}),kind:'due',request_hash:f.requestHash,deadline_at:new Date(Math.min(Date.parse(f.terms.not_after),Date.parse(f.terms.accepted_at)+f.terms.execution_budget_ms)).toISOString()});
const model=(f,key='first')=>({operation_id:randomUUID(),operation_key:hash(key),kind:'model',request_hash:hash('fictional-model:'+key),deadline_at:new Date(f.now()+30000).toISOString()});
async function originalDispatch(f,kind='model',whole=true){
 await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim(whole);let request=model(f),checkpoint;
 await f.repository.transaction(async tx=>{
  const task=await tx.get(f.identity.owner,'tasks',f.ids.task_id),run=await tx.get(f.identity.owner,'catpaw-runs',f.ids.run_id);
  if(kind==='model'){const round={state:'dispatched',request_hash:request.request_hash};await tx.put(f.identity.owner,'tasks',{...task,state:{...task.state,local_model:{step:0,messages:[],round}}});checkpoint={kind,request_hash:round.request_hash,checkpoint_hash:hash(round)};}
  else{const source=run.frozen_request.public_sources.sources[0],plan=task.state.plan_binding,id=sourceReadIdentity(run.id,plan,source.source_id),requestHash=hash({run_id:run.id,task_id:task.id,run_request_hash:run.request_hash,source,plan_reference:plan,policy_hash:run.frozen_request.public_sources.policy_hash}),read={id,run_id:run.id,task_id:task.id,conversation_id:run.frozen_request.conversation_id,source_id:source.source_id,requested_url:source.requested_url,plan_reference:plan,policy_hash:run.frozen_request.public_sources.policy_hash,request_hash:requestHash,state:'dispatched',dispatch_lease_id:f.execution().lease_id,dispatched_at:new Date(f.now()).toISOString()};await tx.put(f.identity.owner,'catpaw-task-source-reads',read);request={...request,operation_id:id,kind:'source',request_hash:requestHash};checkpoint={kind,read_id:id,request_hash:requestHash,checkpoint_hash:hash(read)};}
 });
 const reserved=await f.service.reserve(f.identity,request,{execution:f.execution()});return {request,input:{original_reservation:reserved.reservation,execution:f.execution(),durable_checkpoint:checkpoint}};
}
test('new transport guards bind the actual original dispatched model/source checkpoint and maintained attempt',async()=>{
 for(const kind of ['model','source']){const f=await fixture({limits:{due:1,model:1,source:1}}),{input}=await originalDispatch(f,kind),before=f.repository.snapshot();assert.equal(await f.repository.transaction(tx=>f.service.assertNewDispatchInTransaction(tx,f.identity,input)),undefined);assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.service.read(f.identity,{principal:f.principal})).grant.remaining[kind],0);}
});
test('a new dispatch guard rejects substituted checkpoint, attempt, control fence and expired original transport',async()=>{
 for(const defect of ['checkpoint','attempt','revision','terminal','transport_deadline','source_read']){const kind=defect==='source_read'?'source':'model',f=await fixture({limits:{due:1,model:1,source:1}}),{input,request}=await originalDispatch(f,kind);
  if(defect==='checkpoint')input.durable_checkpoint.checkpoint_hash=hash('a substituted durable checkpoint');
  if(defect==='attempt')await f.repository.transaction(tx=>tx.put(f.identity.owner,'runs',{id:input.execution.lease_id,taskId:f.ids.task_id,status:'running'}));
  if(defect==='revision'||defect==='terminal')await f.repository.transaction(async tx=>{const task=await tx.get(f.identity.owner,'tasks',f.ids.task_id);await tx.put(f.identity.owner,'tasks',defect==='revision'?{...task,state:{...task.state,task_control:{revision:1}}}:{...task,status:'succeeded',leaseId:null,leaseUntil:null});});
  if(defect==='source_read')await f.repository.transaction(async tx=>{const read=await tx.get(f.identity.owner,'catpaw-task-source-reads',request.operation_id);await tx.put(f.identity.owner,'catpaw-task-source-reads',{...read,dispatch_lease_id:randomUUID()});});
  if(defect==='transport_deadline')f.advance(30000);const before=f.repository.snapshot();await assert.rejects(f.repository.transaction(tx=>f.service.assertNewDispatchInTransaction(tx,f.identity,input)),e=>e instanceof ApiError&&e.status===409);assert.deepEqual(f.repository.snapshot(),before,defect);
 }
});
test('one accepted due and each original operation consume budget once across duplicate callers and snapshot restore',async()=>{
 const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});
 const request=due(f),both=await Promise.all([f.service.reserve(f.identity,request),f.service.reserve(f.identity,request)]);
 assert.equal(both.filter(r=>r.may_dispatch).length,1);assert.equal(both.filter(r=>r.created).length,1);
 const replay=await f.service.reserve(f.identity,request);assert.equal(replay.may_dispatch,false);assert.deepEqual(replay.reservation,both.find(r=>r.created).reservation);
 const restored=new TaskWorkGrantService({repository:new TestRepository(f.repository.snapshot()),authorize:async()=>({authorized:true}),now:f.now});
 assert.equal((await restored.reserve(f.identity,request)).may_dispatch,false);
 assert.deepEqual((await restored.read(f.identity,{principal:f.principal})).grant.consumed,{due:1,model:0,source:0});
 await assert.rejects(restored.reserve(f.identity,{...request,operation_id:randomUUID()}),e=>e.code==='work_grant_operation_key_conflict');
 await assert.rejects(restored.reserve(f.identity,{...request,request_hash:hash('changed original request')}),e=>e.code==='work_grant_operation_conflict');
});

const receivedRound=request=>({state:'received',request_hash:request.request_hash,text:'Fictional supplied-data response',calls:[],next:0,results:[]});
const received=(request,round=receivedRound(request))=>({operation_id:request.operation_id,request_hash:request.request_hash,outcome:'received',receipt_reference:{receipt_id:request.operation_id,receipt_hash:hash(round)}});
async function checkpointReceived(f,request){
 const facade=new LocalOutputFacade({repository:f.repository,authenticate:()=>{throw Error('HTTP authentication unused');}}),store=new TaskExecutionStore(facade,{now:f.now}),task=await f.repository.transaction(tx=>tx.get(f.identity.owner,'tasks',f.ids.task_id));
 assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:f.execution().lease_id},{state:{...task.state,local_model:{step:0,messages:[],round:receivedRound(request)}}}));return received(request);
}
test('a transport received self-hash and a missing original unknown checkpoint cannot acknowledge a reservation',async()=>{
 for(const outcome of ['received','unknown']){const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();const request=model(f);await f.service.reserve(f.identity,request,{execution:f.execution()});const before=f.repository.snapshot();await assert.rejects(f.service.settle(f.identity,outcome==='received'?received(request):{operation_id:request.operation_id,request_hash:request.request_hash,outcome,receipt_reference:null},{execution:f.execution()}),e=>e.code==='work_grant_transport_checkpoint_required');assert.deepEqual(f.repository.snapshot(),before);}
});
test('source received remains fail closed until the real single-read receipt verifier is composed',async()=>{
 const f=await fixture({limits:{due:1,model:1,source:1}}),{request}=await originalDispatch(f,'source');await f.repository.transaction(async tx=>{const read=await tx.get(f.identity.owner,'catpaw-task-source-reads',request.operation_id);await tx.put(f.identity.owner,'catpaw-task-source-reads',{...read,state:'received',receipt_hash:hash('fictional unverified source')});});const before=f.repository.snapshot();await assert.rejects(f.service.settle(f.identity,{...received(request),receipt_reference:{receipt_id:request.operation_id,receipt_hash:hash('fictional unverified source')}},{execution:f.execution()}),e=>e.code==='work_grant_source_receipt_verifier_required');assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.service.read(f.identity,{principal:f.principal})).grant.remaining.source,0);
});
test('a received continuation requires the original durable payload and refuses fabricated/missing checkpoints',async()=>{
 for(const defect of ['missing','payload','unknown']){
  const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();const request=model(f);await f.service.reserve(f.identity,request,{execution:f.execution()});await checkpointReceived(f,request);await f.service.settle(f.identity,received(request),{execution:f.execution()});
  await f.repository.transaction(async tx=>{const task=await tx.get(f.identity.owner,'tasks',f.ids.task_id),round=task.state.local_model.round;await tx.put(f.identity.owner,'tasks',{...task,state:{...task.state,local_model:{...task.state.local_model,round:defect==='missing'?null:defect==='payload'?{...round,text:'Unreceived replacement'}:{state:'dispatched',request_hash:round.request_hash}}}});});
  const before=f.repository.snapshot();await assert.rejects(f.repository.transaction(tx=>f.service.commitReceivedContinuationInTransaction(tx,f.identity,request.operation_id,record=>record.put(f.identity.owner,'fictional-work-results',{id:request.operation_id,text:'Must not publish'}),{execution:f.execution(),currentSliceDeadline:f.now()+5000})),e=>e.code==='work_grant_received_checkpoint_required');assert.deepEqual(f.repository.snapshot(),before,defect);
 }
});
test('terminal unknown cannot replace a missing original dispatch reservation with a new identity',async()=>{
 const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();const {store}=await maintainedStore(f,true),task=await f.repository.transaction(tx=>tx.get(f.identity.owner,'tasks',f.ids.task_id));await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:task.leaseId},{state:{...task.state,local_model:{step:0,messages:[],round:{state:'dispatched',request_hash:hash('lost original operation identity')}}}});const previous=await f.repository.transaction(tx=>tx.get(f.identity.owner,'tasks',f.ids.task_id));assert.equal((await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:previous.leaseId},{status:'failed',leaseId:null,leaseUntil:null})).status,'outcome_unknown');const before=f.repository.snapshot();await assert.rejects(f.repository.transaction(tx=>f.service.settleOriginalAttemptInTransaction(tx,f.identity,{previous_task:previous,attempt_id:previous.leaseId,completion_receipt:null})),e=>e.code==='work_grant_original_unknown_required');assert.deepEqual(f.repository.snapshot(),before);
});
for(const whole of [true,false])test(`actual ${whole?'whole':'bounded'} unknown acknowledgement keeps the original operation and cannot masquerade as succeeded`,async()=>{
 for(const kind of ['model','source']){const f=await fixture({limits:{due:1,model:1,source:1}}),{request}=await originalDispatch(f,kind,whole),{store}=await maintainedStore(f,whole),previous=await f.repository.transaction(tx=>tx.get(f.identity.owner,'tasks',f.ids.task_id));
 attachAttemptAcknowledgement(f,store,null);const next=await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:previous.leaseId},{status:'outcome_unknown',leaseId:null,leaseUntil:null});assert.equal(next.status,'outcome_unknown');
 const read=await f.service.read(f.identity,{principal:f.principal}),original=read.reservations.find(r=>r.id===request.operation_id);assert.equal(original.state,'reserved');assert.equal(original.frozen.input.request_hash,request.request_hash);assert.equal(read.reservations.find(r=>r.id===f.ids.operation_id).state,'unknown');assert.equal(read.grant.consumed[kind],1);assert.equal((await f.service.reserve(f.identity,request)).may_dispatch,false);
 await assert.rejects(f.service.reserve(f.identity,{...model(f,'forbidden-resend'),kind},{execution:f.execution()}),e=>['work_grant_original_outcome_unknown','work_grant_execution_conflict'].includes(e.code));}
});
test('typed terminal acknowledgement rejects stale attempt, control revision and fabricated domain completion receipt',async()=>{
 for(const defect of ['attempt','revision','verify_self_hash','plan','missing_verify','missing_proof']){
  const f=await fixture(),{store,previous,proof}=await completedReport(f,true);assert.ok(await store.compareAndSwap(f.identity.owner,'tasks',f.ids.task_id,{status:'running',leaseId:previous.leaseId},{status:'succeeded',leaseId:null,leaseUntil:null}));const input={previous_task:clone(previous),attempt_id:previous.leaseId,completion_receipt:clone(proof)};
  if(defect==='attempt'){input.attempt_id=randomUUID();input.previous_task.leaseId=input.attempt_id;}
  if(defect==='revision')input.previous_task.state.task_control={revision:1};
  if(defect==='verify_self_hash'){input.completion_receipt.verification_receipt.receipt_hash=hash('independent forged validation');await f.repository.transaction(async tx=>{const row=await tx.get(f.identity.owner,'catpaw-task-plan-receipts',proof.verification_receipt.id);await tx.put(f.identity.owner,'catpaw-task-plan-receipts',{...row,receipt_hash:input.completion_receipt.verification_receipt.receipt_hash});});}
  if(defect==='plan')input.completion_receipt.plan_reference.plan_hash=hash('other plan');
  if(defect==='missing_verify')input.completion_receipt.verification_receipt.id=randomUUID()+':1:verify';
  if(defect==='missing_proof')input.completion_receipt=null;
  const before=f.repository.snapshot();await assert.rejects(f.repository.transaction(tx=>f.service.settleOriginalAttemptInTransaction(tx,f.identity,input)),e=>e.status===409);assert.deepEqual(f.repository.snapshot(),before,defect);
 }
});
test('the last allowed model dispatch can record its original receipt and bounded result without restoring budget',async()=>{
 const f=await fixture({limits:{due:1,model:1,source:0}});await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));
 await f.claim();const request=model(f),reserved=await f.service.reserve(f.identity,request,{execution:f.execution()});assert.equal(reserved.may_dispatch,true);assert.equal((await f.service.read(f.identity,{principal:f.principal})).grant.remaining.model,0);
 const outcome=await checkpointReceived(f,request),settled=await f.service.settle(f.identity,outcome,{execution:f.execution()});assert.equal(settled.created,true);assert.equal(settled.reservation.state,'received');
 await f.repository.transaction(tx=>f.service.commitReceivedContinuationInTransaction(tx,f.identity,request.operation_id,async record=>{await record.insertIfAbsent(f.identity.owner,'fictional-work-results',{id:request.operation_id,text:'Only the last allowed synthetic result'});},{execution:f.execution(),currentSliceDeadline:f.now()+5000}));
 const read=await f.service.read(f.identity,{principal:f.principal});assert.equal(read.grant.remaining.model,0);assert.equal(read.grant.task_completed,false);
 assert.equal((await f.service.settle(f.identity,outcome)).created,false);assert.equal((await f.service.reserve(f.identity,request)).may_dispatch,false);
 await assert.rejects(f.service.reserve(f.identity,model(f,'second'),{execution:f.execution()}),e=>e.code==='work_grant_budget_exhausted');
});

test('a stale executor cannot reserve a new request merely because its work grant is active',async()=>{
 const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();
 const stale={...f.execution(),lease_id:randomUUID()};await assert.rejects(f.service.reserve(f.identity,model(f),{execution:stale}),e=>e.code==='work_grant_execution_conflict');
 assert.deepEqual((await f.service.read(f.identity,{principal:f.principal})).grant.consumed,{due:1,model:0,source:0});
});

test('admission verifies the persisted grant state after its final awaited write',async()=>{
 const f=await fixture(),before=f.repository.snapshot(),transaction=f.repository.transaction.bind(f.repository);let injected=false;
 f.repository.transaction=fn=>transaction(async tx=>{const put=tx.put.bind(tx);tx.put=async(owner,kind,row)=>{const result=await put(owner,kind,row);if(!injected&&kind===TASK_WORK_GRANT_KINDS.grants){injected=true;await put(owner,kind,{...row,state:'paused'});}return result;};return fn(tx);});
 await assert.rejects(f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms}),e=>e.code==='work_grant_not_active');assert.equal(injected,true);assert.deepEqual(f.repository.snapshot(),before);
});

test('all duration and cumulative limits are explicit bounded terms without recurring or external-effect authority',async()=>{
 const f=await fixture();
 for(const change of [
  t=>{delete t.not_after;},t=>{delete t.limits;},t=>{t.allow_expired=true;},t=>{t.mode='recurring';},t=>{t.limits.due=2;},
  t=>{t.limits.model=TASK_WORK_GRANT_LIMITS.model+1;},t=>{t.limits.model=-1;},t=>{t.limits.source=TASK_WORK_GRANT_LIMITS.source+1;},
  t=>{t.not_after=new Date(Date.parse(t.accepted_at)+TASK_WORK_GRANT_LIMITS.lifetime_ms+1).toISOString();},t=>{t.not_after=t.accepted_at;},
  t=>{t.execution_budget_ms=0;},t=>{t.execution_budget_ms=TASK_WORK_GRANT_LIMITS.execution_budget_ms+1;},
  t=>{t.allowed_tools.push('write_calendar');},t=>{t.source_auth.refresh_token='fictional-never-a-token';},t=>{t.scope.owner=4;},t=>{t.memory_generation=0;}
 ]){const terms=clone(f.terms);change(terms);assert.throws(()=>validateWorkGrantTerms(terms),e=>e.status===422);}
});

test('legacy, started and stale runs cannot receive retroactive work authorization',async()=>{
 const legacy=await fixture({legacy:true}),before=legacy.repository.snapshot();await assert.rejects(legacy.service.admit({identity:legacy.identity,principal:legacy.principal,terms:legacy.terms}),e=>e.code==='work_grant_run_binding_conflict');assert.deepEqual(legacy.repository.snapshot(),before);
 for(const reason of ['started','stale']){const f=await fixture();if(reason==='started')await f.claim();else f.advance(TASK_WORK_GRANT_LIMITS.write_budget_ms);const original=f.repository.snapshot();await assert.rejects(f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms}),e=>e.code==='work_grant_late_admission');assert.deepEqual(f.repository.snapshot(),original);}
});

test('grant admission and viewing require their own principal and a configured trusted authority port',async()=>{
 const f=await fixture(),before=f.repository.snapshot(),unconfigured=new TaskWorkGrantService({repository:f.repository,now:f.now});
 await assert.rejects(unconfigured.admit({identity:f.identity,principal:f.principal,terms:f.terms}),e=>e.code==='work_grant_authority_not_configured');assert.deepEqual(f.repository.snapshot(),before);
 await assert.rejects(f.service.admit({identity:f.identity,principal:{...f.principal,session_id:randomUUID()},terms:f.terms}),e=>e.code==='work_grant_admission_principal_conflict');
 await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await assert.rejects(f.service.read(f.identity,{principal:{subject_id:randomUUID()}}),e=>e.code==='work_grant_viewer_conflict');
 f.deny();await assert.rejects(f.service.reserve(f.identity,due(f)),e=>e.code==='fictional_authority_revoked');
});

test('model and public-source unknown retain their original identity and spent budget through recovery',async()=>{
 for(const kind of ['model','source']){const f=await fixture({limits:{due:1,model:2,source:2}}),{request}=await originalDispatch(f,kind),unknown={operation_id:request.operation_id,request_hash:request.request_hash,outcome:'unknown',receipt_reference:null};await f.service.settle(f.identity,unknown,{execution:f.execution()});
  const restored=new TaskWorkGrantService({repository:new TestRepository(f.repository.snapshot()),authorize:async()=>({authorized:true}),now:f.now}),read=await restored.read(f.identity,{principal:f.principal}),original=read.reservations.find(r=>r.id===request.operation_id);
  assert.equal(original.state,'unknown');assert.equal(original.frozen.input.request_hash,request.request_hash);assert.equal(read.grant.consumed[kind],1);assert.equal(read.grant.remaining[kind],1);
  assert.equal((await restored.reserve(f.identity,request)).may_dispatch,false);assert.equal((await restored.settle(f.identity,unknown)).created,false);
  await assert.rejects(restored.reserve(f.identity,{...model(f,'new-operation'),kind},{execution:f.execution()}),e=>e.code==='work_grant_original_outcome_unknown');
  await assert.rejects(restored.settle(f.identity,received(request),{execution:f.execution()}),e=>e.code==='work_grant_outcome_conflict');
  assert.equal((await restored.read(f.identity,{principal:f.principal})).grant.consumed[kind],1);
 }
});

test('an unacknowledged operation blocks new dispatch and due closure requires original domain acknowledgement',async()=>{
 const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});const d=due(f);await f.service.reserve(f.identity,d);await f.claim();const first=model(f);await f.service.reserve(f.identity,first,{execution:f.execution()});
 await assert.rejects(f.service.reserve(f.identity,model(f,'second'),{execution:f.execution()}),e=>e.code==='work_grant_original_outcome_pending');
 await assert.rejects(f.service.settle(f.identity,received(d)),e=>e.code==='work_grant_due_acknowledgement_required');
 await checkpointReceived(f,first);await f.service.settle(f.identity,received(first),{execution:f.execution()});await assert.rejects(f.service.settle(f.identity,received(d)),e=>e.code==='work_grant_due_acknowledgement_required');
});

test('model received and source unknown keep separate cumulative budgets after snapshot restoration',async()=>{
 const f=await fixture({limits:{due:1,model:1,source:1}});await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();
 const m=model(f);await f.service.reserve(f.identity,m,{execution:f.execution()});await checkpointReceived(f,m);await f.service.settle(f.identity,received(m),{execution:f.execution()});
 await assert.rejects(f.service.reserve(f.identity,model(f,'extra-model'),{execution:f.execution()}),e=>e.code==='work_grant_budget_exhausted');
 const request=await f.repository.transaction(async tx=>{const task=await tx.get(f.identity.owner,'tasks',f.ids.task_id),run=await tx.get(f.identity.owner,'catpaw-runs',f.ids.run_id),source=run.frozen_request.public_sources.sources[0],plan=task.state.plan_binding,id=sourceReadIdentity(run.id,plan,source.source_id),request_hash=hash({run_id:run.id,task_id:task.id,run_request_hash:run.request_hash,source,plan_reference:plan,policy_hash:run.frozen_request.public_sources.policy_hash});await tx.put(f.identity.owner,'catpaw-task-source-reads',{id,run_id:run.id,task_id:task.id,conversation_id:run.frozen_request.conversation_id,source_id:source.source_id,requested_url:source.requested_url,plan_reference:plan,policy_hash:run.frozen_request.public_sources.policy_hash,request_hash,state:'dispatched',dispatch_lease_id:f.execution().lease_id,dispatched_at:new Date(f.now()).toISOString()});return {...model(f,'source'),operation_id:id,kind:'source',request_hash};});
 await f.service.reserve(f.identity,request,{execution:f.execution()});await f.service.settle(f.identity,{operation_id:request.operation_id,request_hash:request.request_hash,outcome:'unknown',receipt_reference:null},{execution:f.execution()});
 const restored=new TaskWorkGrantService({repository:new TestRepository(f.repository.snapshot()),authorize:async()=>({authorized:true}),now:f.now});
 for(const kind of ['model','source'])await assert.rejects(restored.reserve(f.identity,{...model(f,'later-'+kind),kind},{execution:f.execution()}),e=>e.code==='work_grant_original_outcome_unknown');
 assert.deepEqual((await restored.read(f.identity,{principal:f.principal})).grant.remaining,{due:0,model:0,source:0});
});

test('absolute expiry and the original result deadline never renew on replay',async()=>{
 const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});const d=due(f);await f.service.reserve(f.identity,d);await f.claim();const request=model(f);await f.service.reserve(f.identity,request,{execution:f.execution()});
 await checkpointReceived(f,request);f.advance(30000);const before=f.repository.snapshot();await assert.rejects(f.service.settle(f.identity,received(request),{execution:f.execution()}),e=>e.code==='work_grant_result_deadline');assert.deepEqual(f.repository.snapshot(),before);
 assert.equal((await f.service.reserve(f.identity,request)).may_dispatch,false);f.advance(30000);
 const read=await f.service.read(f.identity,{principal:f.principal});assert.equal(read.grant.expired,true);assert.equal(read.reservations.find(r=>r.id===request.operation_id).state,'reserved');assert.deepEqual(read.grant.consumed,{due:1,model:1,source:0});
 await assert.rejects(f.service.reserve(f.identity,model(f,'after-expiry'),{execution:f.execution()}),e=>['work_grant_expired','work_grant_execution_conflict'].includes(e.code));
});

test('receipts, immutable terms and cumulative counters cannot be replaced by a matching independent self-hash',async()=>{
 for(const corrupt of ['receipt','terms','counter','reservation']){const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();const request=model(f);await f.service.reserve(f.identity,request,{execution:f.execution()});
  await checkpointReceived(f,request);await f.repository.transaction(async tx=>{
   if(corrupt==='receipt'){const row=await tx.get(f.identity.owner,TASK_WORK_GRANT_KINDS.terms,f.identity.grant_id),receipt={...row.receipt,run_binding:{...row.receipt.run_binding,run_id:randomUUID()}};receipt.receipt_hash=workGrantReceiptHash(receipt);await tx.put(f.identity.owner,TASK_WORK_GRANT_KINDS.terms,{...row,receipt});}
   if(corrupt==='terms'){const row=await tx.get(f.identity.owner,TASK_WORK_GRANT_KINDS.terms,f.identity.grant_id),terms={...row.terms,limits:{...row.terms.limits,model:3}};await tx.put(f.identity.owner,TASK_WORK_GRANT_KINDS.terms,{...row,terms,terms_hash:hash(terms)});}
   if(corrupt==='counter'){const row=await tx.get(f.identity.owner,TASK_WORK_GRANT_KINDS.grants,f.identity.grant_id);await tx.put(f.identity.owner,TASK_WORK_GRANT_KINDS.grants,{...row,consumed:{...row.consumed,model:0}});}
   if(corrupt==='reservation'){const row=await tx.get(f.identity.owner,TASK_WORK_GRANT_KINDS.reservations,request.operation_id),frozen={...row.frozen,run_binding:{...row.frozen.run_binding,run_id:randomUUID()}};await tx.put(f.identity.owner,TASK_WORK_GRANT_KINDS.reservations,{...row,frozen,reservation_hash:hash(frozen)});}
  });
  await assert.rejects(f.service.read(f.identity,{principal:f.principal}),e=>e.status===409);await assert.rejects(f.service.reserve(f.identity,model(f,'new'),{execution:f.execution()}),e=>e.status===409);
 }
});

test('grant, task control, generation and lease withdrawal fence both new requests and late results',async()=>{
 for(const reason of ['paused','revoked','control','generation','lease']){const f=await fixture();await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();const request=model(f);await f.service.reserve(f.identity,request,{execution:f.execution()});
  await checkpointReceived(f,request);await f.repository.transaction(async tx=>{
   if(['paused','revoked'].includes(reason)){const grant=await tx.get(f.identity.owner,TASK_WORK_GRANT_KINDS.grants,f.identity.grant_id);await tx.put(f.identity.owner,TASK_WORK_GRANT_KINDS.grants,{...grant,state:reason,revision:grant.revision+1});}
   if(reason==='control'||reason==='lease'){const task=await tx.get(f.identity.owner,'tasks',f.ids.task_id);await tx.put(f.identity.owner,'tasks',reason==='control'?{...task,state:{...task.state,task_control:{revision:1}}}:{...task,leaseId:randomUUID()});}
   if(reason==='generation')await tx.withScope(f.identity.scope_id,async scoped=>{const row=await scoped.scope();await scoped.saveScope({...row,generation:row.generation+1});});
  });const before=f.repository.snapshot();await assert.rejects(f.service.settle(f.identity,received(request),{execution:f.execution()}),e=>e.code===(reason==='generation'?'work_grant_generation_conflict':['control','lease'].includes(reason)?'work_grant_execution_conflict':'work_grant_not_active'));assert.deepEqual(f.repository.snapshot(),before);
  const original=(await f.service.read(f.identity,{principal:f.principal})).reservations.find(r=>r.id===request.operation_id);assert.equal(original.state,'reserved');assert.equal(original.frozen.input.request_hash,request.request_hash);assert.equal((await f.service.reserve(f.identity,request)).may_dispatch,false);
 }
});

test('the final awaited mutation rolls back admission, reservation, outcome and result on cancel, timeout or authority withdrawal',async()=>{
 for(const phase of ['admission','reservation','outcome','continuation'])for(const boundary of ['cancel','deadline','authority']){
  const f=await fixture(),controller=new AbortController();let request;
  if(phase!=='admission'){await f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms});await f.service.reserve(f.identity,due(f));await f.claim();request=model(f);if(phase!=='reservation'){await f.service.reserve(f.identity,request,{execution:f.execution()});await checkpointReceived(f,request);}if(phase==='continuation')await f.service.settle(f.identity,received(request),{execution:f.execution()});}
  const before=f.repository.snapshot(),transaction=f.repository.transaction.bind(f.repository),kind=phase==='admission'||phase==='reservation'?TASK_WORK_GRANT_KINDS.grants:phase==='outcome'?TASK_WORK_GRANT_KINDS.reservations:'fictional-work-results';let injected=false;
  f.repository.transaction=fn=>transaction(async tx=>{const put=tx.put.bind(tx);tx.put=async(owner,table,row)=>{const result=await put(owner,table,row);if(!injected&&table===kind){injected=true;if(boundary==='cancel')controller.abort();if(boundary==='deadline')f.advance(TASK_WORK_GRANT_LIMITS.write_budget_ms);if(boundary==='authority')f.deny();}return result;};return fn(tx);});
  const options={signal:controller.signal,execution:f.execution(),currentSliceDeadline:f.now()+5000};let action;
  if(phase==='admission')action=()=>f.service.admit({identity:f.identity,principal:f.principal,terms:f.terms},options);
  if(phase==='reservation')action=()=>f.service.reserve(f.identity,request,options);
  if(phase==='outcome')action=()=>f.service.settle(f.identity,received(request),options);
  if(phase==='continuation')action=()=>f.repository.transaction(tx=>f.service.commitReceivedContinuationInTransaction(tx,f.identity,request.operation_id,record=>record.put(f.identity.owner,'fictional-work-results',{id:request.operation_id,text:'Must roll back'}),options));
  await assert.rejects(action(),e=>e.code===(boundary==='cancel'?'work_grant_cancelled':boundary==='deadline'?'work_grant_write_deadline':'fictional_authority_revoked'));assert.equal(injected,true,phase+':'+boundary);assert.deepEqual(f.repository.snapshot(),before,phase+':'+boundary);
 }
});
