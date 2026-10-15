import {resolveExecutionGrantInTransaction,readWorkGrantRevisionBindingInTransaction} from './core/src/task-work-execution-selector.mjs';
import {ApiError,check,hash,UUID,iso} from './core/facade-r2/src/common.mjs';import {stableUUID} from './core/src/local-output-facade.mjs';
import {invalidatePendingTaskActionsInTransaction} from './core/src/task-action-service.mjs';
import {validateWorkGrantTerms,validateWorkGrantRunBinding,workGrantReference,workGrantReceiptHash,validateWorkGrantReference,workGrantKinds} from './core/src/task-work-grant-contract.mjs';
import {revokeTaskWorkGrantsForSourceInTransaction} from './core/src/task-work-grant-lifecycle.mjs';
export const membershipOwner=issuer=>`system:supabase:${hash(issuer)}`;
// Called only AFTER signed JWT + official GET /auth/v1/user validation. No managed Auth SQL or tokens persisted.
export class AppScopeAuthority{
 constructor(pool,{diagnostic=entry=>console.error(JSON.stringify(entry))}={}){this.pool=pool;this.diagnostic=diagnostic;}
 async resolve({issuer,subject_id,session_id,issued_at,expires_at}){
  let c,phase='connect';
  const query=(next,sql,args=[])=>{phase=next;return c.query(sql,args);};
  try{
   c=await this.pool.connect();
   await query('begin','BEGIN');
   const owner=membershipOwner(issuer);
   await query('subject_lock','SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[owner+subject_id]);
   const session=(await query('session_read',"SELECT data FROM public.records WHERE owner=$1 AND kind='app-sessions' AND id=$2",[owner,session_id])).rows[0]?.data;
   check(!session||session.subject_id===subject_id,401,'session_revoked');check(session?.state!=='revoked',401,'session_revoked');
   let m=(await query('membership_read',"SELECT data FROM public.records WHERE owner=$1 AND kind='scope-memberships' AND id=$2",[owner,subject_id])).rows[0]?.data;
   if(!m){
    const scope={scope_id:stableUUID(issuer+subject_id+':scope'),profile_id:stableUUID(issuer+subject_id+':profile'),workspace_id:stableUUID(issuer+subject_id+':workspace'),local_output:true};
    const identity={...Object.fromEntries(['scope_id','profile_id','workspace_id'].map(k=>[k,scope[k]])),owner:`catpaw:${hash({profile:scope.profile_id,workspace:scope.workspace_id})}`};
    await query('scope_set',"SELECT set_config('catpaw.scope_id',$1,true)",[scope.scope_id]);
    await query('scope_insert','INSERT INTO catpaw.scopes(scope_id,data) VALUES($1,$2::jsonb) ON CONFLICT DO NOTHING',[scope.scope_id,JSON.stringify({identity,generation:1,enabled:true,last_sequence:0})]);
    m={id:subject_id,subject_id,issuer,state:'active',tokens_valid_after:0,revoked_session_ids:[],scopes:[scope]};
    await query('membership_insert',"INSERT INTO public.records(owner,kind,id,data) VALUES($1,'scope-memberships',$2,$3::jsonb) ON CONFLICT DO NOTHING",[owner,subject_id,JSON.stringify(m)]);
   }
   check(m.state==='active'&&m.issuer===issuer&&issued_at>=m.tokens_valid_after&&!m.revoked_session_ids.includes(session_id),401,'session_revoked');
   for(const s of m.scopes){
    await query('scope_set',"SELECT set_config('catpaw.scope_id',$1,true)",[s.scope_id]);
    const identity=(await query('scope_verify','SELECT data FROM catpaw.scopes WHERE scope_id=$1::uuid',[s.scope_id])).rows[0]?.data?.identity;
    check(identity?.profile_id===s.profile_id&&identity.workspace_id===s.workspace_id,403,'scope_mapping_mismatch');
   }
   const row={id:session_id,subject_id,issuer,state:'active',issued_at,expires_at,verified_at:iso()};
   await query('session_upsert',"INSERT INTO public.records(owner,kind,id,data) VALUES($1,'app-sessions',$2,$3::jsonb) ON CONFLICT(owner,kind,id) DO UPDATE SET data=excluded.data,updated_at=now()",[owner,session_id,JSON.stringify(row)]);
   await query('commit','COMMIT');return {session_active:true,scopes:m.scopes};
  }catch(e){
   if(!(e instanceof ApiError))try{this.diagnostic({event:'catpaw_scope_resolve_failed',phase,sqlstate:/^[0-9A-Z]{5}$/.test(e?.code??'')?e.code:null});}catch{}
   if(c)try{await c.query('ROLLBACK');}catch{}
   throw e instanceof ApiError?e:new ApiError(503,'scope_store_unavailable');
  }finally{c?.release();}
 }
}
async function currentSourceRows(tx,source,scope){
 check(source&&source.scope_id===scope.scope_id&&UUID.test(source.subject_id)&&UUID.test(source.session_id),409,'grant_conflict');const c=tx.connection;check(c?.query,503,'postgres_authority_required');const owner=membershipOwner(source.issuer);await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[owner+source.subject_id]);
 const session=(await c.query("SELECT data FROM public.records WHERE owner=$1 AND kind='app-sessions' AND id=$2",[owner,source.session_id])).rows[0]?.data;
 const m=(await c.query("SELECT data FROM public.records WHERE owner=$1 AND kind='scope-memberships' AND id=$2",[owner,source.subject_id])).rows[0]?.data;
 check(session?.subject_id===source.subject_id&&session.state==='active'&&m?.state==='active'&&source.issued_at>=m.tokens_valid_after&&!m.revoked_session_ids?.includes(source.session_id)&&m.scopes?.some(s=>s.scope_id===scope.scope_id&&s.profile_id===scope.profile_id&&s.workspace_id===scope.workspace_id&&s.local_output===true),409,'grant_conflict');
 return {session,m};
}
// Every new command and historical viewer still needs current authentication.
export async function assertSourceAuthority(tx,source,scope){
 const {session}=await currentSourceRows(tx,source,scope);
 check(session.expires_at>Math.floor(Date.now()/1000),409,'grant_conflict');
}
/** Explicitly accepted work only. This is a source-authority check, never a dispatch,
 * completion or lease permit. Trusted composition must additionally enforce consent,
 * cumulative reservation budgets and the exact current executor/settlement fence.
 * Only trusted finite-work composition may select this port; legacy runs keep
 * assertSourceAuthority. HTTP admission/viewer authentication remains separate.
 * A caller boolean or merely matching reference cannot relax JWT expiry: all facts
 * are re-read from the immutable run and its current bounded segment in this transaction. */
