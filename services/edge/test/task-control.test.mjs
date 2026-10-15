import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {consentId} from '../supabase/functions/_shared/consent.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {boundedTick} from '../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-tick.mjs';
import {singleStepHandler} from '../supabase/functions/_shared/core/src/single-step-handler.mjs';
import {controlTask} from '../supabase/functions/_shared/core/src/task-control-service.mjs';
import {TASK_CONTROL_OPERATIONS,TASK_CONTROL_LIMITS,taskControlReceiptHash} from '../supabase/functions/_shared/core/src/task-control-contract.mjs';
import {TaskWorker,LostLeaseError} from '../supabase/functions/_shared/core/integration/edge-adapter/vendor/openmuse/runtime/engine/worker.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const content={title:'Offline local plan',goal:'Summarize supplied fictional data',requirements:'Do not read the web',stop_conditions:['Save only a local report'],steps:['compose','save','verify'].map(id=>({id,title:id,detail:''}))};
async function fixture({ordinary=false,autoKick=false,resumeTask=false,alternateViewer=false,workerBeforeYield=null}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
 const retained=[],calls=[];let workerCalls=0,now=Date.now();const viewer={...principal,session_id:randomUUID()};
 const provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',assertReady(){},async *stream(input){calls.push(input);if(ordinary){yield{type:'text_delta',text:'Fictional answer'};yield{type:'done',finish_reason:'stop'};}else if(input.tools.some(t=>t.function.name==='delegate_plan_v1')){yield{type:'tool_call',id:randomUUID(),name:'delegate_plan_v1',arguments:content};yield{type:'done',finish_reason:'tool_calls'};}else{
  assert.ok(resumeTask,'unexpected worker call');workerCalls++;if(workerBeforeYield)await workerBeforeYield({repository,scope,input});
  if(workerCalls===1)yield{type:'tool_call',id:randomUUID(),name:'ask_user',arguments:{question:'请通过原计划补充要求'}};
  else{yield{type:'tool_call',id:randomUUID(),name:'save_artifact',arguments:{title:'Resumed same task',summary:'Offline fictional report',content:JSON.stringify(input.messages)}};yield{type:'tool_call',id:randomUUID(),name:'finish_task',arguments:{summary:'Current plan saved'}};}
  yield{type:'done',finish_reason:'tool_calls'};
 }}};
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'},config=readConfig(k=>values[k]);
 const sourceChecker=async(tx,source,identity)=>{const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);assert.equal(source.scope_id,identity.scope_id);if(row?.subject_id!==source.subject_id||row.state!=='active')throw new ApiError(409,'grant_conflict');};
 const runtime=await createCloudRuntime({repository,config,provider,sourceChecker,authenticate:auth=>{if(auth==='Bearer viewer'&&alternateViewer)return viewer;if(auth!=='Bearer offline')throw new ApiError(401,'unauthorized');return principal;},retain:p=>retained.push(p),autoKick,kickOptions:{now:()=>now,sleep:async ms=>{now+=ms;}},diagnostic:()=>{}});
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);
 await repository.transaction(async tx=>{await tx.put(membershipOwner(principal.issuer),'scope-memberships',{id:principal.subject_id,scopes:[scope]});for(const actor of [principal,viewer])await tx.put(membershipOwner(actor.issuer),'app-sessions',{id:actor.session_id,subject_id:actor.subject_id,state:'active',expires_at:9999999999});});
 const cid=randomUUID(),tid=randomUUID(),base='/catpaw/chat/v1/scopes/'+scope.scope_id+'/conversations',consentPath='/catpaw/privacy/v1/scopes/'+scope.scope_id+'/conversations/'+cid+'/model-consent';
 const req=(path,body,auth='Bearer offline')=>runtime.api(new Request('https://offline.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:auth,'Content-Type':'application/json'},...body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)}}));
 assert.equal((await req(base,{conversation_id:cid})).status,201);assert.equal((await req(consentPath,{decision:'allow',expected_revision:0,route_hash:config.routeHash})).status,200);
 const response=await req(base+'/'+cid+'/turns',{turn_id:tid,expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:ordinary?'Answer this fictional question':'Create a local report plan'},context:[]});assert.equal(response.status,200);await response.body.getReader().cancel();await Promise.all(retained);
 const turn=(await(await req(base+'/'+cid+'/turns/'+tid)).json()).turn;assert.equal(turn.state,'completed');
 const binding=turn.task_bindings[0],path=binding?'/catpaw/plans/v1/scopes/'+scope.scope_id+'/runs/'+binding.run_id+'/plan':null;
 return{repository,runtime,principal,viewer,scope,cid,req,turn,binding,path,calls,config,retained,workers:()=>workerCalls,flush:()=>Promise.all(retained)};
}

