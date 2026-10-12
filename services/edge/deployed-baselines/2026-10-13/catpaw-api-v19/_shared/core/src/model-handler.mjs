import {publicWorkerContract,workerPromptFor,workerToolsFor} from './worker-output-contract.mjs';
import { evaluateReport } from './report-completion.mjs';
import { ApiError,check,hash,clone } from '../facade-r2/src/common.mjs';
import { validateCall,assistantToolMessage } from './tools.mjs';
import { collectRound } from './openrouter-provider.mjs';
import { LOCAL_POLICY } from './local-output-facade.mjs';
export function modelHandler(facade,provider,{finishOnArtifactReceipt=false}={}){
  return async(owner,initial,ctx)=>{
    let task=initial;
    await ctx.guard();
    const frozen=await facade.repository.transaction(async tx=>{const {run}=await facade.admittedTask(tx,owner,task.id,{running:true});return clone(run.frozen_request);});
    check(frozen.policy===LOCAL_POLICY&&task.input.policy===LOCAL_POLICY,409,'unmanaged_task');
    let state=task.state.local_model??{step:0,messages:[{role:'user',content:JSON.stringify({output_contract:publicWorkerContract(frozen),goal:frozen.args.goal,requirements:frozen.args.requirements,stop_conditions:frozen.args.stop_conditions,messages:frozen.messages,context:frozen.context})}],round:null,artifact:null};
    if(state.round?.state==='dispatched')return {status:'outcome_unknown',error:'model_dispatch_outcome_unknown; do not automatically resend'};
    const checkpoint=async()=>{task=await ctx.checkpoint({state:{...task.state,local_model:clone(state)}});};
    const prompt=workerPromptFor(frozen),tools=workerToolsFor(frozen);
    for(;state.step<3;){
      await ctx.guard();let round=state.round;
      if(!round){
        check(hash(frozen.model_configuration)===hash(provider.identity),409,'model_configuration_changed');
        provider.assertReady?.();
        // Commit the dispatch intent before network. Recovery cannot know whether it was sent.
        state.round={state:'dispatched',request_hash:hash({model:provider.identity,messages:state.messages,prompt,tools})};await checkpoint();
        try{
          const output=await collectRound(provider,{messages:clone(state.messages),system_prompt:prompt,tools,signal:ctx.signal,provider_context:{source_auth:frozen.source_auth,scope_id:frozen.scope.scope_id,conversation_id:frozen.conversation_id}});
          await ctx.guard();for(const call of output.calls)validateCall(call,'worker');
          const stop=output.calls.findIndex(c=>['finish_task','ask_user'].includes(c.name));check(stop<0||stop===output.calls.length-1,422,'tool_after_task_terminal');
          round={state:'received',...output,next:0,results:[]};state.round=round;await checkpoint();
        }catch(error){
          if(ctx.signal.aborted||error.name==='LostLeaseError')throw error;
          // A received transport/protocol failure is never retried automatically.
          state.round={...state.round,error:error instanceof ApiError?error.code:'provider_failed'};await checkpoint();
          return {status:error instanceof ApiError&&error.reconciliation?'outcome_unknown':'failed',error:error instanceof ApiError?error.code:'provider_failed'};
        }
      }
      if(!round.calls.length)return {status:'failed',error:'task_not_finished_with_artifact'};
      while(round.next<round.calls.length){
        const call=round.calls[round.next];validateCall(call,'worker');await ctx.guard();let result;
        if(call.name==='save_artifact'){
          state.artifact=await facade.publishArtifact(owner,task.id,{kind:'report',title:call.arguments.title,summary:call.arguments.summary,data:{content:call.arguments.content,source:'model_local_output',conversation_id:frozen.conversation_id}},task.leaseId);
          state.artifact_validation=evaluateReport(frozen,call.arguments);
          result={saved:true,artifact_reference:state.artifact,completion_validation:state.artifact_validation};
        }else if(call.name==='finish_task'){
          check(state.artifact,422,'artifact_required_before_finish');
          await facade.assertTaskCompletion(owner,task.id,state.artifact,task.leaseId);
          await checkpoint();await ctx.event('result','Local report saved',state.artifact.content_hash);
          return {status:'succeeded',result:call.arguments.summary,artifactIds:[state.artifact.artifact_id],state:{...task.state,local_model:{...clone(state),finished:true,completion_source:'model_finish_task'}}};
        }else{
          await checkpoint();return {status:'waiting_input',question:call.arguments.question,state:{...task.state,local_model:clone(state)}};
        }
        round.results.push({role:'tool',tool_call_id:call.id,content:JSON.stringify(result)});
        // Increment durably before the next model/tool; repeated save after a crash is hash-idempotent.
        round.next++;await checkpoint();
        if(finishOnArtifactReceipt&&call.name==='save_artifact'&&round.calls.length===1&&round.next===round.calls.length&&state.artifact_validation.valid){
          await facade.assertTaskCompletion(owner,task.id,state.artifact,task.leaseId,{receipt:true});await ctx.guard();await ctx.event('result','Local report committed',state.artifact.content_hash);
          return {status:'succeeded',result:call.arguments.summary,artifactIds:[state.artifact.artifact_id],state:{...task.state,local_model:{...clone(state),finished:true,completion_source:'server_validated_artifact_receipt'}}};
        }
      }
      state.messages.push(assistantToolMessage(round.text,round.calls),...round.results);state.step++;state.round=null;await checkpoint();
    }
    return {status:'failed',error:'model_step_limit'};
  };
}
