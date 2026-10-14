import {check,hash} from '../facade-r2/src/common.mjs';
import {LOCAL_POLICY} from './local-output-facade.mjs';
import {SOURCE_READS,SOURCE_RECEIPTS} from './task-source-service.mjs';
import {TASK_ACTION_KINDS} from './task-action-contract.mjs';
import {TASK_ARTIFACT_KINDS} from './task-artifact-contract.mjs';
import {TASK_REVISION_KINDS} from './task-revision-contract.mjs';
import {TASK_CONTROL_OPERATIONS} from './task-control-contract.mjs';
export const REQUIRED_PURGE_CAPABILITIES=Object.freeze(['physical_remove_owner_records_same_transaction','erase_foundation_immutable_body_same_transaction','write_primary_purge_tombstone','external_restore_deletion_manifest']);
// A reviewable refs/hash-only plan. No execution/default privilege bypass and no deletion receipt is manufactured.
export async function buildSourcePurgePlan({repository,facade,principal,scope_id,source_id}){
 const scope=principal.scopes.find(s=>s.scope_id===scope_id);check(scope,403,'scope_forbidden');const owner=facade.owner(scope);
 return repository.transaction(async records=>records.withScope(scope_id,async tx=>{
  const source=await tx.get('sources',source_id);check(source,404,'not_found');await records.lock(owner,'native-chat-conversations',source.conversation_id);
  const conversation=await records.get(owner,'native-chat-conversations',source.conversation_id);check(conversation?.subject_id===principal.subject_id&&conversation.scope_id===scope_id,404,'not_found');
  const runs=(await records.list(owner,'catpaw-runs')).filter(r=>r.frozen_request?.conversation_id===conversation.id),runIds=new Set(runs.map(r=>r.id)),taskIds=new Set(runs.map(r=>r.task_id)),delegationIds=new Set(runs.map(r=>r.delegation_id));
  const actions=(await records.list(owner,'actions')).filter(a=>taskIds.has(a.taskId)),actionIds=new Set(actions.map(a=>a.id));
  const targets=[],add=(kind,row)=>targets.push({kind,id:row.id,expected_record_hash:hash(row)});
  for(const kind of ['catpaw-runs','catpaw-delegations','catpaw-operations','tasks','runs','run-events','catpaw-artifact-versions','catpaw-artifact-heads','agent-artifacts','catpaw-artifact-aliases','catpaw-task-projection-versions','catpaw-run-links','actions','catpaw-approval-bindings','catpaw-preview-effects','catpaw-task-plan-heads','catpaw-task-plan-versions','catpaw-task-plan-operations','catpaw-task-plan-checkpoints','catpaw-task-plan-receipts',SOURCE_READS,SOURCE_RECEIPTS,...Object.values(TASK_ACTION_KINDS),...Object.values(TASK_ARTIFACT_KINDS),...Object.values(TASK_REVISION_KINDS),TASK_CONTROL_OPERATIONS]){
   for(const row of await records.list(owner,kind)){
    const hit=kind==='catpaw-runs'?runIds.has(row.id):kind==='catpaw-delegations'?delegationIds.has(row.id):kind==='tasks'?taskIds.has(row.id):kind==='catpaw-task-projection-versions'?runIds.has(row.id):kind==='actions'||kind==='catpaw-preview-effects'?actionIds.has(row.id):runIds.has(row.run_id)||taskIds.has(row.task_id)||taskIds.has(row.taskId);
    if(hit||(kind===TASK_CONTROL_OPERATIONS||Object.values(TASK_REVISION_KINDS).includes(kind))&&(row.conversation_id===conversation.id||row.frozen?.conversation_id===conversation.id))add(kind,row);
   }
  }
  const artifactIds=new Set((await records.list(owner,'catpaw-artifact-versions')).filter(a=>runIds.has(a.run_id)).map(a=>a.artifact_id));
  for(const kind of ['catpaw-artifact-heads','agent-artifacts'])for(const row of await records.list(owner,kind))if(artifactIds.has(row.id)&&!targets.some(t=>t.kind===kind&&t.id===row.id))add(kind,row);
  const projections=[];
  for(const kind of ['approvals','artifacts','bindings'])for(const row of await tx.list(kind))if(runIds.has(row.run_id))projections.push({kind,id:row.id,expected_record_hash:hash(row),requires_immutable_erasure:true});
  const blocked=[];if(runs.some(r=>r.frozen_request.policy!==LOCAL_POLICY))blocked.push('non_local_execution_policy');
  const tasks=(await records.list(owner,'tasks')).filter(t=>taskIds.has(t.id));if(tasks.some(t=>['running','queued','scheduled','paused','waiting_input','waiting_approval'].includes(t.status)))blocked.push('revoke_and_fence_active_execution_before_purge');
  if(actions.some(a=>['executing','outcome_unknown'].includes(a.status)))blocked.push('reconcile_unknown_action_before_purge');
  const turns=(await records.list(owner,'native-chat-turns')).filter(t=>t.conversation_id===conversation.id);
  const plan={schema_version:1,contract:'catpaw.source-purge.plan.v1',scope_id,conversation_id:conversation.id,source_id,source_hash:source.content_hash,expected_conversation_revision:conversation.revision,expected_grant_epoch:conversation.grant_epoch,expected_memory_generation:(await tx.scope()).generation,
   owner_records:targets.sort((a,b)=>(a.kind+a.id).localeCompare(b.kind+b.id)),foundation_projections:projections.sort((a,b)=>(a.kind+a.id).localeCompare(b.kind+b.id)),chat_turn_ids:turns.map(t=>t.id).sort(),required_capabilities:REQUIRED_PURGE_CAPABILITIES,blocked,
   execute_supported:false,default_result:'purge_store_capability_not_configured',backups:'not_verified',external_model_requests:'cannot_recall',steps:['verify_authenticated_subject_scope_and_plan_hash','revoke_grants_cancel_tasks_and_fence_late_writes','verify_current_record_hashes_in_one_scope_transaction','erase_foundation_approval_artifact_body_and_binding_projections','physically_remove_owner_raw_records_and_original_chat_copies','advance_memory_generation_cancel_outbox_and_write_refs_only_tombstone','publish_external_deletion_manifest_and_verify_before_any_backup_restore']};
  return {...plan,plan_hash:hash(plan)};
 }));
}