const json=async(response,status=200)=>{const v=await response.json();assert.equal(response.status,status,JSON.stringify(v));return v;};
const controlPath=f=>`/catpaw/controls/v1/scopes/${f.scope.scope_id}/runs/${f.binding.run_id}/control`;
const input=(s,action)=>({operation_id:randomUUID(),action,expected_execution_revision:s.execution_revision,expected_snapshot_hash:s.snapshot_hash,expected_grant_epoch:s.grant_epoch,expected_plan_revision:s.plan_reference.revision,expected_plan_hash:s.plan_reference.plan_hash});
test('typed task pause/resume preserves original grant and same task while reads and replay never wake',async()=>{
 const f=await fixture({resumeTask:true});try {
  const owner=f.runtime.facade.owner(f.scope),path=controlPath(f),before=await f.repository.transaction(tx=>tx.get(owner,'catpaw-runs',f.binding.run_id)),count=f.calls.length,first=(await json(await f.req(path))).control;
  assert.equal(first.can_pause,true);assert.equal(first.execution_revision,0);const pause=input(first,'pause'),paused=await json(await f.req(path+'/operations',pause));
  assert.equal(paused.control.task_status,'paused');assert.equal(paused.control.can_resume,true);assert.equal(paused.operation.accepted_execution_revision,1);assert.equal(f.calls.length,count);assert.equal(paused.operation.state,'applied');
  const original=await json(await f.req(path+'/operations/'+pause.operation_id));assert.deepEqual(original.operation,paused.operation);assert.deepEqual((await json(await f.req(path+'/operations',pause))).operation,paused.operation);assert.equal(f.calls.length,count);
  const resume=input(paused.control,'resume'),resumed=await json(await f.req(path+'/operations',resume));assert.equal(resumed.control.task_status,'scheduled');assert.equal(resumed.control.execution_revision,2);assert.equal(resumed.control.grant_epoch,before.grant_epoch);
  await f.repository.transaction(async tx=>{const run=await tx.get(owner,'catpaw-runs',before.id),d=await tx.get(owner,'catpaw-delegations',run.delegation_id),task=await tx.get(owner,'tasks',run.task_id);assert.deepEqual(run.frozen_request,before.frozen_request);assert.equal(run.request_hash,before.request_hash);assert.equal(d.state,'active');assert.equal(d.grant_epoch,before.grant_epoch);assert.equal(d.revision,before.delegation_revision);assert.equal(task.id,before.task_id);assert.equal(task.leaseId,null);await f.runtime.facade.admittedTask(tx,owner,task.id);});
  assert.equal(f.calls.length,count);assert.equal((await f.repository.transaction(tx=>tx.list(owner,'tasks'))).length,1);
 }finally{await f.runtime.worker.stop();}
});
test('exact control CAS rejects stale snapshot and changed identity without new domain rows',async()=>{
 const f=await fixture();try {const path=controlPath(f),snapshot=(await json(await f.req(path))).control,before=f.repository.snapshot(),count=f.calls.length;
  for(const mutation of [x=>({...x,expected_snapshot_hash:'0'.repeat(64)}),x=>({...x,expected_execution_revision:99}),x=>({...x,expected_plan_hash:'0'.repeat(64)}),x=>({...x,expected_grant_epoch:2})]){const r=await f.req(path+'/operations',mutation(input(snapshot,'pause')));assert.equal(r.status,409);assert.deepEqual(f.repository.snapshot(),before);}
  assert.equal((await f.req(path.replace(f.binding.run_id,randomUUID()))).status,404);assert.equal((await f.req(path.replace(f.scope.scope_id,randomUUID()))).status,403);assert.equal(f.calls.length,count);
 }finally{await f.runtime.worker.stop();}
});
test('original model dispatch remains visible through pause/cancel and cannot be resumed or replayed',async()=>{
 const f=await fixture();try {const owner=f.runtime.facade.owner(f.scope),path=controlPath(f),requestHash='a'.repeat(64);
  await f.repository.transaction(async tx=>{const t=await tx.get(owner,'tasks',f.binding.task_id);await tx.put(owner,'tasks',{...t,status:'running',leaseId:randomUUID(),leaseUntil:new Date(Date.now()+10000).toISOString(),state:{...t.state,local_model:{step:0,messages:[],round:{state:'dispatched',request_hash:requestHash}}}});});
  const count=f.calls.length,first=(await json(await f.req(path))).control;assert.deepEqual(first.unresolved_operations,[{kind:'model',operation_id:requestHash,state:'dispatched',can_retry:false}]);
  const paused=await json(await f.req(path+'/operations',input(first,'pause')));assert.equal(paused.control.task_status,'paused');assert.equal(paused.control.can_resume,false);const rejected=await json(await f.req(path+'/operations',input(paused.control,'resume')),409);assert.equal(rejected.error.code,'control_original_outcome_unknown');
  const cancelled=await json(await f.req(path+'/operations',input(paused.control,'revoke')));assert.equal(cancelled.control.task_status,'cancelled');assert.deepEqual(cancelled.control.unresolved_operations,first.unresolved_operations);assert.equal(f.calls.length,count);assert.equal(cancelled.control.can_resume,false);
 }finally{await f.runtime.worker.stop();}
});
test('control acknowledgement replay preserves original operation and has no second grant or execution change',async()=>{
 const f=await fixture();try {const path=controlPath(f),s=(await json(await f.req(path))).control,pause=input(s,'pause'),p=await json(await f.req(path+'/operations',pause));
  const resumed=await json(await f.req(path+'/operations',input(p.control,'resume'))),before=f.repository.snapshot(),count=f.calls.length;
  const old=await json(await f.req(path+'/operations/'+pause.operation_id));assert.deepEqual(old.operation,p.operation);assert.equal(old.control.execution_revision,resumed.control.execution_revision);
  const replay=await json(await f.req(path+'/operations',pause));assert.deepEqual(replay.operation,p.operation);assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,count);
  const changed=await f.req(path+'/operations',{...pause,action:'revoke'});assert.equal(changed.status,409);assert.deepEqual(f.repository.snapshot(),before);
 }finally{await f.runtime.worker.stop();}
});
test('resumed same-task work reaches received input and amended report through both existing workers',async()=>{
 for(const whole of [false,true]){const f=await fixture({resumeTask:true});try{
  const path=controlPath(f),owner=f.runtime.facade.owner(f.scope),run=await f.repository.transaction(tx=>tx.get(owner,'catpaw-runs',f.binding.run_id));
  const first=(await json(await f.req(path))).control,p=await json(await f.req(path+'/operations',input(first,'pause')));await json(await f.req(path+'/operations',input(p.control,'resume')));
  let now=Date.now();const tick=async()=>{now=Math.max(now,Date.now())+1000;if(whole){const t=await f.repository.transaction(tx=>tx.get(owner,'tasks',f.binding.task_id));if(['queued','scheduled'].includes(t.status))await f.runtime.worker.run(owner,t);}else await boundedTick({repository:f.repository,owners:[owner],admitTask:f.runtime.facade.admittedTask.bind(f.runtime.facade),runStep:singleStepHandler(f.runtime.facade,f.runtime.provider),now:()=>now,budgetMs:10000,settleReserveMs:500,leaseMs:60000});now+=10000;};
  for(let i=0;i<5;i++)await tick();assert.equal((await f.repository.transaction(tx=>tx.get(owner,'tasks',f.binding.task_id))).status,'waiting_input');
  const plan=(await json(await f.req(f.path))).plan;await json(await f.req(f.path+'/amendments',{operation_id:randomUUID(),expected_revision:plan.accepted_revision,expected_plan_hash:plan.accepted_plan_hash,expected_grant_epoch:1,content:{...content,requirements:'Received requested detail; save the same report'}}));
  for(let i=0;i<8;i++)await tick();const task=await f.repository.transaction(tx=>tx.get(owner,'tasks',f.binding.task_id)),after=await f.repository.transaction(tx=>tx.get(owner,'catpaw-runs',run.id));
  assert.equal(task.status,'succeeded');assert.equal(task.id,run.task_id);assert.deepEqual(after.frozen_request,run.frozen_request);assert.equal(after.request_hash,run.request_hash);assert.equal((await f.repository.transaction(tx=>tx.list(owner,'tasks'))).length,1);assert.equal(after.artifact_references.length,1);
  for(const call of f.calls.filter(c=>c.provider_context.task_execution)){assert.equal(call.provider_context.task_execution.execution_revision,2);assert.equal(call.provider_context.task_execution.task_id,task.id);assert.ok(call.provider_context.task_execution.lease_id);}
  assert.equal((await json(await f.req(path))).control.can_pause,false);
 }finally{await f.runtime.worker.stop();}}
});
test('durably paused, revoked or taken-over task fences late dispatch through both existing workers',async()=>{
 for(const whole of [false,true])for(const action of ['pause','revoke','takeover']){const f=await fixture({resumeTask:true});try{
  const owner=f.runtime.facade.owner(f.scope),path=controlPath(f),record=f.repository.transaction.bind(f.repository);let intercepted=false,oldLease,newLease;
  // The first transaction commits dispatch. A separate committed transaction then stops/takes
  // over the task before the old caller receives its stale result. A same-transaction injection
  // would roll the stop back with the checkpoint and does not model a durable user decision.
  f.repository.transaction=async(...args)=>{
   const result=await record(...args);
   const row=result?.state?.local_model?.round?.state==='dispatched'?result:result?.task?.state?.local_model?.round?.state==='dispatched'?result.task:null;
   if(!intercepted&&row?.id===f.binding.task_id&&row.status==='running'){
    intercepted=true;oldLease=row.leaseId;
    if(action==='takeover')await record(async tx=>{const t=await tx.get(owner,'tasks',row.id);newLease=randomUUID();await tx.put(owner,'tasks',{...t,leaseId:newLease,leaseUntil:new Date(Date.now()+60000).toISOString()});await tx.put(owner,'runs',{id:newLease,taskId:t.id,status:'running',startedAt:new Date().toISOString()});});
    else{const s=(await json(await f.req(path))).control;await json(await f.req(path+'/operations',input(s,action)));}
   }
   return result;
  };
  const count=f.calls.length;
  if(whole){const t=await record(tx=>tx.get(owner,'tasks',f.binding.task_id));await f.runtime.worker.run(owner,t);}
  else await boundedTick({repository:f.repository,owners:[owner],admitTask:f.runtime.facade.admittedTask.bind(f.runtime.facade),runStep:singleStepHandler(f.runtime.facade,f.runtime.provider),budgetMs:10000,settleReserveMs:500,leaseMs:60000});
  assert.equal(intercepted,true);assert.equal(f.calls.length,count);
  const current=(await json(await f.req(path))).control,task=await record(tx=>tx.get(owner,'tasks',f.binding.task_id));
  assert.equal(current.task_status,action==='pause'?'paused':action==='revoke'?'cancelled':'running');assert.equal(current.can_resume,false);
  assert.deepEqual(current.unresolved_operations,[{kind:'model',operation_id:task.state.local_model.round.request_hash,state:'dispatched',can_retry:false}]);
  assert.equal(task.leaseId,action==='takeover'?newLease:null);assert.ok(['failed','interrupted'].includes((await record(tx=>tx.get(owner,'runs',oldLease))).status));
 }finally{await f.runtime.worker.stop();}}
});
test('source and memory changes cannot be upgraded through an explicit resume request',async()=>{
 for(const reason of ['source','consent','memory']){const f=await fixture({alternateViewer:true});try{const path=controlPath(f),p=await json(await f.req(path+'/operations',input((await json(await f.req(path))).control,'pause'))),count=f.calls.length,owner=f.runtime.facade.owner(f.scope);
  await f.repository.transaction(async tx=>{if(reason==='source'){const o=membershipOwner(f.principal.issuer),s=await tx.get(o,'app-sessions',f.principal.session_id);await tx.put(o,'app-sessions',{...s,state:'revoked'});}if(reason==='consent'){const id=consentId(f.principal.subject_id,f.cid),s=await tx.get(owner,'provider-consents',id);await tx.put(owner,'provider-consents',{...s,decision:'deny'});}if(reason==='memory')await tx.withScope(f.scope.scope_id,async scoped=>{const s=await scoped.scope();await scoped.saveScope({...s,generation:s.generation+1});});});
  const current=(await json(await f.req(path,undefined,'Bearer viewer'))).control;assert.equal(current.source_authorization_current,false);assert.equal(current.can_resume,false);const r=await json(await f.req(path+'/operations',input(current,'resume'),'Bearer viewer'),403);assert.equal(r.error.code,'control_source_not_current');assert.equal(f.calls.length,count);assert.equal(current.execution_revision,p.control.execution_revision);
 }finally{await f.runtime.worker.stop();}}
});
test('strict task-control JSON refuses decoded duplicate keys and unsafe numeric expectations before mutation',async()=>{
 const f=await fixture();try {const path=controlPath(f),s=(await json(await f.req(path))).control,before=f.repository.snapshot();
  const valid=JSON.stringify(input(s,'pause')),duplicate=valid.replace('"action":"pause"','"action":"resume","\\u0061ction":"pause"');
  const r=await json(await f.req(path+'/operations',duplicate),422);assert.equal(r.error.code,'control_duplicate_key');
  for(const n of [true,-1,1.5,Number.MAX_SAFE_INTEGER+1])assert.equal((await f.req(path+'/operations',{...input(s,'pause'),expected_execution_revision:n})).status,422);
  assert.deepEqual(f.repository.snapshot(),before);
 }finally{await f.runtime.worker.stop();}
});

