import {ApiError,check,hash,UUID,iso} from './core/facade-r2/src/common.mjs';import {stableUUID} from './core/src/local-output-facade.mjs';
import {invalidatePendingTaskActionsInTransaction} from './core/src/task-action-service.mjs';
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
export async function assertSourceAuthority(tx,source,scope){
 check(source&&source.scope_id===scope.scope_id&&UUID.test(source.subject_id)&&UUID.test(source.session_id),409,'grant_conflict');const c=tx.connection;check(c?.query,503,'postgres_authority_required');const owner=membershipOwner(source.issuer);await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[owner+source.subject_id]);
 const session=(await c.query("SELECT data FROM public.records WHERE owner=$1 AND kind='app-sessions' AND id=$2",[owner,source.session_id])).rows[0]?.data;
 const m=(await c.query("SELECT data FROM public.records WHERE owner=$1 AND kind='scope-memberships' AND id=$2",[owner,source.subject_id])).rows[0]?.data;
 check(session?.subject_id===source.subject_id&&session.state==='active'&&session.expires_at>Math.floor(Date.now()/1000)&&m?.state==='active'&&source.issued_at>=m.tokens_valid_after&&!m.revoked_session_ids?.includes(source.session_id)&&m.scopes?.some(s=>s.scope_id===scope.scope_id&&s.profile_id===scope.profile_id&&s.workspace_id===scope.workspace_id&&s.local_output===true),409,'grant_conflict');
}
export async function revokeAppSession(repository,claims,runtime){const stopped=await repository.transaction(async tx=>{
 const stopped=[];
 const owner=membershipOwner(claims.iss),membership=await tx.get(owner,'scope-memberships',claims.sub);
 // Same scope->subject lock order as fresh model publication; no late writes after successful logout commit.
 for(const scope of [...(membership?.scopes??[])].sort((a,b)=>a.scope_id.localeCompare(b.scope_id)))if(tx.connection){await tx.connection.query("SELECT set_config('catpaw.scope_id',$1,true)",[scope.scope_id]);await tx.connection.query('SELECT data FROM catpaw.scopes WHERE scope_id=$1 FOR UPDATE',[scope.scope_id]);}
 if(tx.connection)await tx.connection.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[owner+claims.sub]);
 const row=await tx.get(owner,'app-sessions',claims.session_id);check(!row||row.subject_id===claims.sub,401,'session_revoked');await tx.put(owner,'app-sessions',{id:claims.session_id,subject_id:claims.sub,issuer:claims.iss,state:'revoked',expires_at:claims.exp,revoked_at:iso()});
 for(const scope of membership?.scopes??[]){const resourceOwner=`catpaw:${hash({profile:scope.profile_id,workspace:scope.workspace_id})}`;
  for(const run of await tx.list(resourceOwner,'catpaw-runs')){
   if(run.frozen_request?.subject_id!==claims.sub)continue;
   const task=await tx.get(resourceOwner,'tasks',run.task_id),original=run.frozen_request.source_auth?.session_id===claims.session_id;
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
