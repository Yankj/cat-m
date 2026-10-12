import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { auth,scope,harness,admitted,decision,deferred,input,admission } from './harness.mjs';
import { clone } from '../src/common.mjs';
import { AppError } from '../patched-openmuse/apps/server/src/errors.ts';
import { startSyntheticServer } from '../src/server.mjs';
import { createRuntime } from '../src/runtime.mjs';
import { MemoryRepository } from '../src/memory-repository.mjs';

// Read-committed model with transaction-local writes, identity locks and rollback.
// This is additional MODEL evidence, not a PostgreSQL/PGlite test.
class TransactionModel {
  constructor(){this.rows=new Map();this.locks=new Map();this.barrier=null;}
  arm(kind){let count=0;const b=deferred();this.barrier={kind,wait:async()=>{if(++count===2)b.resolve();await b.promise;}};}
  async transaction(fn){
    const local=new Map(),held=new Set(),release=[],key=(o,k,id)=>JSON.stringify([o,k,id]);
    const lock=async(o,k,id)=>{const s=key(o,k,id);if(held.has(s))return;const prior=this.locks.get(s)??Promise.resolve(),gate=deferred();this.locks.set(s,prior.then(()=>gate.promise));await prior;held.add(s);release.push(gate.resolve);};
    const get=async(o,k,id)=>{const s=key(o,k,id),v=clone(local.get(s)??this.rows.get(s)??null);if(v===null&&this.barrier?.kind===k)await this.barrier.wait();return v;};
    const put=async(o,k,v)=>{await lock(o,k,v.id);local.set(key(o,k,v.id),clone(v));return clone(v);};
    const tx={lock,get,put,insertIfAbsent:async(o,k,v)=>{await lock(o,k,v.id);const s=key(o,k,v.id);if(local.has(s)||this.rows.has(s))return null;return put(o,k,v);},list:async(o,k)=>[...new Map([...this.rows,...local])].filter(([s])=>{const [o2,k2]=JSON.parse(s);return o===o2&&k===k2;}).map(([,v])=>clone(v))};
    try{const result=await fn(tx);for(const [s,v] of local)this.rows.set(s,v);return result;}finally{for(const free of release)free();}
  }
}
for(const shared of ['operation','run'])test(`R01 ${shared} collision has one consistent task/run/op after modeled transactional rollback`,async()=>{
  const repository=new TransactionModel(),h=harness({repository}),d1=input(),d2=input(),a1=admission(),a2=admission();
  a2[shared==='operation'?'operation_id':'run_id']=a1[shared==='operation'?'operation_id':'run_id'];
  await h.facade.createDelegation(auth,scope,d1);await h.facade.createDelegation(auth,scope,d2);repository.arm(shared==='operation'?'catpaw-operations':'catpaw-runs');
  const result=await Promise.allSettled([h.facade.createRun(auth,scope,d1.delegation_id,a1),h.facade.createRun(auth,scope,d2.delegation_id,a2)]);repository.barrier=null;
  assert.equal(result.filter(x=>x.status==='fulfilled').length,1);assert.equal(result.find(x=>x.status==='rejected').reason.code,shared+'_conflict');
  const records=await repository.transaction(async tx=>({tasks:await tx.list(h.owner,'tasks'),runs:await tx.list(h.owner,'catpaw-runs'),ops:await tx.list(h.owner,'catpaw-operations')}));
  assert.equal(records.tasks.length,1);assert.equal(records.runs.length,1);assert.equal(records.ops.length,1);
  assert.equal(records.runs[0].task_id,records.tasks[0].id);assert.equal(records.ops[0].run_id,records.runs[0].id);assert.equal(records.tasks[0].state.catpaw.request_hash,records.runs[0].request_hash);
});
for(const action of ['pause','revoke','takeover'])test(`R02 captured event after guard is rejected after ${action}; original attempt stays interrupted`,async()=>{
  const entered=deferred(),release=deferred(),h=harness({beforePublish:async(_task,context)=>context.event('step','Captured late event','synthetic')}),{d,a,r}=await admitted(h);
  const put=h.store.put.bind(h.store);h.store.put=async(owner,kind,value)=>{if(kind==='run-events'&&value.title==='Captured late event'){entered.resolve();await release.promise;}return put(owner,kind,value);};
  const tick=h.worker.tick();await entered.promise;const old=await h.store.get(h.owner,'tasks',r.run.task_id);let next;
  if(action==='takeover'){
    await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'tasks',old.id,{leaseId:old.leaseId},{leaseUntil:'2000-01-01T00:00:00.000Z'}));next=harness({repository:h.repository});await next.worker.tick();
  }else await h.facade.control(auth,scope,d.delegation_id,{action,expected_revision:1,expected_grant_epoch:1});
  release.resolve();await tick;
  const view=await h.facade.readRun(auth,scope,a.run_id),events=await h.repository.transaction(tx=>tx.list(h.owner,'run-events'));
  assert(!events.some(e=>e.title==='Captured late event'));assert.equal(view.run.attempts.find(x=>x.upstream_run_id===old.leaseId).status,'interrupted');
  assert.equal(view.run.state,{pause:'paused',revoke:'cancelled',takeover:'succeeded'}[action]);await h.worker.stop();await next?.worker.stop();
});
async function pending(){const h=harness(),a=await admitted(h,'preview');await h.worker.tick();const id=(await h.facade.readRun(auth,scope,a.a.run_id)).run.approval_ids[0],p=(await h.facade.readApproval(auth,scope,id)).approval;return {h,...a,id,p};}
test('R03 expired deny commits expired and produces the defined consumed error',async()=>{
  const {h,id,p}=await pending();await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{expiresAt:'2000-01-01T00:00:00.000Z'}));
  await assert.rejects(()=>h.facade.decide(auth,scope,id,{...decision(p),decision:'deny'}),e=>e.code==='approval_consumed'&&e.status===409);
  assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'expired');assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