test('whole worker port cannot take over a still-live lease or write a checkpoint after lease expiry',async()=>{
 const f=await fixture();try{const owner=f.runtime.facade.owner(f.scope),store=f.runtime.store,taskID=f.binding.task_id,initial=await store.get(owner,'tasks',taskID),lease=randomUUID();
  const claimed=await store.compareAndSwap(owner,'tasks',taskID,{status:initial.status,leaseId:null},{status:'running',leaseId:lease,leaseUntil:new Date(Date.now()+60000).toISOString()});assert.ok(claimed);
  const current=await store.get(owner,'tasks',taskID),stolen=await store.compareAndSwap(owner,'tasks',taskID,{status:'running',leaseId:lease,leaseUntil:current.leaseUntil},{status:'running',leaseId:randomUUID(),leaseUntil:new Date(Date.now()+60000).toISOString()});assert.equal(stolen,null);
  await f.repository.transaction(async tx=>{const t=await tx.get(owner,'tasks',taskID);await tx.put(owner,'tasks',{...t,leaseUntil:new Date(Date.now()-1000).toISOString(),state:{...t.state,local_model:{round:{state:'dispatched',request_hash:'b'.repeat(64)}}}});});
  const before=f.repository.snapshot(),expired=await store.get(owner,'tasks',taskID),received=await store.compareAndSwap(owner,'tasks',taskID,{status:'running',leaseId:lease},{state:{...expired.state,local_model:{round:{state:'received',request_hash:'b'.repeat(64)}}}});assert.equal(received,null);assert.deepEqual(f.repository.snapshot(),before);
 }finally{await f.runtime.worker.stop();}
});
test('abort cleanup preserves original dispatched identity and never queues a second send through either worker',async()=>{
 for(const whole of [false,true]){const f=await fixture();try{const owner=f.runtime.facade.owner(f.scope),operationHash='c'.repeat(64),count=f.calls.length;
  if(whole){let worker;worker=new TaskWorker(f.runtime.store,async(o,t,ctx)=>{await ctx.checkpoint({state:{...t.state,local_model:{round:{state:'dispatched',request_hash:operationHash}}}});worker.abort(t.id);throw new LostLeaseError();});const t=await f.runtime.store.get(owner,'tasks',f.binding.task_id);await worker.run(owner,t);await worker.stop();}
  else await boundedTick({repository:f.repository,owners:[owner],admitTask:f.runtime.facade.admittedTask.bind(f.runtime.facade),runStep:async(o,t,ctx)=>{await ctx.beforeDispatch(operationHash);throw new LostLeaseError();},budgetMs:10000,settleReserveMs:500,leaseMs:60000});
  const t=await f.runtime.store.get(owner,'tasks',f.binding.task_id);assert.equal(t.status,'outcome_unknown');assert.equal(t.state.local_model.round.request_hash,operationHash);assert.equal(t.state.local_model.round.state,'dispatched');
  await f.runtime.worker.tick();assert.equal(f.calls.length,count);assert.equal((await f.runtime.store.get(owner,'tasks',f.binding.task_id)).status,'outcome_unknown');
 }finally{await f.runtime.worker.stop();}}
});

