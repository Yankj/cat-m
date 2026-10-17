import { check,hash,iso } from '../facade-r2/src/common.mjs';
import {collectTaskWorkGrantPurgeRecordsInTransaction} from './task-work-grant-lifecycle.mjs';
// Current-primary-store erasure only. An execution/artifact purge journal is a separate unresolved contract.
export async function eraseChatSource({records,principal,scope_id,source}){
  const scope=principal.scopes.find(s=>s.scope_id===scope_id);check(scope,403,'scope_forbidden');
  const owner=`catpaw:${hash({profile:scope.profile_id,workspace:scope.workspace_id})}`;
  await records.lock(owner,'native-chat-conversations',source.conversation_id);
  const c=await records.get(owner,'native-chat-conversations',source.conversation_id);
  check(c?.subject_id===principal.subject_id&&c.scope_id===scope_id,404,'not_found');
  // An explicit memory command is its own authenticated source, never a chat message copy.
  if(source.type==='user_memory_command'){check(source.authenticated_actor_id===principal.subject_id&&source.command_id,403,'scope_forbidden');return;}
  const runs=(await records.list(owner,'catpaw-runs')).filter(r=>r.frozen_request?.conversation_id===c.id);
  const plans=(await records.list(owner,'catpaw-task-plan-heads')).filter(r=>r.conversation_id===c.id);
  let retainedExecution=false;
  for(const kind of ['catpaw-task-source-reads','catpaw-task-source-receipts','catpaw-task-actions','catpaw-task-action-proposals','catpaw-task-action-decisions','catpaw-task-artifact-operations','catpaw-task-artifact-receipts','catpaw-task-revision-operations','catpaw-task-revision-results','catpaw-task-revision-artifact-receipts','catpaw-task-control-operations'])if((await records.list(owner,kind)).some(r=>r.conversation_id===c.id||r.frozen?.conversation_id===c.id))retainedExecution=true;
  const work=await collectTaskWorkGrantPurgeRecordsInTransaction(records,{owner,scope_id,subject_id:principal.subject_id,conversation_id:c.id,runs});
  check(runs.length===0&&plans.length===0&&!retainedExecution&&work.records.length===0&&work.blocked.length===0,409,'source_eraser_requires_execution_purge');
  const turns=(await records.list(owner,'native-chat-turns')).filter(t=>t.conversation_id===c.id);
  const affected=turns.filter(t=>t.id===source.turn_id||t.history.some(m=>m.id===source.id));
  const assistantIDs=new Set(affected.flatMap(t=>t.events.filter(e=>e.type==='turn_completed').map(e=>e.data.message_id)));
  const removedIDs=new Set([source.id,...assistantIDs]);
  const messages=c.messages.filter(m=>!removedIDs.has(m.id));
  // Rebuild model history from remaining authoritative messages; tool history is redundant and cannot retain deleted copies.
  // B5 (context-memory PLAN Rev 2): derived copies on the same row go in the same write: next-turn notes (shown text ≤300 chars,
  // tool titles), interaction outcomes, device undo notes, the v1.2 summary/ledger, and the turn meta (recomputed next turn).
  const {context_summary,context_ledger,model_message_meta,...kept}=c;
  await records.put(owner,'native-chat-conversations',{...kept,state:c.state==='revoked'?'revoked':'paused',revision:c.revision+1,grant_epoch:c.grant_epoch+1,messages,model_messages:messages.map(({id,...m})=>m),turn_outcome_notes:[],device_undo_notes:[],interaction_outcomes:[],source_purged_at:iso()});
  for(const t of affected){
    const input={...t.input,message:t.input.message.id===source.id?{...t.input.message,text:''}:t.input.message,context:[]};
    let events=t.events.map(e=>e.type==='turn_started'&&e.data.attachment_receipts?{...e,data:{...e.data,attachment_receipts:[],content_redacted:true}}:e.type==='turn_completed'&&e.data.provider_receipt?{...e,data:{...e.data,provider_receipt:null,content_redacted:true}}:e.type==='text_delta'?{...e,data:{...e.data,text:'',content_redacted:true}}:e.type==='tool_call'?{...e,data:{call_id:e.data.call_id,name:e.data.name,content_redacted:true}}:e.type==='tool_result'?{...e,data:{call_id:e.data.call_id,name:e.data.name,content_redacted:true}}:e);
    const error={code:'source_deleted',retryable:false,reconciliation_required:false};
    if(t.state==='running')events.push({schema_version:1,contract:'catpaw.native-chat.v1',scope_id:t.scope_id,conversation_id:c.id,turn_id:t.id,sequence:events.length+1,cursor:`${t.id}:${events.length+1}`,grant_epoch:t.grant_epoch,model_reality:t.events[0]?.model_reality??'provider_unverified',type:'turn_failed',data:error});
    await records.put(owner,'native-chat-turns',{...t,input,history:t.history.filter(m=>!removedIDs.has(m.id)),model_history:[],revision_target:null,dispatch_checkpoint:null,continuations:[],events,content_redacted:true,...t.vision_provider_receipt?{vision_provider_receipt:null}: {},...t.image_attachments?{image_attachments:[]}: {},...t.state==='running'?{state:'failed',error,finished_at:iso()}:{} });
  }
  // Assistant sources derived from the erased turn/history are also copies in this same primary store.
  await records.withScope(scope_id,async tx=>{for(const s of await tx.list('sources'))if(assistantIDs.has(s.id))await tx.put('sources',{...s,text:'',deleted_at:iso(),suppressed_for_memory:true});});
}
