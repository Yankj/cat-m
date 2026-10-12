import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm,writeFile,readFile} from 'node:fs/promises';
import {FileRepository} from '../../src/file-repository.mjs';
import {createRuntime} from '../../src/runtime.mjs';
import {startSyntheticServer} from '../../src/server.mjs';
import {auth,scope,input,admission,decision} from '../../test/harness.mjs';
const trace=[];
async function isolated(t,fixture='preview_unknown') {
  const dir=await mkdtemp(new URL('../data/http-',import.meta.url).pathname),path=dir+'/rows.json';
  const runtime=await createRuntime({repository:await FileRepository.open(path)});
  let server;
  t.after(async()=>{if(server)await server.close();await rm(dir,{recursive:true,force:true});});
  server=await startSyntheticServer({port:0,runtime});
  // Own service only. Manual real TaskWorker ticks keep expiry/race assertions deterministic.
  await runtime.worker.stop();
  const base=server.origin+`/catpaw/v1/scopes/${scope}`;
  const request=async(method,route,body,authorization=auth)=>{
    const response=await fetch(base+route,{method,headers:{authorization,'content-type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});
    const dto=await response.json();trace.push({test:t.name,origin:server.origin,method,route,request:body,status:response.status,dto});return {status:response.status,dto};
  };
  const d=input(fixture),a=admission();assert.equal((await request('POST','/delegations',d)).status,201);assert.equal((await request('POST',`/delegations/${d.delegation_id}/runs`,a)).status,201);
  // stop() makes this worker deliberately inert; a fresh runtime is used solely for this owned repository.
  const fresh=await createRuntime({repository:runtime.repository});await fresh.worker.tick();
  const run=(await request('GET',`/runs/${a.run_id}`)).dto.run,id=run.approval_ids[0],p=(await request('GET',`/approvals/${id}`)).dto.approval;
  t.after(()=>fresh.worker.stop());
  return {runtime:fresh,request,d,a,id,p,path,owner:fresh.facade.owner({profile_id:'11111111-1111-4111-8111-111111111111',workspace_id:scope})};
}
test('H01 real HTTP expired approval returns 409 and commits expiry',async t=>{
  const h=await isolated(t,'preview');await h.runtime.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',h.id,{status:'awaiting_review'},{expiresAt:'2000-01-01T00:00:00.000Z'}));
  const result=await h.request('POST',`/approvals/${h.id}/decisions`,decision(h.p));
  const stored=(await h.request('GET',`/approvals/${h.id}`)).dto.approval.status;console.log('H01 actual',result.status,result.dto.error?.code,stored);assert.equal(result.status,409);assert.equal(stored,'expired');
});
for(const [name,value] of [['null',null],['array',[]],['empty string',''],['number',0]])test(`H02 real HTTP rejects reconciliation ${name}`,async t=>{
  const h=await isolated(t);const receipt=await h.request('POST',`/approvals/${h.id}/decisions`,decision(h.p));assert.equal(receipt.dto.approval.status,'outcome_unknown');
  const result=await h.request('POST',`/approvals/${h.id}/reconciliation-checks`,value);console.log('H02 actual',name,result.status,result.dto.error?.code);assert.equal(result.status,422);
});
test('H03 real HTTP unknown duplicate decision and repeated reconciliation never dispatch again',async t=>{
  const h=await isolated(t);const first=await h.request('POST',`/approvals/${h.id}/decisions`,decision(h.p));assert.equal(first.dto.approval.status,'outcome_unknown');
  const duplicate=await h.request('POST',`/approvals/${h.id}/decisions`,decision(h.p));assert.equal(duplicate.status,409);assert.equal(duplicate.dto.error.code,'outcome_unknown');assert.equal(duplicate.dto.error.reconciliation_required,true);
  for(let i=0;i<3;i++){const r=await h.request('POST',`/approvals/${h.id}/reconciliation-checks`,{});assert.equal(r.status,200);assert.equal(r.dto.approval.reconciliation.can_retry,false);assert.equal(r.dto.approval.status,'outcome_unknown');}
  const rows=JSON.parse(await readFile(h.path,'utf8')).rows;assert.equal(rows.filter(([k])=>JSON.parse(k)[1]==='catpaw-preview-effects').length,1);
});
test('H04 real HTTP simultaneous identical admission is 201 then 200; conflict leaves one task',async t=>{
  const h=await isolated(t,'preview');
  const d=input(),a=admission();assert.equal((await h.request('POST','/delegations',d)).status,201);
  const replay=await Promise.all([h.request('POST',`/delegations/${d.delegation_id}/runs`,a),h.request('POST',`/delegations/${d.delegation_id}/runs`,a)]);assert.deepEqual(replay.map(x=>x.status).sort(),[200,201]);assert.equal(replay[0].dto.run.task_id,replay[1].dto.run.task_id);
  const denied=await h.request('POST',`/delegations/${d.delegation_id}/runs`,{...a,run_id:input().delegation_id});assert.equal(denied.status,409);assert.equal(denied.dto.error.code,'operation_conflict');
  const rows=JSON.parse(await readFile(h.path,'utf8')).rows;assert.equal(rows.filter(([k,v])=>JSON.parse(k)[1]==='tasks'&&v.state.catpaw.delegation_id===d.delegation_id).length,1);
});
test('H05 real HTTP pause-resume fences pending old approval and requires a fresh Run',async t=>{
  const h=await isolated(t,'preview');assert.equal((await h.request('POST',`/delegations/${h.d.delegation_id}/control`,{action:'pause',expected_revision:1,expected_grant_epoch:1})).status,200);
  assert.equal((await h.request('POST',`/approvals/${h.id}/decisions`,decision(h.p))).status,409);
  assert.equal((await h.request('POST',`/delegations/${h.d.delegation_id}/control`,{action:'resume',expected_revision:2,expected_grant_epoch:2})).status,200);
  assert.equal((await h.request('POST',`/approvals/${h.id}/decisions`,{...decision(h.p),expected_grant_epoch:3})).status,409);
  const next={...admission(),expected_revision:3,expected_grant_epoch:3};assert.equal((await h.request('POST',`/delegations/${h.d.delegation_id}/runs`,next)).status,201);
  await h.runtime.worker.tick();assert.equal((await h.request('GET',`/runs/${next.run_id}`)).dto.run.state,'waiting_approval');assert.equal((await h.request('GET',`/runs/${h.a.run_id}`)).dto.run.authorization_state,'superseded');
  assert.equal((await h.runtime.repository.transaction(tx=>tx.list(h.owner,'catpaw-preview-effects'))).length,0);
});
test.after(async()=>{await writeFile(new URL('../evidence/loopback-negative-trace.json',import.meta.url),JSON.stringify({synthetic_only:true,real_model:false,sql:false,trace},null,2)+'\n');});