test('late received model output cannot checkpoint after lease expiry; takeover reads original dispatch without retry',async()=>{
 for(const whole of [false,true]){let expired=false;const f=await fixture({resumeTask:true,workerBeforeYield:async({repository,scope,input})=>{
  assert.ok(input.provider_context.task_execution);const owner='catpaw:'+hash({profile:scope.profile_id,workspace:scope.workspace_id});
  await repository.transaction(async tx=>{const t=await tx.get(owner,'tasks',input.provider_context.task_execution.task_id);await tx.put(owner,'tasks',{...t,leaseUntil:new Date(Date.now()-1000).toISOString()});});expired=true;
 }});try{const owner=f.runtime.facade.owner(f.scope),count=f.calls.length;
  const tick=async()=>{if(whole)await f.runtime.worker.run(owner,await f.runtime.store.get(owner,'tasks',f.binding.task_id));else await boundedTick({repository:f.repository,owners:[owner],admitTask:f.runtime.facade.admittedTask.bind(f.runtime.facade),runStep:singleStepHandler(f.runtime.facade,f.runtime.provider),budgetMs:10000,settleReserveMs:500,leaseMs:60000});};
  await tick();assert.equal(expired,true);const t=await f.runtime.store.get(owner,'tasks',f.binding.task_id);assert.equal(t.status,'running');assert.equal(t.state.local_model.round.state,'dispatched');const operation=t.state.local_model.round.request_hash;assert.equal(f.calls.length,count+1);
  await tick();const recovered=await f.runtime.store.get(owner,'tasks',f.binding.task_id);assert.equal(recovered.status,'outcome_unknown');assert.equal(recovered.state.local_model.round.state,'dispatched');assert.equal(recovered.state.local_model.round.request_hash,operation);assert.equal(f.calls.length,count+1);
 }finally{await f.runtime.worker.stop();}}
});
test('whole worker rolls back checkpoint and event when authority changes during an awaited write',async()=>{
 for(const kind of ['tasks','run-events']){const f=await fixture();try{const owner=f.runtime.facade.owner(f.scope),store=f.runtime.store,taskID=f.binding.task_id,lease=randomUUID(),t=await store.get(owner,'tasks',taskID);
  const running=await store.compareAndSwap(owner,'tasks',taskID,{status:t.status,leaseId:null},{status:'running',leaseId:lease,leaseUntil:new Date(Date.now()+60000).toISOString()}),record=f.repository.transaction.bind(f.repository),before=f.repository.snapshot();let injected=false;
  f.repository.transaction=fn=>record(async tx=>{const put=tx.put.bind(tx);tx.put=async(o,k,v)=>{const result=await put(o,k,v);if(!injected&&o===owner&&k===kind){injected=true;const d=await tx.get(owner,'catpaw-delegations',f.binding.delegation_id);await put(owner,'catpaw-delegations',{...d,grant_epoch:d.grant_epoch+1});}return result;};return fn(tx);});
  if(kind==='tasks')assert.equal(await store.compareAndSwap(owner,'tasks',taskID,{status:'running',leaseId:lease},{state:{...running.state,local_model:{step:0,messages:[],round:null}}}),null);
  else await assert.rejects(store.put(owner,'run-events',{id:randomUUID(),taskId:taskID,leaseId:lease,kind:'progress',title:'Synthetic checkpoint'}),e=>e.code==='grant_conflict');
  assert.equal(injected,true);assert.deepEqual(f.repository.snapshot(),before);
 }finally{await f.runtime.worker.stop();}}
});

