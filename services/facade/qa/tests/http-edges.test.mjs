import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm,writeFile,readFile} from 'node:fs/promises';
import {FileRepository} from '../../src/file-repository.mjs';
import {createRuntime} from '../../src/runtime.mjs';
import {startSyntheticServer} from '../../src/server.mjs';
import {AppError} from '../../patched-openmuse/apps/server/src/errors.ts';
import {auth,scope,input,admission,decision} from '../../test/harness.mjs';
import {SYNTHETIC_SCOPE} from '../../src/common.mjs';
const trace=[];
async function setup(t){
  const dir=await mkdtemp(new URL('../data/http-edges-',import.meta.url).pathname),path=dir+'/rows.json';let server,runtime;
  t.after(async()=>{await runtime?.worker.stop();await server?.close();await rm(dir,{recursive:true,force:true});});
  runtime=await createRuntime({repository:await FileRepository.open(path)});server=await startSyntheticServer({port:0,runtime});
  // Drain startup's worker-status transaction before requesting deterministic manual ticks.
  await runtime.worker.tick();await runtime.worker.stop();
  const request=async(method,route,body,{raw=false,authorization=auth}={})=>{const response=await fetch(server.origin+route,{method,headers:{authorization,'content-type':'application/json'},...(body===undefined?{}:{body:raw?body:JSON.stringify(body)})});const dto=await response.json();trace.push({case:t.name,origin:server.origin,method,route,request:typeof body==='string'&&body.length>200?{byte_length:Buffer.byteLength(body)}:body,status:response.status,dto});return {status:response.status,dto};};
  const base=`/catpaw/v1/scopes/${scope}`;
  const pending=async()=>{const d=input('preview'),a=admission();assert.equal((await request('POST',base+'/delegations',d)).status,201);assert.equal((await request('POST',base+`/delegations/${d.delegation_id}/runs`,a)).status,201);const workerRuntime=await createRuntime({repository:runtime.repository});await workerRuntime.worker.tick();await workerRuntime.worker.stop();const run=(await request('GET',base+`/runs/${a.run_id}`)).dto.run,id=run.approval_ids[0],p=(await request('GET',base+`/approvals/${id}`)).dto.approval;return {id,p};};
  return {runtime,path,request,base,pending,owner:runtime.facade.owner(SYNTHETIC_SCOPE)};
}
test('HE01 expired deny returns HTTP 409 and durable expired; wrong digest stays fenced',async t=>{
  const h=await setup(t),{id,p}=await h.pending();await h.runtime.repository.transaction(tx=>tx.compareAndSwap(h.owner,'actions',id,{status:'awaiting_review'},{expiresAt:'2000-01-01T00:00:00.000Z'}));
  const bad=await h.request('POST',h.base+`/approvals/${id}/decisions`,{...decision(p),action_digest:'wrong'});assert.equal(bad.status,409);assert.equal(bad.dto.error.code,'approval_stale');assert.equal((await h.request('GET',h.base+`/approvals/${id}`)).dto.approval.status,'awaiting_review');
  const expired=await h.request('POST',h.base+`/approvals/${id}/decisions`,{...decision(p),decision:'deny'});assert.equal(expired.status,409);assert.equal(expired.dto.error.code,'approval_consumed');assert.equal(expired.dto.error.retryable,false);assert.equal((await h.request('GET',h.base+`/approvals/${id}`)).dto.approval.status,'expired');
  const rows=JSON.parse(await readFile(h.path,'utf8')).rows;assert.equal(rows.find(([k,v])=>JSON.parse(k)[1]==='actions'&&v.id===id)[1].status,'expired');assert.equal(rows.filter(([k])=>JSON.parse(k)[1]==='catpaw-preview-effects').length,0);
});
test('HE02 strict JSON, body size, empty-object shape and auth hold over real HTTP',async t=>{
  const h=await setup(t),route=h.base+'/approvals/unused/reconciliation-checks';
  for(const [body,status,code] of [['{',422,'schema_invalid'],[' '.repeat(32769),413,'request_too_large'],['{"extra":true}',422,'schema_invalid']]){const r=await h.request('POST',route,body,{raw:true});assert.equal(r.status,status);assert.equal(r.dto.error.code,code);assert.equal(r.dto.error.retryable,false);}
  const r=await h.request('GET','/catpaw/v1/capabilities',undefined,{authorization:''});assert.equal(r.status,401);assert.equal(r.dto.error.code,'session_required');
});
for(const known of [true,false])test(`HE03 unrelated authority error known=${known} remains an error and rolls back writes`,async t=>{
  const h=await setup(t),{id,p}=await h.pending();h.runtime.facade.actionsFor=tx=>({decide:async()=>{await tx.put(h.owner,'catpaw-preview-effects',{id:'should-not-exist'});throw known?new AppError('Independent authority failure',409):new Error('Independent authority failure');}});
  const r=await h.request('POST',h.base+`/approvals/${id}/decisions`,decision(p));assert.equal(r.status,known?409:500);assert.equal(r.dto.error.code,known?'approval_stale':'internal_error');assert.equal(r.dto.error.retryable,false);assert(!r.dto.error.message.includes('Independent'));
  assert.equal((await h.request('GET',h.base+`/approvals/${id}`)).dto.approval.status,'awaiting_review');const rows=JSON.parse(await readFile(h.path,'utf8')).rows;assert.equal(rows.filter(([k])=>JSON.parse(k)[1]==='catpaw-preview-effects').length,0);
});
test.after(()=>writeFile(new URL('../evidence/http-edges-trace.json',import.meta.url),JSON.stringify({synthetic_only:true,sql:false,external_calls:false,trace},null,2)+'\n'));
