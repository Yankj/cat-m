import {createRenderUITool,RENDER_UI} from './core/src/generative-ui.mjs';import {createAgentMemoryService,createAgentMemoryPrivacy} from './agent-memory/service.mjs';import {createAgentMemoryChatTools} from './agent-memory/chat-tools.mjs';import {featureAllows} from './config.mjs';import {createEnrollmentRegistry} from './enrollment/registry.mjs';import {createEnrollmentService} from './enrollment/service.mjs';import {FEATURES} from './enrollment/contract.mjs';import {createSuggestionFeed} from './proactive/suggestion-feed.mjs';import {createDeviceTools} from './core/src/device-call.mjs';
import {createTaskChatTools} from './proactive/chat-tools.mjs';import {createProactiveService} from './proactive/service.mjs';
import {createFollowupTriggerHTTPHandler} from './core/src/followup-trigger-http.mjs';
import {readInboxPage} from './core/src/inbox-service.mjs';
import {kickTurnTasks} from './worker-kick.mjs';
import {checkTextConsent} from './sensitivity.mjs';
import {Buffer} from 'node:buffer';
import {randomUUID} from 'node:crypto';import {ApiError,check,hash,UUID,iso} from './core/facade-r2/src/common.mjs';
import {createFoundationChatRuntime} from './core/src/foundation-runtime.mjs';import {OpenRouterProvider} from './core/src/openrouter-provider.mjs';import {FreeRouteChainProvider,withRoutePreference} from './core/src/free-route-chain.mjs';import {handlePushTokenRoute} from './core/src/apns.mjs';
import {boundedTick} from './core/integration/edge-adapter/src/bounded-tick.mjs';import {singleStepHandler} from './core/src/single-step-handler.mjs';
import {assertSourceAuthority,assertAcceptedWorkSourceAuthority,assertAcceptedWorkControlSourceAuthority,revokeAppSession} from './authority.mjs';import {assertConsent,consentId,consentRead,consentWrite} from './consent.mjs';import {authorizeTick} from './tick-auth.mjs';
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
import {ACCEPTED_WORK_EXECUTION_CAPABILITY,acceptedWorkClaimEligibleInTransaction} from './core/src/accepted-work-execution.mjs';
import {TaskWorkGrantService} from './core/src/task-work-grant-service.mjs';
import {TASK_WORK_GRANT_CONTRACT,TASK_REVISION_WORK_GRANT_CONTRACT,workGrantReference} from './core/src/task-work-grant-contract.mjs';
import {ACCEPTED_WORK_INTENT_CONTRACT} from './core/src/accepted-work-intent-contract.mjs';
import {lockTaskWorkSourceInTransaction,readTaskWorkGrantLifecycleInTransaction} from './core/src/task-work-grant-lifecycle.mjs';
import {resolveExecutionGrantInTransaction} from './core/src/task-work-execution-selector.mjs';
import {TASK_REVISION_WORK_CONTRACT,validateFrozenRevisionWorkIntent} from './core/src/task-revision-work-contract.mjs';
import {MEMORY_CONTRACT} from './core/src/memory-contract.mjs';
import {resolveMemoryUsageInTransaction} from './core/src/memory-service.mjs';
import {createVisionContract,boundedJsonBody} from './core/src/vision-contract.mjs';
import {assertImageConsent,imageConsent} from './image-consent.mjs';
import {LIVE_VISION_ROUTE,VISION_CONSENT_UI} from './core/src/live-vision-route.mjs';
import {AttachmentService,createStorageAdapter,ATTACHMENT_CONTRACT,ATTACHMENT_LIMITS} from './attachments.mjs';
const reply=(v,status=200)=>Response.json({schema_version:1,...v},{status,headers:{'Cache-Control':'no-store'}});
export async function createCloudRuntime({repository,authenticate,config,retain=(_promise)=>{},sourceChecker=assertSourceAuthority,provider=null,imageProvider=null,attachmentStorage=null,verifyToken=null,autoKick=true,kickOptions={},diagnostic=entry=>console.info(JSON.stringify(entry)),taskActionTargetVerifier=null,publicSourceReader=null,acceptedSourceChecker=assertAcceptedWorkSourceAuthority,acceptedControlSourceChecker=assertAcceptedWorkControlSourceAuthority,proactiveStore=null,agentMemoryStore=null,agentMemoryPrivacyStore=null,agentMemoryOptions={},enrollmentStore=null}){
 let beforeImageStream=async()=>{throw new ApiError(503,'vision_dispatch_not_configured');};
 const chatMetrics=createChatMetrics({sink:diagnostic});repository.metrics=chatMetrics;
 const beforeModel=async context=>{
   check(context?.source_auth&&context.scope_id===context.source_auth.scope_id,403,'provider_context_required');
   await repository.transaction(async tx=>tx.withScope(context.scope_id,async scoped=>{
     const scopeRow=await scoped.scope(),scope=scopeRow.identity;
     const verify=async()=>{
       const currentGeneration=(await scoped.scope()).generation;let originalRun=null,executionGrant=null;
       if(context.task_execution){
         const execution=context.task_execution;
         const {task,run}=await runtime.facade.admittedTask(tx,scope.owner,execution.task_id,{running:true});
         check(run.id===execution.run_id&&run.request_hash===execution.run_request_hash&&run.frozen_request.conversation_id===context.conversation_id&&run.frozen_request.scope.scope_id===context.scope_id&&task.leaseId===execution.lease_id&&Date.parse(task.leaseUntil)>Date.now()&&taskControlRevision(task)===execution.execution_revision,409,'execution_permission_changed');
         executionGrant=await resolveExecutionGrantInTransaction(tx,scope.owner,run,task);
         check(hash(context.source_auth)===hash(executionGrant?.source_auth??run.frozen_request.source_auth),409,'execution_source_binding_conflict');
         if(executionGrant)check(hash(context.work_grant_reference)===hash(executionGrant.reference),409,'work_grant_provider_context_conflict');
         originalRun=run;
       }
       if(originalRun)await assertRunSource(tx,originalRun);else await sourceChecker(tx,context.source_auth,scope);
       const consent=await assertConsent(tx,scope.owner,context.source_auth,context.conversation_id,config.routeHash);
       if(context.revision_source_auth){
         const fresh=context.revision_source_auth,original=context.revision_original_source_auth;
         check(original&&fresh.subject_id===context.source_auth.subject_id&&fresh.scope_id===scope.scope_id,403,'revision_consent_conflict');
         check(context.revision_memory_generation===currentGeneration,409,'memory_generation_superseded');
         if(executionGrant?.terms.schema_version===2){
           check(hash(fresh)===hash(executionGrant.source_auth)&&hash(original)===hash(originalRun.frozen_request.source_auth)&&hash(context.source_auth)===hash(fresh),409,'revision_execution_source_conflict');
           await acceptedSourceChecker(tx,fresh,scope,executionGrant.reference);
         }else if(context.revision_work_turn_id){
           const turn=await tx.get(scope.owner,'native-chat-turns',context.revision_work_turn_id),f=turn?.revision_target,c=await tx.get(scope.owner,'native-chat-conversations',context.conversation_id);
           check(turn?.id===context.revision_work_turn_id&&turn.scope_id===scope.scope_id&&turn.conversation_id===context.conversation_id&&!turn.content_redacted&&f&&hash(turn.source_auth)===hash(fresh)&&hash(context.source_auth)===hash(fresh)&&hash(f.fresh_source_auth)===hash(fresh)&&hash(f.original_source_auth)===hash(original)&&f.memory_generation===currentGeneration&&hash(context.input_context)===hash([{text:f.raw_instruction},{text:f.base_body}]),409,'revision_frozen_conflict');
           validateFrozenRevisionWorkIntent(turn.revision_work_intent,{turn,target:f.target,scope,conversation:c,routeHash:config.routeHash,callName:'revise_current_report_work_v1'});
           check(f.input_hash===hash(turn.input)&&f.instruction_hash===hash(f.raw_instruction)&&f.base_body_hash===hash(f.base_body)&&f.raw_instruction===turn.input.message.text,409,'revision_frozen_conflict');
           await sourceChecker(tx,fresh,scope);
         }else{
           check(fresh.consent_revision===original.consent_revision,403,'revision_consent_conflict');
           await sourceChecker(tx,original,scope);await assertConsent(tx,scope.owner,original,context.conversation_id,config.routeHash);
           await sourceChecker(tx,fresh,scope);
         }
         await assertConsent(tx,scope.owner,fresh,context.conversation_id,config.routeHash);
       }
       return consent;
     };
     const consent=await verify(),conversation=await tx.get(scope.owner,'native-chat-conversations',context.conversation_id);
     if(context.image_route_hash){check(vision.enabled&&context.image_route_hash===vision.routeHash,503,'image_input_unavailable');await assertImageConsent(tx,scope.owner,context.source_auth,context.conversation_id,vision.routeHash);}
     if(context.memory_usage){const current=await resolveMemoryUsageInTransaction(runtime,tx,context);check(hash(current)===hash(context.memory_context),409,'memory_context_fenced');}
     if(context.memory_context)check(![...context.memory_context.claims,...context.memory_context.conflicts.flatMap(group=>group.claims)].some(claim=>claim.sensitivity==='sensitive')||consent.sensitive_confirmed===true,403,'sensitive_content_requires_confirmation');
     checkTextConsent(JSON.stringify(conversation?.messages??[])+JSON.stringify(context.input_context??[])+JSON.stringify(context.memory_context??null),consent);
     const date=new Date().toISOString().slice(0,10),id=`${context.source_auth.subject_id}:${date}`;
     await tx.lock('system:provider-budget','daily-model-calls',id);const old=await tx.get('system:provider-budget','daily-model-calls',id);
     check((old?.count??0)<(config.dailyCallLimit??20)||config.dailyCallExempt?.has?.(String(context.source_auth.subject_id).toLowerCase()),429,'model_daily_limit');await tx.put('system:provider-budget','daily-model-calls',{id,count:(old?.count??0)+1});
     await verify();
   }));
 };
 const transport=provider??(config.freeChain?new FreeRouteChainProvider({routes:config.freeChain.routes,secrets:config.freeChain.secrets,autoFailover:config.freeChain.autoFailover,timeoutMs:config.modelTimeoutMs,beforeStream:async()=>{}}):null)??new OpenRouterProvider({model:config.route.model,secret:config.modelKey,liveNetworkEnabled:true,timeoutMs:config.modelTimeoutMs,privateRoutingPolicy:config.route.routing_policy,beforeStream:async()=>{},expectedProviderDisplay:config.route.downstream_provider});
 const imageTransport=config.visionLiveEnabled===true?(imageProvider??(provider?.visionContract?.execution_layer==='live_image_adapter'?provider:provider?null:new OpenRouterProvider({model:LIVE_VISION_ROUTE.model,secret:config.modelKey,liveNetworkEnabled:true,timeoutMs:config.modelTimeoutMs,privateRoutingPolicy:LIVE_VISION_ROUTE.routing_policy,beforeStream:async()=>{},expectedProviderDisplay:LIVE_VISION_ROUTE.downstream_provider,allowImageInput:true}))):null;
 if(imageTransport){const previousBefore=imageTransport.beforeStream;imageTransport.beforeStream=async context=>{await previousBefore?.(context);await beforeImageStream(context);};}
 const vision=createVisionContract(config,imageTransport??provider);
 transport.chatMetrics=chatMetrics;if(imageTransport)imageTransport.chatMetrics=chatMetrics;
 const guarded={identity:transport.identity,get reality(){return transport.reality;},assertReady:()=>transport.assertReady?.(),async *stream(input){if(input.image_attachments?.length)check(vision.enabled,503,'image_input_unavailable');yield*(input.image_attachments?.length&&vision.isLive?imageTransport:transport).stream(input);}};
 const runtime=await createFoundationChatRuntime({repository,authenticate,provider:guarded,guardKey:config.guardKey,dataClass:'private',leaseMs:60000,chatOptions:{finishOnDelegationReceipt:true,metrics:chatMetrics},imageRoutePolicy:vision.isLive?{id:vision.route.id,free:true,allow_private_with_consent:true,synthetic_only:false,data_classes:['private'],allow_sensitive:false}:null,beforeProviderRequest:async input=>{const started=chatMetrics.now();try{await beforeModel(input.provider_context);}finally{chatMetrics.record('provider_admission',started);}},routePolicy:{id:config.route.id,free:true,allow_private_with_consent:true,synthetic_only:false,data_classes:['private'],allow_sensitive:true}});
 runtime.vision=vision;runtime.chat.vision=vision;
 runtime.chat.attachments=vision.enabled&&(config.attachmentStorage||attachmentStorage)?new AttachmentService({chat:runtime.chat,storage:attachmentStorage??createStorageAdapter(config.attachmentStorage)}):null;
 beforeImageStream=async context=>{
   check(context?.turn_id&&context.resource_owner&&context.image_route_hash===vision.routeHash,403,'provider_image_context_required');
   await repository.transaction(async tx=>{const turn=await tx.get(context.resource_owner,'native-chat-turns',context.turn_id);check(turn&&turn.subject_id===context.source_auth?.subject_id&&turn.scope_id===context.scope_id&&turn.conversation_id===context.conversation_id&&turn.image_route_hash===vision.routeHash,403,'provider_image_context_required');await runtime.chat.live(tx,{owner:context.resource_owner,scope:{scope_id:context.scope_id},turn});});
 };
 const refreshImageCapability=async()=>{
   if(!vision.isLive)return;
   try{imageTransport.assertReady();await imageTransport.assertImageAvailable();delete vision.capability.reason;Object.assign(vision.capability,{available:true,state:'live_configured',live_validation:'catalog_only_until_real_fixture',catalog:imageTransport.catalogEvidence});}
   catch(e){Object.assign(vision.capability,{available:false,state:'live_unavailable',reason:e instanceof ApiError?e.code:'vision_catalog_unavailable'});}
 };
 runtime.memoryContextEnabled=config.route.data_fields?.includes('user_confirmed_memory_with_source_references')===true;
 runtime.memoryAuthority=async(tx,principal,scope)=>sourceChecker(tx.records,{subject_id:principal.subject_id,scope_id:scope.scope_id,issuer:principal.issuer,session_id:principal.session_id,issued_at:principal.issued_at},scope);
 // A finite original work grant is an additional bounded authority, never a
 // relaxation of fresh commands/viewers or an automatic grant for legacy runs.
 runtime.facade.acceptedWorkRouteHash=config.routeHash;
 // A2: catpaw.task-tools.v1 in-process (same deploy bundle). Absent store => no task tools are offered.
 // Feature gates (docs/feature-gates.md): every CATPAW_*_ENABLED gate is on for everyone when unset; 'allowlist' restricts it to
 // CATPAW_FEATURE_ALLOWLIST_SUBJECTS / DB enrollment; 'false'/'off' disables it. CATPAW_FEATURE_BLOCKLIST_SUBJECTS wins over all of these.
 // catpaw.feature-enrollment.v1: DB enrollment counts as allowlist membership (docs/feature-enrollment.md).
 const enrolled=enrollmentStore?createEnrollmentRegistry({store:enrollmentStore,log:(...a)=>diagnostic({event:'feature_enrollment',detail:a.join(' ')})}):null;runtime.enrollment=enrolled;
 if(enrolled){const gates={agent_memory:config.agentMemory,task_tools:config.taskTools,generative_ui:config.generativeUI,device_tools:config.deviceTools,proactive:config.proactive};
  runtime.enrollmentHTTP=createEnrollmentService({store:enrollmentStore,registry:enrolled,verifyUser:typeof verifyToken==='function'?h=>verifyToken(h):null,features:FEATURES,envAllows:(uid,f)=>featureAllows(gates[f]??'off',config.featureAllowlist,uid)});}
 {const registry=new Map(),gate=(g,turn,f)=>featureAllows(g,config.featureAllowlist,turn?.subject_id,enrolled,f);
  const taskGate=config.taskTools??'on',uiGate=config.generativeUI??'off';
  if(proactiveStore&&taskGate!=='off')for(const [name,tool] of createTaskChatTools({service:createProactiveService({store:proactiveStore,verifyUser:async()=>{throw new ApiError(401,'session_required');}})}))registry.set(name,{...tool,offer:turn=>gate(taskGate,turn,'task_tools')});
  if(uiGate!=='off')registry.set(RENDER_UI,createRenderUITool({allow:turn=>gate(uiGate,turn,'generative_ui')}));
  // catpaw.agent-memory.v1 (Wave 2 B1): CATPAW_AGENT_MEMORY_ENABLED default on (allowlist/off honored; BLOCKLIST_SUBJECTS wins); needs migration 20261016090000 (not applied).
  const memoryGate=config.agentMemory??'off';
  // Codex PR91 v2-3: the stored privacy off is read whenever the store exists, even with the feature gate off.
  {const privacyStore=agentMemoryPrivacyStore??agentMemoryStore;if(privacyStore)runtime.facade.agentMemoryPrivacy=createAgentMemoryPrivacy({store:privacyStore});}
  if(agentMemoryStore&&memoryGate!=='off'){const service=createAgentMemoryService({store:agentMemoryStore,allow:uid=>featureAllows(memoryGate,config.featureAllowlist,uid,enrolled,'agent_memory'),verifyUser:typeof verifyToken==='function'?h=>verifyToken(h):null,schedulerSecret:config.schedulerSecret??null,...agentMemoryOptions});
   runtime.facade.agentMemory=service;runtime.agentMemory=service;for(const [name,tool] of createAgentMemoryChatTools({service}))registry.set(name,tool);}
  // proactive_suggestion SSE (catpaw.proactive.decision.v1): CATPAW_PROACTIVE_SUGGESTIONS_SSE_ENABLED default on (allowlist/off honored; BLOCKLIST_SUBJECTS wins); needs migrations 20261016030000 + 20261016040000.
  const suggestionGate=config.proactiveSuggestionsSSE??'off';if(proactiveStore&&suggestionGate!=='off')runtime.facade.proactiveSuggestions=createSuggestionFeed({store:proactiveStore,allow:uid=>featureAllows(suggestionGate,config.featureAllowlist,uid,enrolled,'proactive')});
  // catpaw.device.v1 (Wave 2 B3): CATPAW_DEVICE_TOOLS_ENABLED default on (allowlist/off honored; BLOCKLIST_SUBJECTS wins); client opts in with X-Catpaw-Device-Contract.
  const deviceGate=config.deviceTools??'off';if(deviceGate!=='off')for(const [name,tool] of createDeviceTools({allow:turn=>gate(deviceGate,turn,'device_tools')}))registry.set(name,tool);
  if(registry.size)runtime.facade.gatedChatTools=registry;}
 runtime.facade.acceptedWorkExecutionReady=ACCEPTED_WORK_EXECUTION_CAPABILITY.executor==='bounded_single_step_v1'&&ACCEPTED_WORK_EXECUTION_CAPABILITY.model===true&&ACCEPTED_WORK_EXECUTION_CAPABILITY.public_source===true&&ACCEPTED_WORK_EXECUTION_CAPABILITY.local_continuation===true&&ACCEPTED_WORK_EXECUTION_CAPABILITY.terminal_ack===true; // Maintained composition, not model/scheduler/device acceptance.
 runtime.facade.workGrantService=new TaskWorkGrantService({repository,authorize:async(tx,ctx)=>{
   const {terms,run,phase,principal}=ctx;
   check(terms.route_hash===config.routeHash&&terms.model_configuration_hash===hash(runtime.facade.modelConfiguration),409,'work_grant_route_conflict');
   await lockTaskWorkSourceInTransaction(tx,{scope_id:terms.scope.scope_id,owner:terms.scope.owner,source:terms.source_auth});
   if(['admission','read'].includes(phase)){
     check(principal?.subject_id===terms.subject_id,403,'work_grant_viewer_conflict');
     const viewer={subject_id:principal.subject_id,scope_id:terms.scope.scope_id,session_id:principal.session_id,issuer:principal.issuer,issued_at:principal.issued_at};
     await sourceChecker(tx,viewer,terms.scope);
     if(phase==='admission'){await sourceChecker(tx,terms.source_auth,terms.scope);await assertConsent(tx,terms.scope.owner,terms.source_auth,terms.conversation_id,config.routeHash);}
   }else{
     const task=await tx.get(terms.scope.owner,'tasks',run.task_id),selected=await resolveExecutionGrantInTransaction(tx,terms.scope.owner,run,task);check(selected&&hash(selected.reference)===hash(workGrantReference(terms))&&hash(selected.source_auth)===hash(terms.source_auth),409,'work_grant_revision_superseded');
     await acceptedSourceChecker(tx,terms.source_auth,terms.scope,selected.reference);
     await assertConsent(tx,terms.scope.owner,terms.source_auth,terms.conversation_id,config.routeHash);
   }
   return {authorized:true};
 }});
 runtime.facade.beforeOwnedRunLocks=async(tx,{owner,run})=>{
   const f=run.frozen_request;
   if(f.source_auth)await lockTaskWorkSourceInTransaction(tx,{scope_id:f.scope.scope_id,owner,source:f.source_auth});
   if(f.work_grant_reference)await readTaskWorkGrantLifecycleInTransaction(tx,owner,run);
 };
 runtime.facade.beforeWorkGrantAdmission=async(tx,{scope,principal,turn,terms})=>{
   check(principal?.subject_id===turn.subject_id&&hash(turn.source_auth)===hash(terms.source_auth),403,'work_intent_subject_conflict');
   await lockTaskWorkSourceInTransaction(tx,{scope_id:scope.scope_id,owner:scope.owner,source:terms.source_auth});
   await sourceChecker(tx,terms.source_auth,scope);await assertConsent(tx,scope.owner,terms.source_auth,terms.conversation_id,config.routeHash);
 };
 const originalWorkIdentity=run=>({owner:run.frozen_request.scope.owner,scope_id:run.frozen_request.scope.scope_id,subject_id:run.frozen_request.subject_id,grant_id:run.frozen_request.work_grant_reference.grant_id});
 const workIdentity=async(tx,run,task)=>{const selected=await resolveExecutionGrantInTransaction(tx,run.frozen_request.scope.owner,run,task??await tx.get(run.frozen_request.scope.owner,'tasks',run.task_id));return selected?.identity??null;};
 const assertRunSource=async(tx,run,task)=>{
   const f=run.frozen_request,owner=f.scope.owner??runtime.facade.owner(f.scope),selected=await resolveExecutionGrantInTransaction(tx,owner,run,task??await tx.get(owner,'tasks',run.task_id)),source=selected?.source_auth??f.source_auth;
   if(selected){
     await lockTaskWorkSourceInTransaction(tx,{scope_id:f.scope.scope_id,owner,source});
     const facts=await runtime.facade.workGrantService.assertAcceptedGrantCurrentInTransaction(tx,await workIdentity(tx,run,task));
     check(hash(facts.reference)===hash(selected.reference),409,'work_grant_run_binding_conflict');
   }else await sourceChecker(tx,source,f.scope);
   await assertConsent(tx,owner,source,f.conversation_id,config.routeHash);return selected;
 };
 runtime.chat.modelBudgetMs=config.chatBudgetMs;runtime.chat.providerTimeoutMs=config.modelTimeoutMs;runtime.chat.finalizationReserveMs=config.chatFinalizationReserveMs;runtime.chat.pollMs=250;
 runtime.chat.beforeTurnAdmission=async(tx,{principal,scope,conversation,turn})=>{const source={subject_id:principal.subject_id,scope_id:scope.scope_id,issuer:principal.issuer,session_id:principal.session_id,issued_at:principal.issued_at};await sourceChecker(tx,source,scope);const row=await tx.get(runtime.facade.owner(scope),'provider-consents',consentId(principal.subject_id,conversation.id));check(row?.decision==='allow'&&row.route_hash===config.routeHash,403,'provider_consent_required');checkTextConsent(JSON.stringify(conversation.messages)+JSON.stringify(turn.input),row);turn.source_sensitivity=row.sensitive_confirmed===true?'sensitive':'low';let imageSource={};if(turn.image_attachments?.length){check(vision.enabled&&turn.image_route_hash===vision.routeHash,503,'image_input_unavailable');const imageRow=await tx.get(runtime.facade.owner(scope),'image-provider-consents',consentId(principal.subject_id,conversation.id));imageSource={image_route_hash:vision.routeHash,image_consent_revision:imageRow?.revision};await assertImageConsent(tx,runtime.facade.owner(scope),{...source,...imageSource},conversation.id,vision.routeHash);}return {...source,consent_revision:row.revision,...imageSource};};
 // Serialize best-effort kicks for the same accepted turn. This is invocation
 // retention only; durable admission/lease/state still live in the original Store.
 const turnKicks=new Map();
 const kickAcceptedTurn=async context=>{
   const key=`${context.owner}:${context.turnId}`;
   while(turnKicks.has(key))await turnKicks.get(key);
   const work=Promise.resolve().then(()=>kickTurnTasks(runtime,context,kickOptions)).catch(()=>{/* durable task remains authoritative */});
   turnKicks.set(key,work);try{await work;}finally{if(turnKicks.get(key)===work)turnKicks.delete(key);}
 };
 runtime.facade.onPlanAmendmentAccepted=({owner,turn_id,source_auth,revision_work_operation_id})=>{
   if(!autoKick||!source_auth)return;
   // No viewer/presentation authority: use exactly the original admitted source.
   retain(kickAcceptedTurn({owner,turnId:turn_id,principal:{subject_id:source_auth.subject_id,session_id:source_auth.session_id},...revision_work_operation_id?{revisionWorkOperationId:revision_work_operation_id}:{}}));
 };
 runtime.facade.onTaskRevisionAccepted=runtime.facade.onPlanAmendmentAccepted;
 runtime.facade.onTaskControlAccepted=runtime.facade.onPlanAmendmentAccepted;
 const originalAdmission=runtime.facade.admittedTask.bind(runtime.facade);
 runtime.facade.admittedTask=async(tx,owner,id,options={})=>{
   const initial=await tx.get(owner,'tasks',id),hint=initial?.state?.catpaw?await tx.get(owner,'catpaw-runs',initial.state.catpaw.run_id):null;
   if(hint?.frozen_request?.work_grant_reference){check(hint.frozen_request.scope.owner===owner,403,'scope_forbidden');await assertRunSource(tx,hint,initial);}
   const admitted=await originalAdmission(tx,owner,id,options),f=admitted.run.frozen_request;
   check(hash(f)===admitted.run.request_hash,409,'run_request_binding_conflict');await assertRunSource(tx,admitted.run,admitted.task);
   await assertTaskRevisionAuthorityInTransaction(runtime.facade,tx,owner,admitted.run,admitted.task);return admitted;
 };
 runtime.facade.beforePlanRead=async(tx,{owner,scope,principal,run})=>{
   const source={subject_id:principal.subject_id,session_id:principal.session_id,issuer:principal.issuer,issued_at:principal.issued_at,scope_id:scope.scope_id};
   await sourceChecker(tx,source,scope);
   const row=await tx.get(owner,'provider-consents',consentId(principal.subject_id,run.frozen_request.conversation_id));
   check(row?.decision==='allow'&&row.scope_id===scope.scope_id&&row.route_hash===config.routeHash,403,'provider_consent_required');
 };
 runtime.facade.beforePlanWrite=async(tx,ctx)=>{
   await runtime.facade.beforePlanRead(tx,ctx);
   const frozen=ctx.run.frozen_request,selected=await assertRunSource(tx,ctx.run,ctx.task);
   const consent=await assertConsent(tx,ctx.owner,selected?.source_auth??frozen.source_auth,frozen.conversation_id,config.routeHash);
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
   const intent=ctx.turn?.revision_work_intent;
   if(intent){
     const f=ctx.run.frozen_request,fresh=ctx.fresh_source_auth??ctx.turn.source_auth,target=ctx.target??ctx.turn.revision_target?.target,c=ctx.conversation??await tx.get(ctx.owner,'native-chat-conversations',f.conversation_id);
     check(f.work_grant_reference&&fresh?.subject_id===f.subject_id&&fresh.scope_id===f.scope.scope_id&&hash(fresh)===hash(ctx.turn.source_auth),403,'revision_consent_conflict');
     validateFrozenRevisionWorkIntent(intent,{turn:ctx.turn,target,scope:f.scope,conversation:c,routeHash:config.routeHash,callName:'revise_current_report_work_v1'});
     const task=await tx.get(ctx.owner,'tasks',ctx.run.task_id),ref=task?.state?.task_revision?.work_grant_reference;
     if(ref?.grant_id===intent.decision_id){const selected=await resolveExecutionGrantInTransaction(tx,ctx.owner,ctx.run,task);check(selected?.terms.schema_version===2&&hash(selected.source_auth)===hash(fresh),409,'revision_execution_source_conflict');await acceptedSourceChecker(tx,fresh,f.scope,selected.reference);}
     else{const viewer={subject_id:ctx.principal.subject_id,session_id:ctx.principal.session_id,issuer:ctx.principal.issuer,issued_at:ctx.principal.issued_at,scope_id:f.scope.scope_id};await sourceChecker(tx,viewer,f.scope);await sourceChecker(tx,fresh,f.scope);}
     const row=await tx.withScope(f.scope.scope_id,async scoped=>scoped.scope());check(row.enabled&&(!ctx.turn.revision_target||row.generation===ctx.turn.revision_target.memory_generation),409,'memory_generation_superseded');
     const consent=await assertConsent(tx,ctx.owner,fresh,f.conversation_id,config.routeHash);check(typeof ctx.raw_instruction==='string'&&typeof ctx.base_body==='string',409,'revision_input_context_required');checkTextConsent(ctx.raw_instruction+'\n'+ctx.base_body,consent);
     if(ref?.grant_id===intent.decision_id){const selected=await resolveExecutionGrantInTransaction(tx,ctx.owner,ctx.run,await tx.get(ctx.owner,'tasks',ctx.run.task_id));await acceptedSourceChecker(tx,fresh,f.scope,selected.reference);}else await sourceChecker(tx,fresh,f.scope);
     await assertConsent(tx,ctx.owner,fresh,f.conversation_id,config.routeHash);const finalScope=await tx.withScope(f.scope.scope_id,async scoped=>scoped.scope());check(finalScope.enabled&&finalScope.generation===row.generation,409,'memory_generation_superseded');
     return {source_current:true};
   }
   const current=await runtime.facade.beforeTaskRevisionRead(tx,ctx);
   check(current.source_current,403,'revision_source_not_current');
   check(!ctx.run.frozen_request.work_grant_reference,409,'revision_new_work_intent_required');
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
   let original;const f=ctx.run.frozen_request,task=ctx.task??await tx.get(ctx.owner,'tasks',ctx.run.task_id),selected=await resolveExecutionGrantInTransaction(tx,ctx.owner,ctx.run,task),source=selected?.source_auth??f.source_auth;
   if(selected){
     const viewer={subject_id:ctx.principal.subject_id,session_id:ctx.principal.session_id,issuer:ctx.principal.issuer,issued_at:ctx.principal.issued_at,scope_id:ctx.scope.scope_id};await sourceChecker(tx,viewer,ctx.scope);
     try{await lockTaskWorkSourceInTransaction(tx,{scope_id:f.scope.scope_id,owner:ctx.owner,source});await acceptedControlSourceChecker(tx,source,f.scope,selected.reference);await assertConsent(tx,ctx.owner,source,f.conversation_id,config.routeHash);original={source_current:true};}
     catch(error){if(error instanceof ApiError&&[403,409].includes(error.status)&&['accepted_work_grant_conflict','work_grant_expired','work_grant_not_active','grant_conflict','provider_consent_required','session_revoked'].includes(error.code))original={source_current:false};else throw error;}
   }else original=await runtime.facade.beforeActionRead(tx,ctx);
   if(!original.source_current)return {source_current:false,reason:'original_source_not_current'};
   const row=await tx.withScope(f.scope.scope_id,async scoped=>scoped.scope());if(row.generation!==(selected?.terms.memory_generation??f.memory_generation))return {source_current:false,reason:'memory_generation_superseded'};
   // The v2 control proof validates its frozen operation/turn and permits paused
   // state; calling the execution-only revision hook here would deny resume.
   if(selected?.terms.schema_version!==2)try{await assertTaskRevisionAuthorityInTransaction(runtime.facade,tx,ctx.owner,ctx.run,ctx.task);}
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
       runtime.sourceService=new TaskSourceService({facade:runtime.facade,reader:selectedSourceReader});runtime.facade.sourceService=runtime.sourceService;runtime.facade.workGrantService.sourceService=runtime.sourceService;
     }catch(error){publicSourceUnavailable=error instanceof ApiError?error.code:'public_source_reader_unavailable';}
   }
 }
 runtime.facade.revisionWorkExecutionReady=runtime.facade.acceptedWorkExecutionReady&&typeof runtime.facade.workGrantService.admitRevisionInTransaction==='function'&&typeof runtime.facade.beforeTaskRevisionWrite==='function'&&typeof runtime.facade.beforeTaskControlRead==='function';
 const originalBefore=runtime.chat.integration.beforeWrite;
 const checkTurnSource=async(tx,ctx)=>{if(ctx.turn?.source_auth){await sourceChecker(tx,ctx.turn.source_auth,{...(await tx.withScope(ctx.turn.scope_id,async scoped=>(await scoped.scope()).identity,{reuseLockedScope:true}))});await assertConsent(tx,ctx.owner,ctx.turn.source_auth,ctx.turn.conversation_id,config.routeHash);if(ctx.turn.image_attachments?.length)await assertImageConsent(tx,ctx.owner,ctx.turn.source_auth,ctx.turn.conversation_id,vision.routeHash);}};
 const checkTurnMemory=async(tx,ctx)=>{if(ctx.turn?.memory_usage||ctx.turn?.memory_extraction)await tx.withScope(ctx.turn.scope_id,async scoped=>{const row=await scoped.scope();check(row.enabled&&row.memory_user_enabled===true&&row.generation===(ctx.turn.memory_usage??ctx.turn.memory_extraction).memory_generation,409,'memory_generation_superseded');},{reuseLockedScope:true});};
 runtime.chat.integration.beforeWrite=async(tx,ctx)=>{await originalBefore(tx,ctx);await checkTurnSource(tx,ctx);await checkTurnMemory(tx,ctx);};
 runtime.chat.integration.beforeFailure=async(tx,ctx)=>{
   // Failure receipts retain runtime/turn generation and scope ownership fences.
   // Only expected source/consent denial permits static terminal metadata; never content publication.
   await originalBefore(tx,ctx);
   const source=ctx.turn?.source_auth;
   if(source)check(source.scope_id===ctx.turn.scope_id&&source.subject_id===ctx.turn.subject_id,409,'failure_source_mismatch');
   try{await checkTurnSource(tx,ctx);await checkTurnMemory(tx,ctx);}catch(e){
     if(e instanceof ApiError&&(e.status===409&&['grant_conflict','memory_generation_superseded'].includes(e.code)||e.status===403&&['provider_consent_required','provider_image_consent_required'].includes(e.code)))return e;
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
 const followupHTTP=createFollowupTriggerHTTPHandler({facade:runtime.facade,repository,verifyViewer:(tx,{principal,scope})=>sourceChecker(tx,{subject_id:principal.subject_id,session_id:principal.session_id,issuer:principal.issuer,issued_at:principal.issued_at,scope_id:scope.scope_id},scope)});
 runtime.api=request=>withRoutePreference(request.headers.get('x-catpaw-route'),()=>runtimeApi(request),{reasoningSummary:request.headers.get('x-catpaw-reasoning-summary')==='1'});
 const runtimeApi=async request=>{try{const url=new URL(request.url),path=url.pathname.replace(/^\/(?:functions\/v1\/)?catpaw-api(?=\/|$)/,'')||'/';
  if(path.startsWith('/catpaw/followups/'))return followupHTTP(request,{path});
  if(path.startsWith('/catpaw/features/v1/')){check(runtime.enrollmentHTTP,404,'not_found');return await runtime.enrollmentHTTP.handle(request,path);}
  if(runtime.enrollment&&path.startsWith('/catpaw/'))await runtime.enrollment.fresh();
  if(path.startsWith('/catpaw/agent-memory/v1/')){check(runtime.agentMemory,404,'not_found');return await runtime.agentMemory.handle(request);}
  if(path==='/healthz')return reply({status:'alive'});
  if(path==='/readyz'){await refreshImageCapability();await repository.transaction(async()=>{});return reply({ready:true,model_route:config.route.id,authentication:'supabase_signed_jwt_and_fresh_session',execution:'bounded-chat-and-original-task-worker',chat_capabilities:{schema_version:1,memory:{contract:MEMORY_CONTRACT,read:true,commands:true,context:runtime.memoryContextEnabled,conversation_proposals:{contract:'catpaw.memory-proposal.v1',enabled:runtime.memoryContextEnabled,confirmation_required:true,current_user_source_only:true,live_verification:'not_verified'},default_enabled:false,explicit_enable:true,unknown_resend:false,original_operation_read:true,live_verification:'not_verified'},text_input:true,image_input:vision.isLive&&vision.capability.available,vision_contract:vision.capability,attachments:{contract:ATTACHMENT_CONTRACT,available:!!runtime.chat.attachments,upload:'signed_put',max_count:ATTACHMENT_LIMITS.max_count,max_bytes:ATTACHMENT_LIMITS.max_bytes,mime_types:ATTACHMENT_LIMITS.mime_types},turn_cancel:true,live_weather:false,web_search:false,tools:['delegate_task','delegate_plan_v1','agent_status',...runtime.facade.publicSourcesEnabled?['delegate_sources_v1']:[]],task_plan:{contract:'catpaw.task-plan.v1',read:true,amend:true,local_report_only:true},task_artifacts:{contract:TASK_ARTIFACT_CONTRACT,read:true,amend:true,manual_revision:true,model_revision:false},task_revisions:{contract:TASK_REVISION_CONTRACT,revise:true,explain:true,same_task:true,immutable_target:true,bounded_work:{contract:TASK_REVISION_WORK_CONTRACT,grant_contract:TASK_REVISION_WORK_GRANT_CONTRACT,enabled:runtime.facade.revisionWorkExecutionReady,same_task:true,required_for_accepted_work:true,unknown_resend:false,live_verification:'not_verified'}},task_controls:{contract:TASK_CONTROL_CONTRACT,read:true,pause:true,resume:true,revoke:true,same_task:true,pause_preserves_grant:true,unknown_resend:false,live_verification:"not_verified"},followups:{contract:'catpaw.followup-trigger.v1',configure:true,durable:true,execution_authorized:false,independent_scheduler:false,native_producer:false,live_verification:'not_verified'},accepted_work:{contract:ACCEPTED_WORK_INTENT_CONTRACT,grant_contract:TASK_WORK_GRANT_CONTRACT,enabled:runtime.facade.acceptedWorkExecutionReady,execution:'bounded_single_step_v1',single_run:true,independent_scheduler:false,native_producer:false,live_verification:'not_verified',limits_explicit:true,unknown_resend:false},task_actions:{contract:TASK_ACTION_CONTRACT,review:true,decision:typeof taskActionTargetVerifier==='function',execution:false,device_calendar_write:false,unavailable_reason:typeof taskActionTargetVerifier==='function'?'device_executor_not_configured':'action_target_verifier_not_configured'},public_sources:{enabled:runtime.facade.publicSourcesEnabled,limited_to_user_urls:true,max_sources:3,policy_hash:runtime.facade.publicSourcePolicyHash,unavailable_reason:publicSourceUnavailable,transport_reality:runtime.facade.publicSourcesEnabled?selectedSourceReader.reality??'capability_unverified':null,live_verification:'not_verified'},durable_acceptance:'turn_started',cursor_events:true}});}
  const auth=request.headers.get('authorization');
  if(path.startsWith('/catpaw/inbox/')){
    const parts=path.split('/').filter(Boolean);
    check(parts.length===6&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='items',404,'not_found');
    check(request.method==='GET',405,'method_not_allowed');
    return reply(await readInboxPage(runtime.facade,auth,parts[4],url.searchParams,{signal:request.signal,verifyViewer:(tx,{principal,scope})=>sourceChecker(tx,{subject_id:principal.subject_id,session_id:principal.session_id,issuer:principal.issuer,issued_at:principal.issued_at,scope_id:scope.scope_id},scope)}));
  }
  if(path.startsWith('/catpaw/work-grants/v1/')){
    check(!url.search,422,'work_intent_schema_invalid');const parts=path.split('/').filter(Boolean);
    check(parts.length===8&&parts[3]==='scopes'&&parts[5]==='runs'&&parts[7]==='grant'&&UUID.test(parts[4]??'')&&UUID.test(parts[6]??''),404,'not_found');
    check(request.method==='GET',405,'method_not_allowed');
    const scoped=await runtime.facade.scoped(auth,parts[4]);
    const run=await repository.transaction(tx=>runtime.facade.ownedRun(tx,scoped.owner,parts[6],scoped.principal,parts[4]));
    check(run.frozen_request.work_grant_reference,404,'work_grant_not_found');
    return reply({contract:TASK_WORK_GRANT_CONTRACT,...await runtime.facade.workGrantService.read(originalWorkIdentity(run),{principal:scoped.principal,signal:request.signal})});
  }
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
  if(path.startsWith('/catpaw/devices/v1/')){const r=await handlePushTokenRoute({path,method:request.method,apns:config.apns,authenticate,auth,repository,body:async()=>{check(Number(request.headers.get('content-length')??0)<=4096,413,'push_request_too_large');const t=await request.text();check(Buffer.byteLength(t)<=4096,413,'push_request_too_large');try{return JSON.parse(t);}catch{throw new ApiError(422,'push_token_invalid');}}});if(r)return reply(r);}
  if(path==='/catpaw/account/v1/session'){const principal=await authenticate(auth);return reply({subject_id:principal.subject_id,scopes:principal.scopes});}
  if(path==='/catpaw/privacy/v1/model-route'){await authenticate(auth);return reply({route:config.route,route_hash:config.routeHash,consent_default:'deny',sensitive_confirmation_default:false,ui:{title:'允许云端模型处理此对话？',body:`本条消息、本对话最近最多40条文本（80kB）以及你主动加入的文字上下文，将发送给${config.freeChain?'以下免费模型服务（按顺序，繁忙时在未输出前切换下一个）：':'OpenRouter及固定服务商'}${config.route.downstream_provider}，用于回复和本地报告。${publicSourcePolicy?'你明确提供并经受理的公开URL、读取的正文和来源记录，也将交给同一现有模型生成有来源的报告；只读已配置范围，不进行自主搜索。':''}${runtime.memoryContextEnabled?'你另行开启的已确认记忆（内容、适用范围、版本和来源引用）也会发送给同一固定模型；候选记忆和原始来源全文不会作为记忆上下文发送。更正或删除影响后续调用，不能收回已发送数据。':''}不会读取邮件、日历、照片、通讯录或其他App数据。云端保存对话、任务与成果，离开App不会撤销已受理任务，回来可查收状态与成果；普通发送受原会话许可期限约束；另行明确受理的有限工作，遵守原先确认的期限和调用次数。撤销可停止后续调用，但不能收回已发送数据。`,allow:'允许此对话',deny:'暂不允许',sensitive_confirmation:'本会话含敏感信息，另外确认发送给这两个固定服务商'}});}
  if(path==='/catpaw/privacy/v1/image-model-route'){await authenticate(auth);await refreshImageCapability();return reply({capability:vision.capability,route:vision.route,route_hash:vision.routeHash,consent_default:'deny',live_transmission_available:vision.isLive&&vision.capability.available,non_sensitive_confirmation_required:true,ui:VISION_CONSENT_UI});}
  const imageMatch=/^\/catpaw\/privacy\/v1\/scopes\/([a-f0-9-]+)\/conversations\/([a-f0-9-]+)\/image-model-consent$/.exec(path);
  if(imageMatch){check(UUID.test(imageMatch[1])&&UUID.test(imageMatch[2]),422,'schema_invalid');check(['GET','POST'].includes(request.method),405,'method_not_allowed');const input=request.method==='POST'?await boundedJsonBody(request,2048):null;return reply({consent:await imageConsent(runtime,sourceChecker,auth,imageMatch[1],imageMatch[2],input)});}
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
 runtime.tick=async request=>{try{await authorizeTick(request,{secret:config.tickKey,repository});let permit=null;for(const row of await repository.transaction(tx=>tx.scan('tasks'))){const task=row.value;if(!task.state?.catpaw||!['queued','scheduled','running'].includes(task.status)||task.status==='scheduled'&&Date.parse(task.nextRunAt)>Date.now()||task.status==='running'&&Date.parse(task.leaseUntil)>Date.now())continue;try{await repository.transaction(async tx=>{const admitted=await runtime.facade.admittedTask(tx,row.owner,task.id);check(await acceptedWorkClaimEligibleInTransaction(tx,runtime.facade.workGrantService,row.owner,admitted.run),409,'accepted_work_due_not_open');});permit={owner:row.owner};break;}catch{}}if(!permit)return reply({tick:{claimed:0,step_calls:0,settled:[]}});const result=await boundedTick({repository,workGrantService:runtime.facade.workGrantService,owners:[permit.owner],admitTask:runtime.facade.admittedTask.bind(runtime.facade),runStep:singleStepHandler(runtime.facade,runtime.provider),budgetMs:config.tickBudgetMs,settleReserveMs:750,leaseMs:60000});return reply({tick:{claimed:result.claimed,step_calls:result.step_calls,settled:result.settled.map(t=>({task_id:t.task_id,status:t.status,nextRunAt:t.nextRunAt}))}});}catch(e){return reply({error:{code:e instanceof ApiError?e.code:'tick_denied',retryable:false}},e instanceof ApiError?e.status:403);}};
 return runtime;
}
