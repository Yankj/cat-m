// Actual maintenance Cloud composition with SERIALIZED synthetic rows and an
// injected provider. These wires prove neither real Auth/PG nor model availability.
import assert from 'node:assert/strict';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {createCloudRuntime} from '../../supabase/functions/_shared/api.mjs';
import {readConfig} from '../../supabase/functions/_shared/config.mjs';
import {consentId} from '../../supabase/functions/_shared/consent.mjs';
import {membershipOwner,assertAcceptedWorkSourceAuthority,assertAcceptedWorkControlSourceAuthority} from '../../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {check,hash,canonical,clone} from '../../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {ACCEPTED_WORK_INTENT_CONTRACT} from '../../supabase/functions/_shared/core/src/accepted-work-intent-contract.mjs';
import {TASK_WORK_GRANT_KINDS as K} from '../../supabase/functions/_shared/core/src/task-work-grant-contract.mjs';
import {boundedTick} from '../../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-tick.mjs';
import {singleStepHandler} from '../../supabase/functions/_shared/core/src/single-step-handler.mjs';

globalThis.fetch=()=>{throw Error('native_accepted_work_fixture_external_network_forbidden');};
const id=n=>`51000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const PLAN={title:'有限工作原生样例',goal:'整理明确提供的虚构资料',requirements:'仅使用原对话和已明确选择的文字上下文',stop_conditions:['保存并核对一份本地报告'],steps:[{id:'compose',title:'整理',detail:''},{id:'save',title:'保存',detail:''},{id:'verify',title:'核对',detail:''}]};
export function decodeFixtureSSE(raw){return raw.split('\n\n').filter(Boolean).map(packet=>{assert.ok(packet.startsWith('data: '));return JSON.parse(packet.slice(6));});}
export function nativeFixtureDomainSnapshot(repository){const snapshot=repository.snapshot();return {...snapshot,records:snapshot.records.filter(([key])=>JSON.parse(key)[1]!=='native-chat-runtime-leases')};}

export async function createNativeAcceptedWorkWireFixture({holdChat=false,modelOutcome='received',autoKick=false,snapshot=null,providerReality='injected_offline_only',sessionLifetimeSeconds=600}={}){
 if(!Number.isSafeInteger(sessionLifetimeSeconds)||sessionLifetimeSeconds<1||sessionLifetimeSeconds>21600)throw Error('synthetic_fixture_session_lifetime_invalid');
 const repository=new TestRepository(snapshot??undefined),scope={scope_id:id(1),profile_id:id(2),workspace_id:id(3),local_output:true};
 const issuer='https://native-wire.example.invalid/auth/v1',subject_id=id(4),actor={subject_id,session_id:id(5),issuer,issued_at:1,scopes:[scope],permissions:{local_output:true}};
 let principal=actor,clock=Date.now(),runtime;const calls=[],retained=[];
 let releaseChat;const chatGate=holdChat?new Promise(resolve=>{releaseChat=resolve;}):Promise.resolve();
 const transaction=repository.transaction.bind(repository);
 repository.transaction=fn=>transaction(tx=>{
  tx.connection={query:async(sql,params)=>{
   if(sql.startsWith('SELECT pg_advisory_xact_lock'))return {rows:[]};
   const kind=/kind='([^']+)'/.exec(sql)?.[1];assert.ok(['app-sessions','scope-memberships'].includes(kind));
   const row=await tx.get(params[0],kind,params[1]);return {rows:row?[{data:row}]:[]};
  }};return fn(tx);
 });
 const provider={identity:{provider:'injected-offline-only',model:'native-wire-synthetic-only',adapter_version:1},reality:providerReality,assertReady(){},async *stream(input){
  calls.push(clone({tools:input.tools,provider_context:input.provider_context}));
  if(input.tools.some(t=>t.function.name==='delegate_plan_v1')){await chatGate;yield {type:'tool_call',id:'native-wire-original-plan',name:'delegate_plan_v1',arguments:PLAN};yield {type:'done',finish_reason:'tool_calls'};return;}
  if(modelOutcome==='unknown')throw Error('synthetic_original_response_lost');
  yield {type:'tool_call',id:'native-wire-save',name:'save_artifact',arguments:{title:'原生有限工作成果',summary:'只使用虚构资料',content:'A useful synthetic report based only on the original conversation and explicitly selected fictional context.'}};
  yield {type:'tool_call',id:'native-wire-finish',name:'finish_task',arguments:{summary:'Saved and verified the original report'}};
  yield {type:'done',finish_reason:'tool_calls'};
 }};
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'native-wire-offline-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'},config=readConfig(key=>values[key]);
 const now=()=>Math.max(clock,Date.now());
 const bootRuntime=async()=>{
  runtime=await createCloudRuntime({repository,config,provider,authenticate:auth=>{check(auth==='Bearer native-wire-offline',401,'session_required');return principal;},autoKick,retain:p=>retained.push(p),diagnostic:()=>{},acceptedSourceChecker:(tx,source,identity,ref)=>assertAcceptedWorkSourceAuthority(tx,source,identity,ref,{now}),acceptedControlSourceChecker:(tx,source,identity,ref)=>assertAcceptedWorkControlSourceAuthority(tx,source,identity,ref,{now})});
  runtime.facade.workGrantService.now=now;return runtime;
 };
 await bootRuntime();if(!snapshot)await runtime.foundation.bootstrapScope(actor,scope.scope_id);const owner=runtime.facade.owner(scope);
 if(!snapshot)await repository.transaction(async tx=>{
  await tx.put(membershipOwner(issuer),'app-sessions',{id:actor.session_id,subject_id,state:'active',expires_at:Math.floor(Date.now()/1000)+sessionLifetimeSeconds});
  await tx.put(membershipOwner(issuer),'scope-memberships',{id:subject_id,state:'active',tokens_valid_after:1,revoked_session_ids:[],scopes:[scope]});
 });
 const req=(path,body)=>runtime.api(new Request('https://native-wire.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer native-wire-offline','Content-Type':'application/json'},...body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)}}));
 const json=async(path,body)=>{const response=await req(path,body);assert.ok([200,201].includes(response.status),`${path}: ${response.status} ${response.status>=400?await response.text():''}`);return response.json();};
 const cid=id(6),chatPath=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations/${cid}`,workPath=`/catpaw/accepted-work/v1/scopes/${scope.scope_id}/conversations/${cid}/turns`;
 // Restoring a local test snapshot does not issue a fresh authenticated command
 // or renew viewer authority. Even expired/revoked rows remain unchanged.
 const conversation=snapshot?{conversation:await repository.transaction(tx=>tx.get(owner,'native-chat-conversations',cid))}:await json(`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,{conversation_id:cid});assert.ok(conversation.conversation);
 const model_route=await json('/catpaw/privacy/v1/model-route');
 const consentPath=`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`;
 const consent=snapshot?{consent:await repository.transaction(tx=>tx.get(owner,'provider-consents',consentId(subject_id,cid)))}:await json(consentPath,{decision:'allow',expected_revision:0,route_hash:model_route.route_hash});
 // Exactly the current native text body: no added text schema/version, lowercase
 // UUIDs, current server revisions, and every selected context in the input hash.
 const turn={turn_id:id(7),expected_revision:conversation.conversation.revision,expected_grant_epoch:conversation.conversation.grant_epoch,message:{id:id(8),text:'请把给定虚构资料整理为本地报告。保留“原样”引用与 \"quoted\" 文本。'},context:[{id:'fictional-records',text:'虚构记录甲：已确认。\n虚构记录乙：待核对，保留 🐾。'}]};
 const work={decision_id:id(9),input_hash:hash(turn),route_hash:model_route.route_hash,tool_policy:'local_output_v1',not_after:new Date(now()+120000).toISOString(),execution_budget_ms:60000,limits:{due:1,model:1,source:0}};
 const request={schema_version:1,contract:ACCEPTED_WORK_INTENT_CONTRACT,turn,work};
 const rows=kind=>repository.transaction(tx=>tx.list(owner,kind));
 const drain=async()=>{await Promise.all([...retained,...runtime.chat.active.values()].map(value=>value.promise??value));};
 const expireOrigin=()=>repository.transaction(async tx=>{const row=await tx.get(membershipOwner(issuer),'app-sessions',actor.session_id);await tx.put(membershipOwner(issuer),'app-sessions',{...row,expires_at:0});});
 const freshViewer=async()=>{principal={...actor,session_id:id(10)};await repository.transaction(tx=>tx.put(membershipOwner(issuer),'app-sessions',{id:principal.session_id,subject_id,state:'active',expires_at:Math.floor(Date.now()/1000)+sessionLifetimeSeconds}));};
 const tick=async()=>{clock=now()+1500;return boundedTick({repository,owners:[owner],workGrantService:runtime.facade.workGrantService,admitTask:runtime.facade.admittedTask.bind(runtime.facade),runStep:singleStepHandler(runtime.facade,runtime.provider),now,budgetMs:1000,settleReserveMs:200,leaseMs:5000});};
 return {repository,scope,subject_id,actor,owner,cid,chatPath,workPath,turn,work,request,model_route,consent,calls,rows,json,req,drain,tick,now,expireOrigin,freshViewer,releaseChat:()=>releaseChat?.(),runtime:()=>runtime,stop:()=>runtime.worker.stop(),restart:async()=>{await runtime.worker.stop();await bootRuntime();}};
}

export async function generateNativeAcceptedWorkWire({providerReality='injected_offline_only'}={}){
 const f=await createNativeAcceptedWorkWireFixture({providerReality});
 try{
  const readyz=await f.json('/readyz'),post=await f.req(f.workPath,f.request);assert.equal(post.status,200);assert.equal(post.headers.get('content-type'),'text/event-stream');
  const raw=await post.text();await f.drain();const accepted_turn=await f.json(f.workPath+'/'+f.turn.turn_id),binding=accepted_turn.turn.task_bindings[0];assert.ok(binding);
  const grantPath=`/catpaw/work-grants/v1/scopes/${f.scope.scope_id}/runs/${binding.run_id}/grant`;
  const grant_accepted=await f.json(grantPath),accepted_projection=await f.json(binding.projection_url),cursor_recovery=await f.json(`${f.chatPath}/turns/${f.turn.turn_id}?after_sequence=1`),eventsRaw=await (await f.req(`${f.chatPath}/turns/${f.turn.turn_id}/events?after_sequence=1`)).text();
  await f.expireOrigin();const denied=await f.req(f.workPath+'/'+f.turn.turn_id);assert.equal(denied.status,409);const expired_viewer_error={status:denied.status,body:await denied.json()};
  for(let index=0;index<4;index++){await f.tick();if((await f.rows('tasks'))[0].status==='succeeded')break;}
  assert.equal((await f.rows('tasks'))[0].status,'succeeded');await f.freshViewer();await f.restart();
  const final_turn=await f.json(f.workPath+'/'+f.turn.turn_id),final_grant=await f.json(grantPath),final_projection=await f.json(binding.projection_url),artifactReference=final_projection.run.artifact_references[0];assert.ok(artifactReference);
  const final_artifact=await f.json(`/catpaw/artifacts/v1/scopes/${f.scope.scope_id}/runs/${binding.run_id}/artifacts/${artifactReference.artifact_id}`);
  assert.equal(f.calls.length,2);assert.equal(final_grant.receipt.task_completed,false);
  const unknown=await createNativeAcceptedWorkWireFixture({modelOutcome:'unknown',providerReality});let unknownWire;
  try{
   await (await unknown.req(unknown.workPath,unknown.request)).text();await unknown.drain();const snapshot=await unknown.json(unknown.workPath+'/'+unknown.turn.turn_id),original=snapshot.turn.task_bindings[0];await unknown.tick();
   assert.equal((await unknown.rows('tasks'))[0].status,'outcome_unknown');
   unknownWire={request:unknown.request,turn:snapshot,grant:await unknown.json(`/catpaw/work-grants/v1/scopes/${unknown.scope.scope_id}/runs/${original.run_id}/grant`),control:await unknown.json(`/catpaw/controls/v1/scopes/${unknown.scope.scope_id}/runs/${original.run_id}/control`),projection:await unknown.json(original.projection_url)};
  }finally{await unknown.stop();}
  return {schema_version:1,fixture_kind:providerReality==='injected_test_provider'?'actual_cloud_offline_accepted_work_wire_v3':'actual_cloud_offline_accepted_work_wire_v2',scope:{scope_id:f.scope.scope_id,profile_id:f.scope.profile_id,workspace_id:f.scope.workspace_id},subject_id:f.subject_id,request:f.request,canonical_turn:canonical(f.turn),input_hash:hash(f.turn),binding,readyz,model_route:f.model_route,consent:f.consent,acceptance_sse:{content_type:post.headers.get('content-type'),raw,events:decodeFixtureSSE(raw)},accepted_turn,accepted_projection,cursor_recovery,cursor_sse:{raw:eventsRaw,events:decodeFixtureSSE(eventsRaw)},grant_accepted,expired_viewer_error,final_turn,final_grant,final_projection,final_artifact,unknown:unknownWire,provenance:{runtime:'actual maintained createCloudRuntime',repository:'serialized TestRepository',provider:providerReality,network:'deny-net; global fetch throws',real_auth:false,real_model:false,real_sql:false,device:false,contract_acceptance:false}};
 }finally{await f.stop();}
}

if(import.meta.main){
 const output=resolve(Deno.args[0]??'services/edge/build/native-accepted-work-20261015/native-accepted-work-wire-v2.json');
 const wire=await generateNativeAcceptedWorkWire({providerReality:Deno.args[1]==='--native-events'?'injected_test_provider':'injected_offline_only'});
 const paths=['services/edge/test/fixtures/generate-native-accepted-work-wire.mjs','services/edge/supabase/functions/_shared/api.mjs','services/edge/supabase/functions/_shared/authority.mjs','services/edge/supabase/functions/_shared/core/src/accepted-work-intent-contract.mjs','services/edge/supabase/functions/_shared/core/src/chat-service.mjs','services/edge/supabase/functions/_shared/core/src/local-output-facade.mjs','services/edge/supabase/functions/_shared/core/src/task-work-grant-contract.mjs','services/edge/supabase/functions/_shared/core/src/task-work-grant-service.mjs','services/edge/supabase/functions/_shared/core/src/accepted-work-execution.mjs'];
 wire.provenance.source_hashes=Object.fromEntries(await Promise.all(paths.map(async path=>[path,hash(await readFile(path,'utf8'))])));
 await mkdir(dirname(output),{recursive:true});const raw=JSON.stringify(wire,null,2)+'\n';await writeFile(output,raw);console.log(JSON.stringify({path:output,sha256:hash(raw),input_hash:wire.input_hash,provider_calls:2}));
}
