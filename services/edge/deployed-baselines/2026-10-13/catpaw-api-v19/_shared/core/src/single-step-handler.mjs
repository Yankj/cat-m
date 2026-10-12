import {publicWorkerContract,workerPromptFor,workerToolsFor} from './worker-output-contract.mjs';
import {check,hash,clone} from '../facade-r2/src/common.mjs';
import {collectRound} from './openrouter-provider.mjs';
import {validateCall,assistantToolMessage} from './tools.mjs';
import {evaluateReport} from './report-completion.mjs';
import {LOCAL_POLICY} from './local-output-facade.mjs';
// One model round OR one received tool operation. Same frozen state.local_model and original worker authority.
export function singleStepHandler(facade,provider,{finishOnArtifactReceipt=false}={}){
 return async(owner,task,ctx)=>{
  check(typeof ctx.assertLive==='function',503,'step_permission_not_configured');
  await ctx.guard();const frozen=await facade.repository.transaction(async tx=>{const admitted=await facade.admittedTask(tx,owner,task.id,{running:true});ctx.assertLive();return clone(admitted.run.frozen_request);});ctx.assertLive();
  check(frozen.policy===LOCAL_POLICY,409,'unmanaged_task');
  const prompt=workerPromptFor(frozen),tools=workerToolsFor(frozen);
  let state=clone(task.state.local_model??{step:0,messages:[{role:'user',content:JSON.stringify({output_contract:publicWorkerContract(frozen),goal:frozen.args.goal,requirements:frozen.args.requirements,stop_conditions:frozen.args.stop_conditions,messages:frozen.messages,context:frozen.context})}],round:null,artifact:null});
  const statePatch=()=>{ctx.assertLive();return {...task.state,local_model:clone(state)};};
  if(!state.round){
   check(state.step<3,503,'model_step_limit');check(hash(frozen.model_configuration)===hash(provider.identity),409,'model_configuration_changed');provider.assertReady?.();
   if(ctx.remainingMs()<25)return {status:'scheduled',state:statePatch()};
   await ctx.checkpoint({state:statePatch()});await ctx.beforeDispatch(hash({model:provider.identity,messages:state.messages,prompt,tools}));
   ctx.assertLive();const output=await collectRound(provider,{messages:clone(state.messages),system_prompt:prompt,tools,signal:ctx.signal,provider_context:{source_auth:frozen.source_auth,scope_id:frozen.scope.scope_id,conversation_id:frozen.conversation_id}});ctx.assertLive();
   for(const call of output.calls)validateCall(call,'worker');const stop=output.calls.findIndex(c=>['finish_task','ask_user'].includes(c.name));check(stop<0||stop===output.calls.length-1,422,'tool_after_task_terminal');
   const saved=await ctx.received({...output,next:0,results:[]});state=clone(saved.state.local_model);
   return {status:output.calls.length?'scheduled':'failed',...!output.calls.length?{error:'task_not_finished_with_artifact'}:{},state:statePatch()};
  }
  check(state.round.state==='received',409,'model_dispatch_outcome_unknown');
  const round=state.round;
  if(round.next===round.calls.length&&finishOnArtifactReceipt&&round.calls.length===1&&state.artifact_validation?.valid){await facade.assertTaskCompletion(owner,task.id,state.artifact,task.leaseId,{receipt:true});ctx.assertLive();state.finished=true;state.completion_source='server_validated_artifact_receipt';return {status:'succeeded',artifactIds:[state.artifact.artifact_id],state:statePatch()};}
  if(round.next===round.calls.length){state.messages.push(assistantToolMessage(round.text,round.calls),...round.results);state.step++;state.round=null;await ctx.checkpoint({state:statePatch()});return {status:'scheduled',state:statePatch()};}
  const call=round.calls[round.next];validateCall(call,'worker');
  if(call.name==='ask_user')return {status:'waiting_input',question:call.arguments.question,state:statePatch()};
  if(call.name==='finish_task'){check(state.artifact,422,'artifact_required_before_finish');await facade.assertTaskCompletion(owner,task.id,state.artifact,task.leaseId);ctx.assertLive();state.finished=true;state.completion_source='model_finish_task';return {status:'succeeded',artifactIds:[state.artifact.artifact_id],state:statePatch()};}
  const next=await ctx.localCommit(`${task.id}:${call.id}`,async(tx,admitted)=>{
   const artifact=await facade.publishArtifactInTransaction(tx,owner,task.id,{kind:'report',title:call.arguments.title,summary:call.arguments.summary,data:{content:call.arguments.content,source:'model_local_output',conversation_id:frozen.conversation_id}},admitted.leaseId,{assertLive:ctx.assertLive});ctx.assertLive();
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
  if(finishOnArtifactReceipt&&state.round.calls.length===1&&state.artifact_validation.valid){await facade.assertTaskCompletion(owner,task.id,state.artifact,task.leaseId,{receipt:true});ctx.assertLive();state.finished=true;state.completion_source='server_validated_artifact_receipt';return {status:'succeeded',artifactIds:[state.artifact.artifact_id],state:statePatch()};}
  return {status:'scheduled',state:statePatch()};
 };
}
