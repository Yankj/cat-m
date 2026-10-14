import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const PROMPT='请直接把以下虚构资料交给后台短任务整理并保存一份本地成果，标题「合成出门清单」：小猫下午去公园30分钟；已备水杯、纸巾；天气未知。正文列「安排」「物品」「未知」，注明天气未知、出发前自行确认，末尾包含 CATPAW_TASK_OK。不要追问，不查网络，不设长期任务；成果保存后结束任务。';
const REPORT={title:'合成出门清单',summary:'仅使用给定虚构资料的本地短任务成果',content:'安排：小猫下午去公园30分钟。\n物品：已备水杯、纸巾，出发前核对是否携带。\n未知：天气未知，出发前自行确认。未查询网络，未设置任何长期任务。\nCATPAW_TASK_OK'};
const event=(name,args)=>({type:'tool_call',id:randomUUID(),name,arguments:args}),done={type:'done',finish_reason:'tool_calls'};
async function fixture({separateFinish=false,saveOnly=false,structured=false,badReport=false}={}){
 const repository=new TestRepository(),p={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[{scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true}],permissions:{local_output:true}};
 const stranger={...p,subject_id:randomUUID(),session_id:randomUUID(),scopes:[{scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true}]};
 const calls=[],retained=[];let workers=0;
 const provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',assertReady(){},async *stream(input){
  calls.push(input);
  if(input.tools.some(t=>t.function.name==='delegate_task')){yield event('delegate_task',{title:REPORT.title,goal:'整理并保存合成出门清单',requirements:PROMPT,stop_conditions:[structured?'structured synthetic report':'只用给定虚构信息，保存本地成果后结束任务']});yield done;return;}
  workers++;
  if(separateFinish&&workers===2){
   const receipt=JSON.parse(input.messages.at(-1).content);assert.equal(receipt.saved,true);if(structured){assert.equal(receipt.completion_validation.valid,true);assert.ok(!('finish_required' in receipt));}else{assert.equal(receipt.finish_required,true);assert.equal(receipt.completion_mode,'model_finish_local_artifact');assert.ok(!('completion_validation' in receipt));}
   yield event('finish_task',{summary:'已读取保存回执并结束'});yield done;return;
  }
  yield event('save_artifact',badReport?{...REPORT,content:'An invalid structured report'}:REPORT);if(!separateFinish&&!saveOnly)yield event('finish_task',{summary:'本地成果已保存'});yield done;
 }};
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};const config=readConfig(k=>values[k]);
 let fakeNow=Date.now();
 const sourceChecker=async(tx,source,scope)=>{const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);assert.equal(source.scope_id,scope.scope_id);if(row?.subject_id!==source.subject_id||row.state!=='active')throw new ApiError(409,'grant_conflict');};
 const runtime=await createCloudRuntime({repository,config,provider,sourceChecker,authenticate:auth=>auth==='Bearer offline'?p:stranger,retain:x=>retained.push(x),kickOptions:{now:()=>fakeNow,sleep:async ms=>{fakeNow+=ms;}}});
 if(structured){runtime.facade.completionPolicy={schema_version:1,kind:'single_local_report',stop_condition:'structured synthetic report',required_sections:['安排','物品','未知'],required_context_ids:[],min_content_chars:40};runtime.facade.completionAuthorizer=async()=>({schema_version:1,source:'fixture_case_selection',source_reference:'offline-structured-regression',source_version:1,policy_version:1,mode:'single_local_report'});}
 for(const actor of [p,stranger]){await runtime.foundation.bootstrapScope(actor,actor.scopes[0].scope_id);await repository.transaction(async tx=>{await tx.put(membershipOwner(actor.issuer),'scope-memberships',{id:actor.subject_id,scopes:actor.scopes});await tx.put(membershipOwner(actor.issuer),'app-sessions',{id:actor.session_id,subject_id:actor.subject_id,state:'active',expires_at:9999999999});});}
 const scope=p.scopes[0].scope_id,cid=randomUUID(),base=`/catpaw/chat/v1/scopes/${scope}/conversations`,input={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:PROMPT},context:[]};
 const req=(path,body,auth='Bearer offline')=>runtime.api(new Request('https://offline.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:auth,'Content-Type':'application/json'},...body===undefined?{}:{body:JSON.stringify(body)}}));
 assert.equal((await req(base,{conversation_id:cid})).status,201);assert.equal((await req(`/catpaw/privacy/v1/scopes/${scope}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:config.routeHash})).status,200);
 return {runtime,repository,p,stranger,scope,cid,base,input,req,calls,retained};
}
async function accepted(f){const response=await f.req(`${f.base}/${f.cid}/turns`,f.input);assert.equal(response.status,200);await response.body.getReader().cancel();await Promise.all(f.retained);return (await (await f.req(`${f.base}/${f.cid}/turns/${f.input.turn_id}`)).json()).turn;}
async function assertProjection(f,t){
 assert.equal(t.state,'completed');assert.equal(t.task_bindings.length,1);const b=t.task_bindings[0];
 assert.equal(b.scope_id,f.scope);assert.equal(b.conversation_id,f.cid);assert.equal(b.turn_id,f.input.turn_id);assert.equal(new Set([b.conversation_id,b.turn_id,b.delegation_id,b.operation_id,b.run_id]).size,5);assert.match(b.task_id,/^[a-f0-9]{64}$/);assert.equal(b.projection_url,`/catpaw/v1/scopes/${f.scope}/runs/${b.run_id}`);
 const wire=await (await f.req(b.projection_url)).json(),run=wire.run,task=wire.task;assert.equal(wire.schema_version,1);assert.equal(run.state,'succeeded');assert.equal(run.authorization_state,'current');
 for(const k of ['run_id','operation_id','delegation_id'])assert.equal(k==='run_id'?run.id:run[k],b[k]);assert.equal(run.task_id,b.task_id);assert.equal(task.id,b.task_id);assert.equal(run.request_hash,b.request_hash);assert.equal(run.grant_epoch,b.grant_epoch);assert.equal(run.delegation_revision,b.delegation_revision);assert.equal(run.artifact_references.length,1);
 const ref=run.artifact_references[0];assert.equal(ref.version,1);const artifact=(await (await f.req(`/catpaw/v1/scopes/${f.scope}/artifacts/${ref.artifact_id}/versions/${ref.version}`)).json()).artifact;
 assert.equal(artifact.artifact_id,ref.artifact_id);assert.equal(artifact.version,ref.version);assert.equal(artifact.content_hash,ref.content_hash);assert.equal(hash(artifact.body),ref.content_hash);assert.equal(artifact.run_id,b.run_id);assert.equal(artifact.task_id,b.task_id);const body=JSON.parse(artifact.body);assert.equal(body.title,REPORT.title);assert.equal(body.data.content,REPORT.content);
 const frozen=await f.repository.transaction(tx=>tx.get(f.runtime.facade.owner(f.p.scopes[0]),'catpaw-runs',b.run_id));assert.equal(frozen.frozen_request.subject_id,f.p.subject_id);assert.equal(frozen.frozen_request.source_auth.session_id,f.p.session_id);assert.equal(frozen.frozen_request.source_auth.scope_id,f.scope);assert.ok(['model_finish_local_artifact','single_local_report'].includes(frozen.frozen_request.completion_contract.mode));
 assert.equal(wire.plan.applied_revision,1);assert.equal(wire.plan.application_state,'applied');assert.equal(wire.plan.task_id,b.task_id);assert.deepEqual(wire.plan.step_receipts.map(r=>r.step_id),['compose','save','verify']);assert.ok(wire.plan.step_receipts.every(r=>r.plan_revision===1&&r.plan_hash===wire.plan.applied_plan_hash));assert.deepEqual(artifact.plan_reference,{revision:1,plan_hash:wire.plan.applied_plan_hash});
 return {b,ref,wire};
}
test('one chat plus one worker round yields same-bound artifact v1 and native HTTP projection after disconnect',async()=>{
 const f=await fixture(),t=await accepted(f),{b}=await assertProjection(f,t);assert.equal(f.calls.length,2);
 const before=f.retained.length;assert.equal((await (await f.req(`${f.base}/${f.cid}/turns`,f.input)).json()).replayed,true);assert.equal(f.calls.length,2);assert.equal(f.retained.length,before);
 assert.equal((await f.req(b.projection_url,undefined,'Bearer other')).status,403);assert.equal((await f.req(`/catpaw/v1/scopes/${f.stranger.scopes[0].scope_id}/runs/${b.run_id}`,undefined,'Bearer other')).status,404);
 const restored=new TestRepository(f.repository.snapshot()),stored=await restored.transaction(tx=>tx.get(f.runtime.facade.owner(f.p.scopes[0]),'catpaw-runs',b.run_id));assert.equal(stored.id,b.run_id);assert.equal(stored.artifact_references.length,1);await f.runtime.worker.stop();
});
test('save receipt then a separate finish round completes with three model rounds and five slices',async()=>{
 const f=await fixture({separateFinish:true}),t=await accepted(f),{wire}=await assertProjection(f,t);assert.equal(f.calls.length,3);assert.equal(wire.run.attempts.length,5);await f.runtime.worker.stop();
});
test('saved report alone never becomes completed; the bounded six-slice checkpoint remains scheduled',async()=>{
 const f=await fixture({saveOnly:true}),t=await accepted(f),b=t.task_bindings[0],wire=await (await f.req(b.projection_url)).json();assert.equal(f.calls.length,3);assert.equal(wire.run.state,'scheduled');assert.equal(wire.run.attempts.length,6);assert.equal(wire.run.artifact_references.length,1);await f.runtime.worker.stop();
});

test('structured report still returns and enforces its frozen completion validation',async()=>{
 const f=await fixture({structured:true,separateFinish:true}),t=await accepted(f);await assertProjection(f,t);assert.equal(f.calls.length,3);await f.runtime.worker.stop();
});
test('invalid structured report cannot be completed by finish_task',async()=>{
 const f=await fixture({structured:true,badReport:true}),t=await accepted(f),wire=await (await f.req(t.task_bindings[0].projection_url)).json();assert.equal(wire.run.state,'failed');assert.equal(wire.run.artifact_references.length,1);assert.equal(f.calls.length,2);await f.runtime.worker.stop();
});
