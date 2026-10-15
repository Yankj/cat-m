import {check,hash,clone} from '../facade-r2/src/common.mjs';
import {TASK_ACTION_KINDS} from './task-action-contract.mjs';
import {DEVICE_EFFECT_CONTRACT,DEVICE_EFFECT_ACTION_CONTRACT,DEVICE_EFFECT_KINDS,DEVICE_EFFECT_LIMITS,DEVICE_EFFECT_POLICY_REFERENCE,deviceEffectID,deviceSubeffectID,deviceEffectLeaseID,deviceEffectUUID,deviceEffectHash,deviceEffectRevision,deviceEffectUTC,validateDeviceEffectAction,validateDeviceEffectAdmission,validateDeviceEffectDispatch,validateDeviceEffectResult,validateDeviceEffectStop,deviceEffectRecordHash,sealDeviceEffectRecord,deviceEffectState} from './device-effect-contract.mjs';

// No executor, timer, registry, transport, notification or platform import exists here.
// Trusted composition ports must read current COMMITTED viewer/source authority, not
// an admission cache or a transaction-local mutation that will disappear on rollback.
const same=(a,b)=>hash(a)===hash(b);
const time=facade=>{const d=facade.deviceEffectClock?.()??new Date();check(d instanceof Date&&Number.isFinite(d.getTime()),503,'device_effect_clock_invalid');return d;};
const liveTask=new Set(['queued','scheduled','running','waiting_input','waiting_approval']);

