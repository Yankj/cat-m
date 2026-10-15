import {Buffer} from 'node:buffer';
import {check,hash,clone,UUID} from '../facade-r2/src/common.mjs';
import {readTaskArtifact} from './task-artifact-service.mjs';
import {readTaskActions} from './task-action-service.mjs';

export const INBOX_CONTRACT='catpaw.inbox.v1';
const STATUSES=new Set(['queued','scheduled','running','succeeded','failed','outcome_unknown','waiting_input','waiting_approval','paused','cancelled','interrupted']);
const BINDING_KEYS=['scope_id','conversation_id','turn_id','call_id','delegation_id','operation_id','run_id','task_id','request_hash','delegation_revision','grant_epoch','projection_url'];
const canonicalUUID=v=>typeof v==='string'&&UUID.test(v)&&v===v.toLowerCase();
const digest=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const instant=v=>typeof v==='string'&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString()===v;
const same=(a,b)=>a!==undefined&&b!==undefined&&hash(a)===hash(b);
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
function queryOptions(query,scopeID,subjectID,now){
 check([...query.keys()].every(k=>['limit','cursor'].includes(k))&&['limit','cursor'].every(k=>query.getAll(k).length<=1),422,'inbox_query_invalid');
 const limit=query.has('limit')?query.get('limit'):'20';check(/^[1-9][0-9]?$/.test(limit)&&Number(limit)<=50,422,'inbox_query_invalid');
 let cursor=null;
 if(query.has('cursor')){
  const raw=query.get('cursor');check(raw.length>0&&raw.length<=2048&&/^[A-Za-z0-9_-]+$/.test(raw),422,'inbox_cursor_invalid');
  try{const bytes=Buffer.from(raw,'base64url');check(bytes.toString('base64url')===raw,422,'inbox_cursor_invalid');cursor=JSON.parse(bytes.toString('utf8'));check(JSON.stringify(cursor)===bytes.toString('utf8'),422,'inbox_cursor_invalid');}catch{check(false,422,'inbox_cursor_invalid');}
  check(exact(cursor,['schema_version','scope_id','subject_id','as_of','after_created_at','after_run_id'])&&cursor.schema_version===1&&canonicalUUID(cursor.scope_id)&&canonicalUUID(cursor.subject_id)&&instant(cursor.as_of)&&instant(cursor.after_created_at)&&canonicalUUID(cursor.after_run_id)&&Date.parse(cursor.after_created_at)<=Date.parse(cursor.as_of)&&Date.parse(cursor.as_of)<=now,422,'inbox_cursor_invalid');
  check(cursor.scope_id===scopeID&&cursor.subject_id===subjectID,409,'inbox_cursor_partition_conflict');
 }
 return {limit:Number(limit),cursor,asOf:cursor?.as_of??new Date(now).toISOString()};
}
const beforeCursor=(run,cursor)=>!cursor||run.created_at<cursor.after_created_at||run.created_at===cursor.after_created_at&&run.id<cursor.after_run_id;
function bindingFor(run,turn,scopeID){
 const f=run.frozen_request,binding=turn.task_bindings?.filter(b=>b.run_id===run.id);
 check(binding?.length===1,409,'inbox_binding_conflict');const b=binding[0];
 check(exact(b,BINDING_KEYS)&&['scope_id','conversation_id','turn_id','delegation_id','operation_id','run_id'].every(k=>canonicalUUID(b[k]))&&typeof b.call_id==='string'&&b.call_id.length>0&&Buffer.byteLength(b.call_id)<=256&&!/[\u0000-\u001f\u007f-\u009f]/.test(b.call_id)&&typeof b.task_id==='string'&&/^[A-Za-z0-9._-]{1,256}$/.test(b.task_id)&&digest(b.request_hash)&&Number.isSafeInteger(b.delegation_revision)&&b.delegation_revision>0&&Number.isSafeInteger(b.grant_epoch)&&b.grant_epoch>0,409,'inbox_binding_conflict');
 check(b.scope_id===scopeID&&b.conversation_id===f.conversation_id&&b.turn_id===f.turn_id&&b.call_id===f.call_id&&b.run_id===run.id&&b.task_id===run.task_id&&['delegation_id','operation_id','request_hash','delegation_revision','grant_epoch'].every(k=>b[k]===run[k])&&b.projection_url===`/catpaw/v1/scopes/${scopeID}/runs/${run.id}`&&same(f.run_binding,{delegation_id:b.delegation_id,operation_id:b.operation_id,run_id:b.run_id,task_id:b.task_id}),409,'inbox_binding_conflict');
 return clone(b);
}
const removed=row=>!row||row.content_redacted===true||Boolean(row.source_purged_at)||row.deleted===true||Boolean(row.deleted_at);
async function sourceDeleted(tx,owner,run,task,conversation,turn){
 if(removed(conversation)||removed(turn))return true;
 const pointer=task?.state?.task_revision;
 if(pointer?.operation_id){const op=await tx.get(owner,'catpaw-task-revision-operations',pointer.operation_id);check(op?.frozen?.turn_id,409,'inbox_binding_conflict');const revisionTurn=await tx.get(owner,'native-chat-turns',op.frozen.turn_id);if(removed(revisionTurn))return true;}
 return false;
}
function titleFor(task){
 check(typeof task.title==='string',409,'inbox_task_corrupt');
 let result='',bytes=0;for(const scalar of task.title.replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g,' ').trim()){const size=Buffer.byteLength(scalar);if(bytes+size>512)break;result+=scalar;bytes+=size;}return result||'Task';
}
/** A read-only index of the maintained run/turn/task facts. Cursors are an
 * untrusted pagination position, never a capability or a retained snapshot. */
