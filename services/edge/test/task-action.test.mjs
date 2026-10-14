import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,check,hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {TASK_ACTION_CONTRACT,TASK_ACTION_KINDS,TASK_ACTION_REGISTRY,CALENDAR_CREATE_KIND,taskActionID,validateCalendarCreateParameters,validateTaskActionProposal,validateTaskActionDecision} from '../supabase/functions/_shared/core/src/task-action-contract.mjs';
import {readTaskAction,proposeTaskAction,decideTaskAction,invalidatePendingTaskActionsInTransaction} from '../supabase/functions/_shared/core/src/task-action-service.mjs';

// Only a named, serialized offline authority double. These checks cannot prove PG/process/device/OS effects.
globalThis.fetch=()=>{throw Error('task_action_test_external_network_forbidden');};
async function fixture(snapshot=null){
 const repository=new TestRepository(snapshot??undefined),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()},principal={subject_id:randomUUID(),session_id:randomUUID(),scopes:[]};principal.scopes=[scope];
 const owner='offline-task-action:'+scope.scope_id,runID=randomUUID(),taskID=hash(runID),conversationID=randomUUID(),turnID=randomUUID(),delegationID=randomUUID(),deviceID=randomUUID(),environmentID=randomUUID(),planHash=hash({offline:'actual plan fixture'});
 const source={subject_id:principal.subject_id,scope_id:scope.scope_id,session_id:principal.session_id,issuer:'https://offline.example.invalid/auth/v1',consent_revision:1};
 await repository.bootstrapScope({...scope,owner});
 const state={sourceCurrent:true,viewerCurrent:true,targetCurrent:true,readCalls:0,writeCalls:0,failFinalWrite:false,failFinalRead:false,failSave:false};
 const facade={repository,actionClock:()=>new Date('2026-10-14T00:00:00.000Z'),async scoped(auth,id){check(auth==='Bearer named-offline-authority',401,'session_required');check(id===scope.scope_id,403,'scope_forbidden');return {owner,scope,principal};},async ownedRun(tx,o,id,p,s){const r=await tx.get(o,'catpaw-runs',id);check(r?.frozen_request.subject_id===p.subject_id&&r.frozen_request.scope.scope_id===s,404,'not_found');return r;},async ownedDelegation(tx,o,id,p,{lock,scopeID}){if(lock)await tx.lock(o,'catpaw-delegations',id);const d=await tx.get(o,'catpaw-delegations',id);check(d?.subject_id===p.subject_id&&scopeID===scope.scope_id,404,'not_found');return d;},async beforeActionRead(_tx,ctx){state.readCalls++;check(state.viewerCurrent&&ctx.principal.subject_id===principal.subject_id&&ctx.source_auth.session_id===source.session_id,403,'offline_viewer_denied');return {source_current:state.failFinalRead&&state.readCalls%2===0?false:state.sourceCurrent};},async beforeActionWrite(_tx,ctx){state.writeCalls++;check(state.viewerCurrent&&ctx.source_auth.session_id===source.session_id,403,'offline_viewer_denied');const target=ctx.input?.target??ctx.action?.frozen.target;check(state.targetCurrent&&target?.device_id===deviceID&&target?.environment_id===environmentID,403,'offline_target_environment_denied');return {source_current:state.failFinalWrite&&state.writeCalls%2===0?false:state.sourceCurrent};}};
 await repository.transaction(async tx=>{
  await tx.put(owner,'catpaw-delegations',{id:delegationID,revision:1,grant_epoch:1,state:'active',subject_id:principal.subject_id});
  await tx.put(owner,'catpaw-runs',{id:runID,task_id:taskID,delegation_id:delegationID,delegation_revision:1,grant_epoch:1,request_hash:hash({runID}),frozen_request:{scope,subject_id:principal.subject_id,conversation_id:conversationID,turn_id:turnID,source_auth:source}});
  await tx.put(owner,'tasks',{id:taskID,status:'waiting_input',state:{catpaw:{run_id:runID,delegation_id:delegationID,request_hash:hash({runID}),grant_epoch:1,delegation_revision:1},plan_binding:{revision:1,plan_hash:planHash}}});
  await tx.put(owner,'catpaw-task-plan-heads',{id:runID,run_id:runID,task_id:taskID,scope_id:scope.scope_id,subject_id:principal.subject_id,conversation_id:conversationID,accepted_revision:1,accepted_plan_hash:planHash,applied_revision:1,applied_plan_hash:planHash});
 });
 const input=()=>({operation_id:randomUUID(),kind:CALENDAR_CREATE_KIND,expected_plan_revision:1,expected_plan_hash:planHash,expected_grant_epoch:1,target:{device_id:deviceID,environment_id:environmentID,calendar_id:'offline-calendar',calendar_display_name:'Offline test calendar',calendar_snapshot_hash:hash({fixture_calendar:true})},parameters:{title:'Offline acceptance meeting',start_at:'2026-10-15T01:00:00.000Z',end_at:'2026-10-15T01:20:00.000Z',time_zone:'Asia/Shanghai',reminder_offset_seconds:-300},artifact_reference:null,replaces_action_id:null});
 const auth='Bearer named-offline-authority';
 const propose=value=>proposeTaskAction(facade,auth,scope.scope_id,runID,value);
 const read=(id,options)=>readTaskAction(facade,auth,scope.scope_id,runID,id,options);
 const decision=(action,choice='approve')=>({operation_id:randomUUID(),decision:choice,expected_revision:action.revision,action_digest:action.action_digest,expected_grant_epoch:action.grant_epoch});
 const decide=(id,value)=>decideTaskAction(facade,auth,scope.scope_id,runID,id,value);
 return {repository,facade,state,scope,principal,source,owner,runID,taskID,input,propose,read,decision,decide};
}
const rejects=(fn,code)=>assert.rejects(fn,error=>error instanceof ApiError&&(!code||error.code===code));
async function alter(f,kind,id,patch){await f.repository.transaction(async tx=>{const row=await tx.get(f.owner,kind,id);await tx.put(f.owner,kind,{...row,...patch});});}

