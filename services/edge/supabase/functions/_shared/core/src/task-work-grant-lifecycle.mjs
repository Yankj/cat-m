import {check,hash,clone,shape,UUID} from '../facade-r2/src/common.mjs';
import {TASK_WORK_GRANT_CONTRACT,TASK_WORK_GRANT_KINDS as K,validateWorkGrantTerms,validateWorkGrantRunBinding,validateWorkGrantReservation,validateWorkGrantOutcome,validateWorkGrantExecution,workGrantReference,workGrantReceiptHash,workGrantInstant} from './task-work-grant-contract.mjs';

const conflict=value=>check(value,409,'work_grant_lifecycle_conflict');
const same=(a,b)=>a!==undefined&&b!==undefined&&hash(a)===hash(b);
const positive=value=>Number.isSafeInteger(value)&&value>0;
const kinds=Object.values(K);
const metadata=['scope_id','subject_id','conversation_id','run_id','task_id'];

/** Locks only: no viewer, source, dispatch, lease or completion authorization.
 * Synthetic repositories serialize transactions instead of taking PostgreSQL locks. */
export async function lockTaskWorkSourceInTransaction(tx,{scope_id,owner,source}){
 conflict(UUID.test(scope_id)&&typeof owner==='string'&&source?.scope_id===scope_id&&UUID.test(source.subject_id)&&UUID.test(source.session_id)&&typeof source.issuer==='string');
 await tx.withScope(scope_id,async scoped=>{const row=await scoped.scope();conflict(row.identity.owner===owner);});
 const sourceOwner=`system:supabase:${hash(source.issuer)}`;
 if(typeof tx.connection?.query==='function')await tx.connection.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[sourceOwner+source.subject_id]);
 else await tx.lock(sourceOwner,'source-subject',source.subject_id); // Explicit synthetic lock boundary; never a source proof.
}

function grantRows(row,state,run){
 try{
  shape(row,['id','scope_id','subject_id','conversation_id','run_id','task_id','terms','terms_hash','run_binding','receipt']);
  shape(state,['id','scope_id','subject_id','conversation_id','run_id','task_id','reference','run_binding','state','revision','consumed']);shape(state.consumed,['due','model','source']);
  const terms=validateWorkGrantTerms(row.terms),reference=workGrantReference(terms),binding=validateWorkGrantRunBinding(terms,run);
  const expected={scope_id:terms.scope.scope_id,subject_id:terms.subject_id,conversation_id:terms.conversation_id,run_id:run.id,task_id:run.task_id};
  conflict(row.id===terms.grant_id&&row.terms_hash===reference.terms_hash&&same(row.run_binding,binding)&&same(run.frozen_request.work_grant_reference,reference)&&metadata.every(k=>row[k]===expected[k]&&state[k]===expected[k]));
  conflict(state.id===row.id&&same(state.reference,reference)&&same(state.run_binding,binding)&&positive(state.revision)&&['active','paused','revoked'].includes(state.state)&&['due','model','source'].every(k=>Number.isSafeInteger(state.consumed[k])&&state.consumed[k]>=0&&state.consumed[k]<=terms.limits[k]));
  const r=row.receipt;shape(r,['contract','grant_id','terms_hash','run_binding','accepted_at','task_completed','receipt_hash']);
  conflict(r.contract===TASK_WORK_GRANT_CONTRACT&&r.grant_id===row.id&&r.terms_hash===row.terms_hash&&same(r.run_binding,binding)&&r.accepted_at===terms.accepted_at&&r.task_completed===false&&workGrantReceiptHash(r)===r.receipt_hash);
  return {row,state,terms,reference,binding};
 }catch{conflict(false);}
}