test('final task-control ledger write cancellation, deadline and source withdrawal roll back all facts before any wake or abort',async()=>{
 for(const action of ['pause','resume','revoke'])for(const boundary of ['cancel','deadline','source']){const f=await fixture();try{
  const path=controlPath(f),owner=f.runtime.facade.owner(f.scope);
  if(action==='resume'){const first=(await json(await f.req(path))).control;await json(await f.req(path+'/operations',input(first,'pause')));}
  const snapshot=(await json(await f.req(path))).control,request=input(snapshot,action),before=f.repository.snapshot(),count=f.calls.length,controller=new AbortController();let wakes=0,aborts=0,now=1000,intercepted=false;
  f.runtime.facade.onTaskControlAccepted=()=>{wakes++;};f.runtime.facade.abortTask=()=>{aborts++;};f.runtime.facade.taskControlNow=()=>now;
  const record=f.repository.transaction.bind(f.repository);f.repository.transaction=fn=>record(async tx=>{
   const put=tx.put.bind(tx);tx.put=async(o,k,row)=>{const stored=await put(o,k,row);if(!intercepted&&o===owner&&k===TASK_CONTROL_OPERATIONS&&row.id===request.operation_id){
    intercepted=true;if(boundary==='cancel')controller.abort();if(boundary==='deadline')now+=TASK_CONTROL_LIMITS.write_budget_ms;
    if(boundary==='source'){const s=await tx.get(membershipOwner(f.principal.issuer),'app-sessions',f.principal.session_id);await put(membershipOwner(f.principal.issuer),'app-sessions',{...s,state:'revoked'});}await Promise.resolve();
   }return stored;};return fn(tx);
  });
  await assert.rejects(controlTask(f.runtime.facade,'Bearer offline',f.scope.scope_id,f.binding.run_id,request,{signal:controller.signal}),e=>e.code===(boundary==='cancel'?'control_cancelled':boundary==='deadline'?'control_deadline':'grant_conflict'));
  assert.equal(intercepted,true);assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,count);assert.equal(wakes,0);assert.equal(aborts,0);
 }finally{await f.runtime.worker.stop();}}
});

