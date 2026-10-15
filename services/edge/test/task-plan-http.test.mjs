import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {consentId} from '../supabase/functions/_shared/consent.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {validateCall} from '../supabase/functions/_shared/core/src/tools.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const content={title:'Offline local plan',goal:'Summarize supplied fictional data',requirements:'Do not read the web',stop_conditions:['Save only a local report'],steps:['compose','save','verify'].map(id=>({id,title:id,detail:''}))};
async function fixture({ordinary=false,autoKick=false,resumeTask=false,alternateViewer=false}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
 const retained=[],calls=[];let workerCalls=0,now=Date.now();const viewer={...principal,session_id:randomUUID()};
 const provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',assertReady(){},async *stream(input){calls.push(input);if(ordinary){yield{type:'text_delta',text:'Fictional answer'};yield{type:'done',finish_reason:'stop'};}else if(input.tools.some(t=>t.function.name==='delegate_plan_v1')){yield{type:'tool_call',id:randomUUID(),name:'delegate_plan_v1',arguments:content};yield{type:'done',finish_reason:'tool_calls'};}else{
  assert.ok(resumeTask,'unexpected worker call');workerCalls++;
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
test('maintenance API: original task plan CAS, operation replay, strict wire and read-only reconciliation',async()=>{
 const f=await fixture(),initial=await f.req(f.path);assert.equal(initial.status,200);assert.equal(initial.headers.get('cache-control'),'no-store');
 const first=await initial.json();assert.equal(first.contract,'catpaw.task-plan.v1');assert.deepEqual(first.plan.content,content);assert.equal(first.plan.accepted_revision,1);assert.equal(first.plan.task_id,f.binding.task_id);
 const operation=randomUUID(),input={operation_id:operation,expected_revision:1,expected_plan_hash:first.plan.accepted_plan_hash,expected_grant_epoch:1,content:{...content,requirements:'Add a risks section using the same supplied data'}};
 const response=await f.req(f.path+'/amendments',input);assert.equal(response.status,200);const accepted=await response.json();assert.equal(accepted.amendment.operation_id,operation);assert.equal(accepted.plan.accepted_revision,2);assert.equal(accepted.plan.application_state,'applied');assert.equal(accepted.plan.task_id,f.binding.task_id);assert.equal(accepted.plan.run_id,f.binding.run_id);
 const replay=await f.req(f.path+'/amendments',input);assert.equal(replay.status,200);assert.deepEqual(await replay.json(),accepted);
 const original=await f.req(f.path+'/amendments/'+operation);assert.equal(original.status,200);assert.deepEqual(await original.json(),accepted);
 assert.equal((await f.req(f.path+'/amendments',{...input,operation_id:randomUUID()})).status,409);
 assert.equal((await f.req(f.path+'/amendments',{...input,content})).status,409);
 assert.equal((await f.req(f.path+'?revision=1')).status,422);
 assert.equal((await f.req(f.path+'/amendments',{...input,extra:'untrusted'})).status,422);
 assert.equal((await f.req(f.path+'/amendments','{invalid')).status,422);
 assert.equal((await f.req(f.path+'/amendments',' '.repeat(48001))).status,413);
 assert.equal((await f.req(f.path,undefined,'Bearer missing')).status,401);
 assert.equal((await f.req(f.path.replace(f.scope.scope_id,randomUUID()))).status,403);
 assert.equal(f.calls.length,1);assert.equal((await f.repository.transaction(tx=>tx.list(f.runtime.facade.owner(f.scope),'tasks'))).length,1);
});
test('maintenance plan API rechecks current consent and source session, never authorizes from display',async()=>{
 const f=await fixture(),first=await(await f.req(f.path)).json(),owner=f.runtime.facade.owner(f.scope);
 await f.repository.transaction(async tx=>{const row=await tx.get(owner,'provider-consents',consentId(f.principal.subject_id,f.cid));await tx.put(owner,'provider-consents',{...row,decision:'deny'});});
 assert.equal((await f.req(f.path)).status,403);
 const input={operation_id:randomUUID(),expected_revision:1,expected_plan_hash:first.plan.accepted_plan_hash,expected_grant_epoch:1,content};
 assert.equal((await f.req(f.path+'/amendments',input)).status,403);
 await f.repository.transaction(async tx=>{const row=await tx.get(owner,'provider-consents',consentId(f.principal.subject_id,f.cid));await tx.put(owner,'provider-consents',{...row,decision:'allow'});const session=await tx.get(membershipOwner(f.principal.issuer),'app-sessions',f.principal.session_id);await tx.put(membershipOwner(f.principal.issuer),'app-sessions',{...session,state:'revoked'});});
 assert.equal((await f.req(f.path)).status,409);assert.equal((await f.req(f.path+'/amendments',input)).status,409);assert.equal(f.calls.length,1);
});
test('ordinary chat creates no task or plan; planned delegation registry rejects invented actions',async()=>{
 const f=await fixture({ordinary:true});assert.deepEqual(f.turn.task_bindings,[]);assert.equal((await f.repository.transaction(tx=>tx.list(f.runtime.facade.owner(f.scope),'tasks'))).length,0);
 assert.throws(()=>validateCall({id:'call',name:'delegate_plan_v1',arguments:{...content,steps:[{id:'browse',title:'Read the web',detail:''},...content.steps.slice(1)]}},'chat'));
 assert.throws(()=>validateCall({id:'call',name:'delegate_plan_v1',arguments:{...content,steps:[content.steps[1],content.steps[0],content.steps[2]]}},'chat'));
 assert.throws(()=>validateCall({id:'call',name:'delegate_plan_v1',arguments:{...content,steps:content.steps.map(s=>({...s,code:'untrusted'}))}},'chat'));
});
test('source purge preview includes every plan ledger and preserves execution deletion barrier',async()=>{
 const f=await fixture(),first=await(await f.req(f.path)).json();
 await f.req(f.path+'/amendments',{operation_id:randomUUID(),expected_revision:1,expected_plan_hash:first.plan.accepted_plan_hash,expected_grant_epoch:1,content:{...content,requirements:'Additional fictional requirement'}});
 const owner=f.runtime.facade.owner(f.scope),run=f.binding.run_id;
 // Simulate persisted checkpoint/receipt rows, never a model or execution completion.
 await f.repository.transaction(async tx=>{
  await tx.put(owner,'catpaw-task-plan-checkpoints',{id:run+':fixture',run_id:run,checkpoint:{fictional_data:true}});
  await tx.put(owner,'catpaw-task-plan-receipts',{id:run+':fixture',run_id:run,receipt_hash:'synthetic-fixture'});
 });
 const sources=await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,scoped=>scoped.list('sources')));
 const source=sources.find(s=>s.role==='user')??sources[0];assert.ok(source);
 const base='/catpaw/memory/v1/scopes/'+f.scope.scope_id+'/sources/'+source.id;
 const response=await f.req(base+'/purge-plan');assert.equal(response.status,200);
 const {plan}=await response.json(),kinds=new Set(plan.owner_records.map(r=>r.kind));
 for(const kind of ['heads','versions','operations','checkpoints','receipts'])assert.ok(kinds.has('catpaw-task-plan-'+kind),kind);
 assert.equal(plan.execute_supported,false);assert.ok(plan.blocked.includes('revoke_and_fence_active_execution_before_purge'));
 assert.equal((await f.req(base+'/delete',{})).status,409);
 const rows=await f.repository.transaction(tx=>tx.list(owner,'catpaw-task-plan-heads'));assert.equal(rows.length,1);
});
test('Cloud amendment resumes waiting input through original accepted turn after disconnect, without manual tick',async()=>{
 const f=await fixture({autoKick:true,resumeTask:true,alternateViewer:true}),owner=f.runtime.facade.owner(f.scope);
 let task=await f.repository.transaction(tx=>tx.get(owner,'tasks',f.binding.task_id));assert.equal(task.status,'waiting_input');assert.equal(f.workers(),1);
 const first=(await(await f.req(f.path)).json()).plan,operation=randomUUID(),input={operation_id:operation,expected_revision:1,expected_plan_hash:first.accepted_plan_hash,expected_grant_epoch:1,content:{...content,requirements:'Original task amendment from another current session'}};
 const retainedBefore=f.retained.length,response=await f.req(f.path+'/amendments',input,'Bearer viewer');assert.equal(response.status,200);const receipt=await response.json();assert.equal(receipt.plan.applied_revision,2);assert.equal(receipt.amendment.state,'applied');assert.equal(f.retained.length,retainedBefore+1);
 await f.flush();task=await f.repository.transaction(tx=>tx.get(owner,'tasks',f.binding.task_id));assert.equal(task.status,'succeeded');assert.equal(f.workers(),2);assert.match(f.calls[2].messages.at(-1).content,/Original task amendment from another current session/);assert.equal(f.calls[2].provider_context.source_auth.session_id,f.principal.session_id);
 assert.equal((await f.repository.transaction(tx=>tx.list(owner,'tasks'))).length,1);const run=await f.repository.transaction(tx=>tx.get(owner,'catpaw-runs',f.binding.run_id));assert.equal(run.task_id,f.binding.task_id);assert.equal(run.frozen_request.source_auth.session_id,f.principal.session_id);
 const retainedAfter=f.retained.length,callsAfter=f.calls.length;
 assert.equal((await f.req(f.path+'/amendments',input,'Bearer viewer')).status,200);assert.equal((await f.req(f.path+'/amendments/'+operation,undefined,'Bearer viewer')).status,200);assert.equal((await f.req(f.path,undefined,'Bearer viewer')).status,200);await f.flush();assert.equal(f.retained.length,retainedAfter);assert.equal(f.calls.length,callsAfter);
});
test('Cloud unknown amendment and revoked admission never wake or resend original work',async()=>{
 const f=await fixture({autoKick:true,resumeTask:true}),owner=f.runtime.facade.owner(f.scope),first=(await(await f.req(f.path)).json()).plan;
 await f.repository.transaction(async tx=>{const task=await tx.get(owner,'tasks',f.binding.task_id);await tx.put(owner,'tasks',{...task,status:'outcome_unknown',state:{...task.state,local_model:{...task.state.local_model,round:{state:'dispatched',request_hash:'a'.repeat(64)}}}});});
 const retainedBefore=f.retained.length,callsBefore=f.calls.length,input={operation_id:randomUUID(),expected_revision:1,expected_plan_hash:first.accepted_plan_hash,expected_grant_epoch:1,content:{...content,requirements:'Preserve unknown original operation'}};
 const accepted=await f.req(f.path+'/amendments',input);assert.equal(accepted.status,200);assert.equal((await accepted.json()).plan.application_state,'blocked_unknown');await f.flush();assert.equal(f.retained.length,retainedBefore);assert.equal(f.calls.length,callsBefore);
 assert.equal((await f.req(f.path+'/amendments',input)).status,200);assert.equal((await f.req(f.path+'/amendments/'+input.operation_id)).status,200);assert.equal(f.retained.length,retainedBefore);
 await f.repository.transaction(async tx=>{const row=await tx.get(membershipOwner(f.principal.issuer),'app-sessions',f.principal.session_id);await tx.put(membershipOwner(f.principal.issuer),'app-sessions',{...row,state:'revoked'});});
 assert.equal((await f.req(f.path+'/amendments',{...input,operation_id:randomUUID(),expected_revision:2})).status,409);assert.equal(f.retained.length,retainedBefore);assert.equal(f.calls.length,callsBefore);
});
