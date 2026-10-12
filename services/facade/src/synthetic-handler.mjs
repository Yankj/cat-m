// TaskHandler for the real OpenMuse TaskWorker. Curated local data/tools only.
export function syntheticHandler(facade,{beforePublish=async()=>{}}={}) {
  return async(owner,task,context)=>{
    await context.guard();
    if(task.actionId){
      const a=await facade.repository.transaction(tx=>tx.get(owner,'actions',task.actionId));
      if(a?.status==='succeeded')return {status:'succeeded',result:'Synthetic preview completed; no external write'};
      if(a?.status==='outcome_unknown')return {status:'waiting_input',question:'Unknown acknowledgement. Query and reconcile the original approval; do not resend.'};
      return {status:'cancelled',result:'Synthetic preview declined or expired'};
    }
    await facade.publishEvent(owner,task.id,task.leaseId,{kind:'plan',title:'Use synthetic fixture',detail:'No source connectors, network tools or external writes'});
    await beforePublish(task,context);await context.guard();
    const reference=await facade.publishArtifact(owner,task.id,{kind:'report',title:task.title,summary:'Synthetic report only',data:{fixture:task.input.synthetic_fixture_id,lines:['Alpha synthetic record','Beta synthetic record']}},task.leaseId);
    if(task.input.synthetic_fixture_id==='report')return {status:'succeeded',result:'Synthetic report prepared',artifactIds:[reference.artifact_id]};
    const a=await facade.proposePreview(owner,task.id,reference,task.leaseId);
    return {status:'waiting_approval',actionId:a.id,artifactIds:[reference.artifact_id]};
  };
}
