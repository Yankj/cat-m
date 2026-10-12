import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {harness,input,admission,admitted,decision,deferred,auth,scope} from '../../test/harness.mjs';
import {clone} from '../../src/common.mjs';
import {AppError} from '../../patched-openmuse/apps/server/src/errors.ts';
import {LostLeaseError} from '../../patched-openmuse/apps/server/src/engine/worker.ts';

// Independent committed/local-row model, unique-insert waits and rollback.
// It exercises real Facade admission, not a PostgreSQL instance or its query parser.
class CommitModel {
  constructor(){this.committed=new Map();this.waiters=new Map();this.barrier=null;}
  arm(kind){const release=deferred();let reads=0;this.barrier={kind,wait:async()=>{if(++reads===2)release.resolve();await release.promise;}};}
  async transaction(fn){
    const local=new Map(),held=new Set(),frees=[],key=(o,k,id)=>JSON.stringify([o,k,id]);
    const lock=async(o,k,id)=>{const s=key(o,k,id);if(held.has(s))return;const previous=this.waiters.get(s)??Promise.resolve(),gate=deferred();this.waiters.set(s,previous.then(()=>gate.promise));await previous;held.add(s);frees.push(gate.resolve);};
    const get=async(o,k,id)=>{const s=key(o,k,id),v=clone(local.get(s)??this.committed.get(s)??null);if(v===null&&this.barrier?.kind===k)await this.barrier.wait();return v;};
    const put=async(o,k,v)=>{await lock(o,k,v.id);local.set(key(o,k,v.id),clone(v));return clone(v);};
    const tx={get,put,lock,insertIfAbsent:async(o,k,v)=>{await lock(o,k,v.id);const s=key(o,k,v.id);if(local.has(s)||this.committed.has(s))return null;return put(o,k,v);},list:async(o,k)=>[...new Map([...this.committed,...local])].filter(([s])=>{const [a,b]=JSON.parse(s);return a===o&&b===k;}).map(([,v])=>clone(v))};
    try{const v=await fn(tx);for(const [s,row] of local)this.committed.set(s,row);return v;}finally{for(const free of frees)free();}
  }
}
for(const collision of ['operation','run'])test(`C01 ${collision} collision rolls back loser identities in committed-row model`,async()=>{
  const repository=new CommitModel(),h=harness({repository}),d1=input(),d2=input(),a1=admission(),a2=admission();a2[collision+'_id']=a1[collision+'_id'];
  await h.facade.createDelegation(auth,scope,d1);await h.facade.createDelegation(auth,scope,d2);repository.arm('catpaw-'+(collision==='operation'?'operations':'runs'));
  const results=await Promise.allSettled([h.facade.createRun(auth,scope,d1.delegation_id,a1),h.facade.createRun(auth,scope,d2.delegation_id,a2)]);repository.barrier=null;
  assert.equal(results.filter(x=>x.status==='fulfilled').length,1);assert.equal(results.find(x=>x.status==='rejected').reason.code,collision+'_conflict');
  const rows=await repository.transaction(async tx=>({operations:await tx.list(h.owner,'catpaw-operations'),runs:await tx.list(h.owner,'catpaw-runs'),tasks:await tx.list(h.owner,'tasks')}));
  assert.equal(rows.operations.length,1);assert.equal(rows.runs.length,1);assert.equal(rows.tasks.length,1);
  assert.equal(rows.operations[0].run_id,rows.runs[0].id);assert.equal(rows.runs[0].task_id,rows.tasks[0].id);assert.equal(rows.operations[0].request_hash,rows.runs[0].request_hash);assert.deepEqual(rows.tasks[0].state.catpaw,{run_id:rows.runs[0].id,operation_id:rows.operations[0].id,delegation_id:rows.runs[0].delegation_id,delegation_revision:1,grant_epoch:1,request_hash:rows.runs[0].request_hash});
});
for(const control of ['pause','revoke','takeover'])test(`C02 captured event crosses guard then ${control}: rejects old lease, preserves terminal state`,async()=>{
  const arrived=deferred(),release=deferred();let thrown;
  const h=harness({beforePublish:(_task,context)=>context.event('step','Independent delayed progress')}),{d,a,r}=await admitted(h);
  const put=h.store.put.bind(h.store);h.store.put=async(o,k,v)=>{if(k==='run-events'&&v.title==='Independent delayed progress'){arrived.resolve();await release.promise;try{return await put(o,k,v);}catch(e){thrown=e;throw e;}}return put(o,k,v);};
  const tick=h.worker.tick();await arrived.promise;const old=await h.store.get(h.owner,'tasks',r.run.task_id);let other;
  try{
    if(control==='takeover'){await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'tasks',old.id,{leaseId:old.leaseId},{leaseUntil:'2000-01-01T00:00:00.000Z'}));other=harness({repository:h.repository});await other.worker.tick();}
    else await h.facade.control(auth,scope,d.delegation_id,{action:control,expected_revision:1,expected_grant_epoch:1});
    release.resolve();await tick;assert(thrown instanceof LostLeaseError);
    const view=await h.facade.readRun(auth,scope,a.run_id);assert.equal(view.run.state,{pause:'paused',revoke:'cancelled',takeover:'succeeded'}[control]);assert.equal(view.run.attempts.find(x=>x.upstream_run_id===old.leaseId).status,'interrupted');
    const events=await h.repository.transaction(tx=>tx.list(h.owner,'run-events'));assert(!events.some(e=>e.title==='Independent delayed progress'));
  }finally{release.resolve();await tick;await h.worker.stop();await other?.worker.stop();}
});
test('C03 ordinary progress storage exception is not swallowed; failure and its diagnostic persist',async()=>{
  const h=harness({beforePublish:(_task,context)=>context.event('step','Injected progress failure')}),{a,r}=await admitted(h),put=h.store.put.bind(h.store);
  h.store.put=async(o,k,v)=>{if(k==='run-events'&&v.title==='Injected progress failure')throw new Error('Independent progress store failure');return put(o,k,v);};
  await h.worker.tick();const view=await h.facade.readRun(auth,scope,a.run_id),task=await h.store.get(h.owner,'tasks',r.run.task_id),events=await h.repository.transaction(tx=>tx.list(h.owner,'run-events'));
  assert.equal(view.run.state,'failed');assert.equal(task.error,'Independent progress store failure');assert.equal(view.run.artifact_references.length,0);assert.equal(view.run.attempts[0].status,'failed');assert(events.some(e=>e.kind==='error'&&e.detail==='Independent progress store failure'&&e.leaseId===view.run.attempts[0].upstream_run_id));
});
async function ready(){const h=harness(),ad=await admitted(h,'preview');await h.worker.tick();const run=(await h.facade.readRun(auth,scope,ad.a.run_id)).run,id=run.approval_ids[0],p=(await h.facade.readApproval(auth,scope,id)).approval;return {h,...ad,id,p,ref:run.artifact_references[0]};}
test('C04 expired deny returns consumed and persists expiry; wrong digest fails before authority',async()=>{
  const {h,id,p}=await ready();await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{expiresAt:'2000-01-01T00:00:00.000Z'}));
  let calls=0;const factory=h.facade.actionsFor;h.facade.actionsFor=tx=>{const actual=factory(tx);return {decide:async(...args)=>{calls++;return actual.decide(...args);}};};
  await assert.rejects(()=>h.facade.decide(auth,scope,id,{...decision(p),action_digest:'wrong'}),e=>e.code==='approval_stale');assert.equal(calls,0);assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'awaiting_review');
  await assert.rejects(()=>h.facade.decide(auth,scope,id,{...decision(p),decision:'deny'}),e=>e.status===409&&e.code==='approval_consumed');assert.equal(calls,1);assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'expired');
  assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