function reservationRows(rows,ctx){
 const counts={due:0,model:0,source:0},keys=new Set();
 try{for(const row of rows){
  shape(row,['id','grant_id','terms_hash','scope_id','subject_id','conversation_id','run_id','task_id','run_binding','frozen','reservation_hash','reserved_at','state','outcome']);shape(row.frozen,['grant_reference','run_binding','execution','input']);
  const input=validateWorkGrantReservation(row.frozen.input),key=input.kind+':'+input.operation_key;
  conflict(row.id===input.operation_id&&row.grant_id===ctx.row.id&&row.terms_hash===ctx.row.terms_hash&&metadata.every(k=>row[k]===ctx.row[k])&&same(row.run_binding,ctx.binding)&&same(row.frozen.run_binding,ctx.binding)&&same(row.frozen.grant_reference,ctx.reference)&&hash(row.frozen)===row.reservation_hash&&!keys.has(key));keys.add(key);
  conflict(workGrantInstant(row.reserved_at)&&Date.parse(row.reserved_at)>=Date.parse(ctx.terms.accepted_at)&&Date.parse(input.deadline_at)>Date.parse(row.reserved_at)&&Date.parse(input.deadline_at)<=Date.parse(ctx.terms.not_after)&&['reserved','received','unknown'].includes(row.state));
  if(input.kind==='due')conflict(row.frozen.execution===null&&row.id===ctx.binding.operation_id&&input.request_hash===ctx.binding.run_request_hash&&input.operation_key===hash({accepted_run:ctx.binding.run_id}));
  else{const e=validateWorkGrantExecution(row.frozen.execution);conflict(e.run_id===ctx.binding.run_id&&e.task_id===ctx.binding.task_id&&e.run_request_hash===ctx.binding.run_request_hash);}
  if(row.state==='reserved')conflict(row.outcome===null);
  else{
   shape(row.outcome,input.kind==='due'?['input','recorded_at','checkpoint_hash','acknowledgement']:['input','recorded_at','checkpoint_hash','transport_checkpoint']);
   const outcome=validateWorkGrantOutcome(row.outcome.input),fields={reservation_hash:row.reservation_hash,input:outcome,recorded_at:row.outcome.recorded_at,...input.kind==='due'?{acknowledgement:row.outcome.acknowledgement}:{transport_checkpoint:row.outcome.transport_checkpoint}};
   conflict(outcome.operation_id===row.id&&outcome.request_hash===input.request_hash&&outcome.outcome===row.state&&workGrantInstant(row.outcome.recorded_at)&&Date.parse(row.outcome.recorded_at)>=Date.parse(row.reserved_at)&&Date.parse(row.outcome.recorded_at)<Date.parse(input.deadline_at)&&row.outcome.checkpoint_hash===hash(fields));
  }
  counts[input.kind]++;
 }conflict(same(counts,ctx.state.consumed));}catch{conflict(false);}
 return rows;
}

/** Lifecycle facts only. Full executor/transport/ack verification remains in the
 * grant service. A malformed retained grant cannot be treated as a legacy run. */
export async function readTaskWorkGrantLifecycleInTransaction(tx,owner,run,{now=Date.now,assertLive=()=>{}}={}){
 const ref=run?.frozen_request?.work_grant_reference;
 const linked=[];for(const kind of kinds)for(const row of await tx.list(owner,kind))if(row.run_id===run.id||row.task_id===run.task_id||row.terms?.origin?.run_id===run.id||ref&&(kind===K.reservations?row.grant_id===ref.grant_id:row.id===ref.grant_id))linked.push({kind,row});assertLive();
 if(!ref){conflict(linked.length===0);return null;}
 conflict(ref.contract===TASK_WORK_GRANT_CONTRACT&&UUID.test(ref.grant_id));
 await tx.lock(owner,K.grants,ref.grant_id);assertLive();
 const row=await tx.get(owner,K.terms,ref.grant_id);assertLive();const state=await tx.get(owner,K.grants,ref.grant_id);assertLive();const ctx=grantRows(row,state,run);
 conflict(ctx.terms.scope.owner===owner&&linked.every(v=>v.kind===K.reservations?v.row.grant_id===ref.grant_id:v.row.id===ref.grant_id));
 const reservations=reservationRows(linked.filter(v=>v.kind===K.reservations).map(v=>v.row),ctx),at=now();conflict(Number.isSafeInteger(at));assertLive();
 const due=reservations.find(r=>r.frozen.input.kind==='due'),deadline=Math.min(Date.parse(ctx.terms.not_after),due?Date.parse(due.frozen.input.deadline_at):Infinity);
 return {...ctx,reservations,due,deadline,dueClosed:Boolean(due&&due.state!=='reserved'),dueUnknown:due?.state==='unknown',expired:at<Date.parse(ctx.terms.accepted_at)||at>=deadline};
}

