import {kickTurnTasks} from './worker-kick.mjs';
import {checkTextConsent} from './sensitivity.mjs';
import {Buffer} from 'node:buffer';
import {randomUUID} from 'node:crypto';import {ApiError,check,hash,UUID,iso} from './core/facade-r2/src/common.mjs';
import {createFoundationChatRuntime} from './core/src/foundation-runtime.mjs';import {OpenRouterProvider} from './core/src/openrouter-provider.mjs';
import {boundedTick} from './core/integration/edge-adapter/src/bounded-tick.mjs';import {singleStepHandler} from './core/src/single-step-handler.mjs';
import {assertSourceAuthority,revokeAppSession} from './authority.mjs';import {assertConsent,consentId,consentRead,consentWrite} from './consent.mjs';import {authorizeTick} from './tick-auth.mjs';
import {createChatMetrics} from './core/src/chat-metrics.mjs';
import {TASK_ACTION_CONTRACT,TASK_ACTION_LIMITS,taskActionUUID} from './core/src/task-action-contract.mjs';
import {readTaskAction,readTaskActions,proposeTaskAction,decideTaskAction} from './core/src/task-action-service.mjs';
import {TaskSourceService} from './core/src/task-source-service.mjs';
import {validatePublicSourcePolicy,sourcePolicyHash} from './core/src/public-source-contract.mjs';
import {PublicWebReader} from './public-web-reader.mjs';
import {TASK_ARTIFACT_CONTRACT,TASK_ARTIFACT_LIMITS,taskArtifactUUID,taskArtifactID,taskArtifactVersion} from './core/src/task-artifact-contract.mjs';
import {readTaskArtifact,readTaskArtifactOperation,amendTaskArtifact} from './core/src/task-artifact-service.mjs';
import {TASK_REVISION_CONTRACT} from './core/src/task-revision-contract.mjs';
import {assertTaskRevisionAuthorityInTransaction} from './core/src/task-revision-service.mjs';
import {TASK_CONTROL_CONTRACT,TASK_CONTROL_LIMITS,taskControlRevision,parseTaskControlJSON} from './core/src/task-control-contract.mjs';
import {readTaskControl,controlTask} from './core/src/task-control-service.mjs';
const reply=(v,status=200)=>Response.json({schema_version:1,...v},{status,headers:{'Cache-Control':'no-store'}});
export async function createCloudRuntime({repository,authenticate,config,retain=(_promise)=>{},sourceChecker=assertSourceAuthority,provider=null,verifyToken=null,autoKick=true,kickOptions={},diagnostic=entry=>console.info(JSON.stringify(entry)),taskActionTargetVerifier=null,publicSourceReader=null}){
 const chatMetrics=createChatMetrics({sink:diagnostic});repository.metrics=chatMetrics;
 const beforeModel=async context=>{
   check(context?.source_auth&&context.scope_id===context.source_auth.scope_id,403,'provider_context_required');
   await repository.transaction(async tx=>tx.withScope(context.scope_id,async scoped=>{
     const scopeRow=await scoped.scope(),scope=scopeRow.identity;
     const verify=async()=>{
       await sourceChecker(tx,context.source_auth,scope);
       const consent=await assertConsent(tx,scope.owner,context.source_auth,context.conversation_id,config.routeHash);
       if(context.task_execution){
         const execution=context.task_execution;
         const {task,run}=await runtime.facade.admittedTask(tx,scope.owner,execution.task_id,{running:true});
         check(run.id===execution.run_id&&run.request_hash===execution.run_request_hash&&run.frozen_request.conversation_id===context.conversation_id&&run.frozen_request.scope.scope_id===context.scope_id&&task.leaseId===execution.lease_id&&Date.parse(task.leaseUntil)>Date.now()&&taskControlRevision(task)===execution.execution_revision,409,'execution_permission_changed');
       }
       if(context.revision_source_auth){
         const fresh=context.revision_source_auth,original=context.revision_original_source_auth;
         check(original&&fresh.subject_id===context.source_auth.subject_id&&fresh.scope_id===scope.scope_id&&fresh.consent_revision===original.consent_revision,403,'revision_consent_conflict');
         check(context.revision_memory_generation===scopeRow.generation,409,'memory_generation_superseded');
         await sourceChecker(tx,original,scope);await assertConsent(tx,scope.owner,original,context.conversation_id,config.routeHash);
         await sourceChecker(tx,fresh,scope);await assertConsent(tx,scope.owner,fresh,context.conversation_id,config.routeHash);
       }
       return consent;
     };
     const consent=await verify(),conversation=await tx.get(scope.owner,'native-chat-conversations',context.conversation_id);
     checkTextConsent(JSON.stringify(conversation?.messages??[])+JSON.stringify(context.input_context??[]),consent);
     const date=new Date().toISOString().slice(0,10),id=`${context.source_auth.subject_id}:${date}`;
     await tx.lock('system:provider-budget','daily-model-calls',id);const old=await tx.get('system:provider-budget','daily-model-calls',id);
     check((old?.count??0)<config.dailyCallLimit,429,'model_daily_limit');await tx.put('system:provider-budget','daily-model-calls',{id,count:(old?.count??0)+1});
     await verify();
   }));
 };
 const transport=provider??new OpenRouterProvider({model:config.route.model,secret:config.modelKey,liveNetworkEnabled:true,timeoutMs:config.modelTimeoutMs,privateRoutingPolicy:config.route.routing_policy,beforeStream:async()=>{},expectedProviderDisplay:config.route.downstream_provider});
 transport.chatMetrics=chatMetrics;
 const guarded={identity:transport.identity,get reality(){return transport.reality;},assertReady:()=>transport.assertReady?.(),async *stream(input){yield*transport.stream(input);}};
 const runtime=await createFoundationChatRuntime({repository,authenticate,provider:guarded,guardKey:config.guardKey,dataClass:'private',leaseMs:60000,chatOptions:{finishOnDelegationReceipt:true,metrics:chatMetrics},beforeProviderRequest:async input=>{const started=chatMetrics.now();try{await beforeModel(input.provider_context);}finally{chatMetrics.record('provider_admission',started);}},routePolicy:{id:config.route.id,free:true,allow_private_with_consent:true,synthetic_only:false,data_classes:['private'],allow_sensitive:true}});
 runtime.chat.modelBudgetMs=config.chatBudgetMs;runtime.chat.providerTimeoutMs=config.modelTimeoutMs;runtime.chat.finalizationReserveMs=config.chatFinalizationReserveMs;runtime.chat.pollMs=250;
 runtime.chat.beforeTurnAdmission=async(tx,{principal,scope,conversation,turn})=>{const source={subject_id:principal.subject_id,scope_id:scope.scope_id,issuer:principal.issuer,session_id:principal.session_id,issued_at:principal.issued_at};await sourceChecker(tx,source,scope);const row=await tx.get(runtime.facade.owner(scope),'provider-consents',consentId(principal.subject_id,conversation.id));check(row?.decision==='allow'&&row.route_hash===config.routeHash,403,'provider_consent_required');checkTextConsent(JSON.stringify(conversation.messages)+JSON.stringify(turn.input),row);return {...source,consent_revision:row.revision};};
 // Serialize best-effort kicks for the same accepted turn. This is invocation
 // retention only; durable admission/lease/state still live in the original Store.
 const turnKicks=new Map();
 const kickAcceptedTurn=async context=>{
   const key=`${context.owner}:${context.turnId}`;
   while(turnKicks.has(key))await turnKicks.get(key);
   const work=Promise.resolve().then(()=>kickTurnTasks(runtime,context,kickOptions)).catch(()=>{/* durable task remains authoritative */});
   turnKicks.set(key,work);try{await work;}finally{if(turnKicks.get(key)===work)turnKicks.delete(key);}
 };
 runtime.facade.onPlanAmendmentAccepted=({owner,turn_id,source_auth})=>{
   if(!autoKick||!source_auth)return;
   // No viewer/presentation authority: use exactly the original admitted source.
   retain(kickAcceptedTurn({owner,turnId:turn_id,principal:{subject_id:source_auth.subject_id,session_id:source_auth.session_id}}));
 };
 runtime.facade.onTaskRevisionAccepted=runtime.facade.onPlanAmendmentAccepted;
 runtime.facade.onTaskControlAccepted=runtime.facade.onPlanAmendmentAccepted;
 const originalAdmission=runtime.facade.admittedTask.bind(runtime.facade);
 runtime.facade.admittedTask=async(tx,owner,id,options={})=>{const admitted=await originalAdmission(tx,owner,id,options),f=admitted.run.frozen_request;check(hash(f)===admitted.run.request_hash,409,'run_request_binding_conflict');await sourceChecker(tx,f.source_auth,f.scope);await assertConsent(tx,owner,f.source_auth,f.conversation_id,config.routeHash);await assertTaskRevisionAuthorityInTransaction(runtime.facade,tx,owner,admitted.run,admitted.task);return admitted;};
 runtime.facade.beforePlanRead=async(tx,{owner,scope,principal,run})=>{
   const source={subject_id:principal.subject_id,session_id:principal.session_id,issuer:principal.issuer,issued_at:principal.issued_at,scope_id:scope.scope_id};
   await sourceChecker(tx,source,scope);
   const row=await tx.get(owner,'provider-consents',consentId(principal.subject_id,run.frozen_request.conversation_id));
   check(row?.decision==='allow'&&row.scope_id===scope.scope_id&&row.route_hash===config.routeHash,403,'provider_consent_required');
 };
 runtime.facade.beforePlanWrite=async(tx,ctx)=>{
   await runtime.facade.beforePlanRead(tx,ctx);
   const frozen=ctx.run.frozen_request;await sourceChecker(tx,frozen.source_auth,frozen.scope);
   const consent=await assertConsent(tx,ctx.owner,frozen.source_auth,frozen.conversation_id,config.routeHash);
   checkTextConsent(JSON.stringify(ctx.content??{}),consent);
 };
 runtime.facade.beforeActionRead=async(tx,ctx)=>{
   const viewer={subject_id:ctx.principal.subject_id,session_id:ctx.principal.session_id,issuer:ctx.principal.issuer,issued_at:ctx.principal.issued_at,scope_id:ctx.scope.scope_id};
   await sourceChecker(tx,viewer,ctx.scope); // A historical original decision never bypasses current viewer authentication.
   const frozen=ctx.run.frozen_request;
   try{await sourceChecker(tx,frozen.source_auth,frozen.scope);await assertConsent(tx,ctx.owner,frozen.source_auth,frozen.conversation_id,config.routeHash);return {source_current:true};}
   catch(error){if(error instanceof ApiError&&[403,409].includes(error.status)&&['grant_conflict','provider_consent_required','session_revoked'].includes(error.code))return {source_current:false};throw error;}
 };
 runtime.facade.beforeActionWrite=async(tx,ctx)=>{
   const current=await runtime.facade.beforeActionRead(tx,ctx);check(current.source_current,403,'action_source_not_current');
   check(typeof taskActionTargetVerifier==='function',503,'action_target_verifier_not_configured');
   const target=ctx.input?.target??ctx.action?.frozen.target;check(target,422,'action_target_invalid');
   // The verifier is a trusted composition port; neither model nor HTTP fields may install it or assert a result.
   const verified=await taskActionTargetVerifier(tx,{...ctx,target});check(verified?.verified===true,403,'action_target_not_verified');
   // Target verification may await. Fence the same original source/consent again before the write hook returns.
   const final=await runtime.facade.beforeActionRead(tx,ctx);check(final.source_current,403,'action_source_not_current');return final;
 };
 runtime.facade.beforeSourceRead=async(tx,ctx)=>runtime.facade.beforePlanRead(tx,ctx);
 runtime.facade.beforeArtifactRead=async(tx,ctx)=>runtime.facade.beforeActionRead(tx,ctx);
 runtime.facade.beforeArtifactWrite=async(tx,ctx)=>{
   const current=await runtime.facade.beforeArtifactRead(tx,ctx);
   check(current.source_current,403,'artifact_source_not_current');return current;
 };
 runtime.facade.beforeTaskRevisionRead=async(tx,ctx)=>runtime.facade.beforeActionRead(tx,ctx);
 runtime.facade.beforeTaskRevisionWrite=async(tx,ctx)=>{
   const current=await runtime.facade.beforeTaskRevisionRead(tx,ctx);
   check(current.source_current,403,'revision_source_not_current');
   const original=ctx.run.frozen_request,fresh=ctx.fresh_source_auth??ctx.turn?.source_auth;
   check(fresh?.subject_id===original.subject_id&&fresh.scope_id===original.scope.scope_id&&fresh.consent_revision===original.source_auth.consent_revision,403,'revision_consent_conflict');
   await sourceChecker(tx,fresh,original.scope);
   const consent=await assertConsent(tx,ctx.owner,fresh,original.conversation_id,config.routeHash);
   check(typeof ctx.raw_instruction==='string'&&typeof ctx.base_body==='string',409,'revision_input_context_required');
   checkTextConsent(ctx.raw_instruction+'\n'+ctx.base_body,consent);
   await sourceChecker(tx,original.source_auth,original.scope);
   await assertConsent(tx,ctx.owner,original.source_auth,original.conversation_id,config.routeHash);
   await sourceChecker(tx,fresh,original.scope);
   await assertConsent(tx,ctx.owner,fresh,original.conversation_id,config.routeHash);
   return {source_current:true};
 };
 runtime.facade.beforeTaskControlRead=async(tx,ctx)=>{
   const original=await runtime.facade.beforeActionRead(tx,ctx);
   if(!original.source_current)return {source_current:false,reason:'original_source_not_current'};
   const f=ctx.run.frozen_request;
   const row=await tx.withScope(f.scope.scope_id,async scoped=>scoped.scope());
   if(row.generation!==f.memory_generation)return {source_current:false,reason:'memory_generation_superseded'};
   try{await assertTaskRevisionAuthorityInTransaction(runtime.facade,tx,ctx.owner,ctx.run,ctx.task);}
   catch(error){if(error instanceof ApiError&&[403,409].includes(error.status)&&['grant_conflict','provider_consent_required','revision_source_not_current','revision_consent_conflict','memory_generation_superseded'].includes(error.code))return {source_current:false,reason:'revision_source_not_current'};throw error;}
   return {source_current:true,reason:null};
 };
 runtime.facade.beforeTaskControlWrite=async(tx,ctx)=>{
   const current=await runtime.facade.beforeTaskControlRead(tx,ctx);
   if(ctx.action==='resume')check(current.source_current,403,'control_source_not_current');return current;
 };
 let publicSourceUnavailable='public_source_policy_not_configured';
 const publicSourcePolicy=config.publicSourcePolicy?validatePublicSourcePolicy(config.publicSourcePolicy):null;
 const selectedSourceReader=publicSourcePolicy?(publicSourceReader??new PublicWebReader({policy:publicSourcePolicy})):null;
 runtime.facade.publicSourcePolicy=publicSourcePolicy;runtime.facade.publicSourcePolicyHash=publicSourcePolicy?sourcePolicyHash(publicSourcePolicy):null;
 runtime.facade.publicSourcesEnabled=false;
 if(publicSourcePolicy){
   publicSourceUnavailable='public_source_reader_not_configured';
   if(selectedSourceReader&&typeof selectedSourceReader.assertReady==='function'&&typeof selectedSourceReader.read==='function'){
     try{
       selectedSourceReader.assertReady();check(sourcePolicyHash(selectedSourceReader.policy)===runtime.facade.publicSourcePolicyHash&&selectedSourceReader.policyHash===runtime.facade.publicSourcePolicyHash,409,'public_source_policy_mismatch');
       runtime.facade.publicSourcesEnabled=true;publicSourceUnavailable=null;
       runtime.sourceService=new TaskSourceService({facade:runtime.facade,reader:selectedSourceReader});runtime.facade.sourceService=runtime.sourceService;
     }catch(error){publicSourceUnavailable=error instanceof ApiError?error.code:'public_source_reader_unavailable';}
   }
 }
 const originalBefore=runtime.chat.integration.beforeWrite;
 const checkTurnSource=async(tx,ctx)=>{if(ctx.turn?.source_auth){await sourceChecker(tx,ctx.turn.source_auth,{...(await tx.withScope(ctx.turn.scope_id,async scoped=>(await scoped.scope()).identity,{reuseLockedScope:true}))});await assertConsent(tx,ctx.owner,ctx.turn.source_auth,ctx.turn.conversation_id,config.routeHash);}};
 runtime.chat.integration.beforeWrite=async(tx,ctx)=>{await originalBefore(tx,ctx);await checkTurnSource(tx,ctx);};
 runtime.chat.integration.beforeFailure=async(tx,ctx)=>{
   // Failure receipts retain runtime/turn generation and scope ownership fences.
   // Only expected source/consent denial permits static terminal metadata; never content publication.
   await originalBefore(tx,ctx);
   const source=ctx.turn?.source_auth;
   if(source)check(source.scope_id===ctx.turn.scope_id&&source.subject_id===ctx.turn.subject_id,409,'failure_source_mismatch');
   try{await checkTurnSource(tx,ctx);}catch(e){
     if(e instanceof ApiError&&(e.status===409&&e.code==='grant_conflict'||e.status===403&&e.code==='provider_consent_required'))return e;
     throw e;
   }
 };
 runtime.chat.beforeObservation=async(tx,{trusted,conversation})=>{
   const {scope,principal,owner}=trusted;
   await tx.withScope(scope.scope_id,async scoped=>{
     const identity=(await scoped.scope()).identity;check(identity.owner===owner,403,'scope_forbidden');
     const source={subject_id:principal.subject_id,session_id:principal.session_id,issuer:principal.issuer,issued_at:principal.issued_at,scope_id:scope.scope_id};
     await sourceChecker(tx,source,identity);
     // Observation uses the viewer's current consent, not a model dispatch grant.
     // Model/write checks above still enforce the turn's frozen consent revision.
     const consent=await tx.get(owner,'provider-consents',consentId(principal.subject_id,conversation.id));
     check(consent?.decision==='allow'&&consent.scope_id===scope.scope_id&&consent.route_hash===config.routeHash,403,'provider_consent_required');
   });
 };
 const releaseLease=async owner=>{if([...runtime.chat.active.keys()].some(k=>k.startsWith(owner+':')))return;await repository.transaction(async tx=>{await tx.lock(owner,'native-chat-runtime-leases','runtime');const lease=await tx.get(owner,'native-chat-runtime-leases','runtime');if(lease?.holder_id===runtime.holderId)await tx.compareAndSwap(owner,'native-chat-runtime-leases','runtime',lease,{lease_until:iso()});});};
 const raw=runtime.fetchHandler;
 runtime.onAccepted=({owner,principal,turnId})=>{
   const promises=[...runtime.chat.active.values()].filter(v=>v.subject_id===principal.subject_id&&v.session_id===principal.session_id).map(v=>v.promise);
   retain(Promise.allSettled(promises).then(async()=>{await releaseLease(owner);if(autoKick)await kickAcceptedTurn({owner,principal,turnId});}));
 };
 runtime.api=async request=>{try{const url=new URL(request.url),path=url.pathname.replace(/^\/(?:functions\/v1\/)?catpaw-api(?=\/|$)/,'')||'/';
  if(path==='/healthz')return reply({status:'alive'});
  if(path==='/readyz'){await repository.transaction(async()=>{});return reply({ready:true,model_route:config.route.id,authentication:'supabase_signed_jwt_and_fresh_session',execution:'bounded-chat-and-original-task-worker',chat_capabilities:{schema_version:1,text_input:true,image_input:false,live_weather:false,web_search:false,tools:['delegate_task','delegate_plan_v1','agent_status',...runtime.facade.publicSourcesEnabled?['delegate_sources_v1']:[]],task_plan:{contract:'catpaw.task-plan.v1',read:true,amend:true,local_report_only:true},task_artifacts:{contract:TASK_ARTIFACT_CONTRACT,read:true,amend:true,manual_revision:true,model_revision:false},task_revisions:{contract:TASK_REVISION_CONTRACT,revise:true,explain:true,same_task:true,immutable_target:true},task_controls:{contract:TASK_CONTROL_CONTRACT,read:true,pause:true,resume:true,revoke:true,same_task:true,pause_preserves_grant:true,unknown_resend:false,live_verification:"not_verified"},task_actions:{contract:TASK_ACTION_CONTRACT,review:true,decision:typeof taskActionTargetVerifier==='function',execution:false,device_calendar_write:false,unavailable_reason:typeof taskActionTargetVerifier==='function'?'device_executor_not_configured':'action_target_verifier_not_configured'},public_sources:{enabled:runtime.facade.publicSourcesEnabled,limited_to_user_urls:true,max_sources:3,policy_hash:runtime.facade.publicSourcePolicyHash,unavailable_reason:publicSourceUnavailable,transport_reality:runtime.facade.publicSourcesEnabled?selectedSourceReader.reality??'capability_unverified':null,live_verification:'not_verified'},durable_acceptance:'turn_started',cursor_events:true}});}
  const auth=request.headers.get('authorization');
  if(path.startsWith('/catpaw/controls/v1/')){
    check(!url.search,422,'control_schema_invalid');const parts=path.split('/').filter(Boolean);
    check(parts[3]==='scopes'&&parts[5]==='runs'&&parts[7]==='control'&&UUID.test(parts[4]??'')&&UUID.test(parts[6]??''),422,'control_schema_invalid');
    const scope=parts[4],run=parts[6];
    if(parts.length===8&&request.method==='GET')return reply(await readTaskControl(runtime.facade,auth,scope,run));
    if(parts.length===10&&parts[8]==='operations'&&request.method==='GET'&&UUID.test(parts[9]))return reply(await readTaskControl(runtime.facade,auth,scope,run,parts[9]));
    if(parts.length===9&&parts[8]==='operations'&&request.method==='POST'){
      check(Number(request.headers.get('content-length')??0)<=TASK_CONTROL_LIMITS.payload_bytes,413,'control_request_too_large');const raw=await request.text();check(Buffer.byteLength(raw)<=TASK_CONTROL_LIMITS.payload_bytes,413,'control_request_too_large');
      const input=parseTaskControlJSON(raw);
      return reply(await controlTask(runtime.facade,auth,scope,run,input,{signal:request.signal}));
    }
    throw new ApiError(404,'not_found');
  }
  if(path==='/catpaw/account/v1/logout'){check(request.method==='POST'&&typeof verifyToken==='function',405,'method_not_allowed');check((await request.text()).trim()==='{}',422,'schema_invalid');const claims=await verifyToken(auth);await revokeAppSession(repository,claims,runtime);for(const entry of runtime.chat.active.values())if(entry.subject_id===claims.sub&&entry.session_id===claims.session_id)entry.controller.abort();return reply({revoked:true,client_action:'clear_keychain_and_supabase_signout'});}
  if(path==='/catpaw/account/v1/session'){const principal=await authenticate(auth);return reply({subject_id:principal.subject_id,scopes:principal.scopes});}
  if(path==='/catpaw/privacy/v1/model-route'){await authenticate(auth);return reply({route:config.route,route_hash:config.routeHash,consent_default:'deny',sensitive_confirmation_default:false,ui:{title:'允许云端模型处理此对话？',body:`本条消息、本对话最近最多40条文本（80kB）以及你主动加入的文字上下文，将发送给OpenRouter及固定服务商${config.route.downstream_provider}，用于回复和本地报告。${publicSourcePolicy?'你明确提供并经受理的公开URL、读取的正文和来源记录，也将交给同一现有模型生成有来源的报告；只读已配置范围，不进行自主搜索。':''}不会读取邮件、日历、照片、通讯录或其他App数据。云端保存对话、任务与成果，关闭App后已授权报告任务会继续。撤销可停止后续调用，但不能收回已发送数据。`,allow:'允许此对话',deny:'暂不允许',sensitive_confirmation:'本会话含敏感信息，另外确认发送给这两个固定服务商'}});}
  const consent=/^\/catpaw\/privacy\/v1\/scopes\/([a-f0-9-]+)\/conversations\/([a-f0-9-]+)\/model-consent$/.exec(path);
  if(consent){check(UUID.test(consent[1])&&UUID.test(consent[2]),422,'schema_invalid');if(request.method==='GET')return reply({consent:await consentRead(runtime,auth,consent[1],consent[2])});check(request.method==='POST',405,'method_not_allowed');const text=await request.text();check(text.length<=2048,413,'request_too_large');return reply({consent:await consentWrite(runtime,auth,consent[1],consent[2],JSON.parse(text),config)});}
  if(path.startsWith('/catpaw/artifacts/v1/')){
    check(!url.search,422,'artifact_schema_invalid');const parts=path.split('/').filter(Boolean);
    check(parts[3]==='scopes'&&parts[5]==='runs'&&parts[7]==='artifacts',404,'not_found');
    const scope=taskArtifactUUID(parts[4]),run=taskArtifactUUID(parts[6]),artifact=taskArtifactID(parts[8]);
    if(parts.length===9&&request.method==='GET')return reply(await readTaskArtifact(runtime.facade,auth,scope,run,artifact));
    if(parts.length===11&&parts[9]==='versions'&&request.method==='GET'){
      check(/^[1-9][0-9]{0,15}$/.test(parts[10]),422,'artifact_schema_invalid');
      return reply(await readTaskArtifact(runtime.facade,auth,scope,run,artifact,{version:taskArtifactVersion(Number(parts[10]))}));
    }
    if(parts.length===10&&parts[9]==='amendments'&&request.method==='POST'){
      check(Number(request.headers.get('content-length')??0)<=TASK_ARTIFACT_LIMITS.payload_bytes,413,'artifact_request_too_large');
      const text=await request.text();check(Buffer.byteLength(text)<=TASK_ARTIFACT_LIMITS.payload_bytes,413,'artifact_request_too_large');
      let input;try{input=JSON.parse(text);}catch{throw new ApiError(422,'artifact_schema_invalid');}
      return reply(await amendTaskArtifact(runtime.facade,auth,scope,run,artifact,input,{signal:request.signal}));
    }
    if(parts.length===11&&parts[9]==='amendments'&&request.method==='GET')return reply(await readTaskArtifactOperation(runtime.facade,auth,scope,run,artifact,taskArtifactUUID(parts[10])));
    throw new ApiError(404,'not_found');
  }
  if(path.startsWith('/catpaw/actions/v1/')){
    check(!url.search,422,'action_schema_invalid');const parts=path.split('/').filter(Boolean);
    check(parts[0]==='catpaw'&&parts[1]==='actions'&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='runs'&&parts[7]==='actions',404,'not_found');
    const scope=taskActionUUID(parts[4]),run=taskActionUUID(parts[6]),action=parts[8];
    const body=async()=>{check(Number(request.headers.get('content-length')??0)<=TASK_ACTION_LIMITS.payload_bytes,413,'action_request_too_large');const text=await request.text();check(Buffer.byteLength(text)<=TASK_ACTION_LIMITS.payload_bytes,413,'action_request_too_large');try{return JSON.parse(text);}catch{throw new ApiError(422,'action_schema_invalid');}};
    if(parts.length===8&&request.method==='GET')return reply(await readTaskActions(runtime.facade,auth,scope,run));
    if(parts.length===8&&request.method==='POST')return reply(await proposeTaskAction(runtime.facade,auth,scope,run,await body()),201);
    if(parts.length===9&&request.method==='GET')return reply(await readTaskAction(runtime.facade,auth,scope,run,taskActionUUID(action)));
    if(parts.length===10&&parts[9]==='decisions'&&request.method==='POST')return reply(await decideTaskAction(runtime.facade,auth,scope,run,taskActionUUID(action),await body()));
    if(parts.length===11&&parts[9]==='decisions'&&request.method==='GET')return reply(await readTaskAction(runtime.facade,auth,scope,run,taskActionUUID(action),{decisionOperationID:taskActionUUID(parts[10])}));
    throw new ApiError(404,'not_found');
  }
  if(path.startsWith('/catpaw/sources/v1/')){
    check(!url.search,422,'schema_invalid');const parts=path.split('/').filter(Boolean);check(parts.length===8&&parts[3]==='scopes'&&parts[5]==='runs'&&parts[7]==='sources',404,'not_found');
    const scope=taskActionUUID(parts[4]),run=taskActionUUID(parts[6]);check(request.method==='GET',405,'method_not_allowed');check(runtime.sourceService,503,'source_service_not_configured');return reply(await runtime.sourceService.readCatalog(auth,scope,run));
  }
  const response=await raw(new Request(new URL(path+url.search,url.origin),request));
  return response;
 }catch(e){return reply({error:{code:e instanceof ApiError?e.code:'internal_error',retryable:false,reconciliation_required:e instanceof ApiError?e.reconciliation:false}},e instanceof ApiError?e.status:500);}};
 runtime.tick=async request=>{try{await authorizeTick(request,{secret:config.tickKey,repository});let permit=null;for(const row of await repository.transaction(tx=>tx.scan('tasks'))){const task=row.value;if(!task.state?.catpaw||!['queued','scheduled','running'].includes(task.status)||task.status==='scheduled'&&Date.parse(task.nextRunAt)>Date.now()||task.status==='running'&&Date.parse(task.leaseUntil)>Date.now())continue;try{await repository.transaction(tx=>runtime.facade.admittedTask(tx,row.owner,task.id));permit={owner:row.owner};break;}catch{}}if(!permit)return reply({tick:{claimed:0,step_calls:0,settled:[]}});const result=await boundedTick({repository,owners:[permit.owner],admitTask:runtime.facade.admittedTask.bind(runtime.facade),runStep:singleStepHandler(runtime.facade,runtime.provider),budgetMs:config.tickBudgetMs,settleReserveMs:750,leaseMs:60000});return reply({tick:{claimed:result.claimed,step_calls:result.step_calls,settled:result.settled.map(t=>({task_id:t.task_id,status:t.status,nextRunAt:t.nextRunAt}))}});}catch(e){return reply({error:{code:e instanceof ApiError?e.code:'tick_denied',retryable:false}},e instanceof ApiError?e.status:403);}};
 return runtime;
}
