import {check,shape,hash,clone} from '../facade-r2/src/common.mjs';
import {TASK_WORK_GRANT_CONTRACT,TASK_WORK_ATTEMPT_ACK_CONTRACT,TASK_WORK_GRANT_KINDS as K,TASK_WORK_GRANT_LIMITS as L,validateWorkGrantTerms,validateWorkGrantRunBinding,validateWorkGrantIdentity,validateWorkGrantReservation,validateWorkGrantOutcome,validateWorkGrantExecution,validateWorkGrantDispatch,validateWorkGrantAttemptSettlement,validateWorkGrantCompletionReceipt,workGrantOperationID,workGrantInstant,workGrantReference,workGrantReceiptHash} from './task-work-grant-contract.mjs';
import {taskControlRevision} from './task-control-contract.mjs';
import {completionAuthorityValid,evaluateReport} from './report-completion.mjs';
import {completionPlanCheck,effectiveTaskRequest} from './task-plan-service.mjs';
import {validateFrozenSourceCatalog,sourceReadIdentity} from './public-source-contract.mjs';
import {lockTaskWorkSourceInTransaction} from './task-work-grant-lifecycle.mjs';

const iso=ms=>new Date(ms).toISOString();
const same=(a,b)=>a!==undefined&&b!==undefined&&hash(a)===hash(b);

/** Trusted server composition only. No JWT, session renewal, scheduler, network or
 * authority defaults. The mandatory port must enforce fresh admission/viewer auth
 * and current source/consent/lease fences for execution in this same transaction. */
