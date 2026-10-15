import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,check,hash,clone} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TASK_ACTION_KINDS} from '../supabase/functions/_shared/core/src/task-action-contract.mjs';
import {DEVICE_EFFECT_CONTRACT,DEVICE_EFFECT_ACTION_CONTRACT,DEVICE_EFFECT_ACTION_KIND,DEVICE_EFFECT_KINDS,DEVICE_EFFECT_POLICY_REFERENCE,deviceEffectID,deviceSubeffectID,validateDeviceEffectAdmission,validateDeviceEffectDispatch,validateDeviceEffectResult,sealDeviceEffectRecord} from '../supabase/functions/_shared/core/src/device-effect-contract.mjs';
import {admitDeviceEffect,readDeviceEffect,dispatchDeviceSubeffect,recordDeviceSubeffectResult,stopDeviceEffect} from '../supabase/functions/_shared/core/src/device-effect-service.mjs';

// Two independently committed SERIALIZED TEST DOUBLE stores model fresh authority
// and the candidate effect transaction. This is not SQL, OS, device or process proof.
globalThis.fetch=()=>{throw Error('device_effect_external_network_forbidden');};
const rejects=(fn,code)=>assert.rejects(fn,e=>{assert.ok(e instanceof ApiError,e?.stack);if(code)assert.equal(e.code,code);return true;});
async function fixture({reminder=-300}={}){
 const repository=new TestRepository(),authorityRepository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()},owner='offline-device-effect:'+scope.scope_id;
 const principal={subject_id:randomUUID(),session_id:randomUUID()},runID=randomUUID(),taskID=hash(runID),delegationID=randomUUID(),plan={revision:1,plan_hash:hash({offline:'calendar plan'})};
 const source={subject_id:principal.subject_id,scope_id:scope.scope_id,session_id:randomUUID(),issuer:'https://offline.example.invalid/auth/v1'};
 const frozenRun={scope,subject_id:principal.subject_id,source_auth:source,conversation_id:randomUUID(),turn_id:randomUUID()};
 const target={device_id:randomUUID(),environment_id:randomUUID(),calendar_id:'offline-calendar-1',calendar_display_name:'Explicit offline calendar',calendar_snapshot_hash:hash({offline:'calendar descriptor'})};
 const parameters={title:'Synthetic exact calendar write',start_at:'2026-10-15T01:00:00.000Z',end_at:'2026-10-15T01:20:00.000Z',time_zone:'Asia/Shanghai',reminder_offset_seconds:reminder};
 const frozen={contract:DEVICE_EFFECT_ACTION_CONTRACT,id:randomUUID(),proposal_operation_id:randomUUID(),scope_id:scope.scope_id,subject_id:principal.subject_id,conversation_id:frozenRun.conversation_id,turn_id:frozenRun.turn_id,run_id:runID,task_id:taskID,request_hash:hash(frozenRun),delegation_id:delegationID,delegation_revision:1,grant_epoch:1,plan_reference:plan,kind:DEVICE_EFFECT_ACTION_KIND,tool_version:2,target,parameters,parameters_hash:hash(parameters),artifact_reference:null,execution_policy:clone(DEVICE_EFFECT_POLICY_REFERENCE),created_at:'2026-10-14T00:00:00.000Z',expires_at:'2026-10-14T00:30:00.000Z'};
 const action={id:frozen.id,run_id:runID,task_id:taskID,scope_id:scope.scope_id,subject_id:principal.subject_id,source_auth:source,frozen,action_digest:hash(frozen),revision:2,approval_status:'approved',decision_operation_id:randomUUID()};
 const current={id:'current',subject_id:principal.subject_id,scope_id:scope.scope_id,session_id:principal.session_id,viewer_current:true,viewer_expires_at:'2026-10-15T00:00:00.000Z',scope_current:true,source_session_id:source.session_id,source_current:true,source_expires_at:'2026-10-15T00:00:00.000Z',delegation_id:delegationID,delegation_revision:1,grant_epoch:1,delegation_state:'active',task_id:taskID,execution_revision:0,task_status:'waiting_input',plan_current:true,plan_reference:plan,task_lease_id:null,task_lease_until:null,action_reference:{action_id:action.id,revision:2,action_digest:action.action_digest,approval_status:'approved',decision_operation_id:action.decision_operation_id,binding_current:true},device_reference:{...target,device_generation:1,enabled:true}};
 const device={id:'device',verified:true,subject_id:principal.subject_id,scope_id:scope.scope_id,...target,device_generation:1};
 await repository.bootstrapScope({...scope,owner});await authorityRepository.bootstrapScope({...scope,owner});
 await repository.transaction(async tx=>{
  await tx.put(owner,'catpaw-runs',{id:runID,task_id:taskID,delegation_id:delegationID,delegation_revision:1,grant_epoch:1,request_hash:hash(frozenRun),frozen_request:frozenRun});
  await tx.put(owner,'tasks',{id:taskID,status:'waiting_input',leaseId:null,leaseUntil:null,state:{catpaw:{run_id:runID,delegation_id:delegationID,delegation_revision:1,grant_epoch:1,request_hash:hash(frozenRun)},plan_binding:plan,task_control:{revision:0}}});
  await tx.put(owner,TASK_ACTION_KINDS.actions,action);
  await tx.put(owner,TASK_ACTION_KINDS.decisions,{id:action.decision_operation_id,contract:DEVICE_EFFECT_ACTION_CONTRACT,action_id:action.id,run_id:runID,task_id:taskID,scope_id:scope.scope_id,subject_id:principal.subject_id,action_digest:action.action_digest,decision:'approve',execution_policy:clone(DEVICE_EFFECT_POLICY_REFERENCE),committed_at:'2026-10-14T00:00:00.000Z'});
 });
 await authorityRepository.transaction(async tx=>{await tx.put(owner,'offline-authority',current);await tx.put(owner,'offline-target',device);});
 const state={now:Date.parse('2026-10-14T00:00:00.000Z'),readCalls:0,writeCalls:0,targetCalls:0,receiptCalls:0,externalCalls:0,authorityHook:null,targetHook:null,receiptHook:null,afterMutation:null};
 const fresh=()=>authorityRepository.transaction(tx=>tx.get(owner,'offline-authority','current'));
 const changeAuthority=patch=>authorityRepository.transaction(async tx=>{const old=await tx.get(owner,'offline-authority','current');await tx.put(owner,'offline-authority',{...old,...clone(patch)});});
 const changeTarget=patch=>authorityRepository.transaction(async tx=>{const old=await tx.get(owner,'offline-target','device');await tx.put(owner,'offline-target',{...old,...clone(patch)});});
 const facade={repository,deviceEffectExecutionPolicy:clone(DEVICE_EFFECT_POLICY_REFERENCE),deviceEffectClock:()=>new Date(state.now),async scoped(auth,id){check(auth==='Bearer named-offline-viewer',401,'session_required');check(id===scope.scope_id,403,'scope_forbidden');return {owner,scope,principal};},async ownedRun(tx,o,id,p,s){const r=await tx.get(o,'catpaw-runs',id);check(r?.frozen_request.subject_id===p.subject_id&&r.frozen_request.scope.scope_id===s,404,'not_found');return r;},async beforeDeviceEffectRead(_tx,ctx){state.readCalls++;if(state.authorityHook)await state.authorityHook('read',ctx);return fresh();},async beforeDeviceEffectWrite(_tx,ctx){state.writeCalls++;if(state.authorityHook)await state.authorityHook('write',ctx);return fresh();},async deviceEffectTargetVerifier(_tx,ctx){state.targetCalls++;if(state.targetHook)await state.targetHook(ctx);return authorityRepository.transaction(tx=>tx.get(owner,'offline-target','device'));},async deviceEffectReceiptVerifier(_tx,ctx){state.receiptCalls++;if(state.receiptHook)await state.receiptHook(ctx);return {verified:true,receipt_hash:hash(ctx.receipt),subject_id:principal.subject_id,scope_id:scope.scope_id,effect_id:ctx.receipt.effect_id,subeffect_id:ctx.receipt.subeffect_id};}};
 // A fault occurs after a candidate mutation and commits only to the independent
 // authority store. Rejection must roll back effects without resurrecting authority.
 facade.repository={transaction:fn=>repository.transaction(tx=>fn(new Proxy(tx,{get(obj,key){const v=obj[key];if(typeof v!=='function')return v;return async(...args)=>{const result=await v.apply(obj,args);if(['put','insertIfAbsent','compareAndSwap'].includes(key)&&state.afterMutation)await state.afterMutation(key,args,result);return result;};}})))};
 const auth='Bearer named-offline-viewer',id=deviceEffectID(action);
 const admission=()=>({operation_id:randomUUID(),action_id:action.id,decision_operation_id:action.decision_operation_id,expected_action_revision:2,action_digest:action.action_digest,expected_grant_epoch:1,expected_plan_revision:1,expected_plan_hash:plan.plan_hash,expected_execution_revision:0,device_id:target.device_id,calendar_snapshot_hash:target.calendar_snapshot_hash,policy_reference:clone(DEVICE_EFFECT_POLICY_REFERENCE)});
 const admit=input=>admitDeviceEffect(facade,auth,scope.scope_id,runID,input??admission());
 const read=()=>readDeviceEffect(facade,auth,scope.scope_id,runID,action.id,id);
 const dispatchInput=(row,kind='calendar')=>({operation_id:randomUUID(),subeffect:kind,expected_effect_revision:row.revision,binding_hash:row.binding_hash,lease_id:row.frozen.lease_id});
 const dispatch=input=>dispatchDeviceSubeffect(facade,auth,scope.scope_id,runID,action.id,id,input);
 const resultInput=(row,kind='calendar',outcome='succeeded')=>{
  const s=row.subeffects[kind],f=row.frozen,due=new Date(Date.parse(parameters.start_at)+reminder*1000).toISOString();
  const external=kind==='calendar'?{calendar_id:target.calendar_id,event_identifier:'offline/event/original',calendar_item_identifier:'offline/item/original',external_identifier:null,effect_marker:`catpawm://calendar-effect/${s.id}`,content_hash:hash({offline:'actual provider readback'})}:{request_identifier:s.id,schedule_hash:hash({subeffect_id:s.id,due_at:due,parameters_hash:frozen.parameters_hash,channel:'catpaw_local_notification'}),due_at:due,state:'pending'};
  return {operation_id:randomUUID(),subeffect:kind,expected_effect_revision:row.revision,binding_hash:row.binding_hash,lease_id:f.lease_id,dispatch_operation_id:s.dispatch.operation_id,outcome,receipt:outcome==='unknown'?null:{contract:DEVICE_EFFECT_CONTRACT,effect_id:row.id,subeffect_id:s.id,dispatch_operation_id:s.dispatch.operation_id,action_digest:f.action_digest,binding_hash:row.binding_hash,device_id:target.device_id,device_generation:1,outcome,external_reference:outcome==='not_executed'?null:external,observed_at:new Date(state.now).toISOString()}};
 };
 const result=input=>recordDeviceSubeffectResult(facade,auth,scope.scope_id,runID,action.id,id,input);
 const stopInput=row=>({operation_id:randomUUID(),expected_effect_revision:row.revision,binding_hash:row.binding_hash});
 const stop=input=>stopDeviceEffect(facade,auth,scope.scope_id,runID,action.id,id,input);
 const rows=kind=>repository.transaction(tx=>tx.list(owner,kind));
 const alter=(kind,key,patch)=>repository.transaction(async tx=>{const old=await tx.get(owner,kind,key);await tx.put(owner,kind,{...old,...clone(patch)});});
 return {repository,authorityRepository,facade,state,scope,principal,source,owner,runID,taskID,action,target,parameters,id,admission,admit,read,dispatchInput,dispatch,resultInput,result,stopInput,stop,rows,alter,fresh,changeAuthority,changeTarget};
}

