import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { auth,scope,harness,input,admission,admitted,decision,deferred } from './harness.mjs';
import { MemoryRepository } from '../src/memory-repository.mjs';
import { hash,SYNTHETIC_SCOPE } from '../src/common.mjs';
import { createFetchHandler } from '../src/http.mjs';
import { createRuntime } from '../src/runtime.mjs';
const rejects=(fn,code)=>assert.rejects(fn,e=>e.code===code);

test('real TaskWorker: admit -> disconnect -> status read -> immutable report; operation/task/lease IDs stay distinct',async()=>{
  const entered=deferred(),release=deferred(),h=harness({beforePublish:async()=>{entered.resolve();await release.promise;}}),{d,a,r}=await admitted(h);
  const tick=h.worker.tick();await entered.promise;
  // Client has no stream/connection handle. Worker proceeds independently of this new read client.
  const secondClient=harness({repository:h.repository});
  const running=await secondClient.facade.readOperation(auth,scope,a.operation_id);
  assert.equal(running.run.state,'running');assert.equal(running.run.attempts.length,1);
  assert.equal(new Set([a.operation_id,a.run_id,r.run.task_id,running.run.attempts[0].upstream_run_id]).size,4);
  release.resolve();await tick;
  const done=await secondClient.facade.readRun(auth,scope,a.run_id);assert.equal(done.run.state,'succeeded');assert.equal(done.run.attempts[0].status,'succeeded');
  const ref=done.run.artifact_references[0],artifact=await secondClient.facade.readArtifact(auth,scope,ref.artifact_id,ref.version);
  assert.equal(hash(artifact.artifact.body),ref.content_hash);assert.equal(ref.version,1);
  const count=done.task.attempts;await h.worker.tick();assert.equal((await h.facade.readRun(auth,scope,a.run_id)).task.attempts,count);
  assert.equal((await h.facade.readDelegation(auth,scope,d.delegation_id)).delegation.state,'active');await h.worker.stop();
});
test('same frozen operation is idempotent under simultaneous requests; changed run is rejected',async()=>{
  const h=harness(),d=input(),a=admission();await h.facade.createDelegation(auth,scope,d);
  const results=await Promise.all([h.facade.createRun(auth,scope,d.delegation_id,a),h.facade.createRun(auth,scope,d.delegation_id,a)]);
  assert.equal(results[0].run.task_id,results[1].run.task_id);assert.equal(results.filter(x=>x.idempotent).length,1);
  assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'tasks'))).length,1);
  await rejects(()=>h.facade.createRun(auth,scope,d.delegation_id,{...a,run_id:randomUUID()}),'operation_conflict');
  await rejects(()=>h.facade.createDelegation(auth,scope,{...d,goal:'Changed goal'}),'operation_conflict');
  const frozen=await h.repository.transaction(tx=>tx.get(h.owner,'catpaw-runs',a.run_id));assert.equal(hash(frozen.frozen_request),frozen.request_hash);
});
test('server model configuration is frozen and cannot silently replace same operation',async()=>{
  const h=harness(),{d,a}=await admitted(h);h.facade.modelConfiguration={backend:'synthetic',model:'changed'};
  await rejects(()=>h.facade.createRun(auth,scope,d.delegation_id,a),'operation_conflict');
});
test('scope isolation includes identical object IDs; client owner injection is rejected',async()=>{
  const other={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()};
  const h=harness({authenticate:async()=>({scopes:[SYNTHETIC_SCOPE,other]})}),d=input();await h.facade.createDelegation(auth,scope,d);
  await rejects(()=>h.facade.readDelegation(auth,other.scope_id,d.delegation_id),'not_found');
  await h.facade.createDelegation(auth,other.scope_id,{...d,title:'Other scope'});
  assert.equal((await h.facade.readDelegation(auth,scope,d.delegation_id)).delegation.title,d.title);
  await rejects(()=>h.facade.readDelegation(auth,randomUUID(),d.delegation_id),'scope_forbidden');
  await rejects(()=>h.facade.createDelegation(auth,scope,{...input(),owner:'local-user'}),'schema_invalid');
});
for(const action of ['pause','revoke'])test(`${action} wins before output commit: old worker/artifact/event/lease cannot write`,async()=>{
  const entered=deferred(),release=deferred(),h=harness({beforePublish:async()=>{entered.resolve();await release.promise;}}),{d,a,r}=await admitted(h);
  const tick=h.worker.tick();await entered.promise;
  const old=await h.store.get(h.owner,'tasks',r.run.task_id);
  await h.facade.control(auth,scope,d.delegation_id,{action,expected_revision:1,expected_grant_epoch:1});release.resolve();await tick;
  const current=await h.facade.readRun(auth,scope,a.run_id);assert.equal(current.run.state,action==='pause'?'paused':'cancelled');assert.equal(current.run.authorization_state,'superseded');assert.equal(current.run.artifact_references.length,0);
  await rejects(()=>h.facade.publishArtifact(h.owner,old.id,{kind:'report',title:'Late',summary:'Late',data:{}},old.leaseId),'grant_conflict');
  await rejects(()=>h.facade.publishEvent(h.owner,old.id,old.leaseId,{kind:'result',title:'Late'}),'grant_conflict');
  assert.equal(await h.store.compareAndSwap(h.owner,'tasks',old.id,{status:'running',leaseId:old.leaseId},{status:'succeeded'}),null);
  await h.worker.stop();
});
test('resume creates a fresh admission and never unpauses the superseded task',async()=>{
  const h=harness(),{d,r}=await admitted(h);await h.facade.control(auth,scope,d.delegation_id,{action:'pause',expected_revision:1,expected_grant_epoch:1});
  await h.facade.control(auth,scope,d.delegation_id,{action:'resume',expected_revision:2,expected_grant_epoch:2});
  assert.equal((await h.store.get(h.owner,'tasks',r.run.task_id)).status,'paused');
  const a={...admission(),expected_revision:3,expected_grant_epoch:3};await h.facade.createRun(auth,scope,d.delegation_id,a);await h.worker.tick();
  assert.equal((await h.facade.readRun(auth,scope,a.run_id)).run.state,'succeeded');
});
test('old approval denied on artifact replacement; new proposal binds version and succeeds once',async()=>{
  const h=harness(),{a,r}=await admitted(h,'preview');await h.worker.tick();let view=await h.facade.readRun(auth,scope,a.run_id);
  const oldID=view.run.approval_ids[0],old=await h.facade.readApproval(auth,scope,oldID),task=await h.store.get(h.owner,'tasks',r.run.task_id);
  const lease=randomUUID();await h.store.compareAndSwap(h.owner,'tasks',task.id,{status:'waiting_approval',leaseId:null},{status:'running',leaseId:lease,attempts:task.attempts+1});
  const ref=await h.facade.publishArtifact(h.owner,task.id,{kind:'report',title:'Revision 2',summary:'Changed fixed result',data:{revision:2}},lease);
  assert.equal(ref.version,2);await rejects(()=>h.facade.decide(auth,scope,oldID,decision(old.approval)),'approval_stale');
  assert.equal((await h.facade.readApproval(auth,scope,oldID)).approval.status,'denied');
  const fresh=await h.facade.proposePreview(h.owner,task.id,ref,lease);
  await h.store.compareAndSwap(h.owner,'tasks',task.id,{status:'running',leaseId:lease},{status:'waiting_approval',leaseId:null,leaseUntil:null});
  const p=(await h.facade.readApproval(auth,scope,fresh.id)).approval;
  assert.notEqual(p.action_digest,old.approval.action_digest);
  assert.equal((await h.facade.decide(auth,scope,p.id,decision(p))).approval.status,'succeeded');
  await rejects(()=>h.facade.decide(auth,scope,p.id,decision(p)),'approval_consumed');
  const version1=await h.facade.readArtifact(auth,scope,ref.artifact_id,1);assert.equal(hash(version1.artifact.body),version1.artifact.content_hash);
  await h.worker.tick();assert.equal((await h.facade.readRun(auth,scope,a.run_id)).run.state,'succeeded');
  assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,1);
});
test('unknown acknowledgement stays unknown: read/reconcile is evidence-only and never dispatches again',async()=>{
  const h=harness(),{a}=await admitted(h,'preview_unknown');await h.worker.tick();
  const run=await h.facade.readRun(auth,scope,a.run_id),id=run.run.approval_ids[0],p=(await h.facade.readApproval(auth,scope,id)).approval;
  const receipt=await h.facade.decide(auth,scope,id,decision(p));assert.equal(receipt.approval.status,'outcome_unknown');assert.equal(receipt.approval.receipt_status,'unknown');
  await rejects(()=>h.facade.decide(auth,scope,id,decision(p)),'outcome_unknown');
  const reconciled=await h.facade.reconcile(auth,scope,id);assert.equal(reconciled.approval.status,'outcome_unknown');assert.equal(reconciled.approval.reconciliation.state,'resolved_local');assert.equal(reconciled.approval.reconciliation.can_retry,false);
  await h.worker.tick();assert.equal((await h.facade.readRun(auth,scope,a.run_id)).run.state,'outcome_unknown');
  assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,1);
});
test('revoked pending proposal and modified digest cannot dispatch',async()=>{
  const h=harness(),{d,a}=await admitted(h,'preview');await h.worker.tick();const id=(await h.facade.readRun(auth,scope,a.run_id)).run.approval_ids[0],p=(await h.facade.readApproval(auth,scope,id)).approval;
  await rejects(()=>h.facade.decide(auth,scope,id,{...decision(p),action_digest:'changed'}),'approval_stale');
  await h.facade.control(auth,scope,d.delegation_id,{action:'revoke',expected_revision:1,expected_grant_epoch:1});
  await rejects(()=>h.facade.decide(auth,scope,id,decision(p)),'grant_conflict');assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
test('expired lease recovery maps another actual worker attempt into the original stable run',async()=>{
  const h=harness(),{a,r}=await admitted(h),old=randomUUID();
  await h.store.compareAndSwap(h.owner,'tasks',r.run.task_id,{status:'queued',leaseId:null},{status:'running',leaseId:old,leaseUntil:'2000-01-01T00:00:00.000Z',attempts:1});
  // Explicit memory snapshot rehydration only; this does not claim disk/SQL durability.
  const restarted=harness({repository:new MemoryRepository(h.repository.snapshot())});await restarted.worker.tick();
  const view=await restarted.facade.readOperation(auth,scope,a.operation_id);assert.equal(view.run.id,a.run_id);assert.equal(view.run.state,'succeeded');assert.equal(view.run.attempts.length,2);
  assert.equal(view.run.attempts.find(x=>x.upstream_run_id===old).status,'interrupted');
});
test('HTTP DTOs: auth, explicit errors, scope gate, unknown methods and unknown fields',async()=>{
  const h=harness(),fetch=createFetchHandler(h.facade),base=`http://127.0.0.1/catpaw/v1/scopes/${scope}`,d=input();
  const req=(path,method='GET',body,authorization=auth)=>fetch(new Request(base+path,{method,headers:{authorization,'content-type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})}));
  assert.equal((await req('/delegations/'+d.delegation_id,'GET',undefined,'')).status,401);
  const c=await req('/delegations','POST',d);assert.equal(c.status,201);assert.equal((await c.json()).schema_version,1);
  const bad=await req('/delegations','POST',{...input(),private_sources:true});assert.equal(bad.status,422);assert.equal((await bad.json()).error.retryable,false);
  assert.equal((await req('/delegations/'+d.delegation_id,'DELETE')).status,404);
  const capabilities=await fetch(new Request('http://127.0.0.1/catpaw/v1/capabilities',{headers:{authorization:auth}}));assert.equal((await capabilities.json()).supports.sse_replay,false);
});
test('transaction failure commits neither task nor operation nor run',async()=>{
  const h=harness(),d=input(),a=admission();await h.facade.createDelegation(auth,scope,d);
  const original=h.repository.transaction.bind(h.repository);
  h.repository.transaction=fn=>original(tx=>{const insert=tx.insertIfAbsent.bind(tx);tx.insertIfAbsent=async(owner,kind,value)=>{if(kind==='catpaw-operations')throw new Error('Synthetic database failure');return insert(owner,kind,value);};return fn(tx);});
  await assert.rejects(()=>h.facade.createRun(auth,scope,d.delegation_id,a));h.repository.transaction=original;
  assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'tasks'))).length,0);
  await rejects(()=>h.facade.readOperation(auth,scope,a.operation_id),'not_found');
});
test('restart never re-dispatches an interrupted executing proposal',async()=>{
  const h=harness(),{a}=await admitted(h,'preview');await h.worker.tick();const id=(await h.facade.readRun(auth,scope,a.run_id)).run.approval_ids[0];
  await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{status:'executing'}));
  const runtime=await createRuntime({repository:new MemoryRepository(h.repository.snapshot())});
  const recovered=await runtime.facade.readApproval(auth,scope,id);assert.equal(recovered.approval.status,'outcome_unknown');
  const check=await runtime.facade.reconcile(auth,scope,id);assert.equal(check.approval.reconciliation.state,'unresolved');assert.equal(check.approval.reconciliation.can_retry,false);
  await runtime.worker.tick();assert.equal((await runtime.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