export async function assertAcceptedWorkSourceAuthority(tx,source,scope,reference,{now=Date.now}={}){
 return acceptedWorkSourceProof(tx,source,scope,reference,{now},['active']);
}
// A fresh authenticated control command may inspect its original paused finite
// source. This fixed port grants no execution permission and cannot admit work.
export async function assertAcceptedWorkControlSourceAuthority(tx,source,scope,reference,{now=Date.now}={}){
 return acceptedWorkSourceProof(tx,source,scope,reference,{now},['active','paused']);
}
async function acceptedWorkSourceProof(tx,source,scope,reference,{now},allowedStates){
 const conflict=condition=>check(condition,409,'accepted_work_grant_conflict');
 const same=(a,b)=>a!==undefined&&b!==undefined&&hash(a)===hash(b);
 try{validateWorkGrantReference(reference);}catch{conflict(false);}const kinds=workGrantKinds(reference);
 const owner=`catpaw:${hash({profile:scope.profile_id,workspace:scope.workspace_id})}`;
 conflict(scope.owner===owner&&typeof now==='function');
 let lastClock=now();conflict(Number.isSafeInteger(lastClock));
 const grantLive=terms=>{const timestamp=now();conflict(Number.isSafeInteger(timestamp)&&timestamp>=lastClock&&timestamp>=Date.parse(terms.accepted_at)&&timestamp<Date.parse(terms.not_after));lastClock=timestamp;};
 // Match existing scope -> subject authority lock order before grant locks.
 await tx.withScope(scope.scope_id,async scoped=>{const s=await scoped.scope();conflict(s.enabled&&same(s.identity,scope));});
 await currentSourceRows(tx,source,scope);
 const proof=async()=>{
  await tx.lock(owner,kinds.grants,reference.grant_id);
  const row=await tx.get(owner,kinds.terms,reference.grant_id);
  let terms;try{terms=validateWorkGrantTerms(row?.terms);}catch{conflict(false);}
  const state=await tx.get(owner,kinds.grants,reference.grant_id),r=row.receipt;
  conflict(same(reference,workGrantReference(terms))&&row.id===terms.grant_id&&row.terms_hash===reference.terms_hash&&same(terms.scope,scope)&&same(terms.source_auth,source));
  conflict(allowedStates.includes(state?.state)&&state.id===row.id&&same(state.reference,reference)&&same(state.run_binding,row.run_binding));
  conflict(Number.isSafeInteger(state.revision)&&state.revision>0&&['due','model','source'].every(k=>Number.isSafeInteger(state.consumed?.[k])&&state.consumed[k]>=0&&state.consumed[k]<=terms.limits[k]));
  grantLive(terms);
  conflict(r?.contract===terms.contract&&r.grant_id===row.id&&r.terms_hash===row.terms_hash&&r.accepted_at===terms.accepted_at&&r.task_completed===false&&same(r.run_binding,row.run_binding)&&workGrantReceiptHash(r)===r.receipt_hash);
  await tx.withScope(scope.scope_id,async scoped=>{const s=await scoped.scope();conflict(s.enabled&&same(s.identity,scope)&&s.generation===terms.memory_generation);});
  const run=await tx.get(owner,'catpaw-runs',terms.origin.run_id),f=run?.frozen_request;
  let binding;try{binding=terms.schema_version===2?(await readWorkGrantRevisionBindingInTransaction(tx,owner,run,terms)).run_binding:validateWorkGrantRunBinding(terms,run);}catch{conflict(false);}
  conflict(same(row.run_binding,binding)&&row.scope_id===scope.scope_id&&row.subject_id===source.subject_id&&row.conversation_id===terms.conversation_id&&row.run_id===run.id&&row.task_id===run.task_id);
  conflict(state.scope_id===row.scope_id&&state.subject_id===row.subject_id&&state.conversation_id===row.conversation_id&&state.run_id===row.run_id&&state.task_id===row.task_id);
  const operation=await tx.get(owner,'catpaw-operations',run.operation_id),task=await tx.get(owner,'tasks',run.task_id);
  conflict(operation?.run_id===run.id&&operation.request_hash===run.request_hash&&same(task?.state?.catpaw,{operation_id:run.operation_id,run_id:run.id,delegation_id:run.delegation_id,request_hash:run.request_hash,grant_epoch:run.grant_epoch,delegation_revision:run.delegation_revision}));
  const selected=await resolveExecutionGrantInTransaction(tx,owner,run,task);conflict(selected&&same(selected.reference,reference)&&same(selected.source_auth,source));
  const delegation=await tx.get(owner,'catpaw-delegations',run.delegation_id),conversation=await tx.get(owner,'native-chat-conversations',terms.conversation_id);
  conflict(delegation?.state==='active'&&delegation.subject_id===source.subject_id&&delegation.conversation_id===terms.conversation_id&&delegation.grant_epoch===run.grant_epoch&&delegation.revision===run.delegation_revision);
  conflict(conversation?.state==='active'&&conversation.subject_id===source.subject_id&&conversation.scope_id===scope.scope_id&&conversation.grant_epoch===f.conversation_epoch);
  grantLive(terms);
 };
 await proof();await currentSourceRows(tx,source,scope);await proof();
}
export async function revokeAppSession(repository,claims,runtime){const stopped=await repository.transaction(async tx=>{
 const stopped=[];
 const owner=membershipOwner(claims.iss),membership=await tx.get(owner,'scope-memberships',claims.sub);
 // Same scope->subject lock order as fresh model publication; no late writes after successful logout commit.
 for(const scope of [...(membership?.scopes??[])].sort((a,b)=>a.scope_id.localeCompare(b.scope_id)))if(tx.connection){await tx.connection.query("SELECT set_config('catpaw.scope_id',$1,true)",[scope.scope_id]);await tx.connection.query('SELECT data FROM catpaw.scopes WHERE scope_id=$1 FOR UPDATE',[scope.scope_id]);}
 if(tx.connection)await tx.connection.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[owner+claims.sub]);
 const row=await tx.get(owner,'app-sessions',claims.session_id);check(!row||row.subject_id===claims.sub,401,'session_revoked');await tx.put(owner,'app-sessions',{id:claims.session_id,subject_id:claims.sub,issuer:claims.iss,state:'revoked',expires_at:claims.exp,revoked_at:iso()});
 for(const scope of [...(membership?.scopes??[])].sort((a,b)=>a.scope_id.localeCompare(b.scope_id))){const resourceOwner=`catpaw:${hash({profile:scope.profile_id,workspace:scope.workspace_id})}`;
  await revokeTaskWorkGrantsForSourceInTransaction(tx,{owner:resourceOwner,scope_id:scope.scope_id,subject_id:claims.sub,session_id:claims.session_id});
  for(const run of await tx.list(resourceOwner,'catpaw-runs')){
   if(run.frozen_request?.subject_id!==claims.sub)continue;
   const task=await tx.get(resourceOwner,'tasks',run.task_id),hasRevisionWork=Boolean(task?.state?.task_revision?.work_grant_reference),original=!hasRevisionWork&&run.frozen_request.source_auth?.session_id===claims.session_id;
   const pointer=task?.state?.task_revision,operation=pointer?await tx.get(resourceOwner,'catpaw-task-revision-operations',pointer.operation_id):null,fresh=operation?.frozen?.fresh_source_auth;
   const revision=fresh?.subject_id===claims.sub&&fresh.session_id===claims.session_id&&fresh.issuer===claims.iss&&fresh.scope_id===scope.scope_id;
   if(!original&&!revision)continue;
   if(original){const d=await tx.get(resourceOwner,'catpaw-delegations',run.delegation_id);if(d?.state==='active')await tx.put(resourceOwner,'catpaw-delegations',{...d,state:'revoked',revision:d.revision+1,grant_epoch:d.grant_epoch+1});}
   if(task&&!['succeeded','failed','cancelled'].includes(task.status)){
    const prior=task.state?.task_control?.revision,current=Number.isSafeInteger(prior)&&prior>=0&&prior<Number.MAX_SAFE_INTEGER?prior:0;
    const state={...task.state,task_control:{revision:current+1,operation_id:stableUUID(`session-stop:${claims.session_id}:${task.id}`),reason:original?'original_source_not_current':'revision_source_not_current',previous_status:task.status}};
    await tx.put(resourceOwner,'tasks',{...task,status:original?'cancelled':'paused',leaseId:null,leaseUntil:null,state,updatedAt:iso()});stopped.push(task.id);
   }
   await invalidatePendingTaskActionsInTransaction(tx,resourceOwner,{run_id:run.id,task_id:run.task_id,reason:'source_authority_changed'});
   for(const binding of await tx.list(resourceOwner,'catpaw-approval-bindings'))if(binding.run_id===run.id){const action=await tx.get(resourceOwner,'actions',binding.id);if(action?.status==='awaiting_review')await tx.compareAndSwap(resourceOwner,'actions',binding.id,{status:'awaiting_review'},{status:'denied'});}
  }
  for(const turn of await tx.list(resourceOwner,'native-chat-turns'))if(turn.state==='running'&&turn.source_auth?.session_id===claims.session_id&&turn.subject_id===claims.sub){await tx.lock(resourceOwner,'native-chat-conversations',turn.conversation_id);const c=await tx.get(resourceOwner,'native-chat-conversations',turn.conversation_id);await tx.put(resourceOwner,'native-chat-conversations',{...c,grant_epoch:c.grant_epoch+1,revision:c.revision+1});const error={code:'app_session_revoked',retryable:false,reconciliation_required:false};await tx.put(resourceOwner,'native-chat-turns',{...turn,state:'failed',error,events:[...turn.events,runtime.chat.event(turn,'turn_failed',error)]});}
 }
 return stopped;
});for(const id of stopped)runtime.facade?.abortTask(id);}
export function officialUserVerifier({projectUrl,publishableKey,fetchImpl=fetch}){
 return async({authorization,subject_id,is_anonymous=false})=>{
  const r=await fetchImpl(projectUrl+'/auth/v1/user',{
   headers:{Authorization:authorization,apikey:publishableKey},
   signal:AbortSignal.timeout(5000),
   redirect:'error'
  });
  check(r.status===200,401,'invalid_session');
  const user=await r.json();
  check(
   user.id===subject_id&&
   (user.is_anonymous===true)===is_anonymous&&
   (user.is_anonymous!==true||
    new URL(projectUrl).origin==='https://dbyklgxdvjbutxzsjeth.supabase.co'),
   401,'invalid_session'
  );
 };
}
