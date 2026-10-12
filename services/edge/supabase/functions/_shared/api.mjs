import {kickTurnTasks} from './worker-kick.mjs';
import {checkTextConsent} from './sensitivity.mjs';
import {randomUUID} from 'node:crypto';import {ApiError,check,hash,UUID,iso} from './core/facade-r2/src/common.mjs';
import {createFoundationChatRuntime} from './core/src/foundation-runtime.mjs';import {OpenRouterProvider} from './core/src/openrouter-provider.mjs';
import {boundedTick} from './core/integration/edge-adapter/src/bounded-tick.mjs';import {singleStepHandler} from './core/src/single-step-handler.mjs';
import {assertSourceAuthority,revokeAppSession} from './authority.mjs';import {assertConsent,consentId,consentRead,consentWrite} from './consent.mjs';import {authorizeTick} from './tick-auth.mjs';
import {createChatMetrics} from './core/src/chat-metrics.mjs';
const reply=(v,status=200)=>Response.json({schema_version:1,...v},{status,headers:{'Cache-Control':'no-store'}});
export async function createCloudRuntime({repository,authenticate,config,retain=(_promise)=>{},sourceChecker=assertSourceAuthority,provider=null,verifyToken=null,autoKick=true,kickOptions={},diagnostic=entry=>console.info(JSON.stringify(entry))}){
 const chatMetrics=createChatMetrics({sink:diagnostic});repository.metrics=chatMetrics;
 const beforeModel=async context=>{check(context?.source_auth&&context.scope_id===context.source_auth.scope_id,403,'provider_context_required');await repository.transaction(async tx=>{await tx.withScope(context.scope_id,async scoped=>{const scope=(await scoped.scope()).identity;await sourceChecker(tx,context.source_auth,scope);const consent=await assertConsent(tx,scope.owner,context.source_auth,context.conversation_id,config.routeHash);const conversation=await tx.get(scope.owner,'native-chat-conversations',context.conversation_id);checkTextConsent(JSON.stringify(conversation?.messages??[])+JSON.stringify(context.input_context??[]),consent);const date=new Date().toISOString().slice(0,10),id=`${context.source_auth.subject_id}:${date}`;await tx.lock('system:provider-budget','daily-model-calls',id);const old=await tx.get('system:provider-budget','daily-model-calls',id);check((old?.count??0)<config.dailyCallLimit,429,'model_daily_limit');await tx.put('system:provider-budget','daily-model-calls',{id,count:(old?.count??0)+1});});});};
 const transport=provider??new OpenRouterProvider({model:config.route.model,secret:config.modelKey,liveNetworkEnabled:true,timeoutMs:config.modelTimeoutMs,privateRoutingPolicy:config.route.routing_policy,beforeStream:async()=>{},expectedProviderDisplay:config.route.downstream_provider});
 transport.chatMetrics=chatMetrics;
 const guarded={identity:transport.identity,get reality(){return transport.reality;},assertReady:()=>transport.assertReady?.(),async *stream(input){yield*transport.stream(input);}};
 const runtime=await createFoundationChatRuntime({repository,authenticate,provider:guarded,guardKey:config.guardKey,dataClass:'private',leaseMs:60000,chatOptions:{finishOnDelegationReceipt:true,metrics:chatMetrics},beforeProviderRequest:async input=>{const started=chatMetrics.now();try{await beforeModel(input.provider_context);}finally{chatMetrics.record('provider_admission',started);}},routePolicy:{id:config.route.id,free:true,allow_private_with_consent:true,synthetic_only:false,data_classes:['private'],allow_sensitive:true}});
 runtime.chat.modelBudgetMs=config.chatBudgetMs;runtime.chat.providerTimeoutMs=config.modelTimeoutMs;runtime.chat.finalizationReserveMs=config.chatFinalizationReserveMs;runtime.chat.pollMs=250;
 runtime.chat.beforeTurnAdmission=async(tx,{principal,scope,conversation,turn})=>{const source={subject_id:principal.subject_id,scope_id:scope.scope_id,issuer:principal.issuer,session_id:principal.session_id,issued_at:principal.issued_at};await sourceChecker(tx,source,scope);const row=await tx.get(runtime.facade.owner(scope),'provider-consents',consentId(principal.subject_id,conversation.id));check(row?.decision==='allow'&&row.route_hash===config.routeHash,403,'provider_consent_required');checkTextConsent(JSON.stringify(conversation.messages)+JSON.stringify(turn.input),row);return {...source,consent_revision:row.revision};};
 const originalAdmission=runtime.facade.admittedTask.bind(runtime.facade);
 runtime.facade.admittedTask=async(tx,owner,id,options={})=>{const admitted=await originalAdmission(tx,owner,id,options),f=admitted.run.frozen_request;await sourceChecker(tx,f.source_auth,f.scope);await assertConsent(tx,owner,f.source_auth,f.conversation_id,config.routeHash);return admitted;};
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
   retain(Promise.allSettled(promises).then(async()=>{await releaseLease(owner);if(autoKick)try{await kickTurnTasks(runtime,{owner,principal,turnId},kickOptions);}catch{/* durable original task remains authoritative */}}));
 };
 runtime.api=async request=>{try{const url=new URL(request.url),path=url.pathname.replace(/^\/(?:functions\/v1\/)?catpaw-api(?=\/|$)/,'')||'/';
  if(path==='/healthz')return reply({status:'alive'});
  if(path==='/readyz'){await repository.transaction(async()=>{});return reply({ready:true,model_route:config.route.id,authentication:'supabase_signed_jwt_and_fresh_session',execution:'bounded-chat-and-original-task-worker',chat_capabilities:{schema_version:1,text_input:true,image_input:false,live_weather:false,web_search:false,tools:['delegate_task','agent_status'],durable_acceptance:'turn_started',cursor_events:true}});}
  const auth=request.headers.get('authorization');
  if(path==='/catpaw/account/v1/logout'){check(request.method==='POST'&&typeof verifyToken==='function',405,'method_not_allowed');check((await request.text()).trim()==='{}',422,'schema_invalid');const claims=await verifyToken(auth);await revokeAppSession(repository,claims,runtime);for(const entry of runtime.chat.active.values())if(entry.subject_id===claims.sub&&entry.session_id===claims.session_id)entry.controller.abort();return reply({revoked:true,client_action:'clear_keychain_and_supabase_signout'});}
  if(path==='/catpaw/account/v1/session'){const principal=await authenticate(auth);return reply({subject_id:principal.subject_id,scopes:principal.scopes});}
  if(path==='/catpaw/privacy/v1/model-route'){await authenticate(auth);return reply({route:config.route,route_hash:config.routeHash,consent_default:'deny',sensitive_confirmation_default:false,ui:{title:'允许云端模型处理此对话？',body:`本条消息、本对话最近最多40条文本（80kB）以及你主动加入的文字上下文，将发送给OpenRouter及固定服务商${config.route.downstream_provider}，用于回复和本地报告。不会读取邮件、日历、照片、通讯录或其他App数据。云端保存对话、任务与成果，关闭App后已授权报告任务会继续。撤销可停止后续调用，但不能收回已发送数据。`,allow:'允许此对话',deny:'暂不允许',sensitive_confirmation:'本会话含敏感信息，另外确认发送给这两个固定服务商'}});}
  const consent=/^\/catpaw\/privacy\/v1\/scopes\/([a-f0-9-]+)\/conversations\/([a-f0-9-]+)\/model-consent$/.exec(path);
  if(consent){check(UUID.test(consent[1])&&UUID.test(consent[2]),422,'schema_invalid');if(request.method==='GET')return reply({consent:await consentRead(runtime,auth,consent[1],consent[2])});check(request.method==='POST',405,'method_not_allowed');const text=await request.text();check(text.length<=2048,413,'request_too_large');return reply({consent:await consentWrite(runtime,auth,consent[1],consent[2],JSON.parse(text),config)});}
  const response=await raw(new Request(new URL(path+url.search,url.origin),request));
  return response;
 }catch(e){return reply({error:{code:e instanceof ApiError?e.code:'internal_error',retryable:false,reconciliation_required:e instanceof ApiError?e.reconciliation:false}},e instanceof ApiError?e.status:500);}};
 runtime.tick=async request=>{try{await authorizeTick(request,{secret:config.tickKey,repository});let permit=null;for(const row of await repository.transaction(tx=>tx.scan('tasks'))){const task=row.value;if(!task.state?.catpaw||!['queued','scheduled','running'].includes(task.status)||task.status==='scheduled'&&Date.parse(task.nextRunAt)>Date.now()||task.status==='running'&&Date.parse(task.leaseUntil)>Date.now())continue;try{await repository.transaction(tx=>runtime.facade.admittedTask(tx,row.owner,task.id));permit={owner:row.owner};break;}catch{}}if(!permit)return reply({tick:{claimed:0,step_calls:0,settled:[]}});const result=await boundedTick({repository,owners:[permit.owner],admitTask:runtime.facade.admittedTask.bind(runtime.facade),runStep:singleStepHandler(runtime.facade,runtime.provider),budgetMs:config.tickBudgetMs,settleReserveMs:750,leaseMs:60000});return reply({tick:{claimed:result.claimed,step_calls:result.step_calls,settled:result.settled.map(t=>({task_id:t.task_id,status:t.status,nextRunAt:t.nextRunAt}))}});}catch(e){return reply({error:{code:e instanceof ApiError?e.code:'tick_denied',retryable:false}},e instanceof ApiError?e.status:403);}};
 return runtime;
}
