import {check} from './core/facade-r2/src/common.mjs';
import {boundedTick} from './core/integration/edge-adapter/src/bounded-tick.mjs';
import {singleStepHandler} from './core/src/single-step-handler.mjs';
// One accepted turn's existing tasks only. Bounded best-effort work, not a durable scheduler.
export async function kickTurnTasks(runtime,{owner,principal,turnId},{maxSlices=6,maxWallMs=60000,now=Date.now,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms))}={}){
 const deadline=now()+maxWallMs;let slices=0;const outcomes=[];
 const limited=()=>({slices,reason:'bounded_kick_limit',outcomes});
 const turn=await runtime.repository.transaction(tx=>tx.get(owner,'native-chat-turns',turnId));
 if(now()+800>=deadline)return limited();
 if(!turn||turn.subject_id!==principal.subject_id||turn.source_auth?.session_id!==principal.session_id||turn.state!=='completed')return {slices:0,reason:'turn_not_eligible'};
 const ids=new Set(turn.task_bindings.map(b=>b.task_id));if(!ids.size)return {slices:0,reason:'no_tasks'};
 const admit=async(tx,actor,id,options)=>{check(now()<deadline,503,'invocation_closed');check(actor===owner&&ids.has(id),403,'scope_forbidden');const a=await runtime.facade.admittedTask(tx,actor,id,options);check(now()<deadline,503,'invocation_closed');check(a.run.frozen_request.subject_id===principal.subject_id&&a.run.frozen_request.source_auth?.session_id===principal.session_id,403,'scope_forbidden');return a;};
 const handler=singleStepHandler(runtime.facade,runtime.provider);
 const runStep=(actor,task,ctx)=>{
  // The handler checks assertLive after awaits and immediately before model transport.
  const assertLive=()=>{ctx.assertLive();check(now()+750<deadline,503,'step_deadline');};
  assertLive();
  return handler(actor,task,{...ctx,assertLive,remainingMs:()=>Math.min(ctx.remainingMs(),Math.max(0,deadline-now()-750))});
 };
 while(slices<maxSlices&&now()+800<deadline){
  const tasks=await runtime.repository.transaction(async tx=>Promise.all([...ids].map(id=>tx.get(owner,'tasks',id))));
  if(now()+800>=deadline)break;
  if(tasks.every(t=>!t||!['queued','scheduled'].includes(t.status)))return {slices,reason:'settled_or_attention',outcomes};
  const eligible=tasks.filter(t=>t&&['queued','scheduled'].includes(t.status));const next=Math.min(...eligible.map(t=>t.status==='queued'?now():Date.parse(t.nextRunAt)));
  if(next>now()){if(next>=deadline)return {slices,reason:'future_work',outcomes};await sleep(Math.min(next-now(),deadline-now()));if(now()+800>=deadline)break;continue;}
  const budget=Math.min(30000,deadline-now());if(budget<=800)break;
  const result=await boundedTick({repository:runtime.repository,owners:[owner],admitTask:admit,runStep,budgetMs:budget,settleReserveMs:750,leaseMs:60000,now});slices++;outcomes.push(...result.settled.map(t=>({task_id:t.task_id,status:t.status})));
  if(now()+800>=deadline)break;
  if(!result.claimed)return {slices,reason:'busy_or_fenced',outcomes};
 }
 return limited();
}