export class TaskWorkGrantService{
 constructor({repository,authorize,sourceService=null,now=Date.now}){Object.assign(this,{repository,authorize,sourceService,now});}
 permission(signal,assertLive=()=>{}){check(typeof assertLive==='function',422,'work_grant_schema_invalid');const started=this.now();check(Number.isSafeInteger(started),409,'work_grant_write_deadline');let lastClock=started;return()=>{assertLive();const now=this.now();check(!signal?.aborted,409,'work_grant_cancelled');check(Number.isSafeInteger(now)&&now>=lastClock&&now-started<L.write_budget_ms,409,'work_grant_write_deadline');lastClock=now;};}
 async authority(tx,ctx,phase,live){
  live();check(typeof this.authorize==='function',503,'work_grant_authority_not_configured');
  const result=await this.authorize(tx,{...ctx,phase});live();check(result?.authorized===true,403,'work_grant_authority_denied');
 }
 async resolve(tx,identity,terms,live){
  live();await tx.withScope(identity.scope_id,async scoped=>{const row=await scoped.scope();live();check(same(row.identity,terms.scope),403,'work_grant_scope_conflict');});live();
  check(identity.owner===terms.scope.owner&&identity.subject_id===terms.subject_id&&identity.grant_id===terms.grant_id&&identity.scope_id===terms.scope.scope_id,403,'work_grant_scope_conflict');
  await lockTaskWorkSourceInTransaction(tx,{scope_id:identity.scope_id,owner:identity.owner,source:terms.source_auth});live();
  await tx.lock(identity.owner,K.grants,identity.grant_id);live();
  const run=await tx.get(identity.owner,'catpaw-runs',terms.origin.run_id);live();const runBinding=validateWorkGrantRunBinding(terms,run);
  const op=await tx.get(identity.owner,'catpaw-operations',run.operation_id);live();check(op?.run_id===run.id&&op.request_hash===run.request_hash,409,'work_grant_run_binding_conflict');
  const task=await tx.get(identity.owner,'tasks',run.task_id);live();check(task?.id===run.task_id&&same(task.state?.catpaw,{operation_id:run.operation_id,run_id:run.id,delegation_id:run.delegation_id,request_hash:run.request_hash,grant_epoch:run.grant_epoch,delegation_revision:run.delegation_revision}),409,'work_grant_task_binding_conflict');
  const delegation=await tx.get(identity.owner,'catpaw-delegations',run.delegation_id);live();const conversation=await tx.get(identity.owner,'native-chat-conversations',terms.conversation_id);live();
  check(delegation?.subject_id===terms.subject_id&&delegation.conversation_id===terms.conversation_id&&conversation?.subject_id===terms.subject_id&&conversation.scope_id===identity.scope_id,409,'work_grant_run_binding_conflict');
  return {identity,owner:identity.owner,terms,run,task,delegation,conversation,run_binding:runBinding};
 }
 async current(tx,identity,live){
  const row=await tx.get(identity.owner,K.terms,identity.grant_id);live();check(row,404,'work_grant_not_found');
  let terms;try{terms=validateWorkGrantTerms(row.terms);shape(row,['id','scope_id','subject_id','conversation_id','run_id','task_id','terms','terms_hash','run_binding','receipt']);}catch{check(false,409,'work_grant_record_corrupt');}
  const ctx=await this.resolve(tx,identity,terms,live),state=await tx.get(identity.owner,K.grants,identity.grant_id);live();
  check(row.id===terms.grant_id&&row.terms_hash===hash(terms)&&row.scope_id===identity.scope_id&&row.subject_id===identity.subject_id&&row.conversation_id===terms.conversation_id&&row.run_id===ctx.run.id&&row.task_id===ctx.task.id&&same(row.run_binding,ctx.run_binding),409,'work_grant_record_corrupt');
  const r=row.receipt;try{shape(r,['contract','grant_id','terms_hash','run_binding','accepted_at','task_completed','receipt_hash']);shape(state,['id','scope_id','subject_id','conversation_id','run_id','task_id','reference','run_binding','state','revision','consumed']);shape(state.consumed,['due','model','source']);}catch{check(false,409,'work_grant_record_corrupt');}
  check(r?.contract===TASK_WORK_GRANT_CONTRACT&&r.grant_id===row.id&&r.terms_hash===row.terms_hash&&same(r.run_binding,ctx.run_binding)&&r.accepted_at===terms.accepted_at&&r.task_completed===false&&workGrantReceiptHash(r)===r.receipt_hash,409,'work_grant_record_corrupt');
  check(state?.id===row.id&&same(state.reference,workGrantReference(terms))&&same(state.run_binding,ctx.run_binding)&&Number.isSafeInteger(state.revision)&&state.revision>0&&['active','paused','revoked'].includes(state.state)&&state.scope_id===identity.scope_id&&state.subject_id===identity.subject_id&&state.conversation_id===terms.conversation_id&&state.run_id===ctx.run.id&&state.task_id===ctx.task.id,409,'work_grant_record_corrupt');
  check(['due','model','source'].every(k=>Number.isSafeInteger(state.consumed?.[k])&&state.consumed[k]>=0&&state.consumed[k]<=terms.limits[k]),409,'work_grant_record_corrupt');
  const current={...ctx,row,state};current.reservations=await this.inventory(tx,current,live);return current;
 }
 async inventory(tx,ctx,live){
  const rows=(await tx.list(ctx.owner,K.reservations)).filter(r=>r.grant_id===ctx.terms.grant_id||r.run_id===ctx.run.id);live();
  check(rows.length<=L.due+L.model+L.source,409,'work_grant_record_corrupt');const counts={due:0,model:0,source:0},keys=new Set();
  for(const row of rows){
   let input;try{shape(row,['id','grant_id','terms_hash','scope_id','subject_id','conversation_id','run_id','task_id','run_binding','frozen','reservation_hash','reserved_at','state','outcome']);shape(row.frozen,['grant_reference','run_binding','execution','input']);input=validateWorkGrantReservation(row.frozen.input);if(input.kind!=='due')validateWorkGrantExecution(row.frozen.execution);}catch{check(false,409,'work_grant_record_corrupt');}
   check(row.id===input.operation_id&&row.grant_id===ctx.terms.grant_id&&row.terms_hash===ctx.row.terms_hash&&row.scope_id===ctx.identity.scope_id&&row.subject_id===ctx.identity.subject_id&&row.conversation_id===ctx.terms.conversation_id&&row.run_id===ctx.run.id&&row.task_id===ctx.task.id&&same(row.run_binding,ctx.run_binding)&&same(row.frozen.run_binding,ctx.run_binding)&&same(row.frozen.grant_reference,workGrantReference(ctx.terms))&&hash(row.frozen)===row.reservation_hash&&workGrantInstant(row.reserved_at)&&Date.parse(row.reserved_at)>=Date.parse(ctx.terms.accepted_at)&&Date.parse(input.deadline_at)>Date.parse(row.reserved_at)&&Date.parse(input.deadline_at)<=Date.parse(ctx.terms.not_after)&&Date.parse(input.deadline_at)-Date.parse(row.reserved_at)<=(input.kind==='due'?ctx.terms.execution_budget_ms:L.result_budget_ms)&&['reserved','received','unknown'].includes(row.state),409,'work_grant_record_corrupt');
   if(row.state==='reserved')check(row.outcome===null,409,'work_grant_record_corrupt');
   else{
    let outcome;try{shape(row.outcome,input.kind==='due'?['input','recorded_at','checkpoint_hash','acknowledgement']:['input','recorded_at','checkpoint_hash','transport_checkpoint']);outcome=validateWorkGrantOutcome(row.outcome.input);if(input.kind!=='due')shape(row.outcome.transport_checkpoint,['kind','request_hash','checkpoint_hash','payload_hash']);}catch{check(false,409,'work_grant_record_corrupt');}
    const fields={reservation_hash:row.reservation_hash,input:outcome,recorded_at:row.outcome.recorded_at,...input.kind==='due'?{acknowledgement:row.outcome.acknowledgement}:{transport_checkpoint:row.outcome.transport_checkpoint}};
    check(outcome.operation_id===row.id&&outcome.request_hash===input.request_hash&&outcome.outcome===row.state&&workGrantInstant(row.outcome.recorded_at)&&Date.parse(row.outcome.recorded_at)>=Date.parse(row.reserved_at)&&Date.parse(row.outcome.recorded_at)<Date.parse(input.deadline_at)&&row.outcome.checkpoint_hash===hash(fields),409,'work_grant_record_corrupt');
    if(input.kind==='due')await this.validateStoredAcknowledgement(tx,ctx,row,live);
    else{const point=row.outcome.transport_checkpoint;check((point.kind===input.kind||input.kind==='source'&&row.state==='received'&&point.kind==='source_failure')&&point.request_hash===input.request_hash&&/^[a-f0-9]{64}$/.test(point.checkpoint_hash)&&(row.state==='unknown'?point.payload_hash===null:/^[a-f0-9]{64}$/.test(point.payload_hash)&&outcome.receipt_reference.receipt_id===row.id&&(input.kind==='model'?outcome.receipt_reference.receipt_hash===point.checkpoint_hash:outcome.receipt_reference.receipt_hash===point.payload_hash)),409,'work_grant_record_corrupt');}
   }
   const key=input.kind+':'+input.operation_key;check(!keys.has(key),409,'work_grant_record_corrupt');keys.add(key);counts[input.kind]++;
   if(input.kind==='due')check(row.frozen.execution===null&&input.operation_id===ctx.run.operation_id&&input.request_hash===ctx.run.request_hash&&input.operation_key===hash({accepted_run:ctx.run.id}),409,'work_grant_record_corrupt');
   else check(row.frozen.execution.run_id===ctx.run.id&&row.frozen.execution.task_id===ctx.task.id&&row.frozen.execution.run_request_hash===ctx.run.request_hash,409,'work_grant_record_corrupt');
  }
  check(same(counts,ctx.state.consumed)&&['due','model','source'].every(k=>counts[k]<=ctx.terms.limits[k]),409,'work_grant_record_corrupt');
  const due=rows.find(r=>r.frozen.input.kind==='due');for(const row of rows)if(row.frozen.input.kind!=='due')check(due&&Date.parse(row.frozen.input.deadline_at)<=Date.parse(due.frozen.input.deadline_at),409,'work_grant_record_corrupt');
  return rows;
 }
 async grantCurrent(tx,ctx,live){
  const now=this.now();check(ctx.state.state==='active',409,'work_grant_not_active');check(Number.isSafeInteger(now)&&now>=Date.parse(ctx.terms.accepted_at)&&now<Date.parse(ctx.terms.not_after),409,'work_grant_expired');
  await tx.withScope(ctx.identity.scope_id,async scoped=>{const row=await scoped.scope();live();check(row.enabled&&row.generation===ctx.terms.memory_generation,409,'work_grant_generation_conflict');});live();
  check(ctx.delegation.state==='active'&&ctx.delegation.grant_epoch===ctx.run.grant_epoch&&ctx.delegation.revision===ctx.run.delegation_revision&&ctx.conversation.state==='active'&&ctx.conversation.grant_epoch===ctx.run.frozen_request.conversation_epoch,409,'work_grant_not_active');
  const finalClock=this.now();check(Number.isSafeInteger(finalClock)&&finalClock>=Date.parse(ctx.terms.accepted_at)&&finalClock<Date.parse(ctx.terms.not_after),409,'work_grant_expired');live();
 }
 async execution(tx,ctx,live){await this.grantCurrent(tx,ctx,live);check(!['paused','cancelled','failed','succeeded','outcome_unknown'].includes(ctx.task.status),409,'work_grant_not_active');}
 /** Current grant/source facts only. Safe at the store's final terminal recheck;
  * this neither authorizes a dispatch nor verifies/completes a terminal Task. */
 async assertAcceptedGrantCurrentInTransaction(tx,identity,{signal,assertLive}={}){
  identity=validateWorkGrantIdentity(identity);const live=this.permission(signal,assertLive),ctx=await this.current(tx,identity,live);
  await this.grantCurrent(tx,ctx,live);await this.authority(tx,ctx,'accepted_work',live);check(this.now()<Date.parse(ctx.terms.not_after),409,'work_grant_expired');live();
  return {reference:workGrantReference(ctx.terms),run_binding:clone(ctx.run_binding),not_after:ctx.terms.not_after};
 }
 executor(ctx,input,live){
  let execution;try{execution=validateWorkGrantExecution(input);}catch{check(false,409,'work_grant_execution_conflict');}
  check(execution.run_id===ctx.run.id&&execution.task_id===ctx.task.id&&execution.run_request_hash===ctx.run.request_hash&&ctx.task.status==='running'&&ctx.task.leaseId===execution.lease_id&&Date.parse(ctx.task.leaseUntil)>this.now()&&taskControlRevision(ctx.task)===execution.execution_revision,409,'work_grant_execution_conflict');live();return execution;
 }
 async runningAttempt(tx,ctx,execution,live){
  const attempt=await tx.get(ctx.owner,'runs',execution.lease_id);live();const link=await tx.get(ctx.owner,'catpaw-run-links',execution.lease_id);live();const whole=Boolean(attempt?.execution),bounded=Boolean(attempt?.slice),proof=whole?attempt.execution:attempt?.slice;
  check(whole!==bounded&&attempt?.id===execution.lease_id&&attempt.taskId===ctx.task.id&&attempt.status==='running'&&proof?.acknowledged===false&&proof.authority_hash===hash(ctx.task.state.catpaw)&&(whole?proof.revision:proof.execution_revision)===execution.execution_revision&&link?.id===execution.lease_id&&link.run_id===ctx.run.id&&link.task_id===ctx.task.id&&link.operation_id===ctx.run.operation_id&&link.grant_epoch===ctx.run.grant_epoch,409,'work_grant_attempt_conflict');
 }
 async dispatchedCheckpoint(tx,ctx,reservation,point,live,expectedState='dispatched'){
  const input=reservation.frozen.input;check(point.kind===input.kind&&point.request_hash===input.request_hash,409,'work_grant_dispatch_checkpoint_conflict');
  if(input.kind==='model'){const round=ctx.task.state.local_model?.round;check(round?.state==='dispatched'&&round.request_hash===input.request_hash&&hash(round)===point.checkpoint_hash,409,'work_grant_dispatch_checkpoint_conflict');return;}
  const catalog=validateFrozenSourceCatalog(ctx.run.frozen_request.public_sources);await effectiveTaskRequest(tx,ctx.owner,ctx.run,ctx.task);live();
  const read=await tx.get(ctx.owner,'catpaw-task-source-reads',point.read_id);live();const source=catalog.sources.find(s=>s.source_id===read?.source_id),plan=ctx.task.state.plan_binding;
  check(['dispatched','unknown'].includes(expectedState)&&source&&read?.id===input.operation_id&&sourceReadIdentity(ctx.run.id,plan,source.source_id)===read.id&&read.run_id===ctx.run.id&&read.task_id===ctx.task.id&&read.conversation_id===ctx.terms.conversation_id&&read.requested_url===source.requested_url&&same(read.plan_reference,plan)&&read.policy_hash===catalog.policy_hash&&read.request_hash===hash({run_id:ctx.run.id,task_id:ctx.task.id,run_request_hash:ctx.run.request_hash,source,plan_reference:plan,policy_hash:catalog.policy_hash})&&read.request_hash===input.request_hash&&read.state===expectedState&&read.dispatch_lease_id===reservation.frozen.execution.lease_id&&hash(read)===point.checkpoint_hash,409,'work_grant_dispatch_checkpoint_conflict');
 }
 /** A final fact guard for the original, newly reserved call stack. Returns no
  * permit and performs no send; reserve replay remains may_dispatch:false. */
 async assertNewDispatchInTransaction(tx,identity,input,{signal,assertLive}={}){
  identity=validateWorkGrantIdentity(identity);input=validateWorkGrantDispatch(input);const live=this.permission(signal,assertLive),ctx=await this.current(tx,identity,live),reservation=ctx.reservations.find(r=>r.id===input.original_reservation.id),due=ctx.reservations.find(r=>r.frozen.input.kind==='due');
  check(reservation?.state==='reserved'&&reservation.frozen.input.kind!=='due'&&same(reservation,input.original_reservation)&&due?.state==='reserved'&&!ctx.reservations.some(r=>r.state==='unknown'),409,'work_grant_original_operation_required');
  const execution=this.executor(ctx,input.execution,live);check(same(execution,reservation.frozen.execution),409,'work_grant_execution_conflict');await this.runningAttempt(tx,ctx,execution,live);await this.dispatchedCheckpoint(tx,ctx,reservation,input.durable_checkpoint,live);await this.execution(tx,ctx,live);await this.authority(tx,{...ctx,reservation,execution},'transport',live);
  const final=await this.current(tx,identity,live);this.executor(final,execution,live);await this.runningAttempt(tx,final,execution,live);await this.dispatchedCheckpoint(tx,final,reservation,input.durable_checkpoint,live);await this.execution(tx,final,live);await this.authority(tx,{...final,reservation,execution},'transport',live);check(this.now()<Date.parse(reservation.frozen.input.deadline_at),409,'work_grant_result_deadline');live();
 }
 projection(ctx){return {reference:workGrantReference(ctx.terms),terms:clone(ctx.terms),run_binding:clone(ctx.run_binding),state:ctx.state.state,revision:ctx.state.revision,consumed:clone(ctx.state.consumed),remaining:Object.fromEntries(['due','model','source'].map(k=>[k,ctx.terms.limits[k]-ctx.state.consumed[k]])),expired:this.now()>=Date.parse(ctx.terms.not_after),task_completed:false};}
 async admit({identity,principal,terms},{signal}={}){return this.repository.transaction(tx=>this.admitInTransaction(tx,{identity,principal,terms},{signal}));}
 async admitInTransaction(tx,{identity,principal,terms},{signal}={}){
  identity=validateWorkGrantIdentity(identity);terms=validateWorkGrantTerms(terms);check(principal?.subject_id===terms.subject_id&&principal.session_id===terms.source_auth.session_id&&principal.issuer===terms.source_auth.issuer&&principal.issued_at===terms.source_auth.issued_at,403,'work_grant_admission_principal_conflict');const live=this.permission(signal),ctx=await this.resolve(tx,identity,terms,live);ctx.principal=principal;
  await this.authority(tx,ctx,'admission',live);const prior=await tx.get(identity.owner,K.terms,identity.grant_id);live();
  if(prior){const current=await this.current(tx,identity,live);check(same(current.terms,terms),409,'work_grant_admission_conflict');await this.authority(tx,{...current,principal},'admission',live);return {created:false,grant:this.projection(current),receipt:clone(current.row.receipt)};}
  check(this.now()>=Date.parse(terms.accepted_at)&&this.now()-Date.parse(terms.accepted_at)<L.write_budget_ms&&ctx.run.created_at===terms.accepted_at&&ctx.task.createdAt===terms.accepted_at&&ctx.delegation.created_at===terms.accepted_at&&ctx.task.status==='queued'&&ctx.task.attempts===0&&ctx.task.leaseId===null&&ctx.task.leaseUntil===null&&!ctx.task.state.local_model,409,'work_grant_late_admission');
  const reference=workGrantReference(terms),metadata={scope_id:identity.scope_id,subject_id:identity.subject_id,conversation_id:terms.conversation_id,run_id:ctx.run.id,task_id:ctx.task.id};
  const fields={contract:TASK_WORK_GRANT_CONTRACT,grant_id:terms.grant_id,terms_hash:reference.terms_hash,run_binding:ctx.run_binding,accepted_at:terms.accepted_at,task_completed:false},receipt={...fields,receipt_hash:workGrantReceiptHash(fields)};
  const state={id:terms.grant_id,...metadata,reference,run_binding:ctx.run_binding,state:'active',revision:1,consumed:{due:0,model:0,source:0}};
  await this.execution(tx,{...ctx,state},live);check(await tx.insertIfAbsent(identity.owner,K.terms,{id:terms.grant_id,...metadata,terms,terms_hash:reference.terms_hash,run_binding:ctx.run_binding,receipt}),409,'work_grant_admission_conflict');live();
  check(await tx.insertIfAbsent(identity.owner,K.grants,state),409,'work_grant_admission_conflict');live();const final=await this.current(tx,identity,live);await this.execution(tx,final,live);await this.authority(tx,{...final,principal},'admission',live);check(this.now()<Date.parse(terms.not_after),409,'work_grant_expired');live();
  return {created:true,grant:this.projection(final),receipt};
 }
 async read(identity,{principal,signal}={}){
  identity=validateWorkGrantIdentity(identity);check(principal?.subject_id===identity.subject_id,403,'work_grant_viewer_conflict');const live=this.permission(signal);
  return this.repository.transaction(async tx=>{const ctx=await this.current(tx,identity,live);await this.authority(tx,{...ctx,principal},'read',live);live();return {grant:this.projection(ctx),receipt:clone(ctx.row.receipt),reservations:clone(ctx.reservations)};});
 }
 async reserve(identity,input,{signal,execution}={}){return this.repository.transaction(tx=>this.reserveInTransaction(tx,identity,input,{signal,execution}));}
 async reserveInTransaction(tx,identity,input,{signal,execution}={}){
  identity=validateWorkGrantIdentity(identity);input=validateWorkGrantReservation(input);const live=this.permission(signal),ctx=await this.current(tx,identity,live);
  const prior=await tx.get(identity.owner,K.reservations,input.operation_id);live();
  if(prior){check(ctx.reservations.some(r=>r.id===prior.id)&&same(prior.frozen.input,input),409,'work_grant_operation_conflict');await this.authority(tx,{...ctx,reservation:prior},'recovery',live);return {created:false,may_dispatch:false,reservation:clone(prior)};}
  check(!ctx.reservations.some(r=>r.frozen.input.kind===input.kind&&r.frozen.input.operation_key===input.operation_key),409,'work_grant_operation_key_conflict');
  execution=input.kind==='due'?null:this.executor(ctx,execution,live);if(execution)await this.runningAttempt(tx,ctx,execution,live);await this.authority(tx,{...ctx,input,execution},'dispatch',live);await this.execution(tx,ctx,live);
  const now=this.now(),due=ctx.reservations.find(r=>r.frozen.input.kind==='due');
  if(input.kind==='due')check(input.operation_id===ctx.run.operation_id&&input.request_hash===ctx.run.request_hash&&input.operation_key===hash({accepted_run:ctx.run.id}),409,'work_grant_due_binding_conflict');
  else check(due,409,'work_grant_due_required');
  check(!ctx.reservations.some(r=>r.state==='unknown'),409,'work_grant_original_outcome_unknown');
  check(!ctx.reservations.some(r=>r.frozen.input.kind!=='due'&&r.state==='reserved'),409,'work_grant_original_outcome_pending');
  if(input.kind!=='due')check(due.state==='reserved',409,'work_grant_due_closed');
  check(ctx.state.consumed[input.kind]<ctx.terms.limits[input.kind],409,'work_grant_budget_exhausted');
  check(Date.parse(input.deadline_at)>now&&Date.parse(input.deadline_at)<=Math.min(Date.parse(ctx.terms.not_after),input.kind==='due'?now+ctx.terms.execution_budget_ms:Math.min(now+L.result_budget_ms,Date.parse(due.frozen.input.deadline_at))),409,'work_grant_result_deadline');
  const frozen={grant_reference:workGrantReference(ctx.terms),run_binding:ctx.run_binding,execution,input},row={id:input.operation_id,grant_id:identity.grant_id,terms_hash:ctx.row.terms_hash,scope_id:identity.scope_id,subject_id:identity.subject_id,conversation_id:ctx.terms.conversation_id,run_id:ctx.run.id,task_id:ctx.task.id,run_binding:ctx.run_binding,frozen,reservation_hash:hash(frozen),reserved_at:iso(now),state:'reserved',outcome:null};
  check(await tx.insertIfAbsent(identity.owner,K.reservations,row),409,'work_grant_operation_conflict');live();
  const next={...ctx.state,revision:ctx.state.revision+1,consumed:{...ctx.state.consumed,[input.kind]:ctx.state.consumed[input.kind]+1}};check(Number.isSafeInteger(next.revision),409,'work_grant_record_corrupt');await tx.put(identity.owner,K.grants,next);live();
  const final=await this.current(tx,identity,live);await this.execution(tx,final,live);await this.authority(tx,{...final,input,reservation:row,execution},'dispatch',live);if(execution){this.executor(final,execution,live);await this.runningAttempt(tx,final,execution,live);}check(this.now()<Date.parse(input.deadline_at),409,'work_grant_result_deadline');live();
  return {created:true,may_dispatch:true,reservation:clone(row)};
 }
 async settle(identity,input,options={}){return this.repository.transaction(tx=>this.settleTransportOutcomeInTransaction(tx,identity,input,options));}
 async settleInTransaction(tx,identity,input,options={}){return this.settleTransportOutcomeInTransaction(tx,identity,input,options);}
 async transportEvidence(tx,ctx,prior,input,execution,live){
  if(prior.frozen.input.kind==='model'){
   const round=ctx.task.state.local_model?.round;check(round&&round.request_hash===prior.frozen.input.request_hash&&(input.outcome==='received'?round.state==='received':['dispatched','unknown'].includes(round.state)),409,'work_grant_transport_checkpoint_required');
   if(input.outcome==='received'){
    check(typeof round.text==='string'&&Array.isArray(round.calls)&&Number.isSafeInteger(round.next)&&round.next===0&&Array.isArray(round.results)&&round.results.length===0&&same(input.receipt_reference,{receipt_id:prior.id,receipt_hash:hash(round)}),409,'work_grant_transport_receipt_conflict');
   }return {kind:'model',request_hash:round.request_hash,checkpoint_hash:hash(round),payload_hash:input.outcome==='received'?hash({request_hash:round.request_hash,text:round.text,calls:round.calls}):null};
  }
  const read=await tx.get(ctx.owner,'catpaw-task-source-reads',prior.id);live();check(read?.request_hash===prior.frozen.input.request_hash&&read.run_id===ctx.run.id&&read.task_id===ctx.task.id&&read.dispatch_lease_id===execution.lease_id&&(input.outcome==='received'?read.state==='received':['dispatched','unknown'].includes(read.state)),409,'work_grant_transport_checkpoint_required');
  if(input.outcome==='unknown'){await this.dispatchedCheckpoint(tx,ctx,prior,{kind:'source',read_id:read.id,request_hash:read.request_hash,checkpoint_hash:hash(read)},live,read.state);return {kind:'source',request_hash:read.request_hash,checkpoint_hash:hash(read),payload_hash:null};}
  check(typeof this.sourceService?.validateWorkGrantTransportReceiptInTransaction==='function',503,'work_grant_source_receipt_verifier_required');
  const verified=await this.sourceService.validateWorkGrantTransportReceiptInTransaction(tx,ctx.owner,ctx.run,ctx.task,{read_id:prior.id,request_hash:prior.frozen.input.request_hash,lease_id:execution.lease_id});live();check(verified?.receipt_id===prior.id&&same(verified,input.receipt_reference),409,'work_grant_transport_receipt_conflict');return {kind:'source',request_hash:read.request_hash,checkpoint_hash:hash(read),payload_hash:verified.receipt_hash};
 }
 /** Only a persisted original model result or the mandatory single-source
  * verifier may admit transport receipt identity. A supplied self-hash cannot. */
 async settleTransportOutcomeInTransaction(tx,identity,input,{signal,execution,assertLive}={}){
  identity=validateWorkGrantIdentity(identity);input=validateWorkGrantOutcome(input);const live=this.permission(signal,assertLive),ctx=await this.current(tx,identity,live),prior=ctx.reservations.find(r=>r.id===input.operation_id);
  check(prior&&prior.frozen.input.request_hash===input.request_hash,409,'work_grant_original_operation_required');check(prior.frozen.input.kind!=='due',409,'work_grant_due_acknowledgement_required');
  if(prior.state!=='reserved'){check(same(prior.outcome?.input,input),409,'work_grant_outcome_conflict');await this.authority(tx,{...ctx,reservation:prior},'recovery',live);return {created:false,reservation:clone(prior)};}
  execution=this.executor(ctx,execution,live);check(same(execution,prior.frozen.execution),409,'work_grant_execution_conflict');await this.runningAttempt(tx,ctx,execution,live);const checkpoint=await this.transportEvidence(tx,ctx,prior,input,execution,live);
  return this.#recordTransportOutcomeInTransaction(tx,identity,input,{ctx,prior,execution,checkpoint,live});
 }
 async sourceFailureEvidence(tx,ctx,prior,execution,live){
  const read=await tx.get(ctx.owner,'catpaw-task-source-reads',prior.id);live();check(read?.state==='failed'&&read.request_hash===prior.frozen.input.request_hash&&read.dispatch_lease_id===execution.lease_id,409,'work_grant_transport_checkpoint_required');
  check(typeof this.sourceService?.validateWorkGrantTransportFailureInTransaction==='function',503,'work_grant_source_failure_verifier_required');const receipt=await this.sourceService.validateWorkGrantTransportFailureInTransaction(tx,ctx.owner,ctx.run,ctx.task,{read_id:prior.id,request_hash:prior.frozen.input.request_hash,lease_id:execution.lease_id});live();check(receipt?.receipt_id===prior.id&&/^[a-f0-9]{64}$/.test(receipt.receipt_hash),409,'work_grant_transport_receipt_conflict');
  return {input:{operation_id:prior.id,request_hash:prior.frozen.input.request_hash,outcome:'received',receipt_reference:receipt},checkpoint:{kind:'source_failure',request_hash:read.request_hash,checkpoint_hash:hash(read),payload_hash:receipt.receipt_hash}};
 }
 /** A received, known read failure consumes the original operation. Its typed
  * failed fact is distinct from source bytes and can never continue a report. */
 async settleSourceFailureInTransaction(tx,identity,operationID,{signal,execution,assertLive}={}){
  identity=validateWorkGrantIdentity(identity);check(workGrantOperationID(operationID),422,'work_grant_schema_invalid');const live=this.permission(signal,assertLive),ctx=await this.current(tx,identity,live),prior=ctx.reservations.find(r=>r.id===operationID);check(prior?.frozen.input.kind==='source',409,'work_grant_original_operation_required');
  if(prior.state!=='reserved'){check(prior.state==='received'&&prior.outcome.transport_checkpoint.kind==='source_failure',409,'work_grant_outcome_conflict');await this.authority(tx,{...ctx,reservation:prior},'recovery',live);return {created:false,reservation:clone(prior)};}
  execution=this.executor(ctx,execution,live);check(same(execution,prior.frozen.execution),409,'work_grant_execution_conflict');await this.runningAttempt(tx,ctx,execution,live);const proof=await this.sourceFailureEvidence(tx,ctx,prior,execution,live);return this.#recordTransportOutcomeInTransaction(tx,identity,proof.input,{ctx,prior,execution,checkpoint:proof.checkpoint,live});
 }
 async #recordTransportOutcomeInTransaction(tx,identity,input,{ctx,prior,execution,checkpoint,live}){
  await this.authority(tx,{...ctx,reservation:prior,outcome:input,execution},'settlement',live);await this.execution(tx,ctx,live);check(this.now()<Date.parse(prior.frozen.input.deadline_at),409,'work_grant_result_deadline');
  const recordedAt=iso(this.now()),fields={reservation_hash:prior.reservation_hash,input,recorded_at:recordedAt,transport_checkpoint:checkpoint},outcome={input,recorded_at:recordedAt,checkpoint_hash:hash(fields),transport_checkpoint:checkpoint},next={...prior,state:input.outcome,outcome};
  check(await tx.compareAndSwap(identity.owner,K.reservations,prior.id,{state:'reserved',reservation_hash:prior.reservation_hash},{state:input.outcome,outcome}),409,'work_grant_outcome_conflict');live();
  const final=await this.current(tx,identity,live);await this.execution(tx,final,live);await this.authority(tx,{...final,reservation:next,outcome:input,execution},'settlement',live);this.executor(final,execution,live);await this.runningAttempt(tx,final,execution,live);const verified=checkpoint.kind==='source_failure'?(await this.sourceFailureEvidence(tx,final,prior,execution,live)).checkpoint:await this.transportEvidence(tx,final,prior,input,execution,live);check(same(checkpoint,verified),409,'work_grant_transport_receipt_conflict');check(this.now()<Date.parse(prior.frozen.input.deadline_at),409,'work_grant_result_deadline');live();return {created:true,reservation:clone(next)};
 }
 async attemptEvidence(tx,ctx,attemptID,live){
  const attempt=await tx.get(ctx.owner,'runs',attemptID);live();const link=await tx.get(ctx.owner,'catpaw-run-links',attemptID);live();
  const whole=Boolean(attempt?.execution),bounded=Boolean(attempt?.slice);check(whole!==bounded&&attempt.id===attemptID&&attempt.taskId===ctx.task.id&&link?.id===attemptID&&link.run_id===ctx.run.id&&link.operation_id===ctx.run.operation_id&&link.task_id===ctx.task.id&&link.grant_epoch===ctx.run.grant_epoch,409,'work_grant_attempt_conflict');
  const proof=whole?attempt.execution:attempt.slice;check(proof.acknowledged===true&&proof.authority_hash===hash(ctx.task.state.catpaw),409,'work_grant_attempt_conflict');
  return {attempt,link,proof,execution_revision:whole?proof.revision:proof.execution_revision};
 }
 async completionEvidence(tx,ctx,receipt,live,{historical=false}={}){
  receipt=validateWorkGrantCompletionReceipt(receipt);const reference=receipt.artifact_reference,plan=receipt.plan_reference;
  const artifact=await tx.get(ctx.owner,'catpaw-artifact-versions',reference.artifact_id+':'+reference.version);live();const verify=await tx.get(ctx.owner,'catpaw-task-plan-receipts',receipt.verification_receipt.id);live();
  check(artifact?.run_id===ctx.run.id&&artifact.task_id===ctx.task.id&&artifact.artifact_id===reference.artifact_id&&artifact.version===reference.version&&artifact.content_hash===reference.content_hash&&hash(artifact.body)===reference.content_hash&&same(artifact.plan_reference,plan)&&verify?.id===ctx.run.id+':'+plan.revision+':verify'&&verify.run_id===ctx.run.id&&verify.task_id===ctx.task.id&&verify.step_id==='verify'&&verify.status==='succeeded'&&verify.receipt_kind==='completion_validated'&&verify.plan_revision===plan.revision&&verify.plan_hash===plan.plan_hash&&verify.receipt_hash===receipt.verification_receipt.receipt_hash,409,'work_grant_completion_receipt_conflict');
  let body;try{body=JSON.parse(artifact.body);}catch{check(false,409,'work_grant_completion_receipt_conflict');}
  check(body.kind==='report'&&typeof body.data?.content==='string'&&body.data.content.trim().length>0,409,'work_grant_completion_receipt_conflict');
  if(historical)return;
  check(same(ctx.task.state.plan_binding,plan)&&ctx.task.artifactIds?.includes(reference.artifact_id)&&ctx.run.artifact_references?.some(r=>same(r,reference)),409,'work_grant_completion_receipt_conflict');
  await completionPlanCheck(tx,ctx.owner,ctx.run,ctx.task,artifact);live();const frozen=await effectiveTaskRequest(tx,ctx.owner,ctx.run,ctx.task);live();let validation;
  if(frozen.completion_contract?.mode==='model_finish_local_artifact')validation={valid:true,mode:'model_finish_local_artifact',artifact_reference:reference};
  else{check(frozen.completion_contract?.mode==='single_local_report'&&completionAuthorityValid(frozen),409,'work_grant_completion_receipt_conflict');validation=evaluateReport(frozen,{title:body.title,summary:body.summary,content:body.data.content});check(validation.valid,409,'work_grant_completion_receipt_conflict');}
  check(hash(validation)===verify.receipt_hash,409,'work_grant_completion_receipt_conflict');
  if(frozen.public_sources){
   check(typeof this.sourceService?.validateCitationsInTransaction==='function'&&body.data.source_contract==='sourced-report-v1'&&Array.isArray(body.data.citations),503,'work_grant_source_receipt_verifier_required');
   const bound=await this.sourceService.validateCitationsInTransaction(tx,ctx.owner,ctx.run,ctx.task,body.data.citations.map(({source_id,quote})=>({source_id,quote})));live();check(same(bound.sources,body.data.sources)&&same(bound.citations,body.data.citations)&&same(bound.receipt_references,body.data.source_receipt_references),409,'work_grant_completion_receipt_conflict');
  }
 }
 async validateStoredAcknowledgement(tx,ctx,row,live){
  const ack=row.outcome.acknowledgement;try{shape(ack,['contract','attempt_id','execution_revision','previous_task_hash','next_task_hash','checkpoint_hash','task_status','run_binding','completion_receipt','acknowledged_at']);if(ack.completion_receipt!==null)validateWorkGrantCompletionReceipt(ack.completion_receipt);}catch{check(false,409,'work_grant_record_corrupt');}
  check(ack.contract===TASK_WORK_ATTEMPT_ACK_CONTRACT&&workGrantOperationID(ack.attempt_id)&&Number.isSafeInteger(ack.execution_revision)&&ack.execution_revision>=0&&['previous_task_hash','next_task_hash','checkpoint_hash'].every(k=>/^[a-f0-9]{64}$/.test(ack[k]??''))&&['succeeded','failed','outcome_unknown'].includes(ack.task_status)&&same(ack.run_binding,ctx.run_binding)&&ack.acknowledged_at===row.outcome.recorded_at&&workGrantInstant(ack.acknowledged_at)&&((ack.task_status==='succeeded')===(ack.completion_receipt!==null)),409,'work_grant_record_corrupt');
  const evidence=await this.attemptEvidence(tx,ctx,ack.attempt_id,live);check(evidence.attempt.status===ack.task_status&&evidence.execution_revision===ack.execution_revision&&evidence.proof.checkpoint_out===ack.checkpoint_hash,409,'work_grant_record_corrupt');
  const outcome=row.outcome.input;check(outcome.outcome===(ack.task_status==='outcome_unknown'?'unknown':'received')&&(outcome.outcome==='unknown'?outcome.receipt_reference===null:same(outcome.receipt_reference,{receipt_id:hash({grant_id:ctx.terms.grant_id,attempt_id:ack.attempt_id,next_task_hash:ack.next_task_hash}),receipt_hash:hash(ack)})),409,'work_grant_record_corrupt');
  if(ack.completion_receipt)await this.completionEvidence(tx,ctx,ack.completion_receipt,live,{historical:true});
 }
 async originalUnknownEvidence(tx,ctx,previous,live){
  const originals=ctx.reservations.filter(r=>r.frozen.input.kind!=='due'&&['reserved','unknown'].includes(r.state));
  for(const original of originals){
   if(original.frozen.input.kind==='model'){const round=previous.state.local_model?.round;if(round&&['dispatched','unknown'].includes(round.state)&&round.request_hash===original.frozen.input.request_hash)return;}
   else{const read=await tx.get(ctx.owner,'catpaw-task-source-reads',original.id);live();if(read&&['dispatched','unknown'].includes(read.state)&&read.request_hash===original.frozen.input.request_hash){await this.dispatchedCheckpoint(tx,ctx,original,{kind:'source',read_id:read.id,request_hash:read.request_hash,checkpoint_hash:hash(read)},live,read.state);return;}}
  }check(false,409,'work_grant_original_unknown_required');
 }
 /** Only an original acknowledged maintenance attempt may settle its due. The
  * next terminal task is read from this transaction; there is no terminal bypass. */
 async settleOriginalAttemptInTransaction(tx,identity,input,{signal,assertLive}={}){
  identity=validateWorkGrantIdentity(identity);input=validateWorkGrantAttemptSettlement(input);const live=this.permission(signal,assertLive),ctx=await this.current(tx,identity,live),due=ctx.reservations.find(r=>r.frozen.input.kind==='due');check(due,409,'work_grant_due_required');
  if(due.state!=='reserved'){
   const ack=due.outcome?.acknowledgement;check(ack?.attempt_id===input.attempt_id&&ack.previous_task_hash===hash(input.previous_task)&&same(ack.completion_receipt,input.completion_receipt),409,'work_grant_acknowledgement_conflict');await this.authority(tx,{...ctx,reservation:due},'recovery',live);return {created:false,reservation:clone(due)};
  }
  const previous=input.previous_task,evidence=await this.attemptEvidence(tx,ctx,input.attempt_id,live),next=ctx.task;
  check(previous.id===next.id&&same(previous.state.catpaw,next.state.catpaw)&&Date.parse(previous.leaseUntil)>this.now()&&taskControlRevision(previous)===taskControlRevision(next)&&evidence.execution_revision===taskControlRevision(previous)&&['succeeded','failed','outcome_unknown'].includes(next.status)&&next.leaseId===null&&next.leaseUntil===null&&evidence.attempt.status===next.status&&evidence.proof.checkpoint_out===hash(next.state),409,'work_grant_attempt_conflict');
  if(next.status==='succeeded'){check(input.completion_receipt!==null&&!ctx.reservations.some(r=>r.frozen.input.kind!=='due'&&r.state!=='received')&&next.state.local_model?.round?.state!=='dispatched',409,'work_grant_completion_receipt_conflict');await this.completionEvidence(tx,ctx,input.completion_receipt,live);}
  else{check(input.completion_receipt===null&&(next.status==='outcome_unknown'||!ctx.reservations.some(r=>r.frozen.input.kind!=='due'&&r.state!=='received')),409,'work_grant_attempt_conflict');if(next.status==='outcome_unknown')await this.originalUnknownEvidence(tx,ctx,previous,live);}
  await this.grantCurrent(tx,ctx,live);await this.authority(tx,{...ctx,previous_task:previous,attempt:evidence.attempt,completion_receipt:input.completion_receipt},'terminal_ack',live);check(this.now()<Date.parse(due.frozen.input.deadline_at),409,'work_grant_result_deadline');
  const at=iso(this.now()),ack={contract:TASK_WORK_ATTEMPT_ACK_CONTRACT,attempt_id:input.attempt_id,execution_revision:evidence.execution_revision,previous_task_hash:hash(previous),next_task_hash:hash(next),checkpoint_hash:hash(next.state),task_status:next.status,run_binding:ctx.run_binding,completion_receipt:input.completion_receipt,acknowledged_at:at};
  const outcomeInput={operation_id:due.id,request_hash:due.frozen.input.request_hash,outcome:next.status==='outcome_unknown'?'unknown':'received',receipt_reference:next.status==='outcome_unknown'?null:{receipt_id:hash({grant_id:identity.grant_id,attempt_id:input.attempt_id,next_task_hash:ack.next_task_hash}),receipt_hash:hash(ack)}};
  const fields={reservation_hash:due.reservation_hash,input:outcomeInput,recorded_at:at,acknowledgement:ack},outcome={input:outcomeInput,recorded_at:at,checkpoint_hash:hash(fields),acknowledgement:ack};
  check(await tx.compareAndSwap(ctx.owner,K.reservations,due.id,{state:'reserved',reservation_hash:due.reservation_hash},{state:outcomeInput.outcome,outcome}),409,'work_grant_acknowledgement_conflict');live();
  const final=await this.current(tx,identity,live);check(hash(final.task)===ack.next_task_hash,409,'work_grant_attempt_conflict');await this.grantCurrent(tx,final,live);await this.authority(tx,{...final,previous_task:previous,attempt:evidence.attempt,completion_receipt:input.completion_receipt},'terminal_ack',live);check(this.now()<Date.parse(due.frozen.input.deadline_at),409,'work_grant_result_deadline');live();return {created:true,reservation:clone(final.reservations.find(r=>r.id===due.id))};
 }
 /** Internal alias for the first uninstalled WIP. The caller must still supply
  * an explicit bounded slice deadline; this does not invent a fresh invocation. */
 async commitContinuationInTransaction(tx,identity,operationID,mutate,options={}){
  return this.commitReceivedContinuationInTransaction(tx,identity,operationID,mutate,options);
 }
 async receivedContinuationEvidence(tx,ctx,reservation,live){
  const input=reservation.frozen.input,point=reservation.outcome.transport_checkpoint;
  check(point.kind!=='source_failure',409,'work_grant_received_checkpoint_required');
  if(input.kind==='model'){const round=ctx.task.state.local_model?.round;check(round?.state==='received'&&round.request_hash===input.request_hash&&typeof round.text==='string'&&Array.isArray(round.calls)&&Number.isSafeInteger(round.next)&&round.next>=0&&round.next<=round.calls.length&&Array.isArray(round.results)&&point.payload_hash===hash({request_hash:round.request_hash,text:round.text,calls:round.calls}),409,'work_grant_received_checkpoint_required');return;}
  check(typeof this.sourceService?.validateWorkGrantTransportReceiptInTransaction==='function',503,'work_grant_source_receipt_verifier_required');const verified=await this.sourceService.validateWorkGrantTransportReceiptInTransaction(tx,ctx.owner,ctx.run,ctx.task,{read_id:reservation.id,request_hash:input.request_hash,lease_id:reservation.frozen.execution.lease_id});live();check(same(verified,reservation.outcome.input.receipt_reference),409,'work_grant_received_checkpoint_required');
 }
 /** A durable received result may continue in a later live slice. Transport
  * receipt admission retains its original deadline; local work has the immutable
  * due/grant deadline and a fresh bounded slice. This never replenishes budget. */
 async commitReceivedContinuationInTransaction(tx,identity,operationID,mutate,{signal,execution,currentSliceDeadline,assertLive}={}){
  identity=validateWorkGrantIdentity(identity);check(workGrantOperationID(operationID)&&typeof mutate==='function'&&Number.isSafeInteger(currentSliceDeadline)&&currentSliceDeadline>this.now()&&currentSliceDeadline<=this.now()+L.result_budget_ms,422,'work_grant_schema_invalid');const started=this.now(),live=this.permission(signal,assertLive),ctx=await this.current(tx,identity,live),reservation=ctx.reservations.find(r=>r.id===operationID);
  check(reservation?.state==='received'&&reservation.frozen.input.kind!=='due',409,'work_grant_received_operation_required');
  const due=ctx.reservations.find(r=>r.frozen.input.kind==='due');check(due?.state==='reserved',409,'work_grant_due_closed');check(!ctx.reservations.some(r=>r.state==='unknown'),409,'work_grant_original_outcome_unknown');
  execution=this.executor(ctx,execution,live);await this.runningAttempt(tx,ctx,execution,live);await this.receivedContinuationEvidence(tx,ctx,reservation,live);const deadline=Math.min(Date.parse(ctx.terms.not_after),Date.parse(due.frozen.input.deadline_at),currentSliceDeadline,started+L.write_budget_ms,Date.parse(ctx.task.leaseUntil));
  const bounded=()=>{live();check(this.now()<deadline,409,'work_grant_continuation_deadline');};
  await this.authority(tx,{...ctx,reservation,execution,continuation_deadline:deadline},'continuation',bounded);await this.execution(tx,ctx,bounded);bounded();
  const result=await mutate(tx,{...ctx,reservation,execution,continuation_deadline:deadline});bounded();const final=await this.current(tx,identity,bounded);await this.execution(tx,final,bounded);await this.authority(tx,{...final,reservation,execution,continuation_deadline:deadline},'continuation',bounded);this.executor(final,execution,bounded);await this.runningAttempt(tx,final,execution,bounded);await this.receivedContinuationEvidence(tx,final,reservation,bounded);bounded();return result;
 }
}