test('strict admission dispatch and result reject caller authority and unsafe revisions',async()=>{
 const f=await fixture(),input=f.admission();
 for(const patch of [{allow_expired:true},{executable:true},{subject_id:randomUUID()},{operation_id:input.operation_id.toUpperCase()},{expected_execution_revision:9007199254740992},{expected_grant_epoch:true},{policy_reference:{...input.policy_reference,version:2}}])assert.throws(()=>validateDeviceEffectAdmission({...input,...patch}),ApiError);
 const row=(await f.admit()).effect,d=f.dispatchInput(row);for(const patch of [{retry:true},{expected_effect_revision:true},{subeffect:'reminders_database'},{lease_id:'not-a-lease'}])assert.throws(()=>validateDeviceEffectDispatch({...d,...patch}),ApiError);
 assert.throws(()=>validateDeviceEffectResult({...f.resultInput({...row,subeffects:{...row.subeffects,calendar:{...row.subeffects.calendar,dispatch:{operation_id:randomUUID()}}}},'calendar','unknown'),receipt:{claimed:'success'}}),ApiError);assert.equal(f.state.externalCalls,0);
});
test('old review-only approval is rejected even with an installed execution policy',async()=>{
 const f=await fixture(),old={...f.action.frozen,kind:'calendar.create.v1',tool_version:1};delete old.contract;delete old.execution_policy;
 await f.alter(TASK_ACTION_KINDS.actions,f.action.id,{frozen:old,action_digest:hash(old)});await rejects(()=>f.admit(),'device_effect_review_only_approval');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);
});
test('missing execution authority target and observation ports fail closed',async()=>{
 for(const port of ['deviceEffectExecutionPolicy','beforeDeviceEffectWrite','deviceEffectTargetVerifier']){const f=await fixture();delete f.facade[port];await rejects(()=>f.admit());assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);}
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect;delete f.facade.deviceEffectReceiptVerifier;await rejects(()=>f.result(f.resultInput(d)),'device_effect_receipt_verifier_not_configured');assert.equal((await f.read()).effect.subeffects.calendar.state,'dispatched');
});
test('admission fixes one root and two independent subidentities without dispatch or task completion',async()=>{
 const f=await fixture(),input=f.admission(),a=await f.admit(input);assert.equal(a.effect.id,f.id);assert.equal(a.effect.subeffects.calendar.id,deviceSubeffectID(f.id,'calendar'));assert.notEqual(a.effect.subeffects.calendar.id,a.effect.subeffects.notification.id);assert.equal(a.effect.state,'admitted');assert.equal(a.dispatch_permit,null);
 assert.deepEqual(await f.admit(input),a);await rejects(()=>f.admit(f.admission()),'device_effect_original_identity_conflict');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,1);assert.equal((await f.rows('tasks'))[0].status,'waiting_input');assert.equal(f.state.externalCalls,0);
});
test('admission binds exact decision parameters plan grant epoch device and policy',async()=>{
 for(const patch of [{decision_operation_id:randomUUID()},{action_digest:hash('other')},{expected_action_revision:3},{expected_grant_epoch:2},{expected_plan_hash:hash('other')},{expected_execution_revision:1},{device_id:randomUUID()},{calendar_snapshot_hash:hash('other')}]){const f=await fixture();await rejects(()=>f.admit({...f.admission(),...patch}),'device_effect_approval_conflict');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);}
});
test('separate committed source grant viewer and scope revocation cannot be rolled back by admission',async()=>{
 for(const patch of [{source_current:false},{grant_epoch:2},{delegation_state:'revoked'},{viewer_current:false},{scope_current:false}]){const f=await fixture();await f.changeAuthority(patch);await rejects(()=>f.admit());const committed=await f.fresh();for(const [k,v] of Object.entries(patch))assert.equal(committed[k],v);assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);}
});
test('independent revoke during target verification rejects the candidate and remains committed',async()=>{
 const f=await fixture();f.state.targetHook=()=>f.changeAuthority({source_current:false});await rejects(()=>f.admit(),'device_effect_authority_changed');assert.equal((await f.fresh()).source_current,false);assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);assert.equal((await f.rows(DEVICE_EFFECT_KINDS.operations)).length,0);
});
test('source revoke after the last candidate operation write rolls back both rows only',async()=>{
 const f=await fixture();let fired=false;f.state.afterMutation=async(_method,args)=>{if(!fired&&args[1]===DEVICE_EFFECT_KINDS.operations){fired=true;await f.changeAuthority({source_current:false});}};
 await rejects(()=>f.admit(),'device_effect_authority_changed');assert.equal(fired,true);assert.equal((await f.fresh()).source_current,false);assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);assert.equal((await f.rows(DEVICE_EFFECT_KINDS.operations)).length,0);
});
test('approval and session expiry crossing the final awaited write cannot commit admission',async()=>{
 for(const expiry of ['approval','viewer']){const f=await fixture();let fired=false;f.state.afterMutation=async(_method,args)=>{if(!fired&&args[1]===DEVICE_EFFECT_KINDS.operations){fired=true;f.state.now=Date.parse(expiry==='approval'?f.action.frozen.expires_at:'2026-10-15T00:00:00.000Z');}};await rejects(()=>f.admit());assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);}
});
test('target proof must bind subject scope device environment calendar and generation',async()=>{
 for(const patch of [{verified:1},{subject_id:randomUUID()},{scope_id:randomUUID()},{device_id:randomUUID()},{environment_id:randomUUID()},{calendar_id:'other'},{calendar_snapshot_hash:hash('other')},{device_generation:0}]){const f=await fixture();await f.changeTarget(patch);await rejects(()=>f.admit(),'device_effect_target_not_verified');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);}
});
test('dispatch permit is returned once; repeated or different operations never redispatch',async()=>{
 const f=await fixture(),row=(await f.admit()).effect,input=f.dispatchInput(row),first=await f.dispatch(input);assert.equal(first.dispatch_permit.operation_id,input.operation_id);assert.equal(first.effect.subeffects.calendar.state,'dispatched');
 const replay=await f.dispatch(input);assert.equal(replay.dispatch_permit,null);assert.equal(replay.effect.subeffects.calendar.dispatch.operation_id,input.operation_id);await rejects(()=>f.dispatch(f.dispatchInput(first.effect)),'device_effect_original_outcome_only');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.operations)).filter(r=>r.kind==='dispatch').length,1);assert.equal(f.state.externalCalls,0);
});
test('dispatch rechecks frozen execution epoch task lease pending plan and installed policy',async()=>{
 for(const patch of [{execution_revision:1},{task_lease_id:randomUUID(),task_lease_until:'2026-10-14T00:00:10.000Z'},{plan_current:false},{plan_reference:{revision:2,plan_hash:hash('new')}},{task_status:'paused'}]){const f=await fixture(),row=(await f.admit()).effect;await f.changeAuthority(patch);await rejects(()=>f.dispatch(f.dispatchInput(row)),'device_effect_authority_changed');assert.equal((await f.read()).effect.subeffects.calendar.state,'not_dispatched');}
 const f=await fixture(),row=(await f.admit()).effect;delete f.facade.deviceEffectExecutionPolicy;await rejects(()=>f.dispatch(f.dispatchInput(row)),'device_effect_execution_not_configured');
});
test('lease expiry across dispatch last await rolls back the dispatch journal',async()=>{
 const f=await fixture(),row=(await f.admit()).effect;f.state.now+=1;let fired=false;f.state.afterMutation=async(_method,args)=>{if(!fired&&args[1]===DEVICE_EFFECT_KINDS.operations){fired=true;f.state.now=Date.parse(row.frozen.lease_expires_at);}};await rejects(()=>f.dispatch(f.dispatchInput(row)),'device_effect_lease_expired');f.state.afterMutation=null;assert.equal((await f.read()).effect.subeffects.calendar.state,'not_dispatched');
});
test('lost dispatch response and cold restore only read the exact original with no fresh permit',async()=>{
 const f=await fixture(),input=f.admission(),row=(await f.admit(input)).effect,d=f.dispatchInput(row);await f.dispatch(d);const snapshot=f.repository.snapshot();f.facade.repository=new TestRepository(snapshot);f.state.now+=20000;
 const original=await f.read();assert.equal(original.effect.state,'unknown');assert.equal(original.effect.execution_current,false);assert.equal(original.dispatch_permit,null);assert.equal(original.effect.unresolved_subeffects[0].dispatch_operation_id,d.operation_id);const again=await f.dispatch(d);assert.equal(again.dispatch_permit,null);await rejects(()=>f.dispatch(f.dispatchInput(again.effect)),'device_effect_original_outcome_only');assert.equal(f.state.externalCalls,0);
});
test('original GET never verifies target receipts wakes an executor or changes stored bytes',async()=>{
 const f=await fixture(),row=(await f.admit()).effect;await f.dispatch(f.dispatchInput(row));const before=f.repository.snapshot(),targetCalls=f.state.targetCalls,receiptCalls=f.state.receiptCalls;await f.changeAuthority({source_current:false,grant_epoch:2});const original=await f.read();assert.equal(original.effect.execution_current,false);assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.state.targetCalls,targetCalls);assert.equal(f.state.receiptCalls,receiptCalls);assert.equal(f.state.externalCalls,0);
});
test('calendar success then notification unknown preserves the actual calendar and original notification',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,c=(await f.result(f.resultInput(d))).effect,n=(await f.dispatch(f.dispatchInput(c,'notification'))).effect,u=(await f.result(f.resultInput(n,'notification','unknown'))).effect;
 assert.equal(u.state,'partial_unknown');assert.equal(u.subeffects.calendar.state,'succeeded');assert.equal(u.subeffects.calendar.receipt.external_reference.event_identifier,'offline/event/original');assert.equal(u.subeffects.notification.state,'unknown');await rejects(()=>f.dispatch(f.dispatchInput(u,'notification')),'device_effect_original_outcome_only');await rejects(()=>f.dispatch(f.dispatchInput(u)),'device_effect_original_outcome_only');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.operations)).filter(o=>o.kind==='dispatch').length,2);
});
test('notification cannot dispatch before a verified calendar receipt; null reminder has no notification effect',async()=>{
 const f=await fixture(),a=(await f.admit()).effect;await rejects(()=>f.dispatch(f.dispatchInput(a,'notification')),'device_effect_calendar_receipt_required');
 const g=await fixture({reminder:null}),b=(await g.admit()).effect;assert.equal(b.subeffects.notification.state,'not_required');await rejects(()=>g.dispatch(g.dispatchInput(b,'notification')),'device_effect_original_outcome_only');const d=(await g.dispatch(g.dispatchInput(b))).effect,c=(await g.result(g.resultInput(d))).effect;assert.equal(c.state,'succeeded');
});
test('receipt needs trusted provider observation not an authenticated success declaration',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect;f.facade.deviceEffectReceiptVerifier=async ctx=>({verified:true,receipt_hash:hash('forged')});await rejects(()=>f.result(f.resultInput(d)),'device_effect_receipt_not_verified');assert.equal((await f.read()).effect.subeffects.calendar.state,'dispatched');
});
test('exact external receipt binding rejects another root subeffect marker device and calendar',async()=>{
 for(const patch of [{effect_id:randomUUID()},{subeffect_id:randomUUID()},{dispatch_operation_id:randomUUID()},{action_digest:hash('other')},{binding_hash:hash('other')},{device_id:randomUUID()},{device_generation:2},{external_reference:{calendar_id:'other'}},{external_reference:{effect_marker:'catpawm://calendar-effect/'+randomUUID()}}]){const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,r=f.resultInput(d);r.receipt={...r.receipt,...patch,external_reference:{...r.receipt.external_reference,...patch.external_reference}};await rejects(()=>f.result(r),'device_effect_receipt_binding_conflict');}
});
test('verified original fact after expired lease and source revoke does not grant execution again',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect;await f.changeAuthority({source_current:false,grant_epoch:2,delegation_state:'revoked'});f.state.now+=20000;const result=await f.result(f.resultInput(d));assert.equal(result.effect.subeffects.calendar.state,'succeeded');assert.equal(result.effect.execution_current,false);assert.equal(result.dispatch_permit,null);await rejects(()=>f.dispatch(f.dispatchInput(result.effect,'notification')),'device_effect_lease_expired');
});
test('stop keeps unresolved dispatch identity and blocks future effects; late fact cannot undo stop',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,input=f.stopInput(d),stopped=(await f.stop(input)).effect;assert.equal(stopped.state,'stopped');assert.equal(stopped.subeffects.calendar.state,'unknown');assert.equal(stopped.subeffects.notification.state,'cancelled_before_dispatch');assert.equal(stopped.unresolved_subeffects[0].dispatch_operation_id,d.subeffects.calendar.dispatch.operation_id);
 const late=(await f.result(f.resultInput(stopped))).effect;assert.equal(late.state,'stopped');assert.deepEqual(late.stop,stopped.stop);assert.equal(late.subeffects.calendar.state,'succeeded');await rejects(()=>f.dispatch(f.dispatchInput(late,'notification')),'device_effect_original_outcome_only');assert.equal((await f.stop(input)).effect.state,'stopped');
});
test('revoked viewer during final receipt verifier await cannot commit a late result',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect;f.state.receiptHook=()=>f.changeAuthority({viewer_current:false});await rejects(()=>f.result(f.resultInput(d)),'device_effect_viewer_not_current');assert.equal((await f.fresh()).viewer_current,false);const stored=(await f.rows(DEVICE_EFFECT_KINDS.effects))[0];assert.equal(stored.subeffects.calendar.state,'dispatched');
});
test('another current account or scope cannot read or acknowledge the original effect',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect;await f.changeAuthority({subject_id:randomUUID()});await rejects(()=>f.read(),'device_effect_viewer_not_current');await rejects(()=>f.result(f.resultInput(d)),'device_effect_viewer_not_current');await rejects(()=>readDeviceEffect(f.facade,'Bearer named-offline-viewer',randomUUID(),f.runID,f.action.id,f.id),'scope_forbidden');
});
test('known result replay cannot regress success or duplicate notifications',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,input=f.resultInput(d),c=(await f.result(input)).effect;assert.deepEqual((await f.result(input)).effect,c);await rejects(()=>f.result(f.resultInput(c,'calendar','unknown')),'device_effect_original_outcome_only');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.operations)).filter(o=>o.kind==='result').length,1);
});
test('corrupt stored receipt binding is rejected even if the mutable row hash was recomputed',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,c=(await f.result(f.resultInput(d))).effect;const stored=(await f.rows(DEVICE_EFFECT_KINDS.effects))[0];stored.subeffects.calendar.receipt.action_digest=hash('another action');stored.subeffects.calendar.receipt_hash=hash(stored.subeffects.calendar.receipt);await f.alter(DEVICE_EFFECT_KINDS.effects,f.id,sealDeviceEffectRecord(stored));await rejects(()=>f.read(),'device_effect_receipt_binding_conflict');assert.equal(c.subeffects.calendar.state,'succeeded');
});
test('corrupt original operation body or missing dispatch identity cannot become recoverable',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,c=(await f.result(f.resultInput(d))).effect,stored=(await f.rows(DEVICE_EFFECT_KINDS.effects))[0];stored.subeffects.calendar.receipt.external_reference.event_identifier='different/event';stored.subeffects.calendar.receipt_hash=hash(stored.subeffects.calendar.receipt);await f.alter(DEVICE_EFFECT_KINDS.effects,f.id,sealDeviceEffectRecord(stored));await rejects(()=>f.read(),'device_effect_receipt_binding_conflict');
 const g=await fixture(),b=(await g.admit()).effect,u=(await g.dispatch(g.dispatchInput(b))).effect,missing=(await g.rows(DEVICE_EFFECT_KINDS.effects))[0];missing.subeffects.calendar.state='unknown';missing.subeffects.calendar.dispatch=null;await g.alter(DEVICE_EFFECT_KINDS.effects,g.id,sealDeviceEffectRecord(missing));await rejects(()=>g.read(),'device_effect_dispatch_identity_missing');assert.equal(u.subeffects.calendar.dispatch.operation_id!==null,true);
});
test('a changed decision cannot manufacture a second root effect for the same action',async()=>{
 const f=await fixture(),first=(await f.admit()).effect,next=randomUUID();await f.alter(TASK_ACTION_KINDS.actions,f.action.id,{decision_operation_id:next});
 await f.repository.transaction(tx=>tx.put(f.owner,TASK_ACTION_KINDS.decisions,{id:next,contract:DEVICE_EFFECT_ACTION_CONTRACT,action_id:f.action.id,run_id:f.runID,task_id:f.taskID,scope_id:f.scope.scope_id,subject_id:f.principal.subject_id,action_digest:f.action.action_digest,decision:'approve',execution_policy:clone(DEVICE_EFFECT_POLICY_REFERENCE),committed_at:'2026-10-14T00:00:00.000Z'}));
 assert.equal(deviceEffectID({...f.action,decision_operation_id:next}),first.id);await rejects(()=>f.admit({...f.admission(),decision_operation_id:next}),'device_effect_record_corrupt');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,1);
});
test('a separately committed approval invalidation after dispatch write leaves no dispatch permit',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,ref=(await f.fresh()).action_reference;let fired=false;f.state.afterMutation=async(_method,args)=>{if(!fired&&args[1]===DEVICE_EFFECT_KINDS.operations){fired=true;await f.changeAuthority({action_reference:{...ref,binding_current:false}});}};
 await rejects(()=>f.dispatch(f.dispatchInput(a)),'device_effect_authority_changed');assert.equal((await f.fresh()).source_current,true);assert.equal((await f.fresh()).action_reference.binding_current,false);assert.equal((await f.read()).effect.subeffects.calendar.state,'not_dispatched');assert.equal((await f.rows(DEVICE_EFFECT_KINDS.operations)).filter(o=>o.kind==='dispatch').length,0);
});
test('a separately committed device generation change after admission last write rolls it back',async()=>{
 const f=await fixture(),ref=(await f.fresh()).device_reference;let fired=false;f.state.afterMutation=async(_method,args)=>{if(!fired&&args[1]===DEVICE_EFFECT_KINDS.operations){fired=true;await f.changeAuthority({device_reference:{...ref,device_generation:2}});}};
 await rejects(()=>f.admit(),'device_effect_authority_changed');assert.equal((await f.fresh()).device_reference.device_generation,2);assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,0);
});
test('the concrete task fence cannot be replaced by an older cached authority projection',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,task=(await f.rows('tasks'))[0];await f.alter('tasks',f.taskID,{state:{...task.state,task_control:{revision:1}}});assert.equal((await f.fresh()).execution_revision,0);
 await rejects(()=>f.dispatch(f.dispatchInput(a)),'device_effect_authority_changed');assert.equal((await f.read()).effect.execution_current,false);
});
test('notification receipt has the original deterministic identifier exact due and schedule hash',async()=>{
 for(const field of ['identifier','due','hash']){const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,c=(await f.result(f.resultInput(d))).effect,n=(await f.dispatch(f.dispatchInput(c,'notification'))).effect,r=f.resultInput(n,'notification');
  if(field==='identifier')r.receipt.external_reference.request_identifier=randomUUID();if(field==='due')r.receipt.external_reference.due_at='2026-10-15T00:54:00.000Z';if(field==='hash')r.receipt.external_reference.schedule_hash=hash('another schedule');await rejects(()=>f.result(r),'device_effect_receipt_binding_conflict');assert.equal((await f.read()).effect.subeffects.calendar.state,'succeeded');
 }
});
test('expired approval retains unknown identity and permits original fact recovery only',async()=>{
 const f=await fixture(),a=(await f.admit()).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,u=(await f.result(f.resultInput(d,'calendar','unknown'))).effect;f.state.now=Date.parse(f.action.frozen.expires_at)+1;const read=await f.read();assert.equal(read.effect.state,'unknown');assert.equal(read.effect.unresolved_subeffects[0].dispatch_operation_id,u.subeffects.calendar.dispatch.operation_id);const recovered=await f.result(f.resultInput(read.effect));assert.equal(recovered.effect.subeffects.calendar.state,'succeeded');assert.equal(recovered.effect.execution_current,false);await rejects(()=>f.dispatch(f.dispatchInput(recovered.effect,'notification')),'device_effect_approval_expired');
});
test('operation roles cannot reuse admission or dispatch UUIDs for an acknowledgement',async()=>{
 const f=await fixture(),input=f.admission(),a=(await f.admit(input)).effect,d=(await f.dispatch(f.dispatchInput(a))).effect,r=f.resultInput(d);for(const id of [input.operation_id,d.subeffects.calendar.dispatch.operation_id])await rejects(()=>f.result({...r,operation_id:id}),'device_effect_operation_conflict');assert.equal((await f.read()).effect.subeffects.calendar.state,'dispatched');
});
test('replaying admission observes the frozen old task fence instead of adopting a newer epoch',async()=>{
 const f=await fixture(),input=f.admission(),a=(await f.admit(input)).effect,task=(await f.rows('tasks'))[0];await f.alter('tasks',f.taskID,{state:{...task.state,task_control:{revision:1}}});await f.changeAuthority({execution_revision:1});
 const replay=await f.admit(input);assert.equal(replay.effect.frozen.execution_revision,0);assert.equal(replay.effect.execution_current,false);assert.equal(replay.dispatch_permit,null);assert.deepEqual(replay.effect,(await f.read()).effect);assert.equal((await f.rows(DEVICE_EFFECT_KINDS.effects)).length,1);await rejects(()=>f.dispatch(f.dispatchInput(a)),'device_effect_authority_changed');
});
