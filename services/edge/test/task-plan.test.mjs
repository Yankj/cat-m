import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {boundedTick} from '../supabase/functions/_shared/core/integration/edge-adapter/src/bounded-tick.mjs';
import {AdapterError} from '../supabase/functions/_shared/core/integration/edge-adapter/src/common.mjs';
import {singleStepHandler} from '../supabase/functions/_shared/core/src/single-step-handler.mjs';
import {validatePlanContent,planContentHash} from '../supabase/functions/_shared/core/src/plan-contract.mjs';
import {ApiError,hash,canonical} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';

globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const CONTENT={title:'本地计划',goal:'整理已提供的虚构材料',requirements:'仅使用对话资料，不访问网络',stop_conditions:['保存本地报告并验证后结束'],steps:[{id:'compose',title:'整理资料',detail:'使用给定信息'},{id:'save',title:'保存成果',detail:''},{id:'verify',title:'核对成果',detail:'检查当前计划'}]};
const event=(name,args)=>({type:'tool_call',id:randomUUID(),name,arguments:args}),done={type:'done',finish_reason:'tool_calls'};
async function fixture({workerMode='report',duringModel=null}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
 const stranger={...principal,subject_id:randomUUID(),session_id:randomUUID(),scopes:[{...scope,scope_id:randomUUID(),workspace_id:randomUUID()}]},calls=[],retained=[];
 let f,workers=0,now=Date.now();
 const provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',async *stream(input){
  calls.push(input);
  if(input.tools.some(t=>t.function.name==='delegate_plan_v1')){yield event('delegate_plan_v1',CONTENT);yield done;return;}
  workers++;if(duringModel)await duringModel(f,workers);
  if(workerMode==='question'&&workers===1){yield event('ask_user',{question:'请修改计划补充要求'});yield done;return;}
  const report={title:'本地成果',summary:'虚构输入的本地报告',content:JSON.stringify(input.messages)};
  yield event('save_artifact',report);yield event('finish_task',{summary:'当前本地报告已验证'});yield done;
 }};
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'},config=readConfig(k=>values[k]);
 const sourceChecker=async(tx,source)=>{const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);if(row?.subject_id!==source.subject_id||row.state!=='active')throw new ApiError(409,'grant_conflict');};
 const runtime=await createCloudRuntime({repository,config,provider,sourceChecker,authenticate:auth=>auth==='Bearer offline'?principal:stranger,autoKick:false,retain:p=>retained.push(p),diagnostic:()=>{}});
 for(const actor of [principal,stranger]){await runtime.foundation.bootstrapScope(actor,actor.scopes[0].scope_id);await repository.transaction(async tx=>{await tx.put(membershipOwner(actor.issuer),'app-sessions',{id:actor.session_id,subject_id:actor.subject_id,state:'active',expires_at:9999999999});});}
 const req=(path,body,auth='Bearer offline')=>runtime.api(new Request('https://offline.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:auth,'Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}}));
 const cid=randomUUID(),chat=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,input={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'把给定虚构资料整理为一份本地报告并保存'},context:[]};
 assert.equal((await req(chat,{conversation_id:cid})).status,201);assert.equal((await req(`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash})).status,200);
 const response=await req(`${chat}/${cid}/turns`,input);assert.equal(response.status,200);await response.body.getReader().cancel();await Promise.all(retained);
 const turn=(await (await req(`${chat}/${cid}/turns/${input.turn_id}`)).json()).turn;assert.equal(turn.task_bindings.length,1);const binding=turn.task_bindings[0],owner=runtime.facade.owner(scope),path=`/catpaw/plans/v1/scopes/${scope.scope_id}/runs/${binding.run_id}/plan`;
 const row=()=>repository.transaction(tx=>tx.get(owner,'tasks',binding.task_id));
 f={runtime,repository,principal,stranger,scope,cid,req,binding,owner,path,row,calls,workers:()=>workers,
  read:async()=>{const r=await req(path);assert.equal(r.status,200);return r.json();},
  amend:async(content,options={})=>{const snap=(await f.read()).plan;const request={operation_id:randomUUID(),expected_revision:snap.accepted_revision,expected_plan_hash:snap.accepted_plan_hash,expected_grant_epoch:binding.grant_epoch,content,...options};const response=await req(`${path}/amendments`,request);return {response,request,body:await response.json()};},
  tick:async(handler=null)=>{now=Math.max(now,Date.now())+100;const result=await boundedTick({repository,owners:[owner],admitTask:runtime.facade.admittedTask.bind(runtime.facade),runStep:handler??singleStepHandler(runtime.facade,runtime.provider),now:()=>now,budgetMs:2000,settleReserveMs:250,leaseMs:10000});now+=2000;return result;},
  stop:()=>runtime.worker.stop()};
 return f;
}
const edit=(extra='修改要求')=>({...structuredClone(CONTENT),goal:'按修改后的目标整理',requirements:extra});
const error=async(response,code,status=409)=>{assert.equal(response.status,status);assert.equal((await response.json()).error.code,code);};

test('versioned plan codec locks step identities and canonical Unicode/slash content hash',()=>{
 assert.deepEqual(validatePlanContent(CONTENT),CONTENT);assert.equal(planContentHash(CONTENT),'ca764e5b243afeba0e45424c1fd0831730940c92e407a2e586e713e710b0db64');assert.equal(planContentHash(CONTENT),hash(canonical(CONTENT)));assert.doesNotThrow(()=>validatePlanContent({...CONTENT,requirements:''}));
 for(const content of [{...CONTENT,extra:true},{...CONTENT,steps:[...CONTENT.steps].reverse()},{...CONTENT,title:'x'.repeat(161)},{...CONTENT,goal:' '},{...CONTENT,requirements:'x'.repeat(4001)},{...CONTENT,stop_conditions:[]},{...CONTENT,steps:CONTENT.steps.map(s=>({...s,detail:'x'.repeat(4001)}))}])assert.throws(()=>validatePlanContent(content),e=>e.code==='schema_invalid');
});
test('real chat admission persists plan v1 in existing records and reopens the owned HTTP projection',async()=>{
 const f=await fixture(),wire=await f.read();assert.equal(wire.contract,'catpaw.task-plan.v1');assert.equal(wire.plan.accepted_revision,1);assert.equal(wire.plan.application_state,'applied');assert.deepEqual(wire.plan.content,CONTENT);assert.deepEqual(wire.plan.step_receipts,[]);
 const task=await f.row();assert.equal(task.plan.length,3);assert.ok(task.plan.every(s=>s.status==='pending'));assert.deepEqual(task.state.plan_binding,{revision:1,plan_hash:hash(CONTENT)});
 const restored=new TestRepository(f.repository.snapshot()),stored=await restored.transaction(tx=>tx.get(f.owner,'catpaw-task-plan-heads',f.binding.run_id));assert.equal(stored.accepted_plan_hash,hash(CONTENT));
 await error(await f.req(f.path,undefined,'Bearer stranger'),'scope_forbidden',403);await error(await f.req(f.path.replace(f.scope.scope_id,f.stranger.scopes[0].scope_id),undefined,'Bearer stranger'),'not_found',404);await f.stop();
});
test('same-run CAS amendment v2 applies before dispatch, changes actual model input, and validates bound receipts',async()=>{
 const f=await fixture(),before=await f.repository.transaction(tx=>tx.get(f.owner,'catpaw-runs',f.binding.run_id));const a=await f.amend(edit('保留新的明确要求 https://example.invalid/'));
 assert.equal(a.response.status,200);assert.equal(a.body.amendment.state,'applied');assert.equal(a.body.plan.accepted_revision,2);assert.equal(a.body.plan.applied_revision,2);assert.deepEqual(a.body.plan.step_receipts,[]);
 for(let i=0;i<3;i++)await f.tick();const after=(await f.read()).plan;assert.equal(after.task_status,'succeeded');assert.deepEqual(after.step_receipts.map(r=>[r.step_id,r.receipt_kind]),[['compose','model_response'],['save','artifact_saved'],['verify','completion_validated']]);assert.ok(after.step_receipts.every(r=>r.plan_revision===2&&r.plan_hash===after.applied_plan_hash));
 const request=JSON.parse(f.calls[1].messages[0].content);assert.equal(request.goal,edit().goal);assert.equal(request.requirements,a.request.content.requirements);assert.equal(request.applied_plan.revision,2);
 const run=await f.repository.transaction(tx=>tx.get(f.owner,'catpaw-runs',f.binding.run_id));assert.equal(hash(run.frozen_request),hash(before.frozen_request));assert.equal(run.request_hash,before.request_hash);assert.equal(run.task_id,before.task_id);assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,'tasks'))).length,1);
 const artifact=await f.repository.transaction(tx=>tx.get(f.owner,'catpaw-artifact-versions',`${run.artifact_references[0].artifact_id}:1`));assert.deepEqual(artifact.plan_reference,{revision:2,plan_hash:after.applied_plan_hash});await f.stop();
});
test('original operation replay and read recover lost response, while changed UUID payload and stale CAS preserve draft',async()=>{
 const f=await fixture(),a=await f.amend(edit());assert.equal(a.response.status,200);const replay=await f.req(`${f.path}/amendments`,a.request);assert.equal(replay.status,200);assert.equal((await replay.json()).amendment.accepted_revision,2);
 const read=await f.req(`${f.path}/amendments/${a.request.operation_id}`);assert.equal(read.status,200);assert.deepEqual((await read.json()).amendment,a.body.amendment);
 await error(await f.req(`${f.path}/amendments`,{...a.request,content:edit('different')}),'plan_operation_conflict');await error(await f.req(`${f.path}/amendments`,{...a.request,operation_id:randomUUID()}),'revision_conflict');
 const snap=(await f.read()).plan;await error(await f.req(`${f.path}/amendments`,{...a.request,operation_id:randomUUID(),expected_revision:2,expected_plan_hash:'0'.repeat(64)}),'plan_hash_conflict');assert.deepEqual((await f.read()).plan.content,snap.content);await f.stop();
});
test('amendment during dispatched model stays blocked_unknown; received effects settle before terminal applies v2',async()=>{
 let amendment;const f=await fixture({duringModel:async(f,n)=>{if(n===1)amendment=await f.amend(edit('模型派发后收到的新要求'));}});
 await f.tick();assert.equal(amendment.response.status,200);assert.equal(amendment.body.amendment.state,'blocked_unknown');assert.equal(amendment.body.plan.applied_revision,1);assert.equal((await f.read()).plan.application_state,'pending');
 const second=await f.amend(edit('第三版'));assert.equal(second.response.status,409);assert.equal(second.body.error.code,'plan_application_pending');
 await f.tick();let plan=(await f.read()).plan;assert.equal(plan.applied_revision,1);assert.equal(plan.task_status,'scheduled');assert.deepEqual(plan.step_receipts.map(r=>r.step_id),['compose','save']);
 await f.tick();plan=(await f.read()).plan;assert.equal(plan.applied_revision,2);assert.equal(plan.task_status,'scheduled');assert.deepEqual(plan.step_receipts,[]);assert.equal(f.workers(),1);
 const checkpoint=await f.repository.transaction(tx=>tx.get(f.owner,'catpaw-task-plan-checkpoints',`${f.binding.run_id}:1:2`));assert.equal(checkpoint.local_model.round.next,1);assert.equal(checkpoint.local_model.round.calls[1].name,'finish_task');assert.equal(checkpoint.local_model.round.results.length,1);
 for(let i=0;i<3;i++)await f.tick();plan=(await f.read()).plan;assert.equal(plan.task_status,'succeeded');assert.equal(plan.applied_revision,2);assert.equal(f.workers(),2);assert.match(f.calls[2].messages.at(-1).content,/模型派发后收到的新要求/);
 const run=await f.repository.transaction(tx=>tx.get(f.owner,'catpaw-runs',f.binding.run_id));assert.equal(run.artifact_references[0].version,2);const reconciled=await f.req(`${f.path}/amendments/${amendment.request.operation_id}`);assert.equal((await reconciled.json()).amendment.state,'applied');await f.stop();
});
test('waiting input amendment resumes original task through preserved ask_user checkpoint without fake tool receipt',async()=>{
 const f=await fixture({workerMode:'question'});await f.tick();await f.tick();assert.equal((await f.row()).status,'waiting_input');
 const a=await f.amend(edit('用户明确补充的新要求'));assert.equal(a.response.status,200);assert.equal(a.body.plan.application_state,'applied');assert.equal(a.body.plan.task_status,'scheduled');
 const checkpoint=await f.repository.transaction(tx=>tx.get(f.owner,'catpaw-task-plan-checkpoints',`${f.binding.run_id}:1:2`));assert.equal(checkpoint.local_model.round.calls[0].name,'ask_user');assert.equal(checkpoint.local_model.round.next,0);assert.deepEqual(checkpoint.local_model.round.results,[]);
 for(let i=0;i<3;i++)await f.tick();assert.equal((await f.row()).status,'succeeded');assert.equal(f.workers(),2);await f.stop();
});
test('unknown dispatch is retained and cannot apply or automatically resend after amendment',async()=>{
 const f=await fixture();await f.repository.transaction(async tx=>{const task=await tx.get(f.owner,'tasks',f.binding.task_id);await tx.put(f.owner,'tasks',{...task,status:'outcome_unknown',state:{...task.state,local_model:{step:0,messages:[],round:{state:'dispatched',request_hash:hash('unknown')},artifact:null}}});});
 const a=await f.amend(edit());assert.equal(a.response.status,200);assert.equal(a.body.plan.application_state,'blocked_unknown');assert.equal(a.body.plan.applied_revision,1);assert.equal((await f.tick()).claimed,0);assert.equal(f.workers(),0);assert.equal((await f.row()).state.local_model.round.state,'dispatched');await f.stop();
});
test('old artifacts cannot complete the amended plan and old awaiting approvals are denied while consumed receipts stay intact',async()=>{
 const f=await fixture();await f.tick();await f.tick();const task=await f.row(),old=task.state.local_model.artifact;
 await f.repository.transaction(async tx=>{for(const status of ['awaiting_review','succeeded']){const id=randomUUID();await tx.put(f.owner,'catpaw-approval-bindings',{id,task_id:task.id,run_id:f.binding.run_id,artifact_reference:old});await tx.put(f.owner,'actions',{id,status,taskId:task.id});}});
 const a=await f.amend(edit());assert.equal(a.response.status,200);const actions=await f.repository.transaction(tx=>tx.list(f.owner,'actions'));assert.deepEqual(actions.map(a=>a.status).sort(),['denied','succeeded']);
 const failOld=async(owner,initial,ctx)=>{await assert.rejects(f.runtime.facade.assertTaskCompletion(owner,initial.id,old,initial.leaseId,{assertLive:ctx.assertLive}),e=>e.code==='completion_plan_superseded');return {status:'scheduled',state:initial.state};};
 await f.tick(failOld);assert.equal((await f.row()).status,'scheduled');assert.deepEqual((await f.read()).plan.step_receipts,[]);await f.stop();
});
test('unknown historical effect blocks plan application and new model dispatch; original outcome is preserved',async()=>{
 const f=await fixture(),id=randomUUID();await f.repository.transaction(async tx=>{await tx.put(f.owner,'catpaw-approval-bindings',{id,task_id:f.binding.task_id,run_id:f.binding.run_id,reconciliation_state:'needed'});await tx.put(f.owner,'actions',{id,status:'outcome_unknown',taskId:f.binding.task_id});});
 const a=await f.amend(edit());assert.equal(a.response.status,200);assert.equal(a.body.plan.application_state,'blocked_unknown');assert.equal(a.body.plan.applied_revision,1);await f.tick();assert.equal((await f.row()).status,'outcome_unknown');assert.equal(f.workers(),0);assert.equal((await f.repository.transaction(tx=>tx.get(f.owner,'actions',id))).status,'outcome_unknown');await f.stop();
});
test('completion verification receipt and plan amendment serialize; deadline denial rolls back validation receipt',async()=>{
 const f=await fixture();await f.tick();await f.tick();
 await f.tick(async(owner,task,ctx)=>{
  let checks=0;await assert.rejects(f.runtime.facade.assertTaskCompletion(owner,task.id,task.state.local_model.artifact,task.leaseId,{assertLive:()=>{ctx.assertLive();if(++checks===3)throw new ApiError(409,'lease_lost');}}),e=>e.code==='lease_lost');assert.equal(checks,3);
  assert.equal((await f.read()).plan.step_receipts.length,2);
  await f.runtime.facade.assertTaskCompletion(owner,task.id,task.state.local_model.artifact,task.leaseId,{assertLive:ctx.assertLive});
  const amendment=await f.amend(edit());assert.equal(amendment.response.status,409);assert.equal(amendment.body.error.code,'plan_completion_committing');
  return {status:'succeeded',state:task.state,artifactIds:[task.state.local_model.artifact.artifact_id]};
 });assert.equal((await f.read()).plan.task_status,'succeeded');assert.equal((await f.read()).plan.accepted_revision,1);await f.stop();
});
test('received model round recovers a missing plan receipt without another model dispatch',async()=>{
 const f=await fixture(),original=f.runtime.facade.recordModelPlanReceipt.bind(f.runtime.facade);let interrupted=false;
 f.runtime.facade.recordModelPlanReceipt=async(...args)=>{if(!interrupted){interrupted=true;throw new AdapterError('step_deadline');}return original(...args);};
 await f.tick();assert.equal(f.workers(),1);assert.equal((await f.row()).state.local_model.round.state,'received');assert.deepEqual((await f.read()).plan.step_receipts,[]);
 await f.tick();assert.equal(f.workers(),1);assert.deepEqual((await f.read()).plan.step_receipts.map(r=>r.step_id),['compose','save']);await f.tick();assert.equal((await f.read()).plan.task_status,'succeeded');await f.stop();
});
test('amendment racing immediately before finish validation yields same task instead of false completion',async()=>{
 const f=await fixture();await f.tick();await f.tick();const original=f.runtime.facade.assertTaskCompletion.bind(f.runtime.facade);let amended=false;
 f.runtime.facade.assertTaskCompletion=async(...args)=>{if(!amended){amended=true;assert.equal((await f.amend(edit('最后完成校验前收到修改'))).response.status,200);}return original(...args);};
 await f.tick();let plan=(await f.read()).plan;assert.equal(plan.task_status,'scheduled');assert.equal(plan.applied_revision,1);assert.equal(plan.accepted_revision,2);assert.deepEqual(plan.step_receipts.map(r=>r.step_id),['compose','save']);
 for(let i=0;i<4;i++)await f.tick();plan=(await f.read()).plan;assert.equal(plan.task_status,'succeeded');assert.equal(plan.applied_revision,2);assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,'tasks'))).length,1);await f.stop();
});
test('source/consent and grant fences roll back amendment; public read rechecks viewer before response',async()=>{
 const f=await fixture(),snapshot=f.repository.snapshot();const hook=f.runtime.facade.beforePlanWrite;let calls=0;
 f.runtime.facade.beforePlanWrite=async(tx,ctx)=>{await hook(tx,ctx);if(++calls===2)throw new ApiError(409,'grant_conflict');};const failed=await f.amend(edit());assert.equal(failed.response.status,409);assert.deepEqual(f.repository.snapshot(),snapshot);
 f.runtime.facade.beforePlanWrite=hook;const a=await f.amend(edit(),{expected_grant_epoch:2});assert.equal(a.response.status,409);assert.equal(a.body.error.code,'grant_conflict');
 let reads=0;const readHook=f.runtime.facade.beforePlanRead;f.runtime.facade.beforePlanRead=async(tx,ctx)=>{await readHook(tx,ctx);if(++reads===2)throw new ApiError(409,'grant_conflict');};await error(await f.req(f.path),'grant_conflict');f.runtime.facade.beforePlanRead=readHook;
 await f.repository.transaction(tx=>tx.put(membershipOwner(f.principal.issuer),'app-sessions',{id:f.principal.session_id,subject_id:f.principal.subject_id,state:'revoked'}));await error(await f.req(f.path),'grant_conflict');await f.stop();
});
test('whole worker handler also reads applied plan and records real phase receipts',async()=>{
 const f=await fixture();assert.equal((await f.amend(edit('整个worker也使用新计划'))).response.status,200);
 // Use the existing FencedWorkerStore/TaskWorker composition; this is its real handler port.
 await f.runtime.worker.tick();const plan=(await f.read()).plan;assert.equal(plan.task_status,'succeeded');assert.equal(plan.step_receipts.length,3);assert.match(f.calls[1].messages[0].content,/整个worker也使用新计划/);await f.stop();
});