test('compiled calendar schema has finite parameters and an unavailable real executor',()=>{
 const params={title:'Meeting',start_at:'2026-10-15T00:00:00.000Z',end_at:'2026-10-15T00:20:00.000Z',time_zone:'Asia/Shanghai',reminder_offset_seconds:-300};
 assert.deepEqual(validateCalendarCreateParameters(params),params);assert.equal(TASK_ACTION_REGISTRY[CALENDAR_CREATE_KIND].executable,false);
 for(const patch of [{title:''},{title:'a'.repeat(201)},{title:'newline\nunsafe'},{start_at:'2026-10-15T08:00:00+08:00'},{start_at:'2026-02-30T00:00:00.000Z'},{start_at:'1969-12-31T00:00:00.000Z'},{end_at:'2101-01-01T00:00:00.000Z'},{end_at:params.start_at},{end_at:'2026-10-14T00:00:00.000Z'},{end_at:'2026-10-23T00:00:00.000Z'},{time_zone:'UTC+08:00'},{time_zone:'Asia/DoesNotExist'},{reminder_offset_seconds:1},{reminder_offset_seconds:-604801},{reminder_offset_seconds:-1.5},{reminder_offset_seconds:NaN},{endpoint:'https://external.invalid'},{notification:{code:'untrusted'}}])assert.throws(()=>validateCalendarCreateParameters({...params,...patch}),ApiError);
 for(const zone of ['UTC','America/New_York','Etc/GMT+8'])assert.equal(validateCalendarCreateParameters({...params,time_zone:zone,reminder_offset_seconds:null}).time_zone,zone);
});
test('strict proposal/decision reject unsupported operators, input authority, hashes and noncanonical IDs',async()=>{
 const f=await fixture(),base=f.input();
 for(const patch of [{operation_id:base.operation_id.toUpperCase()},{kind:'calendar.delete.v1'},{expected_plan_revision:1.5},{expected_plan_hash:'forged'},{expected_grant_epoch:0},{subject_id:f.principal.subject_id},{expires_at:'2099-01-01'},{execute:true},{source_auth:f.source},{schema:{eval:'untrusted'}}])assert.throws(()=>validateTaskActionProposal({...base,...patch}),ApiError);
 for(const patch of [{device_id:'other'},{calendar_id:''},{calendar_id:'x'.repeat(257)},{calendar_snapshot_hash:'bad'},{calendar_display_name:''},{endpoint:'https://external.invalid'}])assert.throws(()=>validateTaskActionProposal({...base,target:{...base.target,...patch}}),ApiError);
 const d={operation_id:randomUUID(),decision:'approve',expected_revision:1,action_digest:'a'.repeat(64),expected_grant_epoch:1};
 for(const patch of [{operation_id:d.operation_id.toUpperCase()},{decision:'approve_and_execute'},{expected_revision:0},{action_digest:'bad'},{expected_grant_epoch:1.5},{parameters:base.parameters}])assert.throws(()=>validateTaskActionDecision({...d,...patch}),ApiError);
 assert.equal(taskActionID(f.runID,base.operation_id),taskActionID(f.runID,base.operation_id));
});
test('pending exact proposal is durable, same-bound, source preserved and has no effect',async()=>{
 const f=await fixture(),input=f.input(),prepared=await f.propose(input),a=prepared.action;
 assert.equal(prepared.contract,TASK_ACTION_CONTRACT);assert.equal(a.approval_status,'pending');assert.deepEqual(a.parameters,input.parameters);assert.deepEqual(a.target,input.target);assert.equal(a.execution_authorized,false);assert.equal(a.capability.os_target_verified,false);assert.equal(a.effect.status,'not_dispatched');assert.equal(a.effect.receipt,null);assert.equal(a.task_id,f.taskID);assert.equal(a.subject_id,f.principal.subject_id);assert.equal(a.parameters_hash,hash(input.parameters));
 const row=await f.repository.transaction(tx=>tx.get(f.owner,TASK_ACTION_KINDS.actions,a.id));assert.deepEqual(row.source_auth,f.source);assert.deepEqual(await f.read(a.id),prepared);
 const snapshot=f.repository.snapshot();f.facade.repository=new TestRepository(snapshot);assert.deepEqual(await f.read(a.id),prepared);
 assert.equal((await f.facade.repository.transaction(tx=>tx.list(f.owner,'catpaw-preview-effects'))).length,0);assert.equal((await f.facade.repository.transaction(tx=>tx.get(f.owner,'tasks',f.taskID))).status,'waiting_input');
});
test('same original proposal operation replays, altered bytes conflict without extra action',async()=>{
 const f=await fixture(),input=f.input(),first=await f.propose(input);assert.deepEqual(await f.propose(input),first);
 await rejects(()=>f.propose({...input,parameters:{...input.parameters,title:'Changed'}}),'action_operation_conflict');
 assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.actions))).length,1);
});
test('approved means durable decision awaiting device, not completion or actual effect',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action,input=f.decision(a),accepted=await f.decide(a.id,input);
 assert.equal(accepted.action.approval_status,'approved');assert.equal(accepted.action.revision,2);assert.equal(accepted.action.effect.status,'waiting_device');assert.equal(accepted.action.execution_authorized,false);assert.equal(accepted.action.capability.executable,false);assert.equal(accepted.action.effect.receipt,null);assert.equal(accepted.decision.operation_id,input.operation_id);assert.equal(accepted.decision.state,'accepted');
 assert.deepEqual(await f.decide(a.id,input),accepted);assert.deepEqual(await f.read(a.id,{decisionOperationID:input.operation_id}),accepted);
 assert.equal((await f.repository.transaction(tx=>tx.get(f.owner,'tasks',f.taskID))).status,'waiting_input');
 for(const kind of ['catpaw-effects','catpaw-preview-effects','activity','run-events'])assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,kind))).length,0,kind);
});
test('deny is consumed once without effects or reapproval',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action,d=f.decision(a,'deny'),result=await f.decide(a.id,d);assert.equal(result.action.approval_status,'denied');assert.equal(result.action.effect.status,'not_dispatched');assert.deepEqual(await f.decide(a.id,d),result);
 await rejects(()=>f.decide(a.id,f.decision(a)),'action_approval_consumed');
 await rejects(()=>f.decide(a.id,{...d,decision:'approve'}),'action_operation_conflict');
});
test('one original decision under concurrent double taps; second operation cannot consume it',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action,d=f.decision(a),results=await Promise.all([f.decide(a.id,d),f.decide(a.id,d)]);assert.deepEqual(results[0],results[1]);
 await rejects(()=>f.decide(a.id,f.decision(a)),'action_approval_consumed');assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.decisions))).length,1);
});
test('decision IDs cannot alias proposal, action or run and decision hash binds action/run',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action;
 for(const id of [a.id,a.proposal_operation_id,f.runID])await rejects(()=>f.decide(a.id,{...f.decision(a),operation_id:id}),'action_operation_identity_conflict');
 const b=(await f.propose(f.input())).action,d=f.decision(a);await f.decide(a.id,d);await rejects(()=>f.decide(b.id,{...f.decision(b),operation_id:d.operation_id}),'action_operation_conflict');
});
test('proposal/decision operations cannot alias the original task business identities',async()=>{
 const f=await fixture(),run=await f.repository.transaction(tx=>tx.get(f.owner,'catpaw-runs',f.runID));
 for(const id of [f.runID,run.delegation_id,run.frozen_request.conversation_id,run.frozen_request.turn_id])await rejects(()=>f.propose({...f.input(),operation_id:id}),'action_operation_identity_conflict');
 const a=(await f.propose(f.input())).action;for(const id of [run.delegation_id,run.frozen_request.conversation_id,run.frozen_request.turn_id])await rejects(()=>f.decide(a.id,{...f.decision(a),operation_id:id}),'action_operation_identity_conflict');
});
test('changed task admission tag cannot create a new approval despite matching run ID',async()=>{
 const f=await fixture(),row=await f.repository.transaction(tx=>tx.get(f.owner,'tasks',f.taskID));await alter(f,'tasks',f.taskID,{state:{...row.state,catpaw:{...row.state.catpaw,request_hash:hash('different original request')}}});await rejects(()=>f.propose(f.input()),'action_task_binding_conflict');
});
test('lost response is read by original decision ID, never automatically creates another decision',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action,d=f.decision(a);await f.decide(a.id,d); // Offline simulation discards only the response, not a real system receipt.
 f.facade.repository=new TestRepository(f.repository.snapshot());const read=await f.read(a.id,{decisionOperationID:d.operation_id});assert.equal(read.decision.operation_id,d.operation_id);assert.equal(read.action.effect.status,'waiting_device');
 await rejects(()=>f.read(a.id,{decisionOperationID:randomUUID()}),'not_found');assert.equal((await f.facade.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.decisions))).length,1);
});
test('newer parameters explicitly replace pending review while original proposal stays auditable',async()=>{
 const f=await fixture(),input=f.input(),a=(await f.propose(input)).action,replacement={...input,operation_id:randomUUID(),replaces_action_id:a.id,parameters:{...input.parameters,start_at:'2026-10-15T02:00:00.000Z',end_at:'2026-10-15T02:20:00.000Z'}},b=(await f.propose(replacement)).action;
 const old=await f.read(a.id);assert.equal(old.action.approval_status,'invalidated');assert.equal(old.action.invalidation_reason,'newer_parameters');assert.equal(old.action.superseded_by,b.id);assert.equal(old.action.action_digest,a.action_digest);await rejects(()=>f.decide(a.id,f.decision(a)),'action_approval_consumed');assert.equal(b.parameters.start_at,replacement.parameters.start_at);
 await rejects(()=>f.propose({...replacement,operation_id:randomUUID()}),'action_replacement_conflict');
});
test('explicit calendar target change replaces pending review only after trusted ownership check',async()=>{
 const f=await fixture(),input=f.input(),a=(await f.propose(input)).action;
 const replacement={...input,operation_id:randomUUID(),replaces_action_id:a.id,target:{...input.target,calendar_id:'different',calendar_display_name:'Different approved calendar',calendar_snapshot_hash:hash('new calendar')}};
 const b=(await f.propose(replacement)).action;assert.equal(b.target.calendar_id,'different');assert.equal((await f.read(a.id)).action.approval_status,'invalidated');await f.decide(b.id,f.decision(b));
 await rejects(()=>f.propose({...replacement,operation_id:randomUUID(),replaces_action_id:b.id}),'action_replacement_conflict');
 const g=await fixture(),c=(await g.propose(g.input())).action;g.state.targetCurrent=false;await rejects(()=>g.propose({...g.input(),replaces_action_id:c.id}),'offline_target_environment_denied');assert.equal((await g.read(c.id)).action.approval_status,'pending');
});
test('plan change invalidates pending or approved execution, retains immutable original decision',async()=>{
 for(const approved of [false,true]){
  const f=await fixture(),a=(await f.propose(f.input())).action,d=f.decision(a);if(approved)await f.decide(a.id,d);
  await alter(f,'catpaw-task-plan-heads',f.runID,{accepted_revision:2,accepted_plan_hash:hash('new plan')});
  const read=await f.read(a.id,approved?{decisionOperationID:d.operation_id}:{});assert.equal(read.action.invalidation_reason,'plan_changed');assert.equal(read.action.approval_status,approved?'approved':'invalidated');assert.equal(read.action.effect.status,'not_dispatched');assert.equal(read.action.execution_authorized,false);if(approved)assert.equal(read.decision.operation_id,d.operation_id);
  if(!approved)await rejects(()=>f.decide(a.id,d),'action_approval_stale');
 }
});
test('grant/task/source changes fence old review and preserve original approved history',async()=>{
 for(const change of ['grant','paused','cancelled','source']){
  const f=await fixture(),a=(await f.propose(f.input())).action,d=f.decision(a);await f.decide(a.id,d);
  if(change==='grant'){const run=await f.repository.transaction(tx=>tx.get(f.owner,'catpaw-runs',f.runID));await alter(f,'catpaw-delegations',run.delegation_id,{grant_epoch:2});}
  else if(change==='source')f.state.sourceCurrent=false;else await alter(f,'tasks',f.taskID,{status:change});
  const read=await f.read(a.id,{decisionOperationID:d.operation_id});assert.equal(read.action.approval_status,'approved');assert.equal(read.action.approval_binding_current,false);assert.equal(read.action.effect.status,'not_dispatched');assert.deepEqual((await f.decide(a.id,d)).decision,read.decision);
 }
});
test('expiry is strict and does not authorize delayed device work',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action;f.facade.actionClock=()=>new Date(a.expires_at);assert.equal((await f.read(a.id)).action.approval_status,'expired');await rejects(()=>f.decide(a.id,f.decision(a)),'action_approval_stale');
 const g=await fixture(),b=(await g.propose(g.input())).action,d=g.decision(b);await g.decide(b.id,d);g.facade.actionClock=()=>new Date(b.expires_at);const read=await g.read(b.id,{decisionOperationID:d.operation_id});assert.equal(read.action.approval_status,'approved');assert.equal(read.action.invalidation_reason,'expired');assert.equal(read.action.effect.status,'not_dispatched');
});
test('exact artifact reference must be current; newer artifact cannot reuse old approval',async()=>{
 const f=await fixture(),artifactID=hash('offline-artifact'),body='Offline artifact body',ref={artifact_id:artifactID,version:1,content_hash:hash(body)};
 await f.repository.transaction(async tx=>{await tx.put(f.owner,'catpaw-artifact-heads',{id:artifactID,...ref});await tx.put(f.owner,'catpaw-artifact-versions',{id:artifactID+':1',...ref,run_id:f.runID,task_id:f.taskID,body});});
 const a=(await f.propose({...f.input(),artifact_reference:ref})).action,d=f.decision(a);await f.decide(a.id,d);await alter(f,'catpaw-artifact-heads',artifactID,{version:2,content_hash:hash('new body')});assert.equal((await f.read(a.id,{decisionOperationID:d.operation_id})).action.invalidation_reason,'artifact_changed');
 await rejects(()=>f.propose({...f.input(),artifact_reference:ref}),'action_artifact_conflict');
});
test('missing/invalid authority hooks fail closed; final write recheck rolls back entire candidate',async()=>{
 const f=await fixture(),input=f.input();delete f.facade.beforeActionWrite;await rejects(()=>f.propose(input),'action_authority_not_configured');assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.actions))).length,0);
 const g=await fixture();g.facade.beforeActionWrite=async()=>undefined;await rejects(()=>g.propose(g.input()),'action_authority_result_required');
 const h=await fixture();h.state.failFinalWrite=true;await rejects(()=>h.propose(h.input()),'action_source_not_current');assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,TASK_ACTION_KINDS.actions))).length,0);assert.equal((await h.repository.transaction(tx=>tx.list(h.owner,TASK_ACTION_KINDS.proposals))).length,0);
});
test('final decision authority rejection rolls back decision and leaves the same pending original',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action;f.state.failFinalWrite=true;await rejects(()=>f.decide(a.id,f.decision(a)),'action_source_not_current');assert.equal((await f.read(a.id)).action.approval_status,'pending');assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.decisions))).length,0);
});
test('reads require hook and after-last-read source recheck never returns current authority incorrectly',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action;delete f.facade.beforeActionRead;await rejects(()=>f.read(a.id),'action_authority_not_configured');
 const g=await fixture(),b=(await g.propose(g.input())).action;g.state.failFinalRead=true;const read=await g.read(b.id);assert.equal(read.action.approval_binding_current,false);assert.equal(read.action.invalidation_reason,'source_authority_changed');
});
test('trusted environment hook rejects invented device even when schema-valid',async()=>{
 const f=await fixture(),input=f.input();await rejects(()=>f.propose({...input,target:{...input.target,device_id:randomUUID()}}),'offline_target_environment_denied');f.state.targetCurrent=false;await rejects(()=>f.propose(input),'offline_target_environment_denied');assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.actions))).length,0);
});
test('scope/subject/run/action integrity mismatch cannot project or decide another object',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action;await rejects(()=>readTaskAction(f.facade,'Bearer named-offline-authority',randomUUID(),f.runID,a.id),'scope_forbidden');
 await rejects(()=>f.read(randomUUID()),'not_found');
 const row=await f.repository.transaction(tx=>tx.get(f.owner,TASK_ACTION_KINDS.actions,a.id));await alter(f,TASK_ACTION_KINDS.actions,a.id,{frozen:{...row.frozen,target:{...row.frozen.target,calendar_id:'tampered'}}});await rejects(()=>f.read(a.id),'action_binding_conflict');await rejects(()=>f.decide(a.id,f.decision(a)),'action_binding_conflict');
});
test('row source authority must match the immutable original run before any read or decision',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action;await alter(f,TASK_ACTION_KINDS.actions,a.id,{source_auth:{...f.source,session_id:randomUUID()}});await rejects(()=>f.read(a.id),'action_binding_conflict');await rejects(()=>f.decide(a.id,f.decision(a)),'action_binding_conflict');
});
test('expiry crossing the final write authority await rolls back proposal or original decision',async()=>{
 const f=await fixture(),hook=f.facade.beforeActionWrite;f.facade.beforeActionWrite=async(tx,ctx)=>{const result=await hook(tx,ctx);if(f.state.writeCalls===2)f.facade.actionClock=()=>new Date('2026-10-14T00:30:00.000Z');return result;};
 await rejects(()=>f.propose(f.input()),'action_approval_stale');assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.actions))).length,0);assert.equal((await f.repository.transaction(tx=>tx.list(f.owner,TASK_ACTION_KINDS.proposals))).length,0);
 const g=await fixture(),a=(await g.propose(g.input())).action,nextHook=g.facade.beforeActionWrite;g.facade.beforeActionWrite=async(tx,ctx)=>{const result=await nextHook(tx,ctx);if(g.state.writeCalls===4)g.facade.actionClock=()=>new Date(a.expires_at);return result;};
 await rejects(()=>g.decide(a.id,g.decision(a)),'action_approval_stale');const row=await g.repository.transaction(tx=>tx.get(g.owner,TASK_ACTION_KINDS.actions,a.id));assert.equal(row.approval_status,'pending');assert.equal(row.revision,1);assert.equal((await g.repository.transaction(tx=>tx.list(g.owner,TASK_ACTION_KINDS.decisions))).length,0);
});
test('expiry crossing the final read authority await returns expired with no store mutation',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action,snapshot=f.repository.snapshot(),hook=f.facade.beforeActionRead;f.facade.beforeActionRead=async(tx,ctx)=>{const result=await hook(tx,ctx);if(f.state.readCalls===2)f.facade.actionClock=()=>new Date(a.expires_at);return result;};
 const read=await f.read(a.id);assert.equal(read.action.approval_status,'expired');assert.equal(read.action.approval_binding_current,false);assert.equal(read.action.effect.status,'not_dispatched');assert.deepEqual(f.repository.snapshot(),snapshot);
});
test('trusted amendment/source fence persists invalidation without erasing approved decision',async()=>{
 const f=await fixture(),pending=(await f.propose(f.input())).action,approved=(await f.propose(f.input())).action,d=f.decision(approved);await f.decide(approved.id,d);
 await f.repository.transaction(tx=>invalidatePendingTaskActionsInTransaction(tx,f.owner,{run_id:f.runID,task_id:f.taskID,reason:'source_authority_changed'}));
 assert.equal((await f.read(pending.id)).action.approval_status,'invalidated');const read=await f.read(approved.id,{decisionOperationID:d.operation_id});assert.equal(read.action.approval_status,'approved');assert.equal(read.action.effect.status,'not_dispatched');assert.equal(read.decision.operation_id,d.operation_id);
});
test('pending action source hook denial cannot mutate records or create a decision',async()=>{
 const f=await fixture(),a=(await f.propose(f.input())).action,snapshot=f.repository.snapshot();f.state.sourceCurrent=false;await rejects(()=>f.decide(a.id,f.decision(a)),'action_approval_stale');assert.deepEqual(f.repository.snapshot(),snapshot);
});