/** Same transaction as the exact control receipt. No new terms, reservation,
 * deadline, budget, operation identity or source permission is created. */
export async function transitionTaskWorkGrantInTransaction(tx,owner,run,{action,now=Date.now,assertLive=()=>{}}={}){
 conflict(['pause','resume','revoke'].includes(action));const ctx=await readTaskWorkGrantLifecycleInTransaction(tx,owner,run,{now,assertLive});if(!ctx)return null;
 const next=action==='pause'?'paused':action==='resume'?'active':'revoked';
 if(action==='resume')conflict(ctx.state.state==='paused'&&!ctx.expired&&!ctx.dueClosed&&!ctx.reservations.some(r=>r.state==='unknown'||r.state==='reserved'&&r.frozen.input.kind!=='due'));
 else if(action==='pause')conflict(ctx.state.state==='active');
 if(ctx.state.state===next)return clone(ctx.state);
 const revision=ctx.state.revision+1;conflict(positive(revision));assertLive();
 const changed=await tx.compareAndSwap(owner,K.grants,ctx.row.id,{state:ctx.state.state,revision:ctx.state.revision,consumed:ctx.state.consumed},{state:next,revision});conflict(changed);assertLive();
 const current=await tx.get(owner,K.grants,ctx.row.id);assertLive();conflict(same(current,changed));return clone(changed);
}

function selected(row,selector){
 const terms=row.terms,f=row.frozen,source=terms?.source_auth;
 const matches=(key,value)=>row[key]===value||terms?.[key]===value||f?.[key]===value;
 if(!matches('scope_id',selector.scope_id)&&terms?.scope?.scope_id!==selector.scope_id)return false;
 if(!matches('subject_id',selector.subject_id))return false;
 return (!selector.conversation_id||matches('conversation_id',selector.conversation_id))&&(!selector.run_id||matches('run_id',selector.run_id)||terms?.origin?.run_id===selector.run_id)&&(!selector.session_id||source?.session_id===selector.session_id);
}
/** A withdrawal is a one-way reduction, including malformed/orphan state that
 * can still be attributed to this exact source. Never repairs it into active. */
export async function revokeTaskWorkGrantsForSourceInTransaction(tx,selector){
 conflict(typeof selector.owner==='string'&&UUID.test(selector.scope_id)&&UUID.test(selector.subject_id)&&[selector.session_id,selector.conversation_id,selector.run_id].some(v=>v!==undefined)&&[selector.session_id,selector.conversation_id,selector.run_id].every(v=>v===undefined||UUID.test(v)));
 const terms=await tx.list(selector.owner,K.terms),states=await tx.list(selector.owner,K.grants),runs=await tx.list(selector.owner,'catpaw-runs'),ids=new Set();
 for(const row of terms)if(selected(row,selector))ids.add(row.id);
 for(const run of runs){const f=run.frozen_request;if(f?.scope?.scope_id===selector.scope_id&&f.subject_id===selector.subject_id&&(!selector.session_id||f.source_auth?.session_id===selector.session_id)&&(!selector.conversation_id||f.conversation_id===selector.conversation_id)&&(!selector.run_id||run.id===selector.run_id)){if(f.work_grant_reference?.grant_id)ids.add(f.work_grant_reference.grant_id);for(const row of states)if(row.run_id===run.id&&row.scope_id===selector.scope_id&&row.subject_id===selector.subject_id)ids.add(row.id);}}
 // Conversation withdrawal can attribute orphan state even after its run/terms vanished.
 if(!selector.session_id)for(const row of states)if(selected(row,selector))ids.add(row.id);
 const changed=[];for(const id of [...ids].sort()){
  // An invalid record key cannot be a valid grant reference. Preserve it for
  // refs/hash purge reconciliation, without letting corruption cancel logout.
  if(!UUID.test(id))continue;
  await tx.lock(selector.owner,K.grants,id);const state=await tx.get(selector.owner,K.grants,id);if(!state||state.state==='revoked')continue;
  // Incoherent foreign metadata is already fail-closed at every grant reader;
  // do not let it revoke another subject or roll back the session withdrawal.
  if(state.scope_id!==selector.scope_id||state.subject_id!==selector.subject_id)continue;
  const revision=positive(state.revision)&&state.revision<Number.MAX_SAFE_INTEGER?state.revision+1:1;
  await tx.put(selector.owner,K.grants,{...state,state:'revoked',revision});changed.push(id);
 }return changed;
}

