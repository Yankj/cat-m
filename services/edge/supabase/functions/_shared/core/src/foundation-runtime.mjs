import { randomUUID } from 'node:crypto';
import { ApiError,check,hash,clone } from '../facade-r2/src/common.mjs';
import { PostgresRepository } from '../integration/server-foundation/src/postgres-repository.mjs';
import { Foundation } from '../integration/server-foundation/src/foundation.mjs';
import { ChatRecoveryFence } from '../integration/server-foundation/src/chat-recovery.mjs';
import { ProviderGateway } from '../integration/server-foundation/src/provider-policy.mjs';
import { createChatRuntime } from './runtime.mjs';
import { OpenRouterProvider } from './openrouter-provider.mjs';
import { eraseChatSource } from './source-erasure.mjs';
import { buildSourcePurgePlan } from './purge-plan.mjs';
import { attachFoundationProjections } from './projection-adapter.mjs';
import { createFoundationFetchHandler } from './foundation-http.mjs';
import {freezeMemoryUsage,resolveMemoryProviderInput} from './memory-service.mjs';
import { createSupabaseSessionVerifier } from './supabase-auth.mjs';
import { SupabasePgScopeAuthority } from './supabase-scope-authority.mjs';

// Existing task-9 Store only. No SQL implementation, second scheduler or memory model loop.
export async function createFoundationChatRuntime({repository,authenticate,provider=new OpenRouterProvider(),guardKey,dataClass='private',holderId=randomUUID(),clock=()=>new Date(),leaseMs=120000,workerOptions={},chatOptions={},handlerOptions={},completionPolicy=null,completionAuthorizer=null,routePolicy=null,beforeProviderRequest=null}){
  check(typeof guardKey==='string'&&guardKey.length>=16,503,'memory_guard_not_configured');
  check(['synthetic','private'].includes(dataClass),422,'invalid_data_class');
  const foundation=new Foundation(repository,{guardKey,clock,sourceEraser:eraseChatSource});
  const fence=new ChatRecoveryFence(repository,{clock,lease_ms:leaseMs}),tokens=new Map(),recoveryReports=[];
  const routeId=routePolicy?.id??'openrouter-free-synthetic';const route=routePolicy??{free:true,synthetic_only:true,data_classes:['synthetic'],allow_sensitive:false};
  const policy=new ProviderGateway({routes:{[routeId]:route},complete:async()=>true});
  const guardedProvider={identity:{...provider.identity,data_class:dataClass,route_policy:routeId},get reality(){return provider.reality;},assertReady:()=>provider.assertReady?.(),async *stream(input){
    // Classification is a server composition constant; no HTTP/model field can downgrade private data.
    input=await resolveMemoryProviderInput(runtime,input);
    if(beforeProviderRequest)await beforeProviderRequest(input);
    await normalized(()=>policy.complete({consent_verified:!!beforeProviderRequest,purpose:'chat',allowed_route_policy_id:routeId,data_class:dataClass,sensitivity:'low'}));
    yield*provider.stream(input);
  }};
  const normalized=async fn=>{try{return await fn();}catch(e){if(e?.name==='Error'&&e.code&&Number.isInteger(e.status))throw new ApiError(e.status,e.code,{reconciliation:e.reconciliation_required===true});throw e;}};
  const lockScope=async(tx,scopeId,owner)=>normalized(()=>tx.withScope(scopeId,async scoped=>{const row=await scoped.scope();if(owner)check(row.identity.owner===owner,403,'scope_forbidden');}));
  const integration={
    lockScope,
    async memoryUsage(tx,args){return normalized(()=>freezeMemoryUsage(runtime,tx,args));},
    async prepare({owner}){
      const token=await normalized(()=>fence.acquire(owner,holderId));check(token,503,'chat_runtime_busy');tokens.set(owner,token);
      recoveryReports.push(await normalized(()=>fence.recoverExpiredOwner(owner,token)));
    },
    async beforeWrite(tx,{owner,scope,turn}){
      // Runtime lease precedes scope, conversation, delegation, task on every fenced chat write.
      const token=tokens.get(owner);check(token,409,'runtime_lease_lost');
      await normalized(()=>turn?fence.assertTurnLive(tx,owner,token,turn):fence.assertLive(tx,owner,token));
      await lockScope(tx,scope.scope_id,owner);
    },
    async stampTurn(tx,owner,turn){return normalized(()=>fence.stampTurn(tx,owner,tokens.get(owner),turn));},
    async renew(owner){await normalized(()=>fence.renew(owner,tokens.get(owner)));},
    async capture(tx,{principal,scope,turn}){return normalized(()=>foundation.captureInTransaction(tx,principal,scope.scope_id,{conversation_id:turn.conversation_id,turn_id:turn.id,data_class:dataClass}));}
  };
  const runtime=await createChatRuntime({repository,authenticate,provider:guardedProvider,integration,workerOptions,chatOptions,handlerOptions,completionPolicy,completionAuthorizer});
  runtime.facade.memoryGenerationEnabled=true;
  Object.assign(runtime,{foundation,fence,recoveryReports,holderId,dataClass});
  runtime.syncTurnProjections=async(auth,scopeId,conversationId,turnId)=>{
    const {principal}=await runtime.facade.scoped(auth,scopeId);
    const turn=await runtime.chat.readTurn(auth,scopeId,conversationId,turnId);
    const capture=await foundation.captureCommittedConversation(principal,scopeId,{conversation_id:conversationId,turn_id:turnId,data_class:dataClass});
    const bindings=[];
    for(const b of turn.task_bindings){
      const input=Object.fromEntries(['conversation_id','turn_id','call_id','delegation_id','operation_id','run_id','task_id','request_hash','delegation_revision','grant_epoch'].map(k=>[k,b[k]]));
      bindings.push(await foundation.linkExecution(principal,scopeId,input));
    }
    return {capture,bindings,projection_hash:hash(bindings),...turn.continuations?{continuations:clone(turn.continuations)}:{},artifact_bridge:'explicit_uuid_projection_alias',task_snapshot_bridge:'persisted_owner_projection_revision'};
  };
  runtime.deleteChatSource=async(auth,scopeId,sourceId)=>{
    const {owner,principal}=await runtime.facade.scoped(auth,scopeId);
    const result=await normalized(()=>foundation.deleteSource(principal,scopeId,sourceId));
    // Notify observers only after the deletion transaction commits. No new poller.
    const rows=await repository.transaction(tx=>tx.list(owner,'native-chat-turns'));
    for(const t of rows)if(t.content_redacted){runtime.chat.active.get(`${owner}:${t.id}`)?.controller.abort();runtime.chat.notify(owner,t);}
    return result;
  };
  runtime.previewSourcePurge=async(auth,scope_id,source_id)=>{const {principal}=await runtime.facade.scoped(auth,scope_id);return buildSourcePurgePlan({repository,facade:runtime.facade,principal,scope_id,source_id});};
  attachFoundationProjections(runtime);
  runtime.fetchHandler=createFoundationFetchHandler(runtime);
  return runtime;
}
export async function createSupabaseFoundationChatRuntime({pgPool,authPgPool=pgPool,supabaseProjectUrl,provider,guardKey,workerOptions={}}){
  check(pgPool&&typeof pgPool.connect==='function',503,'database_not_configured');
  const scopeAuthority=new SupabasePgScopeAuthority(authPgPool);
  const authenticate=createSupabaseSessionVerifier({projectUrl:supabaseProjectUrl,scopeAuthority});
  return createFoundationChatRuntime({repository:new PostgresRepository(pgPool),authenticate,provider,guardKey,dataClass:'private',workerOptions});
}
