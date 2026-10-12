import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp,rm,writeFile,readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { hash,SYNTHETIC_SCOPE } from '../src/common.mjs';
const childPath=fileURLToPath(new URL('./child-loopback.mjs',import.meta.url));
const evidencePath=fileURLToPath(new URL('../evidence/process-http-trace.json',import.meta.url));
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function launch(path) {
  const child=spawn(process.execPath,['--experimental-transform-types',childPath,path],{stdio:['ignore','pipe','pipe']});let out='',err='';
  child.stderr.on('data',d=>err+=d);const exit=new Promise(r=>child.once('exit',(code,signal)=>r({code,signal})));
  const origin=await new Promise((ok,fail)=>{const timer=setTimeout(()=>{child.kill('SIGTERM');fail(new Error('Synthetic server startup timeout'));},5000);child.stdout.on('data',d=>{out+=d;const line=out.split('\n')[0];try{const value=JSON.parse(line);clearTimeout(timer);ok(value.origin);}catch{}});child.once('exit',code=>{clearTimeout(timer);fail(new Error(`Synthetic server exited ${code}; ${err}`));});});
  return {origin,stop:async()=>{child.kill('SIGTERM');const status=await exit;assert.equal(status.code,0);}};
}
test('real HTTP + process restart: persistent run, approval, artifact and unknown receipt survive independently of clients',{timeout:20000},async()=>{
  const dir=await mkdtemp(resolve(tmpdir(),'catpaw-facade-')),path=resolve(dir,'synthetic.json'),trace=[];let server;
  const scope=SYNTHETIC_SCOPE.scope_id,base=`/catpaw/v1/scopes/${scope}`;
  const request=async(method,route,body)=>{
    const response=await fetch(server.origin+route,{method,headers:{authorization:'Bearer synthetic-only','content-type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});
    const dto=await response.json();trace.push({method,path:route,status:response.status,dto});assert(response.ok,JSON.stringify(dto));return dto;
  };
  const waitRun=async(id,states)=>{const until=Date.now()+7000;while(Date.now()<until){const dto=await request('GET',`${base}/runs/${id}`);if(states.includes(dto.run.state))return dto;await delay(40);}throw new Error('Synthetic task did not settle');};
  try{
    server=await launch(path);
    const delegation_id=randomUUID(),operation_id=randomUUID(),run_id=randomUUID();
    await request('POST',`${base}/delegations`,{delegation_id,title:'Synthetic restart preview',goal:'Compare two fixed synthetic records',requirements:'Use no connectors',stop_conditions:['Stop after a preview proposal'],synthetic_fixture_id:'preview_unknown'});
    await request('POST',`${base}/delegations/${delegation_id}/runs`,{operation_id,run_id,expected_revision:1,expected_grant_epoch:1});
    // All HTTP connections may close; no streaming run handle exists.
    const waiting=await waitRun(run_id,['waiting_approval']),ref=waiting.run.artifact_references[0],approvalID=waiting.run.approval_ids[0];
    await server.stop();server=undefined;
    server=await launch(path);
    const recovered=await request('GET',`${base}/operations/${operation_id}`);assert.equal(recovered.run.id,run_id);assert.equal(recovered.run.task_id,waiting.run.task_id);assert.equal(recovered.run.state,'waiting_approval');
    const artifact=await request('GET',`${base}/artifacts/${ref.artifact_id}/versions/${ref.version}`);assert.equal(hash(artifact.artifact.body),ref.content_hash);
    const approval=(await request('GET',`${base}/approvals/${approvalID}`)).approval;
    const receipt=await request('POST',`${base}/approvals/${approvalID}/decisions`,{decision:'approve',upstream_hash:approval.upstream_hash,action_digest:approval.action_digest,expected_grant_epoch:approval.grant_epoch});assert.equal(receipt.approval.status,'outcome_unknown');
    await server.stop();server=undefined;server=await launch(path);
    const reread=await request('GET',`${base}/approvals/${approvalID}`);assert.equal(reread.approval.receipt_status,'unknown');
    const checked=await request('POST',`${base}/approvals/${approvalID}/reconciliation-checks`,{});assert.equal(checked.approval.status,'outcome_unknown');assert.equal(checked.approval.reconciliation.state,'resolved_local');
    const disk=JSON.parse(await readFile(path,'utf8'));assert.equal(disk.rows.filter(([k])=>JSON.parse(k)[1]==='catpaw-preview-effects').length,1);
    await writeFile(evidencePath,JSON.stringify({layer:'actual_upstream_worker_and_patched_actionservice_single_process_file_HTTP',real_model:false,intelligence:false,sql:false,synthetic_only:true,process_starts:3,stable_run_id:run_id,trace},null,2)+'\n');
  }finally{if(server)await server.stop();await rm(dir,{recursive:true,force:true});}
});
