import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {hash,clone,ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {TaskWorkGrantService} from '../supabase/functions/_shared/core/src/task-work-grant-service.mjs';
import {TASK_WORK_GRANT_CONTRACT,TASK_WORK_GRANT_KINDS,workGrantReference} from '../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {membershipOwner,assertSourceAuthority,assertAcceptedWorkSourceAuthority} from '../supabase/functions/_shared/authority.mjs';

// Actual immutable grant service, scoped repository and authority SQL boundary,
// with synthetic SQL responses. No hosted Auth, database, provider or HTTP request.
async function fixture(){
 let clock=Date.now();const repository=new TestRepository(),subject=randomUUID();
 const scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()};
 scope.owner='catpaw:'+hash({profile:scope.profile_id,workspace:scope.workspace_id});
 await repository.bootstrapScope(scope);
 const source={subject_id:subject,scope_id:scope.scope_id,session_id:randomUUID(),issuer:'https://fixture.example.invalid/auth/v1',issued_at:Math.floor(clock/1000)-1,consent_revision:1};
 const origin={operation_id:randomUUID(),run_id:randomUUID(),delegation_id:randomUUID(),task_id:hash(randomUUID())};
 const cid=randomUUID(),args={title:'Synthetic accepted work'},model={provider:'injected-offline',model:'no-network'};
 const terms={schema_version:1,contract:TASK_WORK_GRANT_CONTRACT,mode:'accepted_run',grant_id:randomUUID(),scope,subject_id:subject,conversation_id:cid,source_auth:source,origin,input_hash:hash('explicit finite synthetic intent'),args_hash:hash(args),model_configuration_hash:hash(model),route_hash:hash('existing-policy-fixture'),source_catalog_hash:null,memory_generation:1,accepted_at:new Date(clock).toISOString(),not_after:new Date(clock+60000).toISOString(),execution_budget_ms:60000,limits:{due:1,model:1,source:0},allowed_tools:['save_artifact','finish_task','ask_user']};
 const reference=workGrantReference(terms),frozen={scope,subject_id:subject,conversation_id:cid,conversation_epoch:1,source_auth:source,run_binding:origin,current_input_hash:terms.input_hash,args,model_configuration:model,memory_generation:1,work_grant_reference:reference};
 const requestHash=hash(frozen),tag={...Object.fromEntries(['operation_id','run_id','delegation_id'].map(k=>[k,origin[k]])),request_hash:requestHash,grant_epoch:1,delegation_revision:1};
 const owner=membershipOwner(source.issuer),queries=[];
 let afterMembership=null;
 const sql=tx=>{tx.connection={query:async(sqlText,parameters=[])=>{
  queries.push({sql:sqlText,parameters:clone(parameters)});
  if(sqlText.includes('pg_advisory_xact_lock'))return {rows:[]};
  const kind=sqlText.includes("kind='app-sessions'")?'app-sessions':'scope-memberships';
  assert.ok(sqlText.startsWith('SELECT data FROM public.records'));const row=await tx.get(parameters[0],kind,parameters[1]);
  if(kind==='scope-memberships'&&afterMembership)await afterMembership(tx);
  return {rows:row?[{data:row}]:[]};
 }};return tx;};
 await repository.transaction(async tx=>{
  await tx.put(owner,'app-sessions',{id:source.session_id,subject_id:subject,issuer:source.issuer,state:'active',issued_at:source.issued_at,expires_at:Math.floor(clock/1000)+3600});
  await tx.put(owner,'scope-memberships',{id:subject,subject_id:subject,issuer:source.issuer,state:'active',tokens_valid_after:0,revoked_session_ids:[],scopes:[{...scope,local_output:true}]});
  await tx.put(scope.owner,'native-chat-conversations',{id:cid,subject_id:subject,scope_id:scope.scope_id,state:'active',grant_epoch:1});
  await tx.put(scope.owner,'catpaw-delegations',{id:origin.delegation_id,subject_id:subject,conversation_id:cid,state:'active',revision:1,grant_epoch:1,created_at:terms.accepted_at});
  await tx.put(scope.owner,'catpaw-operations',{id:origin.operation_id,run_id:origin.run_id,request_hash:requestHash});
  await tx.put(scope.owner,'catpaw-runs',{id:origin.run_id,...tag,task_id:origin.task_id,frozen_request:frozen,created_at:terms.accepted_at});
  await tx.put(scope.owner,'tasks',{id:origin.task_id,status:'queued',attempts:0,leaseId:null,leaseUntil:null,state:{catpaw:tag},createdAt:terms.accepted_at});
 });
 const service=new TaskWorkGrantService({repository,now:()=>clock,authorize:async(tx)=>{await assertSourceAuthority(sql(tx),source,scope);return {authorized:true};}});
 await service.admit({identity:{owner:scope.owner,scope_id:scope.scope_id,subject_id:subject,grant_id:terms.grant_id},principal:source,terms});
 const update=async(kind,id,mutate)=>repository.transaction(async tx=>{const value=await tx.get(owner,kind,id);await tx.put(owner,kind,mutate(value));});
 const accepted=(ref=reference)=>repository.transaction(tx=>assertAcceptedWorkSourceAuthority(sql(tx),source,scope,ref,{now:()=>clock}));
 return{repository,scope,source,terms,reference,origin,owner,queries,sql,update,accepted,advance:ms=>{clock+=ms;},afterMembership:fn=>{afterMembership=fn;}};
}

