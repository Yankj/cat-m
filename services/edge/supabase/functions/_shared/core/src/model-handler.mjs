import {workerInputContent,workerProviderContext,workerPromptFor,workerToolsFor} from './worker-output-contract.mjs';
import { evaluateReport } from './report-completion.mjs';
import { ApiError,check,hash,clone } from '../facade-r2/src/common.mjs';
import { validateProvidedToolCall,assistantToolMessage } from './tools.mjs';
import {readPublicSourceBatch} from './sourced-worker-tools.mjs';
import { collectRound } from './openrouter-provider.mjs';
import { LOCAL_POLICY } from './local-output-facade.mjs';
export function modelHandler(facade,provider,{finishOnArtifactReceipt=false}={}){
  return async(owner,initial,ctx)=>{
    let task=initial;
    await ctx.guard();
    if(await facade.planExecutionDisposition(owner,task.id,task.leaseId)==='blocked_unknown')return {status:'outcome_unknown',error:'plan_waiting_for_original_outcome',state:clone(task.state)};
    if(await facade.planCheckpointReady(owner,task.id,task.leaseId)){
      const applied=await facade.repository.transaction(tx=>facade.applyPlanCheckpoint(tx,owner,task.id,task.leaseId,{assertLive:()=>check(!ctx.signal.aborted,409,'lease_lost')}));await ctx.guard();return {status:'scheduled',state:clone(applied.task.state)};
    }
    const frozen=await facade.effectiveRequest(owner,task.id);
    check(frozen.work_grant_reference===undefined,409,'accepted_work_whole_executor_unsupported');
    check(frozen.policy===LOCAL_POLICY&&task.input.policy===LOCAL_POLICY,409,'unmanaged_task');
    let state=task.state.local_model??{step:0,messages:[{role:'user',content:JSON.stringify(workerInputContent(frozen))}],round:null,artifact:null};
    if(state.round?.state==='dispatched')return {status:'outcome_unknown',error:'model_dispatch_outcome_unknown; do not automatically resend'};
    const checkpoint=async()=>{task=await ctx.checkpoint({state:{...task.state,local_model:clone(state)}});};
    const completion=async options=>{try{await facade.assertTaskCompletion(owner,task.id,state.artifact,task.leaseId,{...options,assertLive:()=>check(!ctx.signal.aborted,409,'lease_lost')});await ctx.guard();return true;}catch(error){if(error.code==='plan_application_pending')return false;throw error;}};
    const prompt=workerPromptFor(frozen),tools=workerToolsFor(frozen);
    for(;state.step<3;){
      await ctx.guard();let round=state.round;
      if(!round){
        check(hash(frozen.model_configuration)===hash(provider.identity),409,'model_configuration_changed');
        provider.assertReady?.();
        // Commit the dispatch intent before network. Recovery cannot know whether it was sent.
        state.round={state:'dispatched',request_hash:hash({model:provider.identity,messages:state.messages,prompt,tools})};await checkpoint();
        try{
          const output=await collectRound(provider,{messages:clone(state.messages),system_prompt:prompt,tools,signal:ctx.signal,provider_context:workerProviderContext(frozen,state.messages)});
          await ctx.guard();for(const call of output.calls)validateProvidedToolCall(call,'worker',tools);
          const stop=output.calls.findIndex(c=>['finish_task','ask_user'].includes(c.name));check(stop<0||stop===output.calls.length-1,422,'tool_after_task_terminal');
          round={state:'received',request_hash:state.round.request_hash,...output,next:0,results:[]};state.round=round;await checkpoint();
          await facade.recordModelPlanReceipt(owner,task.id,task.leaseId);await ctx.guard();
        }catch(error){
          if(ctx.signal.aborted||error.name==='LostLeaseError')throw error;
          // A received transport/protocol failure is never retried automatically.
          state.round={...state.round,error:error instanceof ApiError?error.code:'provider_failed'};await checkpoint();
          return {status:error instanceof ApiError&&error.reconciliation?'outcome_unknown':'failed',error:error instanceof ApiError?error.code:'provider_failed'};
        }
      }
      if(!round.calls.length)return {status:'failed',error:'task_not_finished_with_artifact'};
      await facade.recordModelPlanReceipt(owner,task.id,task.leaseId);await ctx.guard();
      while(round.next<round.calls.length){
        const call=round.calls[round.next];validateProvidedToolCall(call,'worker',tools);await ctx.guard();let result;
        if(await facade.planExecutionDisposition(owner,task.id,task.leaseId)==='blocked_unknown')return {status:'outcome_unknown',error:'plan_waiting_for_original_outcome',state:{...task.state,local_model:clone(state)}};
        if(['finish_task','ask_user'].includes(call.name)&&await facade.planCheckpointReady(owner,task.id,task.leaseId)){
          const applied=await facade.repository.transaction(tx=>facade.applyPlanCheckpoint(tx,owner,task.id,task.leaseId,{assertLive:()=>check(!ctx.signal.aborted,409,'lease_lost')}));await ctx.guard();return {status:'scheduled',state:clone(applied.task.state)};
        }
        if(call.name==='read_public_sources_v1'){
          const read=await readPublicSourceBatch(facade,owner,task,ctx,call);await ctx.guard();task=read.task;state=clone(task.state.local_model);
          // Yield with the original durable cursor. The legacy worker does not own a new scheduler.
          return {status:read.status,...read.status==='scheduled'?{nextRunAt:new Date(Date.now()+1000).toISOString()}:{},...read.error?{error:read.error}:{},state:clone(task.state)};
        }else if(call.name==='save_sourced_report_v1'){
          task=await facade.repository.transaction(async tx=>{
            const assertLive=()=>check(!ctx.signal.aborted,409,'lease_lost');
            state.artifact=await facade.publishSourcedReportInTransaction(tx,owner,task.id,call.arguments,task.leaseId,{assertLive});
            state.artifact_validation=evaluateReport(frozen,call.arguments);
            round.results.push({role:'tool',tool_call_id:call.id,content:JSON.stringify({saved:true,artifact_reference:state.artifact,completion_validation:state.artifact_validation})});round.next++;
            const current=await tx.get(owner,'tasks',task.id);assertLive();const stored=await tx.put(owner,'tasks',{...current,state:{...current.state,local_model:clone(state)}});assertLive();
            const admitted=await facade.admittedTask(tx,owner,task.id,{running:true});assertLive();
            check(admitted.task.leaseId===task.leaseId&&Date.parse(admitted.task.leaseUntil)>Date.now(),409,'lease_lost');return stored;
          });await ctx.guard();continue;
        }else if(call.name==='save_artifact'){
          state.artifact=await facade.publishArtifact(owner,task.id,{kind:'report',title:call.arguments.title,summary:call.arguments.summary,data:{content:call.arguments.content,source:'model_local_output',conversation_id:frozen.conversation_id}},task.leaseId);
          state.artifact_validation=evaluateReport(frozen,call.arguments);
          result={saved:true,artifact_reference:state.artifact,completion_validation:state.artifact_validation};
        }else if(call.name==='finish_task'){
          check(state.artifact,422,'artifact_required_before_finish');
          if(!await completion())return {status:'scheduled',state:{...task.state,local_model:clone(state)}};
          await checkpoint();await ctx.event('result','Local report saved',state.artifact.content_hash);
          return {status:'succeeded',result:call.arguments.summary,artifactIds:[state.artifact.artifact_id],state:{...task.state,local_model:{...clone(state),finished:true,completion_source:'model_finish_task'}}};
        }else{
          await checkpoint();return {status:'waiting_input',question:call.arguments.question,state:{...task.state,local_model:clone(state)}};
        }
        round.results.push({role:'tool',tool_call_id:call.id,content:JSON.stringify(result)});
        // Increment durably before the next model/tool; repeated save after a crash is hash-idempotent.
        round.next++;await checkpoint();
        if(finishOnArtifactReceipt&&call.name==='save_artifact'&&round.calls.length===1&&round.next===round.calls.length&&state.artifact_validation.valid){
          if(!await completion({receipt:true}))return {status:'scheduled',state:{...task.state,local_model:clone(state)}};await ctx.event('result','Local report committed',state.artifact.content_hash);
          return {status:'succeeded',result:call.arguments.summary,artifactIds:[state.artifact.artifact_id],state:{...task.state,local_model:{...clone(state),finished:true,completion_source:'server_validated_artifact_receipt'}}};
        }
      }
      state.messages.push(assistantToolMessage(round.text,round.calls),...round.results);state.step++;state.round=null;await checkpoint();
    }
    return {status:'failed',error:'model_step_limit'};
  };
}
