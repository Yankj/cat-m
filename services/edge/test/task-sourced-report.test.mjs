import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {PublicWebReader} from '../supabase/functions/_shared/public-web-reader.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {boundedTick} from '../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-tick.mjs';
import {singleStepHandler} from '../supabase/functions/_shared/core/src/single-step-handler.mjs';
import {ApiError,hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {SOURCE_READS,SOURCE_RECEIPTS} from '../supabase/functions/_shared/core/src/task-source-service.mjs';

// HTTP and TLS are injected byte streams, never public network or real models.
globalThis.fetch=()=>{throw Error('public_network_forbidden');};
const POLICY={schema_version:1,contract:'catpaw.public-web-policy.v1',origins:[{origin:'https://docs.example.org',connect_ipv4:'93.184.216.34',path_prefixes:['/docs/']}]};
const URLS=[1,2,3].map(n=>`https://docs.example.org/docs/${n}`),QUOTE='The fictional candidate supports bounded public document reading.';
const CONTENT={title:'公开资料比较计划',goal:'比较用户提供的三个虚构页面',requirements:'按相同标准整理',stop_conditions:['实际读取来源，保存有引用的报告并核对'],steps:[{id:'compose',title:'读取并比较资料',detail:'三个用户网址'},{id:'save',title:'保存带来源成果',detail:''},{id:'verify',title:'核对来源与成果',detail:''}]};
const event=(name,arguments_)=>({type:'tool_call',id:randomUUID(),name,arguments:arguments_}),DONE={type:'done',finish_reason:'tool_calls'};
async function fixture({mode='normal',urls=URLS,userText=URLS.join(' '),readFailure=false,onWrite=null,sourceText=QUOTE}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}},calls=[],retained=[];
 let reads=0,workers=0,f,now=Date.now(),sourceCurrent=true;
 const net={async connect({hostname}){assert.equal(hostname,POLICY.origins[0].connect_ipv4);return {remoteAddr:{hostname,port:443},close(){}};},async startTls(tcp,options){assert.equal(options.hostname,'docs.example.org');let offset=0;const text=`${sourceText} Source ${++reads}.`,bytes=new TextEncoder().encode(`HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${new TextEncoder().encode(text).length}\r\n\r\n${text}`);return {remoteAddr:tcp.remoteAddr,async handshake(){return {alpnProtocol:'http/1.1'};},async write(b){if(onWrite)await onWrite(f);if(readFailure)throw Error('synthetic_original_read_lost');return b.length;},async read(b){if(offset===bytes.length)return null;const n=Math.min(b.length,bytes.length-offset);b.set(bytes.subarray(offset,offset+n));offset+=n;return n;},close(){tcp.close();}};}};
 const reader=new PublicWebReader({policy:POLICY,net}),provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',async *stream(input){
  calls.push(input);
  if(input.tools.some(t=>t.function.name==='delegate_task')){yield event('delegate_sources_v1',{...CONTENT,source_urls:urls});yield DONE;return;}
  workers++;
  if((workers===1&&mode!=='bypass')||(mode==='adaptive'&&workers===2)){yield event('read_public_sources_v1',{});yield DONE;return;}
  if(mode==='legacy-tool'){yield event('save_artifact',{title:'禁止绕过',summary:'无来源',content:'尝试旧工具绕过来源验证'});yield DONE;return;}
  const citations=urls.map((_,i)=>({source_id:`source-${i+1}`,quote:mode==='forged'?'A fabricated quotation not present in any actual receipt.':QUOTE}));
  yield event('save_sourced_report_v1',{title:'资料比较成果',summary:'三份实际注入页面的比较',content:'| 方案 | 依据 |\n|---|---|\n'+urls.map((_,i)=>`| 方案${i+1} | [source-${i+1}] ${QUOTE} |`).join('\n'),citations});yield event('finish_task',{summary:'对应当前来源回执的成果已验证'});yield DONE;
 }};
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard',CATPAW_PUBLIC_SOURCE_POLICY:JSON.stringify(POLICY)},config=readConfig(k=>values[k]);
 const sourceChecker=async(tx,source)=>{const row=await tx.get(membershipOwner(principal.issuer),'app-sessions',source.session_id);if(!sourceCurrent||row?.subject_id!==principal.subject_id||row.state!=='active')throw new ApiError(409,'grant_conflict');};
 const runtime=await createCloudRuntime({repository,config,provider,publicSourceReader:reader,sourceChecker,authenticate:()=>principal,autoKick:false,retain:p=>retained.push(p),diagnostic:()=>{}});
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);await repository.transaction(tx=>tx.put(membershipOwner(principal.issuer),'app-sessions',{id:principal.session_id,subject_id:principal.subject_id,state:'active',expires_at:9999999999}));
 const req=(path,body)=>runtime.api(new Request('https://offline.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer offline','Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}}));
 const cid=randomUUID(),base=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,turnID=randomUUID();
 await req(base,{conversation_id:cid});await req(`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash});
 const response=await req(`${base}/${cid}/turns`,{turn_id:turnID,expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:`请比较这些虚构公开资料并保存报告：${userText}`},context:[]});assert.equal(response.status,200);await response.body.getReader().cancel();await Promise.all(retained);
 const turn=(await (await req(`${base}/${cid}/turns/${turnID}`)).json()).turn,binding=turn.task_bindings[0],owner=runtime.facade.owner(scope);
 f={runtime,repository,scope,principal,owner,turn,binding,calls,config,req,revoke:()=>{sourceCurrent=false;},reads:()=>reads,workers:()=>workers,stop:()=>runtime.worker.stop(),row:()=>repository.transaction(tx=>tx.get(owner,'tasks',binding.task_id)),rows:kind=>repository.transaction(tx=>tx.list(owner,kind)),tick:async()=>{now=Math.max(now,Date.now())+100;const r=await boundedTick({repository,owners:[owner],admitTask:runtime.facade.admittedTask.bind(runtime.facade),runStep:singleStepHandler(runtime.facade,runtime.provider),now:()=>now,budgetMs:10000,settleReserveMs:500,leaseMs:20000});now+=10000;return r;}};
 return f;
}
test('actual byte receipt to original bounded model report completes within six steps with server-built sources',async()=>{
 const f=await fixture();try{
  assert.ok(f.binding);for(let i=0;i<6;i++)await f.tick();const task=await f.row();assert.equal(task.status,'succeeded');assert.equal(f.reads(),3);assert.equal(f.workers(),2);
  const sourceRows=await f.rows(SOURCE_RECEIPTS);assert.equal(sourceRows.length,3);assert.ok(sourceRows.every(r=>r.transport_reality==='injected_offline_only'));
  const artifacts=await f.rows('catpaw-artifact-versions');assert.equal(artifacts.length,1);const body=JSON.parse(artifacts[0].body);assert.equal(hash(artifacts[0].body),artifacts[0].content_hash);assert.equal(body.data.source_contract,'sourced-report-v1');assert.deepEqual(body.data.sources.map(s=>s.requested_url),URLS);assert.equal(body.data.citations.length,3);assert.ok(body.data.sources.every(s=>sourceRows.some(r=>r.id===s.read_id&&r.content_hash===s.content_hash)));
  const plan=(await (await f.req(`/catpaw/plans/v1/scopes/${f.scope.scope_id}/runs/${f.binding.run_id}/plan`)).json()).plan;assert.deepEqual(plan.step_receipts.map(r=>r.step_id),['compose','save','verify']);assert.equal(f.calls[2].provider_context.input_context.length,1);
  const catalog=await f.req(`/catpaw/sources/v1/scopes/${f.scope.scope_id}/runs/${f.binding.run_id}/sources`);assert.equal(catalog.status,200);assert.ok((await catalog.json()).reads.every(r=>r.state==='received'));assert.equal(f.reads(),3);
 }finally{await f.stop();}
});
test('invented model URL cannot create a task or expand authenticated user URL authority',async()=>{
 const f=await fixture({urls:[URLS[0]],userText:URLS[1]});try{assert.equal(f.turn.task_bindings.length,0);assert.equal(f.turn.state,'failed');assert.equal(f.reads(),0);assert.equal((await f.rows('tasks')).length,0);}finally{await f.stop();}
});
test('existing whole worker yields a due continuation and completes the same sourced report without a new scheduler',async()=>{
 const f=await fixture();try{
  let now=Date.now()+100;f.runtime.worker.options.now=()=>now;
  await f.runtime.worker.tick();let task=await f.row();assert.equal(task.status,'scheduled');assert.ok(Number.isFinite(Date.parse(task.nextRunAt)));assert.equal(f.reads(),3);
  now=Date.parse(task.nextRunAt)+100;await f.runtime.worker.tick();task=await f.row();assert.equal(task.status,'succeeded');assert.equal(f.reads(),3);assert.equal(f.workers(),2);assert.equal((await f.rows('tasks')).length,1);
 }finally{await f.stop();}
});
for(const denied of ['cancel','revoke'])test(`whole worker final source save await ${denied} rolls back artifact, compose/save receipts and cursor together`,async()=>{
 const f=await fixture();try{
  let now=Date.now()+100;f.runtime.worker.options.now=()=>now;await f.runtime.worker.tick();const before=await f.row();now=Date.parse(before.nextRunAt)+100;
  const originalTransaction=f.repository.transaction.bind(f.repository);let intercepted=false;
  f.repository.transaction=callback=>originalTransaction(async tx=>{
   const put=tx.put.bind(tx);tx.put=async(owner,kind,row)=>{
    const stored=await put(owner,kind,row);
    if(!intercepted&&owner===f.owner&&kind==='tasks'&&row.state?.local_model?.artifact&&row.state.local_model.round?.next===1){intercepted=true;if(denied==='cancel')f.runtime.worker.abort(row.id);else f.revoke();await Promise.resolve();}
    return stored;
   };return callback(tx);
  });
  await f.runtime.worker.tick();assert.equal(intercepted,true);assert.equal((await f.rows('catpaw-artifact-versions')).length,0);assert.equal((await f.rows('catpaw-task-plan-receipts')).length,0);
  const task=await f.row();assert.notEqual(task.status,'succeeded');assert.equal(task.state.local_model.round.next,0);assert.equal(task.state.local_model.artifact,null);assert.equal(f.reads(),3);
 }finally{await f.stop();}
});
for(const mode of ['bypass','forged','legacy-tool'])test(`source ${mode} cannot publish or complete without required bound evidence`,async()=>{
 const f=await fixture({mode});try{for(let i=0;i<6;i++)await f.tick();assert.notEqual((await f.row()).status,'succeeded');assert.equal((await f.rows('catpaw-artifact-versions')).length,0);const receipts=await f.rows('catpaw-task-plan-receipts');assert.equal(receipts.length,0);}finally{await f.stop();}
});
test('unknown original read is never replayed and blocks an amended plan while retaining same task',async()=>{
 const f=await fixture({readFailure:true});try{
  await f.tick();await f.tick();assert.equal((await f.row()).status,'outcome_unknown');assert.equal(f.reads(),1);for(let i=0;i<3;i++)assert.equal((await f.tick()).claimed,0);assert.equal(f.reads(),1);assert.equal((await f.rows(SOURCE_READS))[0].state,'dispatched');
  const path=`/catpaw/plans/v1/scopes/${f.scope.scope_id}/runs/${f.binding.run_id}/plan`,plan=(await (await f.req(path)).json()).plan;
  const result=await f.req(path+'/amendments',{operation_id:randomUUID(),expected_revision:1,expected_plan_hash:plan.accepted_plan_hash,expected_grant_epoch:1,content:{...CONTENT,requirements:'未知原读取必须先恢复'}});assert.equal(result.status,200);const next=(await result.json()).plan;assert.equal(next.application_state,'blocked_unknown');assert.equal(next.applied_revision,1);assert.equal((await f.rows('tasks')).length,1);
 }finally{await f.stop();}
});
test('received sensitive source text is checked before the subsequent existing model route dispatch',async()=>{
 const f=await fixture({sourceText:QUOTE+' This fictional document contains medical record details.'});try{
  for(let i=0;i<6;i++)await f.tick();assert.equal(f.reads(),3);assert.equal(f.workers(),1);assert.equal(f.calls.length,2);assert.notEqual((await f.row()).status,'succeeded');assert.equal((await f.rows('catpaw-artifact-versions')).length,0);
 }finally{await f.stop();}
});
for(const mode of ['normal','adaptive'])test(`amendment during a received read ${mode==='adaptive'?'completes with new v2 receipts':'cannot consume v1 receipts for v2'}`,async()=>{
 let amended=false;const f=await fixture({mode,onWrite:async f=>{if(amended)return;amended=true;const path=`/catpaw/plans/v1/scopes/${f.scope.scope_id}/runs/${f.binding.run_id}/plan`,plan=(await (await f.req(path)).json()).plan;const r=await f.req(path+'/amendments',{operation_id:randomUUID(),expected_revision:1,expected_plan_hash:plan.accepted_plan_hash,expected_grant_epoch:1,content:{...CONTENT,requirements:'第二版的新比较要求'}});assert.equal(r.status,200);assert.equal((await r.json()).plan.application_state,'blocked_unknown');}});try{
  // First version's reads remain historical. The amended plan is applied only
  // after all received operations in its original model round have settled.
  for(let i=0;i<15;i++)await f.tick();const plan=(await (await f.req(`/catpaw/plans/v1/scopes/${f.scope.scope_id}/runs/${f.binding.run_id}/plan`)).json()).plan;
  assert.equal(plan.applied_revision,2);assert.equal((await f.rows('tasks')).length,1);assert.ok((await f.rows(SOURCE_RECEIPTS)).some(r=>r.plan_reference.revision===1));assert.ok(plan.step_receipts.every(r=>r.plan_revision===2));
  if(mode==='adaptive'){
   assert.equal((await f.row()).status,'succeeded');assert.equal(f.reads(),6);assert.equal((await f.rows(SOURCE_RECEIPTS)).filter(r=>r.plan_reference.revision===2).length,3);assert.equal((await f.rows('catpaw-artifact-versions'))[0].plan_reference.revision,2);return;
  }
  assert.notEqual((await f.row()).status,'succeeded');
  // The deliberately non-adaptive fixture does not reread v2. It cannot turn
  // valid v1 citations into a v2 completion receipt.
  assert.equal((await f.rows('catpaw-artifact-versions')).length,0);
 }finally{await f.stop();}
});