/** Refs/hash only, never physical deletion support. Follow every attributable
 * orphan; malformed/unknown original work must be reconciled before purge. */
export async function collectTaskWorkGrantPurgeRecordsInTransaction(tx,{owner,scope_id,subject_id,conversation_id,runs=[]}){
 const all=[];for(const kind of kinds)for(const row of await tx.list(owner,kind))all.push({kind,row});
 const runIDs=new Set(runs.map(r=>r.id)),taskIDs=new Set(runs.map(r=>r.task_id)),grantIDs=new Set(runs.map(r=>r.frozen_request?.work_grant_reference?.grant_id).filter(Boolean));
 const hit=row=>row.conversation_id===conversation_id||row.terms?.conversation_id===conversation_id||row.frozen?.conversation_id===conversation_id||runIDs.has(row.run_id)||runIDs.has(row.terms?.origin?.run_id)||taskIDs.has(row.task_id)||grantIDs.has(row.id)||grantIDs.has(row.grant_id);
 for(const {kind,row} of all)if(hit(row)){if(row.grant_id)grantIDs.add(row.grant_id);else if(row.id&&kind!==K.reservations)grantIDs.add(row.id);}
 const linked=all.filter(({row})=>hit(row)),blocked=new Set();
 for(const id of grantIDs){
  const row=linked.find(v=>v.kind===K.terms&&v.row.id===id)?.row,state=linked.find(v=>v.kind===K.grants&&v.row.id===id)?.row,run=runs.find(r=>r.id===row?.run_id);
  try{const ctx=grantRows(row,state,run);conflict(ctx.terms.scope.scope_id===scope_id&&ctx.terms.subject_id===subject_id&&ctx.terms.conversation_id===conversation_id);reservationRows(linked.filter(v=>v.kind===K.reservations&&v.row.grant_id===id).map(v=>v.row),ctx);}
  catch{blocked.add('reconcile_malformed_orphan_work_grant_before_purge');}
  if(state&&state.state!=='revoked')blocked.add('revoke_and_fence_work_grants_before_purge');
 }
 for(const {kind,row} of linked){
  if(!row.id||row.scope_id!==scope_id||row.subject_id!==subject_id||row.conversation_id!==conversation_id)blocked.add('reconcile_malformed_orphan_work_grant_before_purge');
  if(kind===K.reservations&&!UUID.test(row.grant_id))blocked.add('reconcile_malformed_orphan_work_grant_before_purge');
  if(kind===K.reservations&&['reserved','unknown'].includes(row.state))blocked.add(row.frozen?.input?.kind==='due'?'settle_original_work_attempt_before_purge':'reconcile_original_work_grant_operation_before_purge');
 }
 return {records:linked.map(({kind,row})=>({kind,id:row.id,expected_record_hash:hash(row)})).sort((a,b)=>(a.kind+a.id).localeCompare(b.kind+b.id)),blocked:[...blocked].sort()};
}