for(const expired of [false,true])test(`C05 unrelated upstream error rolls back even with expired input=${expired}`,async()=>{
  const {h,id,p}=await ready();if(expired)await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{expiresAt:'2000-01-01T00:00:00.000Z'}));
  h.facade.actionsFor=tx=>({decide:async()=>{await tx.put(h.owner,'catpaw-preview-effects',{id:'must-not-commit'});throw new AppError('Independent unexpected conflict',409);}});
  await assert.rejects(()=>h.facade.decide(auth,scope,id,decision(p)),e=>e.status===409&&e.code==='approval_stale');assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'awaiting_review');assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
test('C06 failure after reserving operation and run rolls both back',async()=>{
  const h=harness(),d=input(),a=admission();await h.facade.createDelegation(auth,scope,d);const original=h.repository.transaction.bind(h.repository);
  h.repository.transaction=fn=>original(tx=>{const insert=tx.insertIfAbsent.bind(tx);tx.insertIfAbsent=async(o,k,v)=>{if(k==='tasks')throw new Error('Independent task insertion failure');return insert(o,k,v);};return fn(tx);});
  await assert.rejects(()=>h.facade.createRun(auth,scope,d.delegation_id,a),/Independent task insertion failure/);h.repository.transaction=original;
  for(const kind of ['tasks','catpaw-runs','catpaw-operations'])assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,kind))).length,0);
});
test('C07 expired old approval permits v2 but never permits its old authorization',async()=>{
  const {h,id,p,r,ref}=await ready();await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{expiresAt:'2000-01-01T00:00:00.000Z'}));
  const lease=randomUUID();await h.store.compareAndSwap(h.owner,'tasks',r.run.task_id,{status:'waiting_approval',leaseId:null},{status:'running',leaseId:lease});
  const next=await h.facade.publishArtifact(h.owner,r.run.task_id,{kind:'report',title:'Independent v2',summary:'Fixed new data',data:{v:2}},lease);assert.equal(next.version,2);assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'expired');
  assert.equal((await h.facade.readArtifact(auth,scope,ref.artifact_id,1)).artifact.content_hash,ref.content_hash);await assert.rejects(()=>h.facade.decide(auth,scope,id,decision(p)),e=>e.code==='approval_stale');assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
test('C08 missing event lease remains rejected; captured good event has exact attempt lease',async()=>{
  const entered=deferred(),release=deferred();const h=harness({beforePublish:async(_task,context)=>{await context.event('step','Independent valid event');entered.resolve();await release.promise;}}),{a,r}=await admitted(h);const tick=h.worker.tick();await entered.promise;
  try{await assert.rejects(()=>h.store.put(h.owner,'run-events',{id:randomUUID(),taskId:r.run.task_id,kind:'step',title:'Missing metadata'}),e=>e instanceof LostLeaseError);const view=await h.facade.readRun(auth,scope,a.run_id),events=await h.repository.transaction(tx=>tx.list(h.owner,'run-events'));assert.equal(events.find(x=>x.title==='Independent valid event').leaseId,view.run.attempts[0].upstream_run_id);assert(!events.some(x=>x.title==='Missing metadata'));}finally{release.resolve();await tick;await h.worker.stop();}
});
test('C09 authority observes already-expired status between facade read and claim: still 409, no effect',async()=>{
  const {h,id,p}=await ready(),factory=h.facade.actionsFor;
  h.facade.actionsFor=tx=>{const actual=factory(tx);return {decide:async(...args)=>{await tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{status:'expired',expiresAt:'2000-01-01T00:00:00.000Z'});return actual.decide(...args);}};};
  await assert.rejects(()=>h.facade.decide(auth,scope,id,decision(p)),e=>e.status===409&&e.code==='approval_consumed');assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'expired');assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
