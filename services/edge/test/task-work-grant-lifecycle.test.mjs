import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {hash,clone} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {TaskWorkGrantService} from '../supabase/functions/_shared/core/src/task-work-grant-service.mjs';
import {TASK_WORK_GRANT_CONTRACT,TASK_WORK_GRANT_KINDS as K,workGrantReference} from '../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {controlTask,readTaskControl} from '../supabase/functions/_shared/core/src/task-control-service.mjs';
import {membershipOwner,revokeAppSession,assertAcceptedWorkSourceAuthority,assertAcceptedWorkControlSourceAuthority,assertSourceAuthority} from '../supabase/functions/_shared/authority.mjs';
import {buildSourcePurgePlan} from '../supabase/functions/_shared/core/src/purge-plan.mjs';
import {eraseChatSource} from '../supabase/functions/_shared/core/src/source-erasure.mjs';
import {LOCAL_POLICY} from '../supabase/functions/_shared/core/src/local-output-facade.mjs';
import {revokeTaskWorkGrantsForSourceInTransaction,transitionTaskWorkGrantInTransaction} from '../supabase/functions/_shared/core/src/task-work-grant-lifecycle.mjs';
import {BoundedStore} from '../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-store.mjs';

// Actual maintained grant/control/logout/erasure entry points; auth/SQL responses
// are explicit synthetic ports. No cloud, model, provider, PostgreSQL or OS call.
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
async function fixture({lifetime=60000}={}){
 let clock=Date.now();const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()};scope.owner='catpaw:'+hash({profile:scope.profile_id,workspace:scope.workspace_id});await repository.bootstrapScope(scope);
 const subject=randomUUID(),cid=randomUUID(),session=randomUUID(),issuer='https://fixture.example.invalid/auth/v1',source={subject_id:subject,scope_id:scope.scope_id,session_id:session,issuer,issued_at:Math.floor(clock/1000)-1,consent_revision:1};
 const principal={subject_id:subject,session_id:session,issuer,scopes:[scope]},origin={operation_id:randomUUID(),run_id:randomUUID(),delegation_id:randomUUID(),task_id:hash(randomUUID())},args={title:'Synthetic bounded work'},model={provider:'offline-only',model:'no-network'};
 const terms={schema_version:1,contract:TASK_WORK_GRANT_CONTRACT,mode:'accepted_run',grant_id:randomUUID(),scope,subject_id:subject,conversation_id:cid,source_auth:source,origin,input_hash:hash('finite fictional original request'),args_hash:hash(args),model_configuration_hash:hash(model),route_hash:hash('offline fixed route'),source_catalog_hash:null,memory_generation:1,accepted_at:new Date(clock).toISOString(),not_after:new Date(clock+lifetime).toISOString(),execution_budget_ms:60000,limits:{due:1,model:1,source:0},allowed_tools:['save_artifact','finish_task','ask_user']};
 const reference=workGrantReference(terms),plan={revision:1,plan_hash:hash('same original plan')},sourceID=randomUUID(),frozen={scope,subject_id:subject,conversation_id:cid,conversation_epoch:1,turn_id:randomUUID(),source_auth:source,run_binding:origin,current_input_hash:terms.input_hash,args,model_configuration:model,memory_generation:1,policy:LOCAL_POLICY,work_grant_reference:reference};
 const tag={operation_id:origin.operation_id,run_id:origin.run_id,delegation_id:origin.delegation_id,request_hash:hash(frozen),grant_epoch:1,delegation_revision:1},run={id:origin.run_id,...tag,task_id:origin.task_id,frozen_request:frozen,created_at:terms.accepted_at};
 const owner=membershipOwner(issuer),sql=tx=>{tx.connection={query:async(sql,args=[])=>{if(sql.includes('pg_advisory_xact_lock'))return {rows:[]};const kind=sql.includes("kind='app-sessions'")?'app-sessions':'scope-memberships';const row=await tx.get(args[0],kind,args[1]);return {rows:row?[{data:row}]:[]};}};return tx;};
 await repository.transaction(async tx=>{
  await tx.put(owner,'scope-memberships',{id:subject,issuer,subject_id:subject,state:'active',tokens_valid_after:0,revoked_session_ids:[],scopes:[{...scope,local_output:true}]});
  await tx.put(owner,'app-sessions',{id:session,issuer,subject_id:subject,state:'active',expires_at:Math.floor(clock/1000)+3600});
  await tx.put(scope.owner,'native-chat-conversations',{id:cid,subject_id:subject,scope_id:scope.scope_id,state:'active',revision:1,grant_epoch:1,messages:[{id:sourceID,role:'user',text:'fictional source'}],model_messages:[]});
  await tx.put(scope.owner,'catpaw-delegations',{id:origin.delegation_id,subject_id:subject,conversation_id:cid,state:'active',revision:1,grant_epoch:1,created_at:terms.accepted_at});
  await tx.put(scope.owner,'catpaw-runs',run);await tx.put(scope.owner,'catpaw-operations',{id:origin.operation_id,run_id:run.id,request_hash:run.request_hash});
  await tx.put(scope.owner,'tasks',{id:origin.task_id,status:'queued',attempts:0,leaseId:null,leaseUntil:null,state:{catpaw:tag,plan_binding:plan},createdAt:terms.accepted_at});
  await tx.put(scope.owner,'catpaw-task-plan-heads',{id:run.id,run_id:run.id,task_id:run.task_id,scope_id:scope.scope_id,subject_id:subject,conversation_id:cid,accepted_revision:1,applied_revision:1,applied_plan_hash:plan.plan_hash});
  await tx.withScope(scope.scope_id,s=>s.put('sources',{id:sourceID,scope_id:scope.scope_id,conversation_id:cid,turn_id:frozen.turn_id,content_hash:hash('fictional source'),text:'fictional source'}));
 });
 const identity={owner:scope.owner,scope_id:scope.scope_id,subject_id:subject,grant_id:terms.grant_id},service=new TaskWorkGrantService({repository,now:()=>clock,authorize:async()=>({authorized:true})});await service.admit({identity,principal:source,terms});
 const facade={repository,taskControlNow:()=>clock,owner:()=>scope.owner,scoped:async()=>({owner:scope.owner,scope,principal}),ownedRun:async(tx,o,id)=>{const r=await tx.get(o,'catpaw-runs',id);assert.equal(r.frozen_request.subject_id,subject);return r;},ownedDelegation:async(tx,o,id,_p,{lock})=>{if(lock)await tx.lock(o,'catpaw-delegations',id);return tx.get(o,'catpaw-delegations',id);},beforeTaskControlRead:async()=>({source_current:true}),beforeTaskControlWrite:async()=>({source_current:true}),abortTask(){},onTaskControlAccepted:async()=>{}};
 const control=()=>readTaskControl(facade,'named-offline',scope.scope_id,run.id),change=async action=>{const s=(await control()).control;return controlTask(facade,'named-offline',scope.scope_id,run.id,{operation_id:randomUUID(),action,expected_execution_revision:s.execution_revision,expected_snapshot_hash:s.snapshot_hash,expected_grant_epoch:s.grant_epoch,expected_plan_revision:s.plan_reference.revision,expected_plan_hash:s.plan_reference.plan_hash});};
 const row=kind=>repository.transaction(tx=>tx.get(scope.owner,kind,terms.grant_id)),erase=()=>repository.transaction(tx=>eraseChatSource({records:tx,principal,scope_id:scope.scope_id,source:{id:sourceID,conversation_id:cid,turn_id:frozen.turn_id}}));
 return {repository,scope,subject,cid,session,issuer,source,sourceID,terms,reference,origin,run,identity,service,facade,control,change,row,sql,erase,principal,clock:()=>clock,advance:ms=>{clock+=ms;},dropRun:()=>{for(const kind of ['catpaw-runs','catpaw-task-plan-heads'])repository.records.delete(JSON.stringify([scope.owner,kind,run.id]));}};
}

