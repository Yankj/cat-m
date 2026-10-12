import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {harness,admitted,input,admission,auth,scope,decision,deferred} from '../../test/harness.mjs';
import {createFetchHandler} from '../../src/http.mjs';
import {hash,SYNTHETIC_SCOPE,clone} from '../../src/common.mjs';
const req=(h,path,body)=>createFetchHandler(h.facade)(new Request(`http://127.0.0.1/catpaw/v1/scopes/${scope}${path}`,{method:'POST',headers:{authorization:auth,'content-type':'application/json'},body:JSON.stringify(body)}));
async function ready(fixture='preview') {const h=harness(),ad=await admitted(h,fixture);await h.worker.tick();const id=(await h.facade.readRun(auth,scope,ad.a.run_id)).run.approval_ids[0];return {...ad,h,id,p:(await h.facade.readApproval(auth,scope,id)).approval};}

test('N01 expired approval is a defined 409 response and stays expired',async()=>{
  const {h,id,p}=await ready();
  await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{expiresAt:'2000-01-01T00:00:00.000Z'}));
  const response=await req(h,`/approvals/${id}/decisions`,decision(p));const body=await response.json();
  console.log('N01 actual',JSON.stringify({status:response.status,body,stored_status:(await h.facade.readApproval(auth,scope,id)).approval.status}));
  assert.equal(response.status,409);assert.notEqual(body.error.code,'internal_error');
  assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'expired');
});
for(const [name,value] of [['null',null],['array',[]],['string',''],['number',0]])test(`N02 reconciliation rejects ${name} body as 422`,async()=>{
  const {h,id,p}=await ready('preview_unknown');await h.facade.decide(auth,scope,id,decision(p));
  const response=await req(h,`/approvals/${id}/reconciliation-checks`,value);
  console.log('N02 actual',name,response.status,JSON.stringify(await response.clone().json()));
  assert.equal(response.status,422);assert.equal((await response.json()).error.code,'schema_invalid');
});
test('N03 simultaneous approvals record one effect and reject the loser',async()=>{
  const {h,id,p}=await ready();const results=await Promise.allSettled([h.facade.decide(auth,scope,id,decision(p)),h.facade.decide(auth,scope,id,decision(p))]);
  assert.equal(results.filter(x=>x.status==='fulfilled').length,1);assert.equal(results.find(x=>x.status==='rejected').reason.code,'approval_consumed');
  assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,1);
});
for(const action of ['pause','revoke'])test(`N04 ${action} followed by approval leaves zero effects and old binding unusable after resume`,async()=>{
  const {h,d,id,p}=await ready();await h.facade.control(auth,scope,d.delegation_id,{action,expected_revision:1,expected_grant_epoch:1});
  await assert.rejects(()=>h.facade.decide(auth,scope,id,decision(p)),e=>e.code==='grant_conflict');
  if(action==='pause'){await h.facade.control(auth,scope,d.delegation_id,{action:'resume',expected_revision:2,expected_grant_epoch:2});await assert.rejects(()=>h.facade.decide(auth,scope,id,{...decision(p),expected_grant_epoch:3}),e=>e.code==='grant_conflict');}
  assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
test('N05 former lease cannot publish after a second actual worker claims the task',async()=>{
  const entered=deferred(),release=deferred(),h=harness({beforePublish:async()=>{entered.resolve();await release.promise;}}),{a,r}=await admitted(h);
  const tick=h.worker.tick();await entered.promise;const old=await h.store.get(h.owner,'tasks',r.run.task_id);
  await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'tasks',old.id,{leaseId:old.leaseId},{leaseUntil:'2000-01-01T00:00:00.000Z'}));
  const successor=harness({repository:h.repository});await successor.worker.tick();
  await assert.rejects(()=>h.facade.publishArtifact(h.owner,old.id,{kind:'report',title:'late',summary:'late',data:{}},old.leaseId),e=>e.code==='lease_lost');
  release.resolve();await tick;
  const view=await h.facade.readRun(auth,scope,a.run_id);assert.equal(view.run.state,'succeeded');assert.equal(view.run.artifact_references.length,1);assert.equal(view.run.attempts.length,2);assert.equal(view.run.attempts.find(x=>x.upstream_run_id===old.leaseId).status,'interrupted');
  await h.worker.stop();await successor.worker.stop();
});
test('N06 artifact integrity corruption fails closed',async()=>{
  const h=harness(),{a}=await admitted(h);await h.worker.tick();const ref=(await h.facade.readRun(auth,scope,a.run_id)).run.artifact_references[0];
  await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'catpaw-artifact-versions',`${ref.artifact_id}:1`,{content_hash:ref.content_hash},{body:'tampered'}));
  await assert.rejects(()=>h.facade.readArtifact(auth,scope,ref.artifact_id,1),e=>e.code==='artifact_corrupt');
});
test('N07 scope isolation covers run, operation, artifact, approval and reconciliation',async()=>{
  const other={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()},h=harness({authenticate:async()=>({scopes:[SYNTHETIC_SCOPE,other]})});
  const {a}=await admitted(h,'preview_unknown');await h.worker.tick();const run=(await h.facade.readRun(auth,scope,a.run_id)).run,p=(await h.facade.readApproval(auth,scope,run.approval_ids[0])).approval;
  await h.facade.decide(auth,scope,p.id,decision(p));
  for(const action of [()=>h.facade.readRun(auth,other.scope_id,a.run_id),()=>h.facade.readOperation(auth,other.scope_id,a.operation_id),()=>h.facade.readArtifact(auth,other.scope_id,run.artifact_references[0].artifact_id,1),()=>h.facade.readApproval(auth,other.scope_id,p.id),()=>h.facade.reconcile(auth,other.scope_id,p.id)])await assert.rejects(action,e=>e.code==='not_found');
});
// Interleaving model: row locks serialize a given delegation, not a whole repository.
// Uses the real Facade method; NOT evidence of a live PostgreSQL deployment.
class RowInterleavingRepository {
  constructor(){this.rows=new Map();this.layer='independent_row_interleaving_model';this.barrier=null;}
  arm(kind){const entered=deferred();let count=0;this.barrier={kind,wait:async()=>{if(++count===2)entered.resolve();await entered.promise;}};}
  async transaction(fn){const repo=this,key=(o,k,id)=>JSON.stringify([o,k,id]);return fn({lock:async()=>{},get:async(o,k,id)=>{const value=clone(repo.rows.get(key(o,k,id))??null);if(repo.barrier?.kind===k&&value===null)await repo.barrier.wait();return value;},put:async(o,k,v)=>{repo.rows.set(key(o,k,v.id),clone(v));return clone(v);},insertIfAbsent:async(o,k,v)=>{const k2=key(o,k,v.id);if(repo.rows.has(k2))return null;repo.rows.set(k2,clone(v));return clone(v);},list:async(o,k)=>[...repo.rows].filter(([s])=>{const [o2,k2]=JSON.parse(s);return o===o2&&k===k2;}).map(([,v])=>clone(v))});}
}
test('N08 conflicting operation across different delegations is rejected under row-level interleaving',async()=>{
  const repository=new RowInterleavingRepository(),h=harness({repository}),d1=input(),d2=input(),a1=admission(),a2={...admission(),operation_id:a1.operation_id};
  await h.facade.createDelegation(auth,scope,d1);await h.facade.createDelegation(auth,scope,d2);repository.arm('catpaw-operations');
  const results=await Promise.allSettled([h.facade.createRun(auth,scope,d1.delegation_id,a1),h.facade.createRun(auth,scope,d2.delegation_id,a2)]);repository.barrier=null;
  const operations=await repository.transaction(tx=>tx.list(h.owner,'catpaw-operations')),runs=await repository.transaction(tx=>tx.list(h.owner,'catpaw-runs')),tasks=await repository.transaction(tx=>tx.list(h.owner,'tasks'));
  console.log('N08 actual',JSON.stringify({results:results.map(x=>({status:x.status,run:x.value?.run,error:x.reason?.code})),operations,runs,tasks}));
  assert.equal(results.filter(x=>x.status==='fulfilled').length,1);assert.equal(results.find(x=>x.status==='rejected')?.reason.code,'operation_conflict');assert.equal(runs.length,1);
});
test('N09 conflicting run across different delegations is rejected under row-level interleaving',async()=>{
  const repository=new RowInterleavingRepository(),h=harness({repository}),d1=input(),d2=input(),a1=admission(),a2={...admission(),run_id:a1.run_id};
  await h.facade.createDelegation(auth,scope,d1);await h.facade.createDelegation(auth,scope,d2);repository.arm('catpaw-runs');
  const results=await Promise.allSettled([h.facade.createRun(auth,scope,d1.delegation_id,a1),h.facade.createRun(auth,scope,d2.delegation_id,a2)]);repository.barrier=null;
  console.log('N09 actual',JSON.stringify({results:results.map(x=>({status:x.status,run:x.value?.run,error:x.reason?.code})),tasks:await repository.transaction(tx=>tx.list(h.owner,'tasks')),operations:await repository.transaction(tx=>tx.list(h.owner,'catpaw-operations'))}));
  assert.equal(results.filter(x=>x.status==='fulfilled').length,1);assert.equal(results.find(x=>x.status==='rejected')?.reason.code,'run_conflict');
});
test('N10 pinned TaskContext.event remains usable through the fenced store',async()=>{
  const h=harness({beforePublish:async(_task,context)=>context.event('step','Independent handler progress','fixed local test')}),{a}=await admitted(h);
  await h.worker.tick();const view=await h.facade.readRun(auth,scope,a.run_id),events=await h.repository.transaction(tx=>tx.list(h.owner,'run-events'));
  console.log('N10 actual',JSON.stringify({view,events}));assert.equal(view.run.state,'succeeded');assert(events.some(e=>e.title==='Independent handler progress'));
});
test('N11 handler failure persists a usable error event as well as failed task state',async()=>{
  const h=harness({beforePublish:async()=>{throw new Error('Independent synthetic handler failure');}}),{a}=await admitted(h);
  await h.worker.tick();const view=await h.facade.readRun(auth,scope,a.run_id),events=await h.repository.transaction(tx=>tx.list(h.owner,'run-events'));
  console.log('N11 actual',JSON.stringify({view,events}));assert.equal(view.run.state,'failed');assert(events.some(e=>e.kind==='error'&&e.detail.includes('Independent synthetic handler failure')));
});