function currentExecution(ctx,p,now){
 if(!ctx.action)return false;const f=ctx.action.frozen,a=p.action_reference,d=p.device_reference;
 return p.source_current===true&&deviceEffectUTC(p.source_expires_at)>now&&p.delegation_id===f.delegation_id&&p.delegation_revision===f.delegation_revision&&p.grant_epoch===f.grant_epoch&&p.delegation_state==='active'&&p.task_id===f.task_id&&p.execution_revision===ctx.executionRevision&&(ctx.task.state?.task_control?.revision??0)===ctx.executionRevision&&liveTask.has(ctx.task.status)&&liveTask.has(p.task_status)&&p.plan_current===true&&same(ctx.task.state.plan_binding,f.plan_reference)&&same(p.plan_reference,f.plan_reference)&&a.revision===ctx.action.revision&&a.action_digest===ctx.action.action_digest&&a.approval_status==='approved'&&a.decision_operation_id===ctx.action.decision_operation_id&&a.binding_current===true&&d.enabled===true&&['device_id','environment_id','calendar_id','calendar_snapshot_hash'].every(k=>d[k]===f.target[k])&&(!ctx.effect||d.device_generation===ctx.effect.frozen.device_generation)&&same(ctx.task.leaseId??null,ctx.taskLeaseID)&&same(ctx.task.leaseUntil??null,ctx.taskLeaseUntil)&&same(p.task_lease_id,ctx.taskLeaseID)&&same(p.task_lease_until,ctx.taskLeaseUntil)&&(!p.task_lease_id||deviceEffectUTC(p.task_lease_until)>now)&&!ctx.action.invalidation_reason&&!ctx.action.superseded_by&&deviceEffectUTC(f.expires_at)>now;
}
function localFence(facade,ctx){
 const now=time(facade).getTime();check(now<ctx.deadline,409,'device_effect_write_budget_expired');
 check(deviceEffectUUID(ctx.principal.subject_id)&&deviceEffectUUID(ctx.principal.session_id)&&ctx.scope.scope_id===ctx.scopeID,403,'device_effect_viewer_binding_invalid');
 if(ctx.mode==='execute'&&ctx.action){check(facade.deviceEffectExecutionPolicy&&same(facade.deviceEffectExecutionPolicy,DEVICE_EFFECT_POLICY_REFERENCE),503,'device_effect_execution_not_configured');check(deviceEffectUTC(ctx.action.frozen.expires_at)>now,409,'device_effect_approval_expired');if(ctx.effect)check(deviceEffectUTC(ctx.effect.frozen.lease_expires_at)>now,409,'device_effect_lease_expired');}
 return now;
}
async function gate(facade,tx,ctx){
 localFence(facade,ctx);const hook=ctx.mode==='execute'?facade.beforeDeviceEffectWrite:facade.beforeDeviceEffectRead;
 check(typeof hook==='function',503,'device_effect_authority_not_configured');
 const p=await hook(tx,clone({...ctx,source_auth:ctx.run?.frozen_request.source_auth??null})),now=localFence(facade,ctx);
 check(p&&p.subject_id===ctx.principal.subject_id&&p.scope_id===ctx.scopeID&&p.session_id===ctx.principal.session_id&&p.viewer_current===true&&p.scope_current===true&&deviceEffectUTC(p.viewer_expires_at)>now&&typeof p.source_current==='boolean',403,'device_effect_viewer_not_current');
 if(ctx.action){
  check(p.source_session_id===ctx.run.frozen_request.source_auth.session_id&&Number.isFinite(deviceEffectUTC(p.source_expires_at))&&deviceEffectUUID(p.delegation_id)&&deviceEffectRevision(p.delegation_revision)&&p.delegation_revision>0&&deviceEffectRevision(p.grant_epoch)&&p.grant_epoch>0&&['active','paused','revoked'].includes(p.delegation_state)&&deviceEffectHash(p.task_id)&&deviceEffectRevision(p.execution_revision)&&typeof p.task_status==='string'&&typeof p.plan_current==='boolean'&&p.plan_reference&&deviceEffectRevision(p.plan_reference.revision)&&p.plan_reference.revision>0&&deviceEffectHash(p.plan_reference.plan_hash)&&(p.task_lease_id===null||deviceEffectUUID(p.task_lease_id))&&(p.task_lease_until===null||Number.isFinite(deviceEffectUTC(p.task_lease_until)))&&Boolean(p.task_lease_id)===Boolean(p.task_lease_until),503,'device_effect_authority_result_invalid');
  const a=p.action_reference,d=p.device_reference;check(a?.action_id===ctx.action.id&&deviceEffectRevision(a.revision)&&a.revision>0&&deviceEffectHash(a.action_digest)&&deviceEffectUUID(a.decision_operation_id)&&typeof a.approval_status==='string'&&typeof a.binding_current==='boolean'&&deviceEffectUUID(d?.device_id)&&deviceEffectUUID(d.environment_id)&&typeof d.calendar_id==='string'&&deviceEffectHash(d.calendar_snapshot_hash)&&deviceEffectRevision(d.device_generation)&&d.device_generation>0&&typeof d.enabled==='boolean',503,'device_effect_authority_result_invalid');
  check(p.task_id===ctx.task.id&&p.delegation_id===ctx.action.frozen.delegation_id,409,'device_effect_authority_binding_conflict');const current=Boolean(facade.deviceEffectExecutionPolicy&&same(facade.deviceEffectExecutionPolicy,DEVICE_EFFECT_POLICY_REFERENCE))&&currentExecution(ctx,p,now);if(ctx.mode==='execute')check(current,409,'device_effect_authority_changed');ctx.executionCurrent=current;
 }
 return p;
}
// Every repository/verification await is fenced on both sides, including the last
// write. A failed final fence rolls back the candidate; independently committed
// revocation remains committed. No check grants permission to invoke a platform API.
async function wait(facade,tx,ctx,operation){await gate(facade,tx,ctx);const result=await operation();await gate(facade,tx,ctx);return result;}
async function resolve(facade,tx,scoped,scopeID,runID,actionID,mode){
 const ctx={...scoped,scopeID,mode,deadline:time(facade).getTime()+DEVICE_EFFECT_LIMITS.write_budget_ms,executionCurrent:false};
 await wait(facade,tx,ctx,()=>tx.withScope(scopeID,async s=>{const row=await s.scope();check(row.identity.owner===ctx.owner,403,'scope_forbidden');}));
 const run=await wait(facade,tx,ctx,()=>facade.ownedRun(tx,ctx.owner,runID,ctx.principal,scopeID));ctx.run=run;
 const f=run?.frozen_request;check(run?.id===runID&&f?.subject_id===ctx.principal.subject_id&&f.scope?.scope_id===scopeID&&f.source_auth?.subject_id===f.subject_id&&f.source_auth.scope_id===scopeID&&hash(f)===run.request_hash,409,'device_effect_run_binding_conflict');
 await wait(facade,tx,ctx,()=>tx.lock(ctx.owner,'tasks',run.task_id));
 const task=await wait(facade,tx,ctx,()=>tx.get(ctx.owner,'tasks',run.task_id)),tag=task?.state?.catpaw;
 check(task?.id===run.task_id&&tag?.run_id===runID&&['delegation_id','delegation_revision','grant_epoch','request_hash'].every(k=>tag[k]===run[k]),409,'device_effect_task_binding_conflict');
 ctx.task=task;ctx.executionRevision=task.state?.task_control?.revision??0;ctx.taskLeaseID=task.leaseId??null;ctx.taskLeaseUntil=task.leaseUntil??null;
 check(deviceEffectRevision(ctx.executionRevision),409,'device_effect_task_binding_conflict');
 await wait(facade,tx,ctx,()=>tx.lock(ctx.owner,TASK_ACTION_KINDS.actions,actionID));
 const action=await wait(facade,tx,ctx,()=>tx.get(ctx.owner,TASK_ACTION_KINDS.actions,actionID));check(action,404,'not_found');validateDeviceEffectAction(action);
 const a=action.frozen;check(action.id===actionID&&action.run_id===runID&&action.task_id===task.id&&action.subject_id===ctx.principal.subject_id&&action.scope_id===scopeID&&same(action.source_auth,f.source_auth)&&a.subject_id===f.subject_id&&a.scope_id===scopeID&&a.run_id===runID&&a.task_id===task.id&&a.request_hash===run.request_hash&&a.conversation_id===f.conversation_id&&a.turn_id===f.turn_id&&a.delegation_id===run.delegation_id&&a.delegation_revision===run.delegation_revision&&a.grant_epoch===run.grant_epoch,409,'device_effect_action_binding_conflict');
 ctx.action=action;
 const decision=await wait(facade,tx,ctx,()=>tx.get(ctx.owner,TASK_ACTION_KINDS.decisions,action.decision_operation_id));
 check(decision?.id===action.decision_operation_id&&decision.contract===DEVICE_EFFECT_ACTION_CONTRACT&&decision.action_id===action.id&&decision.run_id===runID&&decision.task_id===task.id&&decision.subject_id===ctx.principal.subject_id&&decision.scope_id===scopeID&&decision.action_digest===action.action_digest&&decision.decision==='approve'&&same(decision.execution_policy,a.execution_policy)&&deviceEffectUTC(decision.committed_at)>=deviceEffectUTC(a.created_at)&&deviceEffectUTC(decision.committed_at)<deviceEffectUTC(a.expires_at),409,'device_effect_decision_binding_conflict');ctx.decision=decision;
 await gate(facade,tx,ctx);return ctx;
}
async function target(facade,tx,ctx){
 check(typeof facade.deviceEffectTargetVerifier==='function',503,'device_effect_target_not_configured');const t=ctx.action.frozen.target;
 const proof=await wait(facade,tx,ctx,()=>facade.deviceEffectTargetVerifier(tx,clone({...ctx,target:t,purpose:ctx.mode==='execute'?'execute':'record_original_fact'})));
 check(proof?.verified===true&&proof.subject_id===ctx.principal.subject_id&&proof.scope_id===ctx.scopeID&&['device_id','environment_id','calendar_id','calendar_snapshot_hash'].every(k=>proof[k]===t[k])&&deviceEffectRevision(proof.device_generation)&&proof.device_generation>0,403,'device_effect_target_not_verified');
 if(ctx.effect)check(proof.device_generation===ctx.effect.frozen.device_generation,409,'device_effect_device_generation_changed');return proof;
}
function operationIdentity(ctx,id){
 const f=ctx.action.frozen,e=ctx.effect?.frozen;
 check(![f.id,f.proposal_operation_id,f.scope_id,f.conversation_id,f.turn_id,f.run_id,f.delegation_id,ctx.action.decision_operation_id,e?.id,e?.lease_id,...Object.values(ctx.effect?.subeffects??{}).map(s=>s.id)].includes(id),422,'device_effect_operation_identity_conflict');
}
function validateRecord(row,ctx){
 check(row?.contract===DEVICE_EFFECT_CONTRACT&&deviceEffectRevision(row.revision)&&row.revision>0&&row.record_hash===deviceEffectRecordHash(row)&&row.binding_hash===hash(row.frozen),409,'device_effect_record_corrupt');
 const f=row.frozen,a=ctx.action.frozen;
 check(f.id===row.id&&row.id===deviceEffectID(ctx.action)&&f.action_id===a.id&&f.action_digest===ctx.action.action_digest&&f.decision_operation_id===ctx.action.decision_operation_id&&f.scope_id===ctx.scopeID&&f.subject_id===ctx.principal.subject_id&&f.run_id===ctx.run.id&&f.task_id===ctx.task.id&&f.run_request_hash===ctx.run.request_hash&&f.conversation_id===a.conversation_id&&f.turn_id===a.turn_id&&f.delegation_id===a.delegation_id&&f.delegation_revision===a.delegation_revision&&f.grant_epoch===a.grant_epoch&&same(f.target,a.target)&&same(f.parameters,a.parameters)&&same(f.policy_reference,DEVICE_EFFECT_POLICY_REFERENCE)&&f.approval_expires_at===a.expires_at&&deviceEffectRevision(f.execution_revision)&&deviceEffectRevision(f.device_generation)&&f.device_generation>0&&deviceEffectUUID(f.admission_operation_id)&&deviceEffectHash(f.admission_request_hash)&&f.lease_id===deviceEffectLeaseID(row.id,f.admission_operation_id)&&deviceEffectUTC(f.lease_expires_at)>deviceEffectUTC(f.admitted_at)&&deviceEffectUTC(f.lease_expires_at)-deviceEffectUTC(f.admitted_at)<=DEVICE_EFFECT_LIMITS.lease_ms&&deviceEffectUTC(f.lease_expires_at)<=deviceEffectUTC(f.approval_expires_at),409,'device_effect_record_corrupt');
 check(row.stop===null||deviceEffectUUID(row.stop.operation_id)&&row.stop.reason==='user_stopped'&&Number.isFinite(deviceEffectUTC(row.stop.stopped_at)),409,'device_effect_record_corrupt');
 check(Object.keys(row.subeffects??{}).sort().join(',')==='calendar,notification',409,'device_effect_record_corrupt');
 for(const [kind,s] of Object.entries(row.subeffects)){
  check(s.id===deviceSubeffectID(row.id,kind)&&s.kind===kind&&['not_dispatched','not_required','dispatched','unknown','succeeded','not_executed','cancelled_before_dispatch'].includes(s.state)&&(!['not_required','cancelled_before_dispatch','not_dispatched'].includes(s.state)||s.dispatch===null&&s.receipt===null),409,'device_effect_record_corrupt');
  check(s.state!=='not_required'||kind==='notification'&&f.parameters.reminder_offset_seconds===null,409,'device_effect_record_corrupt');
  check(!['dispatched','unknown','succeeded','not_executed'].includes(s.state)||s.dispatch!==null,409,'device_effect_dispatch_identity_missing');
  if(s.dispatch){const d=s.dispatch,{dispatch_hash,...body}=d;check(d.contract===DEVICE_EFFECT_CONTRACT&&d.effect_id===row.id&&d.subeffect_id===s.id&&d.kind===kind&&d.binding_hash===row.binding_hash&&d.lease_id===f.lease_id&&deviceEffectUUID(d.operation_id)&&deviceEffectHash(d.request_hash)&&dispatch_hash===hash(body)&&deviceEffectUTC(d.dispatched_at)>=deviceEffectUTC(f.admitted_at)&&deviceEffectUTC(d.dispatched_at)<deviceEffectUTC(f.lease_expires_at),409,'device_effect_record_corrupt');}
  if(s.receipt){const r=s.receipt;check(s.dispatch&&r.effect_id===row.id&&r.subeffect_id===s.id&&r.dispatch_operation_id===s.dispatch.operation_id&&r.action_digest===f.action_digest&&r.binding_hash===row.binding_hash&&r.device_id===f.target.device_id&&r.device_generation===f.device_generation&&r.outcome===s.state,409,'device_effect_receipt_binding_conflict');validateDeviceEffectResult({operation_id:s.result_operation_id,subeffect:kind,expected_effect_revision:1,binding_hash:row.binding_hash,lease_id:f.lease_id,dispatch_operation_id:s.dispatch.operation_id,outcome:r.outcome,receipt:r});check(s.receipt_hash===hash(r),409,'device_effect_receipt_binding_conflict');}
  else check(!['succeeded','not_executed'].includes(s.state),409,'device_effect_record_corrupt');
 }
 return row;
}
function projection(ctx,row){
 validateRecord(row,ctx);const f=row.frozen,leaseCurrent=deviceEffectUTC(f.lease_expires_at)>Date.parse(ctx.observedAt??f.admitted_at);
 const unresolved=Object.values(row.subeffects).filter(s=>['dispatched','unknown'].includes(s.state)).map(s=>({kind:s.kind,subeffect_id:s.id,dispatch_operation_id:s.dispatch.operation_id,state:s.state,can_retry:false}));
 const expiredUnknown=row.stop===null&&!leaseCurrent&&unresolved.length>0;const state=expiredUnknown?(row.subeffects.calendar.state==='succeeded'?'partial_unknown':'unknown'):deviceEffectState(row);
 return {schema_version:1,contract:DEVICE_EFFECT_CONTRACT,effect:{...clone(row),state,execution_current:ctx.executionCurrent===true&&leaseCurrent&&row.stop===null,unresolved_subeffects:unresolved,can_redispatch:false},dispatch_permit:null};
}
async function verifyOperations(facade,tx,ctx,row){
 const expected=[{id:row.frozen.admission_operation_id,kind:'admit',request_hash:row.frozen.admission_request_hash}];
 for(const s of Object.values(row.subeffects)){if(s.dispatch)expected.push({id:s.dispatch.operation_id,kind:'dispatch',request_hash:s.dispatch.request_hash,sub:s});if(s.result_operation_id)expected.push({id:s.result_operation_id,kind:'result',sub:s});}
 if(row.stop)expected.push({id:row.stop.operation_id,kind:'stop'});
 check(new Set(expected.map(e=>e.id)).size===expected.length,409,'device_effect_operation_identity_conflict');
 for(const e of expected){
  const p=await wait(facade,tx,ctx,()=>tx.get(ctx.owner,DEVICE_EFFECT_KINDS.operations,e.id));
  check(p?.id===e.id&&p.contract===DEVICE_EFFECT_CONTRACT&&p.scope_id===ctx.scopeID&&p.subject_id===ctx.principal.subject_id&&p.run_id===ctx.run.id&&p.effect_id===row.id&&p.binding_hash===row.binding_hash&&p.kind===e.kind&&p.request?.operation_id===p.id&&p.request_hash===hash(p.request)&&(!e.request_hash||p.request_hash===e.request_hash),409,'device_effect_operation_corrupt');
  if(e.kind==='admit'){validateDeviceEffectAdmission(p.request);check(p.request.action_id===row.frozen.action_id&&p.request.action_digest===row.frozen.action_digest&&p.request.decision_operation_id===row.frozen.decision_operation_id,409,'device_effect_operation_corrupt');}
  if(e.kind==='dispatch'){validateDeviceEffectDispatch(p.request);check(p.request.subeffect===e.sub.kind&&p.request.binding_hash===row.binding_hash&&p.request.lease_id===row.frozen.lease_id,409,'device_effect_operation_corrupt');}
  if(e.kind==='result'){validateDeviceEffectResult(p.request);check(p.request.subeffect===e.sub.kind&&p.request.outcome===e.sub.state&&same(p.request.receipt,e.sub.receipt)&&p.request.binding_hash===row.binding_hash&&p.request.dispatch_operation_id===e.sub.dispatch.operation_id,409,'device_effect_receipt_binding_conflict');}
  if(e.kind==='stop'){validateDeviceEffectStop(p.request);check(p.request.binding_hash===row.binding_hash,409,'device_effect_operation_corrupt');}
 }
}
async function original(facade,tx,ctx,id){
 await wait(facade,tx,ctx,()=>tx.lock(ctx.owner,DEVICE_EFFECT_KINDS.effects,id));const row=await wait(facade,tx,ctx,()=>tx.get(ctx.owner,DEVICE_EFFECT_KINDS.effects,id));check(row,404,'not_found');validateRecord(row,ctx);ctx.effect=row;
 // Admission froze the task fence. Later reads can report changed authority, but
 // may never adopt a newer execution epoch or a newly owned task lease.
 ctx.executionRevision=row.frozen.execution_revision;ctx.taskLeaseID=row.frozen.task_lease_id;ctx.taskLeaseUntil=row.frozen.task_lease_until;
 await verifyOperations(facade,tx,ctx,row);await gate(facade,tx,ctx);return row;
}
async function prior(facade,tx,ctx,input,kind){
 operationIdentity(ctx,input.operation_id);await wait(facade,tx,ctx,()=>tx.lock(ctx.owner,DEVICE_EFFECT_KINDS.operations,input.operation_id));
 const p=await wait(facade,tx,ctx,()=>tx.get(ctx.owner,DEVICE_EFFECT_KINDS.operations,input.operation_id));
 if(p)check(p.contract===DEVICE_EFFECT_CONTRACT&&p.scope_id===ctx.scopeID&&p.subject_id===ctx.principal.subject_id&&p.run_id===ctx.run.id&&p.effect_id===ctx.effect.id&&p.binding_hash===ctx.effect.binding_hash&&p.kind===kind&&p.request_hash===hash(input)&&same(p.request,input),409,'device_effect_operation_conflict');return p;
}
async function save(facade,tx,ctx,row,input,kind){
 const sealed=sealDeviceEffectRecord(row);validateRecord(sealed,ctx);
 const changed=await wait(facade,tx,ctx,()=>tx.compareAndSwap(ctx.owner,DEVICE_EFFECT_KINDS.effects,row.id,{revision:ctx.effect.revision,record_hash:ctx.effect.record_hash},sealed));check(changed,409,'device_effect_conflict');
 check(await wait(facade,tx,ctx,()=>tx.insertIfAbsent(ctx.owner,DEVICE_EFFECT_KINDS.operations,{id:input.operation_id,contract:DEVICE_EFFECT_CONTRACT,scope_id:ctx.scopeID,subject_id:ctx.principal.subject_id,run_id:ctx.run.id,effect_id:row.id,binding_hash:row.binding_hash,kind,request:clone(input),request_hash:hash(input),committed_at:time(facade).toISOString()})),409,'device_effect_operation_conflict');
 ctx.effect=changed;await gate(facade,tx,ctx);ctx.observedAt=time(facade).toISOString();return projection(ctx,changed);
}
async function scope(facade,auth,scopeID,runID){check(deviceEffectUUID(scopeID)&&deviceEffectUUID(runID),422,'device_effect_schema_invalid');return facade.scoped(auth,scopeID);}