test('both worker ports reject authority-generation drift even when task and lease IDs remain unchanged',async()=>{
 for(const whole of [false,true]){const f=await fixture();try{const owner=f.runtime.facade.owner(f.scope),count=f.calls.length;let invoked=false;
  const execute=async(o,t,ctx)=>{invoked=true;await f.repository.transaction(async tx=>{const current=await tx.get(owner,'tasks',t.id);await tx.put(owner,'tasks',{...current,state:{...current.state,task_control:{revision:1,reason:'authority_fence_injected'}}});});
   // ID/status remain identical: the execution generation, captured at claim, is decisive.
   await ctx.checkpoint({state:{...t.state,local_model:{step:0,messages:[],round:null}}});return {status:'succeeded'};
  };
  if(whole){const worker=new TaskWorker(f.runtime.store,execute);await worker.run(owner,await f.runtime.store.get(owner,'tasks',f.binding.task_id));await worker.stop();}
  else await boundedTick({repository:f.repository,owners:[owner],admitTask:f.runtime.facade.admittedTask.bind(f.runtime.facade),runStep:execute,budgetMs:10000,settleReserveMs:500,leaseMs:60000});
  const t=await f.runtime.store.get(owner,'tasks',f.binding.task_id);assert.equal(invoked,true);assert.equal(t.status,'running');assert.equal(t.state.task_control.revision,1);assert.equal(t.state.local_model,undefined);assert.equal(f.calls.length,count);
 }finally{await f.runtime.worker.stop();}}
});

