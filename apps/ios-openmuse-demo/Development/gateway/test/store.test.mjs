import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DurableStore} from '../src/store.mjs';
import {AssistantService} from '../src/assistant.mjs';
const file = () => join(mkdtempSync(join(tmpdir(),'catpaw-store-')),'state.json');
const scope = {profile_id:'22222222-1111-4111-8111-111111111111',workspace_id:'22222222-2222-4222-8222-111111111111'};
const draft = {title:'Synthetic follow-up',goal:'Draft from synthetic inputs',stop_conditions:['until user stops'],interval_ms:3600000,model_id:'dots-free'};

test('a delegation persists separately from a run; a lease prevents duplicate claim across restart', () => {
  const path = file(); let now=1000000000000;
  const service = new AssistantService(new DurableStore(path),{clock:()=>now});
  const d=service.createDelegation(scope,draft,'create-1');
  assert.equal(service.createDelegation(scope,draft,'create-1').id,d.id);
  const run=service.enqueue(scope,d.id,'manual-1');
  const first=service.claim('worker-one',1000);
  assert.equal(first.run.id,run.id);
  const recovered=new AssistantService(new DurableStore(path),{clock:()=>now});
  assert.equal(recovered.claim('worker-two',1000),null);
  now+=1001;
  const second=recovered.claim('worker-two',1000);
  assert.equal(second.run.id,run.id);
  assert.ok(second.token>first.token);
  assert.throws(()=>service.publish(first,'old worker output'),{code:'lease_lost'});
  const artifact=recovered.publish(second,'new worker output');
  assert.equal(recovered.getDelegation(scope,d.id).state,'active');
  assert.equal(recovered.getRun(scope,run.id).state,'succeeded');
  assert.equal(recovered.getArtifact(scope,artifact.id).versions[0].body,'new worker output');
});

test('pause, resume and source revocation fence in-flight publication without restoring a grant', () => {
  const s=new AssistantService(new DurableStore(file()),{clock:()=>1000000000000});
  const d=s.createDelegation(scope,draft,'create');
  const source=s.addSource(scope,d.id,'https://example.com/synthetic','source');
  const run=s.enqueue(scope,d.id,'run'); const c=s.claim('worker');
  const paused=s.control(scope,d.id,'paused',s.getDelegation(scope,d.id).revision,'pause');
  assert.throws(()=>s.publish(c,'in flight'),{code:'lease_lost'});
  const resumed=s.control(scope,d.id,'active',paused.revision,'resume');
  assert.equal(s.getRun(scope,run.id).state,'cancelled');
  const c2=(s.enqueue(scope,d.id,'run-two'),s.claim('worker-two'));
  s.sourcePermission(scope,source.id,false,source.revision,'revoke');
  assert.throws(()=>s.publish(c2,'revoked context'),{code:'lease_lost'});
  const d2=s.getDelegation(scope,d.id);
  const p2=s.control(scope,d.id,'paused',d2.revision,'pause-two');
  s.control(scope,d.id,'active',p2.revision,'resume-two');
  assert.equal(s.projection(scope).sources[0].allowed,false);
  assert.ok(resumed.revision>paused.revision);
});

test('memory deletion purges persisted replay context, blocks old provenance and rejects late results', () => {
  const path=file(); const s=new AssistantService(new DurableStore(path),{clock:()=>1000000000000});
  const d=s.createDelegation(scope,draft,'create');
  const m=s.addMemory(scope,d.id,'SYNTHETIC_PRIVATE_MEMORY','synthetic-message','memory');
  const run=s.enqueue(scope,d.id,'run'); const c=s.claim('worker'); s.beginModelCall(c);
  s.forgetMemory(scope,m.id,m.revision,'forget');
  assert.throws(()=>s.publish(c,'late result'),{code:'lease_lost'});
  const fresh=new AssistantService(new DurableStore(path),{clock:()=>1000000000000});
  assert.equal(fresh.getRun(scope,run.id).frozen_request,null);
  assert.equal(fresh.projection(scope).memories[0].content,'');
  assert.throws(()=>fresh.addMemory(scope,d.id,'paraphrase','synthetic-message','rebuild'),{code:'memory_source_suppressed'});
  const next=fresh.enqueue(scope,d.id,'next');
  assert.ok(!next.frozen_request.payloadJSON.includes('SYNTHETIC_PRIVATE_MEMORY'));
});

