import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {consentId} from '../supabase/functions/_shared/consent.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,check,hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TASK_ACTION_KINDS} from '../supabase/functions/_shared/core/src/task-action-contract.mjs';

globalThis.fetch=()=>{throw Error('task_action_http_external_network_forbidden');};
async function fixture({verified=true,verifier=null}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true},principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}},viewer={...principal,session_id:randomUUID()},device=randomUUID(),environment=randomUUID(),calls=[],retained=[];
 const config=readConfig(name=>({CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'})[name]);
 const content={title:'Offline action host',goal:'Keep one original local task',requirements:'No system execution',stop_conditions:['Save a local report'],steps:['compose','save','verify'].map(id=>({id,title:id,detail:''}))},fault={original:null,targetAllowed:true,verifications:0};
 const sourceChecker=async(tx,source,identity)=>{check(source.scope_id===identity.scope_id,409,'grant_conflict');if(source.session_id===principal.session_id&&fault.original)throw fault.original;const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);check(row?.subject_id===source.subject_id&&row.state==='active',409,'grant_conflict');};
 const provider={identity:{provider:'offline-only',model:'synthetic-only',adapter_version:1},reality:'injected_offline_only',assertReady(){},async *stream(input){calls.push(input);yield {type:'tool_call',id:randomUUID(),name:'delegate_plan_v1',arguments:content};yield {type:'done',finish_reason:'tool_calls'};}};
 const targetVerifier=verified?async(tx,ctx)=>{fault.verifications++;assert.equal(ctx.run.frozen_request.source_auth.session_id,principal.session_id);assert.equal(ctx.target.device_id,device);assert.equal(ctx.target.environment_id,environment);if(verifier)await verifier(tx,ctx);return {verified:fault.targetAllowed};}:null;
 const runtime=await createCloudRuntime({repository,config,provider,sourceChecker,authenticate:auth=>{if(auth==='Bearer offline')return principal;if(auth==='Bearer viewer')return viewer;throw new ApiError(401,'session_required');},taskActionTargetVerifier:targetVerifier,retain:p=>retained.push(p),autoKick:false,diagnostic:()=>{}});
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);await repository.transaction(async tx=>{for(const person of [principal,viewer])await tx.put(membershipOwner(person.issuer),'app-sessions',{id:person.session_id,subject_id:person.subject_id,state:'active'});});
 const cid=randomUUID(),tid=randomUUID(),chatBase='/catpaw/chat/v1/scopes/'+scope.scope_id+'/conversations';
 const req=(path,body,auth='Bearer offline',method=body===undefined?'GET':'POST')=>runtime.api(new Request('https://offline.example.invalid'+path,{method,headers:{Authorization:auth,'Content-Type':'application/json'},...body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)}}));
 assert.equal((await req(chatBase,{conversation_id:cid})).status,201);assert.equal((await req('/catpaw/privacy/v1/scopes/'+scope.scope_id+'/conversations/'+cid+'/model-consent',{decision:'allow',expected_revision:0,route_hash:config.routeHash})).status,200);
 const response=await req(chatBase+'/'+cid+'/turns',{turn_id:tid,expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'Prepare an offline local report'},context:[]});assert.equal(response.status,200);await response.body.getReader().cancel();await Promise.all(retained);
 const turn=(await(await req(chatBase+'/'+cid+'/turns/'+tid)).json()).turn,binding=turn.task_bindings[0],owner=runtime.facade.owner(scope),plan=(await(await req('/catpaw/plans/v1/scopes/'+scope.scope_id+'/runs/'+binding.run_id+'/plan')).json()).plan;
 const base='/catpaw/actions/v1/scopes/'+scope.scope_id+'/runs/'+binding.run_id+'/actions';
 const proposal=()=>({operation_id:randomUUID(),kind:'calendar.create.v1',expected_plan_revision:plan.accepted_revision,expected_plan_hash:plan.accepted_plan_hash,expected_grant_epoch:binding.grant_epoch,target:{device_id:device,environment_id:environment,calendar_id:'offline-test-calendar',calendar_display_name:'Offline test calendar',calendar_snapshot_hash:hash('named offline target descriptor')},parameters:{title:'Offline review meeting',start_at:'2026-10-15T01:00:00.000Z',end_at:'2026-10-15T01:20:00.000Z',time_zone:'Asia/Shanghai',reminder_offset_seconds:-300},artifact_reference:null,replaces_action_id:null});
 const decision=action=>({operation_id:randomUUID(),decision:'approve',expected_revision:action.revision,action_digest:action.action_digest,expected_grant_epoch:action.grant_epoch});
 return {repository,runtime,principal,viewer,scope,cid,binding,base,req,proposal,decision,fault,calls,owner,config};
}
test('maintenance defaults expose honest non-executable actions and reject unconfigured target authority',async()=>{
 const f=await fixture({verified:false}),ready=await(await f.req('/readyz')).json();assert.equal(ready.chat_capabilities.task_actions.execution,false);assert.equal(ready.chat_capabilities.task_actions.decision,false);assert.equal(ready.chat_capabilities.public_sources.enabled,false);
 const rejected=await f.req(f.base,f.proposal());assert.equal(rejected.status,503);assert.equal((await rejected.json()).error.code,'action_target_verifier_not_configured');assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.actions))).length,0);assert.equal(f.calls.length,1);
});
test('additive action paths reopen same exact review and original decision without effects or model calls',async()=>{
 const f=await fixture(),input=f.proposal(),created=await f.req(f.base,input);assert.equal(created.status,201);assert.equal(created.headers.get('cache-control'),'no-store');const first=await created.json(),a=first.action;
 assert.deepEqual((await(await f.req(f.base+'/'+a.id)).json()).action,a);assert.equal((await(await f.req(f.base)).json()).actions[0].id,a.id);assert.deepEqual((await(await f.req(f.base,input)).json()).action,a);
 const d=f.decision(a),accepted=await f.req(f.base+'/'+a.id+'/decisions',d);assert.equal(accepted.status,200);const envelope=await accepted.json();assert.equal(envelope.action.approval_status,'approved');assert.equal(envelope.action.execution_authorized,false);assert.equal(envelope.action.effect.status,'waiting_device');assert.equal(envelope.action.effect.receipt,null);assert.equal(envelope.action.capability.os_target_verified,false);
 assert.deepEqual(await(await f.req(f.base+'/'+a.id+'/decisions',d)).json(),envelope);assert.deepEqual(await(await f.req(f.base+'/'+a.id+'/decisions/'+d.operation_id)).json(),envelope);
 const unknown=await f.req(f.base+'/'+a.id+'/decisions/'+randomUUID());assert.equal(unknown.status,404);assert.equal((await f.req(f.base+'/'+a.id+'/decisions',f.decision(a))).status,409);
 assert.equal(f.calls.length,1);assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,'catpaw-preview-effects'))).length,0);assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.decisions))).length,1);
 for(const kind of Object.values(TASK_ACTION_KINDS))for(const row of await f.repository.transaction(tx=>tx.list(f.owner,kind)))assert.equal(row.conversation_id,f.cid);
 assert.equal((await f.req('/catpaw/v1/scopes/'+f.scope.scope_id+'/approvals/'+a.id+'/decisions',{})).status,404,'Frozen r2 POST path remains unsupported');
});
test('HTTP strict shapes, canonical IDs, methods and hashes do not gain authority from model fields',async()=>{
 const f=await fixture(),input=f.proposal();for(const body of [{...input,verified:true},{...input,source_auth:{verified:true}},{...input,parameters:{...input.parameters,execute:true}},'{bad',' '.repeat(16385)])assert.ok([413,422].includes((await f.req(f.base,body)).status));
 assert.equal((await f.req(f.base+'?revision=1')).status,422);assert.equal((await f.req(f.base,{...input,operation_id:input.operation_id.toUpperCase()})).status,422);assert.equal((await f.req(f.base.replace(f.scope.scope_id,randomUUID()))).status,403);assert.equal((await f.req(f.base,undefined,'Bearer missing')).status,401);
 const a=(await(await f.req(f.base,input)).json()).action;assert.equal((await f.req(f.base+'/'+a.id+'/decisions',{...f.decision(a),action_digest:hash('forged')})).status,409);assert.equal((await f.req(f.base+'/'+a.id+'/decisions',{},'Bearer offline','PUT')).status,404);
});
test('current viewer is mandatory; original revoked source only invalidates historical execution authority',async()=>{
 const f=await fixture(),a=(await(await f.req(f.base,f.proposal())).json()).action,d=f.decision(a);await f.req(f.base+'/'+a.id+'/decisions',d);
 await f.repository.transaction(async tx=>{const row=await tx.get(membershipOwner(f.principal.issuer),'app-sessions',f.principal.session_id);await tx.put(membershipOwner(f.principal.issuer),'app-sessions',{...row,state:'revoked'});});
 assert.equal((await f.req(f.base+'/'+a.id+'/decisions/'+d.operation_id)).status,409);
 const history=await f.req(f.base+'/'+a.id+'/decisions/'+d.operation_id,undefined,'Bearer viewer');assert.equal(history.status,200);const value=await history.json();assert.equal(value.decision.operation_id,d.operation_id);assert.equal(value.action.approval_status,'approved');assert.equal(value.action.invalidation_reason,'source_authority_changed');assert.equal(value.action.effect.status,'not_dispatched');
 assert.equal((await f.req(f.base,f.proposal(),'Bearer viewer')).status,403);assert.equal(f.calls.length,1);
});
test('unrelated source checker failure stays closed rather than being converted into revocation',async()=>{
 const f=await fixture(),a=(await(await f.req(f.base,f.proposal())).json()).action;for(const error of [new ApiError(500,'offline_store_failed'),new ApiError(409,'offline_unknown_conflict')]){f.fault.original=error;const response=await f.req(f.base+'/'+a.id,undefined,'Bearer viewer');assert.equal(response.status,error.status);assert.equal((await response.json()).error.code,error.code);}
});
test('approve and deny reverify the bound device target; target denial leaves the original review pending',async()=>{
 for(const choice of ['approve','deny']){const f=await fixture(),a=(await(await f.req(f.base,f.proposal())).json()).action,verifications=f.fault.verifications;f.fault.targetAllowed=false;const response=await f.req(f.base+'/'+a.id+'/decisions',{...f.decision(a),decision:choice});assert.equal(response.status,403);assert.equal((await response.json()).error.code,'action_target_not_verified');assert.ok(f.fault.verifications>verifications);assert.equal((await(await f.req(f.base+'/'+a.id)).json()).action.approval_status,'pending');}
});
test('consent change during target verification fences the final write and retains no decision',async()=>{
 let revoke=false;
 const f=await fixture({verifier:async(tx,ctx)=>{if(revoke){const id=consentId(ctx.principal.subject_id,ctx.run.frozen_request.conversation_id),row=await tx.get(ctx.owner,'provider-consents',id);await tx.put(ctx.owner,'provider-consents',{...row,decision:'deny'});}}}),a=(await(await f.req(f.base,f.proposal())).json()).action;revoke=true;
 const response=await f.req(f.base+'/'+a.id+'/decisions',f.decision(a));assert.equal(response.status,403);assert.equal((await response.json()).error.code,'action_source_not_current');assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.decisions))).length,0);assert.equal((await(await f.req(f.base+'/'+a.id)).json()).action.approval_status,'pending','The rejected transaction rolls its test consent mutation back');
});
test('target verifier failure propagates without authorizing or consuming the original review',async()=>{
 let fail=false;const f=await fixture({verifier:async()=>{if(fail)throw new ApiError(500,'offline_target_store_failed');}}),a=(await(await f.req(f.base,f.proposal())).json()).action;fail=true;const response=await f.req(f.base+'/'+a.id+'/decisions',f.decision(a));assert.equal(response.status,500);assert.equal((await response.json()).error.code,'offline_target_store_failed');assert.equal((await(await f.req(f.base+'/'+a.id)).json()).action.approval_status,'pending');assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.decisions))).length,0);
});