test('only a persisted finite original grant may outlive originating JWT expiry; commands remain strict and no session is renewed',async()=>{
 const f=await fixture();await f.update('app-sessions',f.source.session_id,s=>({...s,expires_at:1}));const before=f.repository.snapshot();
 await assert.rejects(f.repository.transaction(tx=>assertSourceAuthority(f.sql(tx),f.source,f.scope)),e=>e.code==='grant_conflict');
 await f.accepted();assert.deepEqual(f.repository.snapshot(),before);
 assert.ok(f.queries.every(q=>q.sql.startsWith('SELECT')));assert.ok(f.queries.some(q=>q.parameters[0]===f.owner));
});
test('missing or forged grant, transplanted source and altered immutable run never obtain the expiry exception',async()=>{
 const f=await fixture();await f.update('app-sessions',f.source.session_id,s=>({...s,expires_at:1}));
 for(const ref of [null,{...f.reference,grant_id:randomUUID()},{...f.reference,terms_hash:'0'.repeat(64)},{...f.reference,allow_expired:true}])await assert.rejects(f.accepted(ref),e=>e instanceof ApiError);
 await f.repository.transaction(async tx=>{const run=await tx.get(f.scope.owner,'catpaw-runs',f.origin.run_id);await tx.put(f.scope.owner,'catpaw-runs',{...run,frozen_request:{...run.frozen_request,source_auth:{...run.frozen_request.source_auth,session_id:randomUUID()}}});});
 await assert.rejects(f.accepted(),e=>e.code==='accepted_work_grant_conflict');
});
test('logout, membership withdrawal, issued-at fences and scope withdrawal still stop accepted work',async()=>{
 for(const change of [
  f=>f.update('app-sessions',f.source.session_id,s=>({...s,state:'revoked'})),
  f=>f.update('scope-memberships',f.source.subject_id,s=>({...s,state:'revoked'})),
  f=>f.update('scope-memberships',f.source.subject_id,s=>({...s,tokens_valid_after:f.source.issued_at+1})),
  f=>f.update('scope-memberships',f.source.subject_id,s=>({...s,revoked_session_ids:[f.source.session_id]})),
  f=>f.update('scope-memberships',f.source.subject_id,s=>({...s,scopes:[]}))
 ]){const f=await fixture();await change(f);await assert.rejects(f.accepted(),e=>e.code==='grant_conflict');}
});
test('grant expiry, pause, epoch retirement, generation changes and corrupt admission receipts fail closed',async()=>{
 for(const change of [
  f=>{f.advance(60000);},
  f=>f.repository.transaction(async tx=>{const s=await tx.get(f.scope.owner,TASK_WORK_GRANT_KINDS.grants,f.terms.grant_id);await tx.put(f.scope.owner,TASK_WORK_GRANT_KINDS.grants,{...s,state:'paused'});}),
  f=>f.repository.transaction(async tx=>{const d=await tx.get(f.scope.owner,'catpaw-delegations',f.origin.delegation_id);await tx.put(f.scope.owner,'catpaw-delegations',{...d,grant_epoch:2});}),
  f=>f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,async scoped=>{const row=await scoped.scope();await scoped.saveScope({...row,generation:2});})),
  f=>f.repository.transaction(async tx=>{const r=await tx.get(f.scope.owner,TASK_WORK_GRANT_KINDS.terms,f.terms.grant_id);await tx.put(f.scope.owner,TASK_WORK_GRANT_KINDS.terms,{...r,receipt:{...r.receipt,receipt_hash:'0'.repeat(64)}});})
 ]){const f=await fixture();await change(f);await assert.rejects(f.accepted(),e=>e.code==='accepted_work_grant_conflict');}
});
test('legitimate terminal facts may be read without minting execution authority or requiring a running lease',async()=>{
 const f=await fixture();await f.update('app-sessions',f.source.session_id,s=>({...s,expires_at:1}));
 await f.repository.transaction(async tx=>{const t=await tx.get(f.scope.owner,'tasks',f.origin.task_id);await tx.put(f.scope.owner,'tasks',{...t,status:'succeeded',leaseId:null,leaseUntil:null});});
 const before=f.repository.snapshot();await f.accepted();assert.deepEqual(f.repository.snapshot(),before);
});
test('post-await grant retirement and server deadline crossing cannot reuse an earlier valid source observation',async()=>{
 for(const mutate of [async(f,tx)=>{const s=await tx.get(f.scope.owner,TASK_WORK_GRANT_KINDS.grants,f.terms.grant_id);await tx.put(f.scope.owner,TASK_WORK_GRANT_KINDS.grants,{...s,state:'revoked'});},async f=>{f.advance(60000);}]){
  const f=await fixture();f.afterMembership(tx=>mutate(f,tx));await assert.rejects(f.accepted(),e=>e.code==='accepted_work_grant_conflict');
 }
});
test('one server clock observation must satisfy both grant bounds; a clock rollback cannot extend authority',async()=>{
 const f=await fixture(),acceptedAt=Date.parse(f.terms.accepted_at),deadline=Date.parse(f.terms.not_after);
 let calls=0;
 await assert.rejects(f.repository.transaction(tx=>assertAcceptedWorkSourceAuthority(f.sql(tx),f.source,f.scope,f.reference,{now:()=>{calls++;return calls<3?acceptedAt:calls===3?deadline+1:acceptedAt-1;}})),e=>e.code==='accepted_work_grant_conflict');
 calls=0;
 await assert.rejects(f.repository.transaction(tx=>assertAcceptedWorkSourceAuthority(f.sql(tx),f.source,f.scope,f.reference,{now:()=>{calls++;return calls===1?acceptedAt+200:acceptedAt+100;}})),e=>e.code==='accepted_work_grant_conflict');
});
