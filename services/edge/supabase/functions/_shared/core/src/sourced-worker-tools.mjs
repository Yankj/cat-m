import {check,clone,hash} from '../facade-r2/src/common.mjs';
import {samePlan} from './plan-contract.mjs';

// Each anonymous read has its own original durable dispatch/receipt. The model
// cursor advances in the receipt transaction only after every required read.
export async function readPublicSourceBatch(facade,owner,initial,ctx,call){
 check(facade.sourceService,503,'source_service_not_configured');
 const assertLive=ctx.assertLive??(()=>check(!ctx.signal.aborted,409,'lease_lost'));
 let task=initial;const frozen=await facade.effectiveRequest(owner,task.id);assertLive();
 const required=frozen.public_sources?.sources;check(required?.length,409,'source_catalog_invalid');
 for(const source of required){
  if(ctx.remainingMs&&ctx.remainingMs()<facade.sourceService.reader.timeoutMs+1000)return {status:'scheduled',task};
  const result=await facade.sourceService.readSource(owner,task.id,task.leaseId,source.source_id,{assertLive,signal:ctx.signal,commitCallback:async(tx,{task:current,toolResult})=>{
   assertLive();const state=clone(current.state.local_model),round=state?.round;
   check(round?.state==='received'&&round.calls[round.next]?.id===call.id&&hash(round.calls[round.next])===hash(call),409,'source_model_cursor_conflict');
   const previous=state.source_reads;
   const items=previous&&samePlan(previous.plan_reference,current.state.plan_binding)?previous.sources.filter(s=>s.source_id!==source.source_id):[];
   items.push(clone(toolResult));items.sort((a,b)=>a.source_id.localeCompare(b.source_id));
   state.source_reads={plan_reference:clone(current.state.plan_binding),sources:items};
   if(required.every(s=>items.some(r=>r.source_id===s.source_id))){
    round.results.push({role:'tool',tool_call_id:call.id,content:JSON.stringify({read:true,contract:'catpaw.public-source-read.v1',plan_reference:clone(current.state.plan_binding),sources:items})});round.next++;
   }
   await tx.put(owner,'tasks',{...current,state:{...current.state,local_model:state}});assertLive();
  }});assertLive();
  if(result.state!=='received')return {status:result.state==='unknown'?'outcome_unknown':'failed',error:result.state==='unknown'?'public_source_read_outcome_unknown':'public_source_read_failed',task};
  task=result.task;
  if(task.state.local_model.round.calls[task.state.local_model.round.next]?.id!==call.id)break;
 }
 return {status:'scheduled',task};
}