export async function admitDeviceEffect(facade,auth,scopeID,runID,input){
 input=validateDeviceEffectAdmission(input);const scoped=await scope(facade,auth,scopeID,runID);
 return facade.repository.transaction(async tx=>{
  // Start in read mode so an old admission can be read after expiration/revocation.
  const ctx=await resolve(facade,tx,scoped,scopeID,runID,input.action_id,'read'),a=ctx.action,f=a.frozen,id=deviceEffectID(a);
  operationIdentity(ctx,input.operation_id);await wait(facade,tx,ctx,()=>tx.lock(ctx.owner,DEVICE_EFFECT_KINDS.effects,id));
  const old=await wait(facade,tx,ctx,()=>tx.get(ctx.owner,DEVICE_EFFECT_KINDS.effects,id));
  if(old){validateRecord(old,ctx);check(old.frozen.admission_operation_id===input.operation_id&&old.frozen.admission_request_hash===hash(input),409,'device_effect_original_identity_conflict');const row=await original(facade,tx,ctx,id);ctx.observedAt=time(facade).toISOString();return projection(ctx,row);}
  check(facade.deviceEffectExecutionPolicy&&same(facade.deviceEffectExecutionPolicy,DEVICE_EFFECT_POLICY_REFERENCE),503,'device_effect_execution_not_configured');
  check(input.decision_operation_id===a.decision_operation_id&&input.expected_action_revision===a.revision&&input.action_digest===a.action_digest&&input.expected_grant_epoch===f.grant_epoch&&input.expected_plan_revision===f.plan_reference.revision&&input.expected_plan_hash===f.plan_reference.plan_hash&&input.expected_execution_revision===ctx.executionRevision&&input.device_id===f.target.device_id&&input.calendar_snapshot_hash===f.target.calendar_snapshot_hash,409,'device_effect_approval_conflict');
  ctx.mode='execute';await gate(facade,tx,ctx);const proof=await target(facade,tx,ctx),now=time(facade),frozen={id,action_id:a.id,action_digest:a.action_digest,decision_operation_id:a.decision_operation_id,scope_id:scopeID,subject_id:ctx.principal.subject_id,conversation_id:f.conversation_id,turn_id:f.turn_id,run_id:runID,task_id:f.task_id,run_request_hash:f.request_hash,delegation_id:f.delegation_id,delegation_revision:f.delegation_revision,grant_epoch:f.grant_epoch,execution_revision:ctx.executionRevision,task_lease_id:ctx.taskLeaseID,task_lease_until:ctx.taskLeaseUntil,target:clone(f.target),parameters:clone(f.parameters),device_generation:proof.device_generation,policy_reference:clone(DEVICE_EFFECT_POLICY_REFERENCE),admission_operation_id:input.operation_id,admission_request_hash:hash(input),admitted_at:now.toISOString(),approval_expires_at:f.expires_at,lease_id:deviceEffectLeaseID(id,input.operation_id),lease_expires_at:new Date(Math.min(now.getTime()+DEVICE_EFFECT_LIMITS.lease_ms,deviceEffectUTC(f.expires_at))).toISOString()};
  const subeffects=Object.fromEntries(['calendar','notification'].map(kind=>[kind,{id:deviceSubeffectID(id,kind),kind,state:kind==='notification'&&f.parameters.reminder_offset_seconds===null?'not_required':'not_dispatched',dispatch:null,receipt:null,receipt_hash:null,result_operation_id:null}]));
  const row=sealDeviceEffectRecord({id,contract:DEVICE_EFFECT_CONTRACT,frozen,binding_hash:hash(frozen),revision:1,stop:null,subeffects});ctx.effect=row;validateRecord(row,ctx);
  check(await wait(facade,tx,ctx,()=>tx.insertIfAbsent(ctx.owner,DEVICE_EFFECT_KINDS.effects,row)),409,'device_effect_conflict');
  check(await wait(facade,tx,ctx,()=>tx.insertIfAbsent(ctx.owner,DEVICE_EFFECT_KINDS.operations,{id:input.operation_id,contract:DEVICE_EFFECT_CONTRACT,scope_id:scopeID,subject_id:ctx.principal.subject_id,run_id:runID,effect_id:id,binding_hash:row.binding_hash,kind:'admit',request:clone(input),request_hash:hash(input),committed_at:now.toISOString()})),409,'device_effect_operation_conflict');
  await gate(facade,tx,ctx);ctx.observedAt=time(facade).toISOString();return projection(ctx,row);
 });
}
export async function readDeviceEffect(facade,auth,scopeID,runID,actionID,effectID){
 check(deviceEffectUUID(actionID)&&deviceEffectUUID(effectID),422,'device_effect_schema_invalid');const scoped=await scope(facade,auth,scopeID,runID);
 return facade.repository.transaction(async tx=>{const ctx=await resolve(facade,tx,scoped,scopeID,runID,actionID,'read'),row=await original(facade,tx,ctx,effectID);await gate(facade,tx,ctx);ctx.observedAt=time(facade).toISOString();return projection(ctx,row);});
}
export async function dispatchDeviceSubeffect(facade,auth,scopeID,runID,actionID,effectID,input){
 check(deviceEffectUUID(actionID)&&deviceEffectUUID(effectID),422,'device_effect_schema_invalid');
 input=validateDeviceEffectDispatch(input);const scoped=await scope(facade,auth,scopeID,runID);
 return facade.repository.transaction(async tx=>{
  const ctx=await resolve(facade,tx,scoped,scopeID,runID,actionID,'read'),row=await original(facade,tx,ctx,effectID),p=await prior(facade,tx,ctx,input,'dispatch');if(p){ctx.observedAt=time(facade).toISOString();return projection(ctx,row);}
  check(input.expected_effect_revision===row.revision&&input.binding_hash===row.binding_hash&&input.lease_id===row.frozen.lease_id,409,'device_effect_conflict');
  const s=row.subeffects[input.subeffect];check(row.stop===null&&s.state==='not_dispatched'&&s.dispatch===null,409,'device_effect_original_outcome_only');
  if(input.subeffect==='notification')check(row.subeffects.calendar.state==='succeeded',409,'device_effect_calendar_receipt_required');
  ctx.mode='execute';await gate(facade,tx,ctx);await target(facade,tx,ctx);
  const dispatch={contract:DEVICE_EFFECT_CONTRACT,effect_id:effectID,subeffect_id:s.id,kind:s.kind,operation_id:input.operation_id,request_hash:hash(input),binding_hash:row.binding_hash,lease_id:row.frozen.lease_id,dispatched_at:time(facade).toISOString()};dispatch.dispatch_hash=hash(dispatch);
  const next={...clone(row),revision:row.revision+1,subeffects:{...clone(row.subeffects),[s.kind]:{...clone(s),state:'dispatched',dispatch}}};
  const result=await save(facade,tx,ctx,next,input,'dispatch');result.dispatch_permit={...clone(dispatch),lease_expires_at:row.frozen.lease_expires_at};return result;
 });
}
export async function recordDeviceSubeffectResult(facade,auth,scopeID,runID,actionID,effectID,input){
 check(deviceEffectUUID(actionID)&&deviceEffectUUID(effectID),422,'device_effect_schema_invalid');
 input=validateDeviceEffectResult(input);const scoped=await scope(facade,auth,scopeID,runID);
 return facade.repository.transaction(async tx=>{
  // Recording a verified original observation is not an execution admission. It
  // remains possible with changed source/grant/lease; current viewer is mandatory.
  const ctx=await resolve(facade,tx,scoped,scopeID,runID,actionID,'fact'),row=await original(facade,tx,ctx,effectID),p=await prior(facade,tx,ctx,input,'result');if(p){ctx.observedAt=time(facade).toISOString();return projection(ctx,row);}
  const s=row.subeffects[input.subeffect];check(input.expected_effect_revision===row.revision&&input.binding_hash===row.binding_hash&&input.lease_id===row.frozen.lease_id&&s.dispatch?.operation_id===input.dispatch_operation_id&&['dispatched','unknown'].includes(s.state),409,'device_effect_original_outcome_only');
  if(input.receipt){
   const r=input.receipt;check(r.effect_id===row.id&&r.subeffect_id===s.id&&r.dispatch_operation_id===s.dispatch.operation_id&&r.action_digest===row.frozen.action_digest&&r.binding_hash===row.binding_hash&&r.device_id===row.frozen.target.device_id&&r.device_generation===row.frozen.device_generation&&deviceEffectUTC(r.observed_at)>=deviceEffectUTC(s.dispatch.dispatched_at)&&deviceEffectUTC(r.observed_at)<=time(facade).getTime(),409,'device_effect_receipt_binding_conflict');
   if(r.outcome==='succeeded'&&s.kind==='calendar')check(r.external_reference.calendar_id===row.frozen.target.calendar_id&&r.external_reference.effect_marker===`catpawm://calendar-effect/${s.id}`,409,'device_effect_receipt_binding_conflict');
   if(r.outcome==='succeeded'&&s.kind==='notification'){const due=new Date(deviceEffectUTC(row.frozen.parameters.start_at)+row.frozen.parameters.reminder_offset_seconds*1000).toISOString();check(r.external_reference.request_identifier===s.id&&r.external_reference.due_at===due&&r.external_reference.schedule_hash===hash({subeffect_id:s.id,due_at:due,parameters_hash:ctx.action.frozen.parameters_hash,channel:'catpaw_local_notification'}),409,'device_effect_receipt_binding_conflict');}
   await target(facade,tx,ctx);check(typeof facade.deviceEffectReceiptVerifier==='function',503,'device_effect_receipt_verifier_not_configured');
   const proof=await wait(facade,tx,ctx,()=>facade.deviceEffectReceiptVerifier(tx,clone({...ctx,receipt:r,purpose:'verify_original_observation'})));check(proof?.verified===true&&proof.receipt_hash===hash(r)&&proof.subject_id===ctx.principal.subject_id&&proof.scope_id===ctx.scopeID&&proof.effect_id===row.id&&proof.subeffect_id===s.id,403,'device_effect_receipt_not_verified');
  }
  const next={...clone(row),revision:row.revision+1,subeffects:{...clone(row.subeffects),[s.kind]:{...clone(s),state:input.outcome,receipt:clone(input.receipt),receipt_hash:input.receipt===null?null:hash(input.receipt),result_operation_id:input.operation_id}}};return save(facade,tx,ctx,next,input,'result');
 });
}
export async function stopDeviceEffect(facade,auth,scopeID,runID,actionID,effectID,input){
 check(deviceEffectUUID(actionID)&&deviceEffectUUID(effectID),422,'device_effect_schema_invalid');
 input=validateDeviceEffectStop(input);const scoped=await scope(facade,auth,scopeID,runID);
 return facade.repository.transaction(async tx=>{
  const ctx=await resolve(facade,tx,scoped,scopeID,runID,actionID,'fact'),row=await original(facade,tx,ctx,effectID),p=await prior(facade,tx,ctx,input,'stop');if(p){ctx.observedAt=time(facade).toISOString();return projection(ctx,row);}
  check(row.stop===null&&deviceEffectState(row)!=='succeeded'&&input.expected_effect_revision===row.revision&&input.binding_hash===row.binding_hash,409,'device_effect_conflict');
  const subeffects=clone(row.subeffects);for(const s of Object.values(subeffects)){if(s.state==='not_dispatched')s.state='cancelled_before_dispatch';if(s.state==='dispatched')s.state='unknown';}
  return save(facade,tx,ctx,{...clone(row),revision:row.revision+1,stop:{operation_id:input.operation_id,reason:'user_stopped',stopped_at:time(facade).toISOString()},subeffects},input,'stop');
 });
}