test('original control operation refuses self-hashed identity, intent, revision, status and schema mismatches',async()=>{
 const receiptChanged=change=>op=>{const fields=change(op.receipt);return {...op,receipt:{...fields,receipt_hash:taskControlReceiptHash(fields)}};};
 const cases=[
  receiptChanged(r=>({...r,action:'resume'})),receiptChanged(r=>({...r,operation_hash:'0'.repeat(64)})),receiptChanged(r=>({...r,subject_id:randomUUID()})),
  receiptChanged(r=>({...r,run_id:randomUUID()})),receiptChanged(r=>({...r,task_id:'0'.repeat(64)})),receiptChanged(r=>({...r,scope_id:randomUUID()})),
  receiptChanged(r=>({...r,conversation_id:randomUUID()})),receiptChanged(r=>({...r,run_request_hash:'0'.repeat(64)})),receiptChanged(r=>({...r,grant_epoch:r.grant_epoch+1})),
  receiptChanged(r=>({...r,base_execution_revision:r.base_execution_revision+1})),receiptChanged(r=>({...r,accepted_execution_revision:r.accepted_execution_revision+1})),
  receiptChanged(r=>({...r,base_snapshot_hash:'0'.repeat(64)})),receiptChanged(r=>({...r,plan_reference:{...r.plan_reference,revision:r.plan_reference.revision+1}})),
  receiptChanged(r=>({...r,result_task_status:'scheduled'})),receiptChanged(r=>({...r,state:'completed'})),receiptChanged(r=>({...r,unexpected:'unregistered receipt extension'})),
  op=>({...op,request_hash:'0'.repeat(64)}),
  op=>{const frozen={...op.frozen,subject_id:randomUUID()};return {...op,frozen,operation_hash:hash(frozen)};},
  op=>{const frozen={...op.frozen,input:{...op.frozen.input,action:'resume'}};return {...op,frozen,operation_hash:hash(frozen)};},
  op=>{const frozen={...op.frozen,source_auth:{...op.frozen.source_auth,session_id:randomUUID()}};return {...op,frozen,operation_hash:hash(frozen)};},
 ];
 for(let index=0;index<cases.length;index++){const f=await fixture();try{const path=controlPath(f),owner=f.runtime.facade.owner(f.scope),pause=input((await json(await f.req(path))).control,'pause');await json(await f.req(path+'/operations',pause));
  await f.repository.transaction(async tx=>{const op=await tx.get(owner,TASK_CONTROL_OPERATIONS,pause.operation_id);await tx.put(owner,TASK_CONTROL_OPERATIONS,cases[index](op));});
  const before=f.repository.snapshot(),count=f.calls.length,rejected=await json(await f.req(path+'/operations/'+pause.operation_id),409);assert.equal(rejected.error.code,'control_operation_corrupt','case '+index);assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,count);
 }finally{await f.runtime.worker.stop();}}
});