test('R04 expired previous approval does not roll back replacement artifact version',async()=>{
  const {h,r,id}=await pending();await h.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{expiresAt:'2000-01-01T00:00:00.000Z'}));
  const lease=randomUUID();await h.store.compareAndSwap(h.owner,'tasks',r.run.task_id,{status:'waiting_approval',leaseId:null},{status:'running',leaseId:lease});
  const ref=await h.facade.publishArtifact(h.owner,r.run.task_id,{kind:'report',title:'Revision two',summary:'New fixed output',data:{revision:2}},lease);
  assert.equal(ref.version,2);assert.equal((await h.facade.readArtifact(auth,scope,ref.artifact_id,2)).artifact.version,2);assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'expired');
});
test('R03b expiry observed by actual authority before its claim still returns defined 409',async()=>{
  const {h,id,p}=await pending(),factory=h.facade.actionsFor;
  h.facade.actionsFor=tx=>{const actual=factory(tx);return {decide:async(...args)=>{
    await tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{status:'expired',expiresAt:'2000-01-01T00:00:00.000Z'});
    return actual.decide(...args);
  }};};
  await assert.rejects(()=>h.facade.decide(auth,scope,id,decision(p)),e=>e.status===409&&e.code==='approval_consumed');
  assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'expired');assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
test('R05 unrelated upstream AppError is mapped but its transaction still rolls back',async()=>{
  const {h,id,p}=await pending();h.facade.actionsFor=tx=>({decide:async()=>{await tx.put(h.owner,'catpaw-preview-effects',{id:'must-rollback'});throw new AppError('Synthetic upstream conflict',409);}});
  await assert.rejects(()=>h.facade.decide(auth,scope,id,decision(p)),e=>e.status===409&&e.code==='approval_stale');assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
  assert.equal((await h.facade.readApproval(auth,scope,id)).approval.status,'awaiting_review');
});
test('R06 real HTTP rejects invalid JSON and oversized reconciliation payload',{timeout:5000},async()=>{
  const runtime=await createRuntime({repository:new MemoryRepository()}),server=await startSyntheticServer({port:0,runtime});
  try{
    const url=server.origin+`/catpaw/v1/scopes/${scope}/approvals/synthetic-id/reconciliation-checks`;
    for(const [body,status,code] of [['{',422,'schema_invalid'],[' '.repeat(32769),413,'request_too_large']]){
      const response=await fetch(url,{method:'POST',headers:{authorization:auth,'content-type':'application/json'},body});assert.equal(response.status,status);assert.equal((await response.json()).error.code,code);
    }
  }finally{await server.close();}
});