test('actual task pause/resume transitions the same finite grant without extending terms or refunding consumed due',async()=>{
 const f=await fixture();await f.service.reserve(f.identity,{operation_id:f.run.operation_id,operation_key:hash({accepted_run:f.run.id}),kind:'due',request_hash:f.run.request_hash,deadline_at:f.terms.not_after});
 const terms=await f.row(K.terms),before=await f.row(K.grants);await f.change('pause');const paused=await f.row(K.grants);assert.equal(paused.state,'paused');assert.equal(paused.revision,before.revision+1);assert.deepEqual(paused.consumed,before.consumed);
 await assert.rejects(f.repository.transaction(tx=>assertAcceptedWorkSourceAuthority(f.sql(tx),f.source,f.scope,f.reference,{now:f.clock})),e=>e.code==='accepted_work_grant_conflict');
 await f.change('resume');const resumed=await f.row(K.grants);assert.equal(resumed.state,'active');assert.deepEqual(resumed.consumed,before.consumed);assert.deepEqual(await f.row(K.terms),terms);assert.equal((await f.repository.transaction(tx=>tx.list(f.scope.owner,K.grants))).length,1);
});
test('actual control revoke and App logout retire grants in the same committed maintenance transaction',async()=>{
 for(const action of ['revoke','logout']){const f=await fixture(),terms=await f.row(K.terms);if(action==='revoke')await f.change('revoke');else await revokeAppSession(f.repository,{iss:f.issuer,sub:f.subject,session_id:f.session,exp:9999999999},{chat:{event(){throw Error('no active turn');}},facade:f.facade});assert.equal((await f.row(K.grants)).state,'revoked');assert.deepEqual(await f.row(K.terms),terms);await assert.rejects(f.repository.transaction(tx=>assertAcceptedWorkSourceAuthority(f.sql(tx),f.source,f.scope,f.reference,{now:f.clock})));}
});
test('expired paused finite work cannot resume or allocate a fresh grant/control receipt',async()=>{
 const f=await fixture();await f.change('pause');f.advance(60000);const before=f.repository.snapshot();await assert.rejects(f.change('resume'));assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.row(K.grants)).state,'paused');
});
test('purge plan fixes every finite grant identity and hash including retained unknown reservations',async()=>{
 const f=await fixture();await f.service.reserve(f.identity,{operation_id:f.run.operation_id,operation_key:hash({accepted_run:f.run.id}),kind:'due',request_hash:f.run.request_hash,deadline_at:f.terms.not_after});
 const plan=await buildSourcePurgePlan({repository:f.repository,facade:f.facade,principal:f.principal,scope_id:f.scope.scope_id,source_id:f.sourceID});
 for(const kind of Object.values(K)){const rows=await f.repository.transaction(tx=>tx.list(f.scope.owner,kind));for(const row of rows)assert.ok(plan.owner_records.some(t=>t.kind===kind&&t.id===row.id&&t.expected_record_hash===hash(row)));}
 assert.equal(plan.execute_supported,false);assert.ok(plan.blocked.includes('revoke_and_fence_work_grants_before_purge'));assert.ok(plan.blocked.includes('settle_original_work_attempt_before_purge'));
});
test('orphan finite grant prevents primary source erasure after its run and plan head are lost',async()=>{
 const f=await fixture();f.dropRun();const before=f.repository.snapshot();await assert.rejects(f.erase(),e=>e.code==='source_eraser_requires_execution_purge');assert.deepEqual(f.repository.snapshot(),before);
 const plan=await buildSourcePurgePlan({repository:f.repository,facade:f.facade,principal:f.principal,scope_id:f.scope.scope_id,source_id:f.sourceID});assert.ok(plan.owner_records.some(t=>t.kind===K.terms&&t.id===f.terms.grant_id));assert.ok(plan.blocked.includes('reconcile_malformed_orphan_work_grant_before_purge'));assert.equal(plan.execute_supported,false);
});
test('paused control source facts survive original JWT expiry while execution, expiry and revoked facts remain strict',async()=>{
 const f=await fixture();await f.change('pause');await f.repository.transaction(async tx=>{const o=membershipOwner(f.issuer),s=await tx.get(o,'app-sessions',f.session);await tx.put(o,'app-sessions',{...s,expires_at:1});});const before=f.repository.snapshot();
 await f.repository.transaction(tx=>assertAcceptedWorkControlSourceAuthority(f.sql(tx),f.source,f.scope,f.reference,{now:f.clock}));assert.deepEqual(f.repository.snapshot(),before);
 await assert.rejects(f.repository.transaction(tx=>assertSourceAuthority(f.sql(tx),f.source,f.scope)),e=>e.code==='grant_conflict');await assert.rejects(f.repository.transaction(tx=>assertAcceptedWorkSourceAuthority(f.sql(tx),f.source,f.scope,f.reference,{now:f.clock})),e=>e.code==='accepted_work_grant_conflict');
 f.advance(60000);await assert.rejects(f.repository.transaction(tx=>assertAcceptedWorkControlSourceAuthority(f.sql(tx),f.source,f.scope,f.reference,{now:f.clock})),e=>e.code==='accepted_work_grant_conflict');
 const g=await fixture();await g.change('revoke');await assert.rejects(g.repository.transaction(tx=>assertAcceptedWorkControlSourceAuthority(g.sql(tx),g.source,g.scope,g.reference,{now:g.clock})),e=>e.code==='accepted_work_grant_conflict');
});
test('replaying an original pause after resume cannot pause the finite grant again or allocate a revision',async()=>{
 const f=await fixture(),p=await f.change('pause');await f.change('resume');const original=await f.repository.transaction(tx=>tx.get(f.scope.owner,'catpaw-task-control-operations',p.operation.operation_id)),before=f.repository.snapshot();
 const replay=await controlTask(f.facade,'named-offline',f.scope.scope_id,f.run.id,original.frozen.input);assert.deepEqual(replay.operation,p.operation);assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.row(K.grants)).state,'active');
});
test('last control authority await crossing the write budget rolls back both task and finite grant state',async()=>{
 const f=await fixture(),before=f.repository.snapshot();f.facade.beforeTaskControlWrite=async(_tx,ctx)=>{if(ctx.task.status==='paused')f.advance(15000);return {source_current:true};};await assert.rejects(f.change('pause'),e=>e.code==='control_deadline');assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.row(K.grants)).state,'active');
});
test('original unknown model ledger blocks resume and purge without refunding its cumulative call',async()=>{
 const f=await fixture();await f.service.reserve(f.identity,{operation_id:f.run.operation_id,operation_key:hash({accepted_run:f.run.id}),kind:'due',request_hash:f.run.request_hash,deadline_at:f.terms.not_after});
 const lease=randomUUID(),request={operation_id:randomUUID(),operation_key:hash('one original model call'),kind:'model',request_hash:hash('original synthetic model request'),deadline_at:new Date(f.clock()+30000).toISOString()},execution={run_id:f.run.id,task_id:f.run.task_id,run_request_hash:f.run.request_hash,lease_id:lease,execution_revision:0};
 await f.repository.transaction(async tx=>{const task=await tx.get(f.scope.owner,'tasks',f.run.task_id);await tx.put(f.scope.owner,'tasks',{...task,status:'running',leaseId:lease,leaseUntil:f.terms.not_after,state:{...task.state,local_model:{round:{state:'dispatched',request_hash:request.request_hash}}}});await tx.put(f.scope.owner,'runs',{id:lease,taskId:task.id,status:'running',execution:{acknowledged:false,authority_hash:hash(task.state.catpaw),revision:0}});await tx.put(f.scope.owner,'catpaw-run-links',{id:lease,run_id:f.run.id,task_id:task.id,operation_id:f.run.operation_id,grant_epoch:1});});
 await f.service.reserve(f.identity,request,{execution});await f.service.settle(f.identity,{operation_id:request.operation_id,request_hash:request.request_hash,outcome:'unknown',receipt_reference:null},{execution});await f.change('pause');
 const current=(await f.control()).control;assert.equal(current.can_resume,false);assert.ok(current.unresolved_operations.some(r=>r.operation_id===request.operation_id&&!r.can_retry));const before=f.repository.snapshot();await assert.rejects(f.change('resume'),e=>e.code==='control_original_outcome_unknown');assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.row(K.grants)).consumed.model,1);
 const plan=await buildSourcePurgePlan({repository:f.repository,facade:f.facade,principal:f.principal,scope_id:f.scope.scope_id,source_id:f.sourceID});assert.ok(plan.blocked.includes('reconcile_original_work_grant_operation_before_purge'));
});
test('exact conversation withdrawal isolates other conversations and malformed foreign subject state',async()=>{
 const f=await fixture(),otherID=randomUUID(),otherCID=randomUUID(),otherSubject=randomUUID();
 await f.repository.transaction(async tx=>{const state=await tx.get(f.scope.owner,K.grants,f.terms.grant_id);await tx.put(f.scope.owner,K.grants,{...state,id:otherID,conversation_id:otherCID,run_id:randomUUID(),task_id:hash('other task')});await tx.put(f.scope.owner,K.grants,{...state,id:randomUUID(),subject_id:otherSubject,conversation_id:f.cid});});
 await f.repository.transaction(tx=>revokeTaskWorkGrantsForSourceInTransaction(tx,{owner:f.scope.owner,scope_id:f.scope.scope_id,subject_id:f.subject,conversation_id:f.cid}));assert.equal((await f.row(K.grants)).state,'revoked');assert.equal((await f.repository.transaction(tx=>tx.get(f.scope.owner,K.grants,otherID))).state,'active');
});
test('maintained control locks scope then source subject then grant before delegation and task',async()=>{
 const f=await fixture(),events=[],transaction=f.repository.transaction.bind(f.repository);f.repository.transaction=fn=>transaction(async tx=>{const scope=tx.withScope.bind(tx),lock=tx.lock.bind(tx);tx.withScope=async(...args)=>{events.push('scope');return scope(...args);};tx.lock=async(...args)=>{events.push(args[1]==='source-subject'?'source':args[1]===K.grants?'grant':args[1]==='catpaw-delegations'?'delegation':args[1]==='tasks'?'task':'other');return lock(...args);};return fn(tx);});
 await f.control();for(const [a,b] of [['scope','source'],['source','grant'],['grant','delegation'],['delegation','task']])assert.ok(events.indexOf(a)<events.indexOf(b),events.join(','));
});
test('a malformed unrelated record key cannot roll back App logout or revoke another subject',async()=>{
 const f=await fixture();await f.repository.transaction(async tx=>{const terms=await tx.get(f.scope.owner,K.terms,f.terms.grant_id),state=await tx.get(f.scope.owner,K.grants,f.terms.grant_id);await tx.put(f.scope.owner,K.terms,{...terms,id:'synthetic-invalid-grant-key'});await tx.put(f.scope.owner,K.grants,{...state,id:'synthetic-invalid-grant-key'});});
 await revokeAppSession(f.repository,{iss:f.issuer,sub:f.subject,session_id:f.session,exp:9999999999},{chat:{event(){throw Error('no active turn');}},facade:f.facade});assert.equal((await f.row(K.grants)).state,'revoked');assert.equal((await f.repository.transaction(tx=>tx.get(membershipOwner(f.issuer),'app-sessions',f.session))).state,'revoked');
});
test('malformed orphan reservations are fixed in the purge hash plan and never become physically erasable',async()=>{
 const f=await fixture();f.dropRun();const id=randomUUID();await f.repository.transaction(tx=>tx.put(f.scope.owner,K.reservations,{id,scope_id:f.scope.scope_id,subject_id:f.subject,conversation_id:f.cid,state:'received',missing_original_grant:true}));
 const plan=await buildSourcePurgePlan({repository:f.repository,facade:f.facade,principal:f.principal,scope_id:f.scope.scope_id,source_id:f.sourceID});assert.ok(plan.owner_records.some(r=>r.kind===K.reservations&&r.id===id));assert.ok(plan.blocked.includes('reconcile_malformed_orphan_work_grant_before_purge'));const before=f.repository.snapshot();await assert.rejects(f.erase(),e=>e.code==='source_eraser_requires_execution_purge');assert.deepEqual(f.repository.snapshot(),before);
});
test('the earlier original due deadline blocks actual resume even while the immutable grant deadline remains live',async()=>{
 const f=await fixture({lifetime:90000}),deadline=new Date(f.clock()+60000).toISOString();await f.service.reserve(f.identity,{operation_id:f.run.operation_id,operation_key:hash({accepted_run:f.run.id}),kind:'due',request_hash:f.run.request_hash,deadline_at:deadline});await f.change('pause');f.advance(60000);
 const current=(await f.control()).control;assert.equal(current.can_resume,false);assert.equal(current.blocked_reason,'work_grant_expired');const before=f.repository.snapshot();await assert.rejects(f.change('resume'));assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.row(K.grants)).state,'paused');assert.equal((await f.row(K.terms)).terms.not_after,f.terms.not_after);const [due]=await f.repository.transaction(tx=>tx.list(f.scope.owner,K.reservations));assert.equal(due.frozen.input.deadline_at,deadline);assert.equal(due.state,'reserved');assert.equal((await f.row(K.grants)).consumed.due,1);
});
test('the final control authority await cannot resume work after its unchanged original due deadline',async()=>{
 const f=await fixture({lifetime:90000}),deadline=new Date(f.clock()+60000).toISOString();await f.service.reserve(f.identity,{operation_id:f.run.operation_id,operation_key:hash({accepted_run:f.run.id}),kind:'due',request_hash:f.run.request_hash,deadline_at:deadline});await f.change('pause');f.advance(59000);let scheduled=0;
 f.facade.beforeTaskControlWrite=async(_tx,ctx)=>{if(ctx.task.status==='scheduled'&&++scheduled===2)f.advance(1000);return {source_current:true};};const before=f.repository.snapshot();await assert.rejects(f.change('resume'),e=>e.code==='control_commit_conflict');assert.equal(scheduled,2);assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.row(K.grants)).state,'paused');
});
test('actual acknowledged closed and unknown due facts cannot reopen the same run from a stale paused projection',async()=>{
 for(const unknown of [false,true]){
  const f=await fixture({lifetime:90000}),store=new BoundedStore({repository:f.repository,owners:[f.scope.owner],now:f.clock,invocation:{open:true,deadline:f.clock()+60000},workGrantService:f.service,admitTask:async(tx,owner,id)=>({run:await tx.get(owner,'catpaw-runs',f.run.id),task:await tx.get(owner,'tasks',id)})}),lease=randomUUID();
  assert.ok(await store.compareAndSwap(f.scope.owner,'tasks',f.run.task_id,{status:'queued'},{status:'running',leaseId:lease,leaseUntil:new Date(f.clock()+60000).toISOString()}));
  if(unknown)await store.beginModelDispatch(f.scope.owner,f.run.task_id,lease,hash('original offline unknown call'),{signal:new AbortController().signal,open:true,deadline:f.clock()+5000});
  assert.ok(await store.compareAndSwap(f.scope.owner,'tasks',f.run.task_id,{status:'running',leaseId:lease},{status:'failed',leaseId:null,leaseUntil:null}));
  const [due]=await f.repository.transaction(async tx=>(await tx.list(f.scope.owner,K.reservations)).filter(r=>r.frozen.input.kind==='due'));assert.equal(due.state,unknown?'unknown':'received');assert.equal(due.outcome.acknowledgement.task_status,unknown?'outcome_unknown':'failed');
  // Explicit stale persisted UI/control projection, after the actual maintained
  // terminal acknowledgement. It must not reopen its original accepted run.
  await f.repository.transaction(async tx=>{const task=await tx.get(f.scope.owner,'tasks',f.run.task_id),grant=await tx.get(f.scope.owner,K.grants,f.terms.grant_id);await tx.put(f.scope.owner,'tasks',{...task,status:'paused',state:{...task.state,task_control:{revision:1,operation_id:randomUUID(),reason:'user_paused',previous_status:'queued'}}});await tx.put(f.scope.owner,K.grants,{...grant,state:'paused',revision:grant.revision+1});});
  const control=(await f.control()).control;assert.equal(control.can_resume,false);assert.equal(control.blocked_reason,unknown?'original_outcome_unknown':'grant_changed');const before=f.repository.snapshot();await assert.rejects(f.change('resume'));await assert.rejects(f.repository.transaction(tx=>transitionTaskWorkGrantInTransaction(tx,f.scope.owner,f.run,{action:'resume',now:f.clock})),e=>e.code==='work_grant_lifecycle_conflict');assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.row(K.grants)).consumed.due,1);assert.equal((await f.row(K.terms)).terms.not_after,f.terms.not_after);
 }
});
