import {workerInputContent,workerProviderContext,workerPromptFor,workerToolsFor} from './worker-output-contract.mjs';
import {check,hash,clone} from '../facade-r2/src/common.mjs';
import {collectRound} from './openrouter-provider.mjs';
import {validateProvidedToolCall,assistantToolMessage} from './tools.mjs';
import {readPublicSourceBatch} from './sourced-worker-tools.mjs';
import {evaluateReport} from './report-completion.mjs';
import {LOCAL_POLICY} from './local-output-facade.mjs';
// One model round OR one received tool operation. Same frozen state.local_model and original worker authority.
export function singleStepHandler(facade,provider,{finishOnArtifactReceipt=false}={}){
 return async(owner,task,ctx)=>{
  check(typeof ctx.assertLive==='function',503,'step_permission_not_configured');
  await ctx.guard();
  if(await facade.planExecutionDisposition(owner,task.id,task.leaseId)==='blocked_unknown')return {status:'outcome_unknown',error:'plan_waiting_for_original_outcome',state:clone(task.state)};
  if(await facade.planCheckpointReady(owner,task.id,task.leaseId)){
   const applied=await ctx.localCommit(`${task.id}:apply-plan`,(tx,current)=>facade.applyPlanCheckpoint(tx,owner,task.id,current.leaseId,{assertLive:ctx.assertLive}));ctx.assertLive();
   return {status:'scheduled',state:clone(applied.task.state)};
  }
  const frozen=await facade.effectiveRequest(owner,task.id);ctx.assertLive();
  check(frozen.policy===LOCAL_POLICY,409,'unmanaged_task');
  const prompt=workerPromptFor(frozen),tools=workerToolsFor(frozen);
  let state=clone(task.state.local_model??{step:0,messages:[{role:'user',content:JSON.stringify(workerInputContent(frozen))}],round:null,artifact:null});
  const statePatch=()=>{ctx.assertLive();return {...task.state,local_model:clone(state)};};
  const completion=async options=>{try{await facade.assertTaskCompletion(owner,task.id,state.artifact,task.leaseId,{...options,assertLive:ctx.assertLive});ctx.assertLive();return true;}catch(error){if(error.code==='plan_application_pending')return false;throw error;}};
  if(!state.round){
   check(state.step<3,503,'model_step_limit');check(hash(frozen.model_configuration)===hash(provider.identity),409,'model_configuration_changed');provider.assertReady?.();
   if(ctx.remainingMs()<25)return {status:'scheduled',state:statePatch()};
   await ctx.checkpoint({state:statePatch()});await ctx.beforeDispatch(hash({model:provider.identity,messages:state.messages,prompt,tools}));
   ctx.assertLive();const output=await collectRound(provider,{messages:clone(state.messages),system_prompt:prompt,tools,signal:ctx.signal,provider_context:workerProviderContext(frozen,state.messages)});ctx.assertLive();
   for(const call of output.calls)validateProvidedToolCall(call,'worker',tools);const stop=output.calls.findIndex(c=>['finish_task','ask_user'].includes(c.name));check(stop<0||stop===output.calls.length-1,422,'tool_after_task_terminal');
   const saved=await ctx.received({...output,next:0,results:[]});state=clone(saved.state.local_model);
   await facade.recordModelPlanReceipt(owner,task.id,task.leaseId,{assertLive:ctx.assertLive});ctx.assertLive();
   return {status:output.calls.length?'scheduled':'failed',...!output.calls.length?{error:'task_not_finished_with_artifact'}:{},state:statePatch()};
  }
  check(state.round.state==='received',409,'model_dispatch_outcome_unknown');
  // A durable received round is enough to recover its receipt without resending the model.
  await facade.recordModelPlanReceipt(owner,task.id,task.leaseId,{assertLive:ctx.assertLive});ctx.assertLive();
  const round=state.round;
  if(round.next===round.calls.length&&finishOnArtifactReceipt&&round.calls.length===1&&state.artifact_validation?.valid){if(!await completion({receipt:true}))return {status:'scheduled',state:statePatch()};state.finished=true;state.completion_source='server_validated_artifact_receipt';return {status:'succeeded',artifactIds:[state.artifact.artifact_id],state:statePatch()};}
  if(round.next===round.calls.length){state.messages.push(assistantToolMessage(round.text,round.calls),...round.results);state.step++;state.round=null;await ctx.checkpoint({state:statePatch()});return {status:'scheduled',state:statePatch()};}
  const call=round.calls[round.next];validateProvidedToolCall(call,'worker',tools);
  if(call.name==='ask_user')return {status:'waiting_input',question:call.arguments.question,state:statePatch()};
  if(call.name==='finish_task'){check(state.artifact,422,'artifact_required_before_finish');if(!await completion())return {status:'scheduled',state:statePatch()};state.finished=true;state.completion_source='model_finish_task';return {status:'succeeded',artifactIds:[state.artifact.artifact_id],state:statePatch()};}
  if(call.name==='read_public_sources_v1'){
   const result=await readPublicSourceBatch(facade,owner,task,ctx,call);ctx.assertLive();task=result.task;state=clone(task.state.local_model);
   return {status:result.status,...result.error?{error:result.error}:{},state:statePatch()};
  }
  const next=await ctx.localCommit(`${task.id}:${call.id}`,async(tx,admitted)=>{
   const artifact=call.name==='save_sourced_report_v1'
    ? await facade.publishSourcedReportInTransaction(tx,owner,task.id,call.arguments,admitted.leaseId,{assertLive:ctx.assertLive})
    : await facade.publishArtifactInTransaction(tx,owner,task.id,{kind:'report',title:call.arguments.title,summary:call.arguments.summary,data:{content:call.arguments.content,source:'model_local_output',conversation_id:frozen.conversation_id}},admitted.leaseId,{assertLive:ctx.assertLive});ctx.assertLive();
   state.artifact=artifact;state.artifact_validation=evaluateReport(frozen,call.arguments);
   // Ordinary local reports require explicit finish_task. A missing structured policy
   // is not a failed save/validation receipt for that mode; never imply task completion.
   const receipt=frozen.completion_contract?.mode==='model_finish_local_artifact'
    ? {saved:true,artifact_reference:artifact,completion_mode:'model_finish_local_artifact',finish_required:true}
    : {saved:true,artifact_reference:artifact,completion_validation:state.artifact_validation};
   round.results.push({role:'tool',tool_call_id:call.id,content:JSON.stringify(receipt)});round.next++;
   const current=await tx.get(owner,'tasks',task.id);ctx.assertLive();const stored=await tx.put(owner,'tasks',{...current,state:{...current.state,local_model:clone(state)}});ctx.assertLive();return stored;
  });
  ctx.assertLive();task=next;state=clone(next.state.local_model);
  if(finishOnArtifactReceipt&&state.round.calls.length===1&&state.artifact_validation.valid){if(!await completion({receipt:true}))return {status:'scheduled',state:statePatch()};state.finished=true;state.completion_source='server_validated_artifact_receipt';return {status:'succeeded',artifactIds:[state.artifact.artifact_id],state:statePatch()};}
  return {status:'scheduled',state:statePatch()};
 };
}