test('approval binds exact artifact version and hash; editing invalidates it and duplicates do not dispatch', () => {
  const s=new AssistantService(new DurableStore(file()),{clock:()=>1000000000000});
  const d=s.createDelegation(scope,draft,'create'); s.enqueue(scope,d.id,'run'); const c=s.claim('w');
  const a=s.publish(c,'version one');
  assert.equal(s.publish(c,'version one').current_reference.version,1);
  const ap=s.prepareApproval(scope,a.id,a.current_reference,'synthetic-review-target','prepare');
  const approved=s.decideApproval(scope,ap.id,ap.revision,ap.action_digest,'approve','decide');
  assert.equal(approved.status,'approved'); assert.equal(approved.receipt,'not_started');
  assert.equal(s.decideApproval(scope,ap.id,ap.revision,ap.action_digest,'approve','decide').status,'approved');
  const a2=s.editArtifact(scope,a.id,1,'version two','edit');
  assert.equal(a2.current_reference.version,2);
  assert.equal(a2.versions[0].body,'version one');
  assert.equal(s.projection(scope).approvals[0].status,'invalidated');
  assert.throws(()=>s.prepareApproval(scope,a.id,a.current_reference,'synthetic-review-target','old'),{code:'approval_stale'});
  assert.throws(()=>s.editArtifact(scope,a.id,1,'stale edit','bad-edit'),{code:'conflict'});
});

test('scheduler coalesces missed checks across restart; run success does not end the delegation', () => {
  const path=file();let now=1000000000000;
  const s=new AssistantService(new DurableStore(path),{clock:()=>now});
  const d=s.createDelegation(scope,draft,'create');now+=3600000*3;
  assert.equal(s.scheduleDue().length,1);
  const restarted=new AssistantService(new DurableStore(path),{clock:()=>now});
  assert.equal(restarted.scheduleDue().length,0);
  const claim=restarted.claim('w');restarted.publish(claim,'synthetic');
  assert.equal(restarted.getDelegation(scope,d.id).state,'active');
  now+=3600000;assert.equal(restarted.scheduleDue().length,1);
  const unchanged=restarted.publish(restarted.claim('w'),'synthetic');
  assert.equal(unchanged.current_reference.version,1);
  assert.equal(restarted.projection(scope).runs.at(-1).outcome,'no_change');
});

test('idempotency conflicts, scope boundaries and per-run max three model calls survive restart', () => {
  const path=file(); const s=new AssistantService(new DurableStore(path),{clock:()=>1000000000000});
  const d=s.createDelegation(scope,draft,'create');
  assert.throws(()=>s.createDelegation(scope,{...draft,goal:'different'},'create'),{code:'idempotency_conflict'});
  const other={...scope,profile_id:'11111111-1111-4111-8111-111111111111'};
  assert.throws(()=>s.getDelegation(other,d.id),{code:'scope_mismatch'});
  s.enqueue(scope,d.id,'run');const c=s.claim('w');
  for(let i=0;i<3;i++) s.beginModelCall(c);
  const restarted=new AssistantService(new DurableStore(path),{clock:()=>1000000000000});
  assert.throws(()=>restarted.beginModelCall(c),{code:'call_limit'});
  assert.equal(restarted.projection(other).artifacts.length,0);
});

test('actual process exit restores a mock run with fencing and recovers a dead transaction lock', async () => {
  const {spawnSync}=await import('node:child_process');
  const path=file();let now=1000000000000;
  const s=new AssistantService(new DurableStore(path),{clock:()=>now});
  const d=s.createDelegation(scope,draft,'create');const run=s.enqueue(scope,d.id,'run');
  const helper=new URL('./process-helper.mjs',import.meta.url);
  const first=spawnSync(process.execPath,[helper.pathname,'crash-after-call',path]);assert.equal(first.status,86);
  assert.equal(s.getRun(scope,run.id).model_calls,1);
  assert.equal(s.claim('early'),null);
  now+=60001;
  const recovered=new AssistantService(new DurableStore(path),{clock:()=>now});
  const c=recovered.claim('recovery');assert.equal(c.run.id,run.id);assert.equal(c.token,2);
  recovered.beginModelCall(c);recovered.publish(c,'after restart');
  assert.equal(recovered.getRun(scope,run.id).model_calls,2);
  const died=spawnSync(process.execPath,[helper.pathname,'crash-in-transaction',path]);assert.equal(died.status,87);
  // Next transaction proves the owner PID is dead; a separate recovery lock serializes cleanup.
  const stillThere=new AssistantService(new DurableStore(path),{clock:()=>now});
  assert.equal(stillThere.claim('none'),null);
  assert.equal(stillThere.getArtifact(scope,stillThere.getRun(scope,run.id).artifact_ids[0]).versions[0].body,'after restart');
});

test('parallel process claimants admit one winning lease', async () => {
  const {spawn}=await import('node:child_process');
  const path=file();const s=new AssistantService(new DurableStore(path),{clock:()=>1000000000000});
  const d=s.createDelegation(scope,draft,'create');const run=s.enqueue(scope,d.id,'run');
  const outputs=await Promise.all(Array.from({length:4},()=>new Promise((resolve,reject)=>{
    const child=spawn(process.execPath,[new URL('./process-helper.mjs',import.meta.url).pathname,'claim',path]);
    let text='';child.stdout.on('data',x=>text+=x);child.on('error',reject);child.on('exit',code=>code===0?resolve(JSON.parse(text)):reject(new Error('child failed')));
  })));
  assert.equal(outputs.filter(x=>x?.run===run.id).length,1);
  assert.ok(outputs.every(x=>x===null||x.run===run.id||x.code==='store_locked'));
  assert.equal(s.getRun(scope,run.id).attempt_count,1);
});
