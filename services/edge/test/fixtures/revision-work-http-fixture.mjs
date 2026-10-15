import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../../supabase/functions/_shared/api.mjs';
import {readConfig} from '../../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {boundedTick} from '../../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-tick.mjs';
import {singleStepHandler} from '../../supabase/functions/_shared/core/src/single-step-handler.mjs';
import {PublicWebReader} from '../../supabase/functions/_shared/public-web-reader.mjs';
import {ApiError,hash} from '../../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TASK_REVISION_WORK_CONTRACT,validatePublicRevisionWorkReceipt} from '../../supabase/functions/_shared/core/src/task-revision-work-contract.mjs';

// Actual maintained HTTP/chat/worker ports with serialized in-memory persistence,
// explicit injected authority, model and TLS. No live Auth/model/SQL/network proof.
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
export const REVISION_RAW='Add risk to conclusion two; retain the other findings.\n中文 / \ufeff \u0085 exact raw';
const PLAN={title:'Offline report',goal:'Compare supplied fictional findings',requirements:'Save and verify a useful report',stop_conditions:['Saved and verified'],steps:['compose','save','verify'].map(id=>({id,title:id,detail:''}))};
const DOC='The fictional public document contains reviewed findings and current risk evidence.';
const POLICY={schema_version:1,contract:'catpaw.public-web-policy.v1',origins:[{origin:'https://docs.example.org',connect_ipv4:'93.184.216.34',path_prefixes:['/docs/']}]};
const call=(name,args)=>({type:'tool_call',id:randomUUID(),name,arguments:args}),done={type:'done',finish_reason:'tool_calls'};
export async function revisionWorkHTTPFixture({sourced=false,autoKick=false,correction=false,originalContext=[]}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}},fresh={...principal,session_id:randomUUID()},foreign={...principal,subject_id:randomUUID(),session_id:randomUUID()},outsideScope={...scope,scope_id:randomUUID()},outside={...principal,subject_id:randomUUID(),session_id:randomUUID(),scopes:[outsideScope]};
 const calls=[],retained=[],hooks={},mode={};let reads=0,tickCount=0,now=Date.now(),fixture;
 const choose=auth=>auth==='Bearer fresh'?fresh:auth==='Bearer foreign'?foreign:auth==='Bearer outside'?outside:principal;
 const once=async key=>{const hook=hooks[key];if(hook){delete hooks[key];await hook(fixture);}};
 const net={async connect({hostname}){assert.equal(hostname,'93.184.216.34');return {remoteAddr:{hostname,port:443},close(){}};},async startTls(tcp,{hostname}){
  assert.equal(hostname,'docs.example.org');reads++;const isRevision=reads>1;let offset=0;
  const bytes=new TextEncoder().encode(`HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${new TextEncoder().encode(DOC).length}\r\n\r\n${DOC}`);
  return {remoteAddr:tcp.remoteAddr,async handshake(){return {alpnProtocol:'http/1.1'};},async write(b){if(isRevision&&mode.sourceUnknown)throw Error('offline_original_source_result_lost');return b.length;},async read(b){if(offset===bytes.length)return null;if(offset===0&&isRevision)await once('beforeSourceResult');const n=Math.min(b.length,bytes.length-offset);b.set(bytes.subarray(offset,offset+n));offset+=n;return n;},close(){tcp.close();}};
 }};
 const provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',async *stream(input){
  calls.push(input);
  if(!input.tools.length){yield {type:'text_delta',text:'Read-only explanation of the selected report.'};yield {type:'done',finish_reason:'stop'};return;}
  if(input.tools.some(t=>['delegate_task','delegate_plan_v1','delegate_sources_v1'].includes(t.function.name))){yield call(sourced?'delegate_sources_v1':'delegate_plan_v1',{...PLAN,...sourced?{source_urls:['https://docs.example.org/docs/one']}:{}});yield done;return;}
  const revisionTool=input.tools.find(t=>['revise_current_report_v1','revise_current_report_work_v1'].includes(t.function.name));
  if(revisionTool){await once('beforeRevisionChatResult');if(mode.chatUnknown)throw Error('offline_original_chat_result_lost');yield call(revisionTool.function.name,{requirements:'Revise conclusion two with risk'});yield done;return;}
  const initial=JSON.parse(input.messages[0].content),revision=initial.task_revision_context;
  if(revision){
   assert.equal(hash(revision.raw_instruction),revision.instruction_hash);assert.ok(revision.base_body.includes('Original conclusion two')||revision.base_body.includes('explicit risk'));
   assert.equal(initial.applied_plan.revision,revision.plan_reference.revision);assert.ok(initial.applied_plan.revision>=2);
   assert.deepEqual(input.provider_context.input_context.slice(-2),[{text:revision.raw_instruction},{text:revision.base_body}]);
   assert.equal(input.provider_context.revision_source_auth.session_id,fresh.session_id);
   assert.equal(input.provider_context.source_auth.session_id,fresh.session_id,'new execution uses its fresh finite source');
   assert.equal(input.provider_context.revision_original_source_auth.session_id,principal.session_id,'old source remains provenance only');
   await once('beforeRevisionWorkerResult');if(mode.modelUnknown)throw Error('offline_original_model_result_lost');
  }
  if(sourced&&!input.messages.some(m=>m.role==='tool')){yield call('read_public_sources_v1',{});yield done;return;}
  const intermediate=revision&&correction&&!input.messages.some(m=>m.role==='tool'&&m.content.includes('"saved":true'));
  yield call(sourced?'save_sourced_report_v1':'save_artifact',{title:PLAN.title,summary:revision?'Revised conclusion with risk':'Original report',content:(intermediate?'Intermediate report awaiting a corrected risk section.':revision?'Conclusion two now includes explicit risk.':'Original conclusion two.')+' '+DOC,...sourced?{citations:[{source_id:'source-1',quote:DOC}]}:{}});
  if(!intermediate)yield call('finish_task',{summary:'Saved and verified'});yield done;
 }};
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard',...sourced?{CATPAW_PUBLIC_SOURCE_POLICY:JSON.stringify(POLICY)}:{}},config=readConfig(k=>values[k]);
 const checkSource=async(tx,source,identity,allowExpired)=>{
  if(source.scope_id!==identity.scope_id)throw new ApiError(409,'grant_conflict');
  const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);
  if(row?.subject_id!==source.subject_id||row.state!=='active'||!allowExpired&&row.expires_at<=Math.floor(now/1000))throw new ApiError(409,'grant_conflict');
 };
 const sourceChecker=(tx,source,identity)=>checkSource(tx,source,identity,false),acceptedChecker=(tx,source,identity)=>checkSource(tx,source,identity,true);
 const runtime=await createCloudRuntime({repository,config,provider,sourceChecker,acceptedSourceChecker:acceptedChecker,acceptedControlSourceChecker:acceptedChecker,verifyToken:async auth=>{const p=choose(auth);return {iss:p.issuer,sub:p.subject_id,session_id:p.session_id,exp:9999999999};},authenticate:choose,autoKick,kickOptions:{maxSlices:12,maxWallMs:60000,now:()=>now,sleep:async ms=>{now+=ms;}},retain:p=>retained.push(p),publicSourceReader:sourced?new PublicWebReader({policy:POLICY,net,clock:()=>now}):null,diagnostic:()=>{}});
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);
 await repository.transaction(async tx=>{for(const p of [principal,fresh,foreign,outside]){await tx.put(membershipOwner(p.issuer),'scope-memberships',{id:p.subject_id,scopes:p.scopes});await tx.put(membershipOwner(p.issuer),'app-sessions',{id:p.session_id,subject_id:p.subject_id,state:'active',expires_at:9999999999});}});
 const owner=runtime.facade.owner(scope),cid=randomUUID(),base=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,path=`/catpaw/revisions/v1/scopes/${scope.scope_id}/conversations/${cid}/turns`,workPath=`/catpaw/revision-work/v1/scopes/${scope.scope_id}/conversations/${cid}/turns`;
 const req=(path,body,auth='Bearer original')=>runtime.api(new Request('https://offline.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:auth,'Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}}));
 const rawReq=(path,raw,auth='Bearer fresh')=>runtime.api(new Request('https://offline.example.invalid'+path,{method:'POST',headers:{Authorization:auth,'Content-Type':'application/json'},body:raw}));
 const json=async(response,status=200)=>{const value=await response.json();assert.equal(response.status,status,JSON.stringify(value));return value;};
 await json(await req(base,{conversation_id:cid}),201);await json(await req(`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash}));
 runtime.facade.workGrantService.now=()=>now;
 if(runtime.sourceService)runtime.sourceService.clock=()=>now;
 const originalTurn=randomUUID(),originalInput={turn_id:originalTurn,expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'Save a report from supplied fictional information https://docs.example.org/docs/one'},context:structuredClone(originalContext)};
 const originalWork={decision_id:randomUUID(),input_hash:hash(originalInput),route_hash:config.routeHash,tool_policy:sourced?'public_sources_v1':'local_output_v1',not_after:new Date(now+600000).toISOString(),execution_budget_ms:300000,limits:{due:1,model:4,source:sourced?3:0}};
 const response=await req(`/catpaw/accepted-work/v1/scopes/${scope.scope_id}/conversations/${cid}/turns`,{schema_version:1,contract:'catpaw.accepted-work-intent.v1',turn:originalInput,work:originalWork});assert.equal(response.status,200);await response.body.getReader().cancel();await runtime.chat.waitIdle();await Promise.all(retained);
 const rows=kind=>repository.transaction(tx=>tx.list(owner,kind)),binding=(await json(await req(`${base}/${cid}/turns/${originalTurn}`))).turn.task_bindings[0];
 const tick=async()=>{tickCount++;now=Math.max(now,Date.now())+100;const result=await boundedTick({repository,owners:[owner],admitTask:runtime.facade.admittedTask.bind(runtime.facade),runStep:singleStepHandler(runtime.facade,runtime.provider),workGrantService:runtime.facade.workGrantService,now:()=>now,budgetMs:10000,settleReserveMs:500,leaseMs:20000});now+=10000;return result;};
 const settle=async(count=10)=>{for(let i=0;i<count;i++)await tick();};await settle();
 const [run]=await rows('catpaw-runs'),[task]=await rows('tasks');assert.equal(task.status,'succeeded');
 const makeRequest=async({text=REVISION_RAW,context=[],work={}}={})=>{
  const [conversation]=await rows('native-chat-conversations'),[currentRun]=await rows('catpaw-runs'),[currentTask]=await rows('tasks');
  const turn={turn_id:randomUUID(),expected_revision:conversation.revision,expected_grant_epoch:conversation.grant_epoch,message:{id:randomUUID(),text},context:structuredClone(context)};
  const target={intent:'revise_report',run_id:currentRun.id,task_id:currentTask.id,artifact_reference:structuredClone(currentRun.artifact_references[0]),expected_grant_epoch:currentRun.grant_epoch,expected_plan_revision:currentTask.state.plan_binding.revision,expected_plan_hash:currentTask.state.plan_binding.plan_hash};
  return {schema_version:1,contract:TASK_REVISION_WORK_CONTRACT,turn,target,work:{decision_id:randomUUID(),input_hash:hash({turn,target}),route_hash:config.routeHash,tool_policy:sourced?'public_sources_v1':'local_output_v1',not_after:new Date(now+300000).toISOString(),execution_budget_ms:240000,limits:{due:1,model:4,source:sourced?3:0},...work}};
 };
 const inputRequest=await makeRequest(),input={turn:inputRequest.turn,target:inputRequest.target};
 const readTurn=async(request,auth='Bearer fresh')=>(await json(await req(workPath+'/'+request.turn.turn_id,undefined,auth))).turn;
 const operationPath=id=>`/catpaw/revision-work/v1/scopes/${scope.scope_id}/runs/${run.id}/operations/${id}`;
 const readOperation=async(id,auth='Bearer fresh')=>validatePublicRevisionWorkReceipt(await json(await req(operationPath(id),undefined,auth)));
 const accept=async(request,auth='Bearer fresh')=>{const result=await req(workPath,request,auth);if(result.status!==200){const error=await result.json();assert.fail(JSON.stringify({status:result.status,body:error}));}await result.body.getReader().cancel();await runtime.chat.waitIdle();await Promise.all(retained);return readTurn(request,auth);};
 const mutateSession=async(p,patch)=>repository.transaction(async tx=>{const key=membershipOwner(p.issuer),old=await tx.get(key,'app-sessions',p.session_id);await tx.put(key,'app-sessions',{...old,...patch});});
 const invalidate=async(reason,request)=>{
  if(reason==='fresh-source')return mutateSession(fresh,{state:'revoked'});
  if(reason==='generation')return repository.transaction(tx=>tx.withScope(scope.scope_id,async scoped=>{const old=await scoped.scope();await scoped.saveScope({...old,generation:old.generation+1});}));
  return repository.transaction(async tx=>{
   if(reason==='revision-source'){const old=await tx.get(owner,'native-chat-turns',request.turn.turn_id);await tx.put(owner,'native-chat-turns',{...old,content_redacted:true});return;}
   if(reason==='conversation'){const old=await tx.get(owner,'native-chat-conversations',cid);await tx.put(owner,'native-chat-conversations',{...old,state:'revoked',grant_epoch:old.grant_epoch+1});return;}
   const old=await tx.get(owner,'tasks',task.id);
   if(reason==='lease')await tx.put(owner,'tasks',{...old,leaseId:randomUUID()});
   else if(reason==='delegation'){const d=await tx.get(owner,'catpaw-delegations',run.delegation_id);await tx.put(owner,'catpaw-delegations',{...d,state:'revoked',revision:d.revision+1,grant_epoch:d.grant_epoch+1});}
   else throw Error('unsupported invalidation');
  });
 };
 fixture={repository,runtime,scope,principal,fresh,foreign,outside,owner,cid,rows,binding,run,task,input,path,workPath,req,rawReq,json,readTurn,operationPath,readOperation,accept,makeRequest,settle,tick,calls,config,originalWork,hooks,mode,invalidate,mutateSession,now:()=>now,advance:ms=>{now+=ms;},reads:()=>reads,ticks:()=>tickCount,stop:()=>runtime.worker.stop()};
 return fixture;
}
