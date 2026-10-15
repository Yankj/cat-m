import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {hash,clone,ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TASK_REVISION_WORK_GRANT_KINDS as K} from '../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {membershipOwner,assertSourceAuthority,assertAcceptedWorkSourceAuthority} from '../supabase/functions/_shared/authority.mjs';
import {revisionWorkHTTPFixture} from './fixtures/revision-work-http-fixture.mjs';

// Maintained HTTP admission creates the actual durable v2 segment first. This
// SQL query adapter then returns serialized TestRepository rows, never real PG.
// Passing proves source-proof binding logic only, not hosted Auth/SQL/concurrency.
async function fixture(){
 const f=await revisionWorkHTTPFixture();
 await f.mutateSession(f.principal,{expires_at:1});f.advance(Date.parse(f.originalWork.not_after)-f.now()+1);
 const request=await f.makeRequest(),turn=await f.accept(request),envelope=turn.revision_work_receipts[0];
 const [row]=await f.rows(K.terms),terms=row.terms,source=terms.source_auth,scope=terms.scope,queries=[],memberOwner=membershipOwner(source.issuer);
 await f.repository.transaction(async tx=>{
  const old=await tx.get(memberOwner,'scope-memberships',source.subject_id);
  await tx.put(memberOwner,'scope-memberships',{...old,subject_id:source.subject_id,issuer:source.issuer,state:'active',tokens_valid_after:0,revoked_session_ids:[],scopes:[{...scope,local_output:true}]});
 });
 let afterMembership=null;
 const sql=tx=>{tx.connection={query:async(sqlText,parameters=[])=>{
  queries.push({sql:sqlText,parameters:clone(parameters)});
  assert.ok(sqlText.startsWith('SELECT'),'source proof never renews a session or writes SQL');
  if(sqlText.includes('pg_advisory_xact_lock'))return {rows:[]};
  assert.ok(sqlText.startsWith('SELECT data FROM public.records'));
  const kind=sqlText.includes("kind='app-sessions'")?'app-sessions':'scope-memberships',value=await tx.get(parameters[0],kind,parameters[1]);
  if(kind==='scope-memberships'&&afterMembership)await afterMembership(tx);
  return {rows:value?[{data:value}]:[]};
 }};return tx;};
 const accepted=(reference=envelope.grant_reference,selectedSource=source)=>f.repository.transaction(tx=>assertAcceptedWorkSourceAuthority(sql(tx),selectedSource,scope,reference,{now:f.now}));
 const mutate=async(kind,id,update,owner=scope.owner)=>f.repository.transaction(async tx=>{const old=await tx.get(owner,kind,id);await tx.put(owner,kind,update(old));});
 return {...f,request,envelope,terms,source,scope,memberOwner,queries,sql,accepted,mutate,afterMembership:hook=>{afterMembership=hook;}};
}
test('v2 proof uses the fresh finite source after the original JWT and original grant window have expired without renewing anything',async()=>{
 const f=await fixture();try{
  assert.ok(f.now()>Date.parse(f.originalWork.not_after));const before=f.repository.snapshot();await f.accepted();assert.deepEqual(f.repository.snapshot(),before);
  assert.equal(f.terms.source_auth.session_id,f.fresh.session_id);assert.notEqual(f.source.session_id,f.principal.session_id);
  assert.ok(f.queries.every(q=>q.sql.startsWith('SELECT')));assert.ok(f.queries.some(q=>q.parameters[0]===f.memberOwner&&q.parameters[1]===f.fresh.session_id));
 }finally{await f.stop();}
});
test('the accepted v2 source may outlive its own JWT only within its finite terms; fresh commands remain strict',async()=>{
 const f=await fixture();try{
  await f.mutateSession(f.fresh,{expires_at:1});const before=f.repository.snapshot();
  await assert.rejects(f.repository.transaction(tx=>assertSourceAuthority(f.sql(tx),f.source,f.scope)),e=>e.code==='grant_conflict');
  await f.accepted();assert.deepEqual(f.repository.snapshot(),before);
  f.advance(Date.parse(f.terms.not_after)-f.now());await assert.rejects(f.accepted(),e=>e.code==='accepted_work_grant_conflict');
 }finally{await f.stop();}
});
test('v2 fresh source revocation, membership retirement, issued-at and session withdrawal fences still reject',async()=>{
 for(const mutate of [
  f=>f.mutateSession(f.fresh,{state:'revoked'}),
  f=>f.mutate('scope-memberships',f.source.subject_id,r=>({...r,state:'revoked'}),f.memberOwner),
  f=>f.mutate('scope-memberships',f.source.subject_id,r=>({...r,tokens_valid_after:f.source.issued_at+1}),f.memberOwner),
  f=>f.mutate('scope-memberships',f.source.subject_id,r=>({...r,revoked_session_ids:[f.source.session_id]}),f.memberOwner),
  f=>f.mutate('scope-memberships',f.source.subject_id,r=>({...r,scopes:[]}),f.memberOwner)
 ]){const f=await fixture();try{await mutate(f);await assert.rejects(f.accepted(),e=>e.code==='grant_conflict');}finally{await f.stop();}}
});
test('v2 grant pause, revocation, generation changes and an altered immutable original binding fail closed',async()=>{
 for(const mutate of [
  f=>f.mutate(K.grants,f.terms.grant_id,r=>({...r,state:'paused'})),
  f=>f.mutate(K.grants,f.terms.grant_id,r=>({...r,state:'revoked'})),
  f=>f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,async scoped=>{const old=await scoped.scope();await scoped.saveScope({...old,generation:old.generation+1});})),
  f=>f.mutate('catpaw-runs',f.run.id,r=>({...r,frozen_request:{...r.frozen_request,current_input_hash:hash('changed original input')}}))
 ]){const f=await fixture();try{await mutate(f);await assert.rejects(f.accepted(),e=>e.code==='accepted_work_grant_conflict');}finally{await f.stop();}}
});
test('old, forged or cross-source references cannot masquerade as the selected v2 grant',async()=>{
 const f=await fixture();try{
  for(const reference of [f.run.frozen_request.work_grant_reference,null,{...f.envelope.grant_reference,grant_id:randomUUID()},{...f.envelope.grant_reference,terms_hash:'0'.repeat(64)},{...f.envelope.grant_reference,allow_expired:true}]){
   await assert.rejects(f.accepted(reference),e=>e instanceof ApiError);
  }
  await assert.rejects(f.accepted(f.envelope.grant_reference,f.run.frozen_request.source_auth),e=>e instanceof ApiError);
  const before=f.repository.snapshot();await f.accepted();assert.deepEqual(f.repository.snapshot(),before);
 }finally{await f.stop();}
});
test('a missing or superseded current revision pointer cannot inherit an earlier segment source proof',async()=>{
 for(const update of [
  p=>({...p,operation_id:randomUUID()}),
  p=>({...p,work_grant_reference:undefined}),
  p=>({...p,work_grant_reference:{...p.work_grant_reference,terms_hash:'0'.repeat(64)}})
 ]){const f=await fixture();try{
  await f.mutate('tasks',f.task.id,t=>{const pointer=update(t.state.task_revision);if(pointer.work_grant_reference===undefined)delete pointer.work_grant_reference;return {...t,state:{...t.state,task_revision:pointer}};});
  await assert.rejects(f.accepted(),e=>e instanceof ApiError);
 }finally{await f.stop();}}
});
test('post-await fresh revocation, finite deadline crossing and pointer retirement cannot reuse an earlier valid observation',async()=>{
 for(const mutate of [
  async(f,tx)=>{const row=await tx.get(f.memberOwner,'app-sessions',f.source.session_id);await tx.put(f.memberOwner,'app-sessions',{...row,state:'revoked'});},
  async f=>{f.advance(Date.parse(f.terms.not_after)-f.now());},
  async(f,tx)=>{const row=await tx.get(f.scope.owner,'tasks',f.task.id);await tx.put(f.scope.owner,'tasks',{...row,state:{...row.state,task_revision:{...row.state.task_revision,operation_id:randomUUID()}}});}
 ]){const f=await fixture();try{f.afterMembership(tx=>mutate(f,tx));await assert.rejects(f.accepted(),e=>e instanceof ApiError);}finally{await f.stop();}}
});
test('v2 source proof refuses a backward clock instead of extending the new finite window',async()=>{
 const f=await fixture();try{
  let calls=0;const acceptedAt=Date.parse(f.terms.accepted_at);
  await assert.rejects(f.repository.transaction(tx=>assertAcceptedWorkSourceAuthority(f.sql(tx),f.source,f.scope,f.envelope.grant_reference,{now:()=>{calls++;return calls===1?acceptedAt+200:acceptedAt+100;}})),e=>e.code==='accepted_work_grant_conflict');
 }finally{await f.stop();}
});