test('restored unknown public-source read retains its original identity and prevents explicit resume',async()=>{
 const f=await fixture();try{const owner=f.runtime.facade.owner(f.scope),path=controlPath(f),readID=randomUUID();
  await f.repository.transaction(tx=>tx.put(owner,'catpaw-task-source-reads',{id:readID,run_id:f.binding.run_id,task_id:f.binding.task_id,conversation_id:f.cid,state:'unknown',request_hash:'d'.repeat(64)}));
  const first=(await json(await f.req(path))).control,count=f.calls.length,pause=input(first,'pause'),p=await json(await f.req(path+'/operations',pause));
  assert.equal(p.control.can_resume,false);assert.equal(p.control.blocked_reason,'original_outcome_unknown');assert.equal(p.control.unresolved_operations.length,1);assert.equal(p.control.unresolved_operations[0].operation_id,readID);assert.equal(p.control.unresolved_operations[0].state,'unknown');assert.equal(p.control.unresolved_operations[0].can_retry,false);
  const before=f.repository.snapshot(),denied=await json(await f.req(path+'/operations',input(p.control,'resume')),409);assert.equal(denied.error.code,'control_original_outcome_unknown');assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,count);
  const original=await json(await f.req(path+'/operations/'+pause.operation_id));assert.deepEqual(original.operation,p.operation);assert.equal(original.control.unresolved_operations[0].operation_id,readID);assert.equal(f.calls.length,count);
 }finally{await f.runtime.worker.stop();}
});

test('unknown task with missing original operation identity cannot gain resume authority from an empty inventory',async()=>{
 for(const whole of [false,true]){const f=await fixture({resumeTask:true});try{const owner=f.runtime.facade.owner(f.scope),path=controlPath(f),count=f.calls.length;
  // Restore damage: the durable task already says unknown, but its dispatch/effect
  // identity checkpoint is missing. Absence is not a receipt proving no effect occurred.
  await f.repository.transaction(async tx=>{const t=await tx.get(owner,'tasks',f.binding.task_id);await tx.put(owner,'tasks',{...t,status:'outcome_unknown',state:{...t.state,local_model:null}});});
  const first=(await json(await f.req(path))).control;assert.deepEqual(first.unresolved_operations,[]);assert.equal(first.blocked_reason,'original_outcome_identity_missing');
  const pause=input(first,'pause'),paused=await json(await f.req(path+'/operations',pause));assert.equal(paused.control.task_status,'paused');assert.equal(paused.control.can_resume,false);assert.equal(paused.control.blocked_reason,'original_outcome_identity_missing');assert.deepEqual(paused.control.unresolved_operations,[]);
  const before=f.repository.snapshot(),denied=await json(await f.req(path+'/operations',input(paused.control,'resume')),409);assert.equal(denied.error.code,'control_original_outcome_unknown');assert.deepEqual(f.repository.snapshot(),before);
  if(whole)await f.runtime.worker.tick();else await boundedTick({repository:f.repository,owners:[owner],admitTask:f.runtime.facade.admittedTask.bind(f.runtime.facade),runStep:singleStepHandler(f.runtime.facade,f.runtime.provider),budgetMs:10000,settleReserveMs:500,leaseMs:60000});
  assert.equal(f.calls.length,count);assert.equal((await f.runtime.store.get(owner,'tasks',f.binding.task_id)).status,'paused');
  const read=await json(await f.req(path+'/operations/'+pause.operation_id));assert.equal(read.operation.result_task_status,'paused');assert.equal(read.operation.state,'applied');assert.deepEqual(read.control.unresolved_operations,[]);
 }finally{await f.runtime.worker.stop();}}
});
