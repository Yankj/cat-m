import {check,hash,iso} from '../facade-r2/src/common.mjs';
import {stableUUID} from './local-output-facade.mjs';
// Version of a persisted read projection, not an invented Task mutation/attempt number.
export function attachFoundationProjections(runtime){
 const {facade,repository,foundation}=runtime;
 foundation.taskReader=async({principal,scope_id,binding})=>{
  const scope=principal.scopes.find(s=>s.scope_id===scope_id);check(scope,403,'scope_forbidden');const owner=facade.owner(scope);
  return repository.transaction(async tx=>{
   if(facade.memoryGenerationEnabled)await tx.withScope(scope_id,async()=>{});
   const run=await facade.ownedRun(tx,owner,binding.run_id,principal,scope_id);check(run.task_id===binding.task_id,404,'not_found');
   await tx.lock(owner,'catpaw-delegations',run.delegation_id);
   const projection=await facade.runProjection(tx,owner,run.id),task=await tx.get(owner,'tasks',run.task_id);
   const authoritative={scope_id,task_id:run.task_id,status:projection.run.state,authorization_state:projection.run.authorization_state,grant_epoch:projection.run.grant_epoch,updated_at:task.updatedAt};
   const digest=hash({authoritative,artifacts:projection.run.artifact_references,attempts:projection.run.attempts,...projection.plan?{plan:projection.plan}:{}});
   await tx.lock(owner,'catpaw-task-projection-versions',run.id);const prior=await tx.get(owner,'catpaw-task-projection-versions',run.id);
   const record=prior?.projection_hash===digest?prior:{id:run.id,scope_id,subject_id:principal.subject_id,projection_hash:digest,version:(prior?.version??0)+1,version_kind:'owner_projection_revision',updated_at:iso()};
   if(record!==prior)await tx.put(owner,'catpaw-task-projection-versions',record);
   return {...authoritative,version:record.version};
  });
 };
 runtime.syncArtifactProjections=async(auth,scope_id,runId)=>{
  const {owner,principal}=await facade.scoped(auth,scope_id);
  const run=await facade.readRun(auth,scope_id,runId);
  const refs=await repository.transaction(async tx=>(await tx.list(owner,'catpaw-artifact-versions')).filter(a=>a.run_id===runId).map(a=>({artifact_id:a.artifact_id,version:a.version})));
  const results=[];
  for(const ref of refs){
   const {artifact:a}=await facade.readArtifact(auth,scope_id,ref.artifact_id,ref.version);
   const projectionId=stableUUID(`catpaw-artifact-projection:${owner}:${scope_id}:${a.artifact_id}`);
   const alias={id:projectionId,scope_id,subject_id:principal.subject_id,canonical_artifact_id:a.artifact_id,run_id:runId,task_id:run.task.id,alias_kind:'foundation_uuid_projection_only'};
   await repository.transaction(async tx=>{const inserted=await tx.insertIfAbsent(owner,'catpaw-artifact-aliases',alias);const old=inserted??await tx.get(owner,'catpaw-artifact-aliases',projectionId);check(hash(old)===hash(alias),409,'artifact_alias_conflict');});
   const projection=await foundation.recordArtifact(principal,scope_id,{artifact_id:projectionId,version:a.version,content_hash:a.content_hash,body:a.body,run_id:runId,task_id:run.task.id});
   results.push({canonical_reference:{artifact_id:a.artifact_id,version:a.version,content_hash:a.content_hash},foundation_projection_id:projectionId,projection_row_id:projection.id});
  }
  return results;
 };
 return runtime;
}
