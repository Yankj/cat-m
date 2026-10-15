import {ApiError,check,hash,UUID} from '../facade-r2/src/common.mjs';
import {parseStrictObjectJSON} from './strict-json.mjs';
import {FollowupTriggerService} from './followup-trigger-service.mjs';
import {lockTaskWorkSourceInTransaction} from './task-work-grant-lifecycle.mjs';

const CONTRACT='catpaw.followup-trigger.v1';
const canonicalUUID=value=>typeof value==='string'&&UUID.test(value)&&value===value.toLowerCase();
const response=(value,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});

/** Fresh viewer + the original maintained run are the sole identity sources.
 * Configuration never imports the run's single-use grant as recurring authority.
 * The caller controls invocation; this module installs no scheduler or poller. */
export function createFollowupTriggerHTTPHandler({facade,repository,verifyViewer,now=Date.now}) {
 check(facade&&repository&&typeof verifyViewer==='function',503,'followup_authority_not_configured');
 return async (request,{path=new URL(request.url).pathname}={})=>{
  try {
   const url=new URL(request.url),parts=path.split('/').filter(Boolean);
   check(parts[0]==='catpaw'&&parts[1]==='followups'&&parts[2]==='v1'&&parts[3]==='scopes'&&canonicalUUID(parts[4]),404,'route_not_supported');
   check(!url.search,422,'followup_query_invalid');
   const scopeID=parts[4],scoped=await facade.scoped(request.headers.get('authorization'),scopeID);
   const identity={owner:scoped.owner,scope_id:scopeID,subject_id:scoped.principal.subject_id};
   const live=()=>check(!request.signal.aborted,409,'followup_request_cancelled');
   // An empty catalog still requires a current viewer. Per-object checks below
   // repeat this inside each write/read transaction with its original source.
   await repository.transaction(async tx=>{await verifyViewer(tx,scoped);live();});
   const service=new FollowupTriggerService({repository,now,authorize:async(tx,selected,origin,{purpose})=>{
    live();check(selected.owner===identity.owner&&selected.scope_id===identity.scope_id&&selected.subject_id===identity.subject_id,403,'scope_forbidden');
    await tx.withScope(scopeID,async view=>{check((await view.scope()).identity.owner===identity.owner,403,'scope_forbidden');});
    await verifyViewer(tx,scoped);live();
    const hint=await facade.ownedRun(tx,identity.owner,origin.run_id,scoped.principal,scopeID),f=hint.frozen_request;
    check(f.conversation_id===origin.conversation_id&&hint.task_id===origin.task_id&&hint.request_hash===origin.request_hash&&hash(f)===hint.request_hash,409,'followup_origin_mismatch');
    check(f.scope.profile_id===scoped.scope.profile_id&&f.scope.workspace_id===scoped.scope.workspace_id&&facade.owner(f.scope)===identity.owner,403,'scope_forbidden');
    await lockTaskWorkSourceInTransaction(tx,{owner:identity.owner,scope_id:scopeID,source:f.source_auth});live();
    const run=await facade.ownedRun(tx,identity.owner,origin.run_id,scoped.principal,scopeID);
    check(hash(run)===hash(hint),409,'followup_origin_changed');
    const d=await facade.ownedDelegation(tx,identity.owner,run.delegation_id,scoped.principal,{lock:true,scopeID});
    await tx.lock(identity.owner,'tasks',run.task_id);
    const task=await tx.get(identity.owner,'tasks',run.task_id),conversation=await tx.get(identity.owner,'native-chat-conversations',f.conversation_id);
    check(task?.state?.catpaw?.run_id===run.id&&task.state.catpaw.request_hash===run.request_hash&&conversation?.scope_id===scopeID&&conversation.subject_id===identity.subject_id,409,'followup_origin_mismatch');
    check(typeof facade.beforeArtifactRead==='function',503,'followup_authority_not_configured');
    const authority=await facade.beforeArtifactRead(tx,{...scoped,run,d,task,conversation,purpose:'followup_'+purpose});live();
    check(typeof authority?.source_current==='boolean',503,'followup_authority_not_configured');
    await verifyViewer(tx,scoped);live();
    const current=authority.source_current&&conversation.state==='active'&&conversation.grant_epoch===f.conversation_epoch&&d.state==='active'&&d.grant_epoch===run.grant_epoch&&d.revision===run.delegation_revision;
    return {source_current:current};
   }});
   let value;
   if(parts[5]==='triggers'&&parts.length===6&&request.method==='GET')value=await service.list(identity,{signal:request.signal});
   else if(parts[5]==='triggers'&&parts.length===7&&canonicalUUID(parts[6])&&request.method==='GET')value=await service.read(identity,parts[6],{signal:request.signal});
   else if(parts[5]==='operations'&&parts.length===7&&canonicalUUID(parts[6])&&request.method==='GET')value=await service.readOperation(identity,parts[6],{signal:request.signal});
   else {
    check(request.method==='POST'&&parts[5]==='triggers'&&(parts.length===6||parts.length===8&&canonicalUUID(parts[6])&&parts[7]==='commands'),404,'route_not_supported');
    const length=request.headers.get('content-length');check(length===null||/^(0|[1-9][0-9]*)$/.test(length)&&Number(length)<=12000,413,'followup_request_too_large');
    const raw=await request.text();check(new TextEncoder().encode(raw).length<=12000,413,'followup_request_too_large');live();
    // Service parsing rejects duplicate members before any command can commit.
    const input=parseStrictObjectJSON(raw,{maxBytes:12000,schemaCode:'followup_schema_invalid',duplicateCode:'followup_duplicate_key',sizeCode:'followup_request_too_large'});
    value=parts.length===6?await service.create(identity,input,{signal:request.signal}):await service.command(identity,parts[6],input,{signal:request.signal});
   }
   live();return response(value);
  } catch(error) {
   return response({schema_version:1,contract:CONTRACT,error:{code:error instanceof ApiError?error.code:'internal_error',retryable:false,reconciliation_required:error instanceof ApiError?error.reconciliation===true:false}},error instanceof ApiError?error.status:500);
  }
 };
}