export async function readInboxPage(facade,auth,scopeID,query,{signal,verifyViewer,now=Date.now}={}){
 check(canonicalUUID(scopeID),422,'inbox_query_invalid');check(typeof verifyViewer==='function',503,'inbox_authority_not_configured');
 const scoped=await facade.scoped(auth,scopeID),at=now();check(Number.isSafeInteger(at),503,'inbox_clock_invalid');
 const options=queryOptions(query,scopeID,scoped.principal.subject_id,at),live=()=>check(!signal?.aborted,409,'inbox_read_cancelled');
 return facade.repository.transaction(async tx=>{
  live();await tx.withScope(scopeID,async scope=>{const row=await scope.scope();check(row.identity.owner===scoped.owner,403,'scope_forbidden');});
  await verifyViewer(tx,scoped);live();
  const rows=(await tx.list(scoped.owner,'catpaw-runs')).filter(run=>run.frozen_request?.subject_id===scoped.principal.subject_id&&run.frozen_request?.scope?.scope_id===scopeID);
  for(const run of rows)check(canonicalUUID(run.id)&&instant(run.created_at),409,'inbox_run_corrupt');
  rows.sort((a,b)=>b.created_at.localeCompare(a.created_at)||b.id.localeCompare(a.id));
  const items=[];
  for(const candidate of rows){
   if(candidate.created_at>options.asOf||!beforeCursor(candidate,options.cursor))continue;
   live();const f=candidate.frozen_request;
   check(facade.owner(f.scope)===scoped.owner&&(f.scope.owner===undefined&&!f.work_grant_reference||f.scope.owner===scoped.owner)&&f.scope.profile_id===scoped.scope.profile_id&&f.scope.workspace_id===scoped.scope.workspace_id&&hash(f)===candidate.request_hash&&f.source_auth?.subject_id===scoped.principal.subject_id&&f.source_auth.scope_id===scopeID,409,'inbox_binding_conflict');
   const conversation=await tx.get(scoped.owner,'native-chat-conversations',f.conversation_id),turn=await tx.get(scoped.owner,'native-chat-turns',f.turn_id),initialTask=await tx.get(scoped.owner,'tasks',candidate.task_id);
   // Erasure cannot be bypassed by a retained run or a stale pagination cursor.
   if(await sourceDeleted(tx,scoped.owner,candidate,initialTask,conversation,turn))continue;
   check(conversation.subject_id===scoped.principal.subject_id&&conversation.scope_id===scopeID&&turn.subject_id===scoped.principal.subject_id&&turn.scope_id===scopeID&&turn.conversation_id===conversation.id&&turn.id===f.turn_id,409,'inbox_binding_conflict');
   const binding=bindingFor(candidate,turn,scopeID),run=await facade.ownedRun(tx,scoped.owner,candidate.id,scoped.principal,scopeID),d=await facade.ownedDelegation(tx,scoped.owner,run.delegation_id,scoped.principal,{lock:true,scopeID});
   await tx.lock(scoped.owner,'tasks',run.task_id);const task=await tx.get(scoped.owner,'tasks',run.task_id),tag=task?.state?.catpaw;
   check(task?.id===run.task_id&&tag?.run_id===run.id&&['delegation_id','operation_id','request_hash','delegation_revision','grant_epoch'].every(k=>tag[k]===run[k])&&STATUSES.has(task.status),409,'inbox_task_corrupt');
   const projection=await facade.runProjection(tx,scoped.owner,run.id),ctx={...scoped,run,d,task,conversation,purpose:'read_inbox'};
   check(typeof facade.beforeArtifactRead==='function',503,'inbox_authority_not_configured');
   const authority=await facade.beforeArtifactRead(tx,ctx);check(typeof authority?.source_current==='boolean',503,'inbox_authority_not_configured');
   let current=authority.source_current&&projection.run.authorization_state==='current'&&conversation.state==='active'&&conversation.grant_epoch===f.conversation_epoch;
   const view=Object.create(facade);view.repository={transaction:fn=>fn(tx)};view.scoped=async()=>scoped;
   const artifacts=[];let pending=0;
   if(current){
    check(Array.isArray(run.artifact_references)&&run.artifact_references.length<=32&&new Set(run.artifact_references.map(r=>r.artifact_id)).size===run.artifact_references.length,409,'inbox_artifact_corrupt');
    for(const ref of run.artifact_references){const result=await readTaskArtifact(view,auth,scopeID,run.id,ref.artifact_id,{version:ref.version}),a=result.artifact;check(a.is_current&&same(a.current_reference,ref)&&a.content_hash===ref.content_hash,409,'inbox_artifact_corrupt');artifacts.push({artifact_id:a.artifact_id,version:a.version,content_hash:a.content_hash});}
    const actions=await readTaskActions(view,auth,scopeID,run.id);pending=actions.actions.filter(a=>a.approval_status==='pending'&&a.approval_binding_current===true).length;
   }
   const finalAuthority=await facade.beforeArtifactRead(tx,ctx);current=current&&finalAuthority.source_current;
   const plan=projection.plan;let planReference=null;
   if(plan){check(Number.isSafeInteger(plan.applied_revision)&&plan.applied_revision>0&&digest(plan.applied_plan_hash)&&same(task.state.plan_binding,{revision:plan.applied_revision,plan_hash:plan.applied_plan_hash}),409,'inbox_plan_corrupt');planReference={revision:plan.applied_revision,plan_hash:plan.applied_plan_hash};}
   const updated=Date.parse(task.updatedAt??task.createdAt);check(Number.isFinite(updated),409,'inbox_task_corrupt');
   items.push({binding,title:titleFor(task),created_at:run.created_at,updated_at:new Date(Math.max(Date.parse(run.created_at),updated)).toISOString(),task_status:task.status,authorization_state:current?'current':'superseded',artifacts:current?artifacts:[],plan_reference:planReference,pending_action_count:current?pending:0});
   if(items.length>options.limit)break;
  }
  const more=items.length>options.limit;if(more)items.pop();const last=items.at(-1);
  const next_cursor=more?Buffer.from(JSON.stringify({schema_version:1,scope_id:scopeID,subject_id:scoped.principal.subject_id,as_of:options.asOf,after_created_at:last.created_at,after_run_id:last.binding.run_id})).toString('base64url'):null;
  // Revalidate the current viewer after the final awaited source/object read.
  await verifyViewer(tx,scoped);live();
  return {schema_version:1,contract:INBOX_CONTRACT,scope_id:scopeID,subject_id:scoped.principal.subject_id,items,next_cursor};
 });
}
