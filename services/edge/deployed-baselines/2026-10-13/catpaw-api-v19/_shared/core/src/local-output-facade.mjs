import {evaluateReport,completionAuthorityValid} from './report-completion.mjs';
import { Facade } from '../facade-r2/src/facade.mjs';
import { check,hash,iso,clone,shape,immutableBody } from '../facade-r2/src/common.mjs';
export const LOCAL_POLICY='conversation-local-output-v1';
export function stableUUID(text) {
  const h=hash(text);return `${h.slice(0,8)}-${h.slice(8,12)}-4${h.slice(13,16)}-8${h.slice(17,20)}-${h.slice(20,32)}`;
}
export class LocalOutputFacade extends Facade {
  // A caller cannot use r2's synthetic POST admission to execute model work.
  async createDelegation(){throw new Error('Chat tool admission only');}
  async createRun(){throw new Error('Chat tool admission only');}
  async proposePreview(){throw new Error('External or preview action unsupported in local-output pilot');}
  // Every public projection resolves the immutable chat subject inside the same transaction.
  async ownedRun(tx,owner,id,principal,scopeID) {
    const r=await tx.get(owner,'catpaw-runs',id);
    check(r?.frozen_request?.subject_id===principal.subject_id&&(!scopeID||r.frozen_request.scope.scope_id===scopeID),404,'not_found');
    const c=await tx.get(owner,'native-chat-conversations',r.frozen_request.conversation_id);
    check(c?.subject_id===principal.subject_id,404,'not_found');return r;
  }
  async ownedDelegation(tx,owner,id,principal,{lock=false,scopeID}={}) {
    const d=await this.delegation(tx,owner,id,{lock});
    const c=await tx.get(owner,'native-chat-conversations',d.conversation_id);
    check(c?.subject_id===principal.subject_id&&(!scopeID||c.scope_id===scopeID)&&(d.subject_id===undefined||d.subject_id===principal.subject_id),404,'not_found');return d;
  }
  async guarded(auth,scopeID,resolve,method,args) {
    const scoped=await this.scoped(auth,scopeID);
    return this.repository.transaction(async tx=>{
      await resolve(tx,scoped.owner,scoped.principal,scopeID);
      const view=Object.create(this);view.repository={transaction:fn=>fn(tx)};view.scoped=async()=>scoped;
      return Facade.prototype[method].call(view,auth,scopeID,...args);
    });
  }
  async readDelegation(auth,scope,id){return this.guarded(auth,scope,(tx,o,p,s)=>this.ownedDelegation(tx,o,id,p,{scopeID:s}),'readDelegation',[id]);}
  async readRun(auth,scope,id){return this.guarded(auth,scope,(tx,o,p,s)=>this.ownedRun(tx,o,id,p,s),'readRun',[id]);}
  async readOperation(auth,scope,id){return this.guarded(auth,scope,async(tx,o,p,s)=>{const v=await tx.get(o,'catpaw-operations',id);check(v,404,'not_found');await this.ownedRun(tx,o,v.run_id,p,s);},'readOperation',[id]);}
  async readArtifact(auth,scope,id,version){return this.guarded(auth,scope,async(tx,o,p,s)=>{const v=await tx.get(o,'catpaw-artifact-versions',`${id}:${version}`);check(v,404,'not_found');await this.ownedRun(tx,o,v.run_id,p,s);},'readArtifact',[id,version]);}
  async ownedApproval(tx,o,id,p,s){const b=await tx.get(o,'catpaw-approval-bindings',id);check(b,404,'not_found');await this.ownedRun(tx,o,b.run_id,p,s);}
  async readApproval(auth,scope,id){return this.guarded(auth,scope,(tx,o,p,s)=>this.ownedApproval(tx,o,id,p,s),'readApproval',[id]);}
  async decide(auth,scope,id,input){return this.guarded(auth,scope,(tx,o,p,s)=>this.ownedApproval(tx,o,id,p,s),'decide',[id,input]);}
  async reconcile(auth,scope,id){return this.guarded(auth,scope,(tx,o,p,s)=>this.ownedApproval(tx,o,id,p,s),'reconcile',[id]);}
  async control(auth,scopeID,id,input) {
    shape(input,['action','expected_revision','expected_grant_epoch']);
    check(['pause','resume','revoke'].includes(input.action)&&Number.isSafeInteger(input.expected_revision)&&input.expected_revision>0&&Number.isSafeInteger(input.expected_grant_epoch)&&input.expected_grant_epoch>0,422,'schema_invalid');
    const {owner,principal}=await this.scoped(auth,scopeID);
    const result=await this.repository.transaction(async tx=>{
      const d=await this.ownedDelegation(tx,owner,id,principal,{lock:true,scopeID});
      check(d.revision===input.expected_revision,409,'revision_conflict');check(d.grant_epoch===input.expected_grant_epoch,409,'grant_conflict');
      check(d.state!=='revoked'&&((input.action==='resume'&&d.state==='paused')||(input.action!=='resume'&&d.state==='active')),409,'grant_conflict');
      const next={...d,revision:d.revision+1,grant_epoch:d.grant_epoch+1,state:{pause:'paused',resume:'active',revoke:'revoked'}[input.action]};
      await tx.put(owner,'catpaw-delegations',next);const stopped=[];
      for(const task of await tx.list(owner,'tasks'))if(task.state?.catpaw?.delegation_id===id&&!['succeeded','failed','cancelled'].includes(task.status)){
        await tx.put(owner,'tasks',{...task,status:input.action==='revoke'?'cancelled':'paused',leaseId:null,leaseUntil:null,updatedAt:iso()});stopped.push(task.id);
      }
      return {envelope:this.envelope({delegation:next}),stopped};
    });
    for(const taskID of result.stopped)this.abortTask(taskID);return result.envelope;
  }
  async runProjection(tx,owner,id){
    let generationCurrent=true;
    if(this.memoryGenerationEnabled){const run=await tx.get(owner,'catpaw-runs',id);check(run?.frozen_request?.scope,404,'not_found');await tx.withScope(run.frozen_request.scope.scope_id,async scoped=>{generationCurrent=(await scoped.scope()).generation===run.frozen_request.memory_generation;});}
    const projection=await super.runProjection(tx,owner,id);if(!generationCurrent)projection.run.authorization_state='superseded';return projection;
  }
  async admittedTask(tx,owner,id,options={}) {
    if(this.memoryGenerationEnabled){
      const task=await tx.get(owner,'tasks',id),run=task?.state?.catpaw?await tx.get(owner,'catpaw-runs',task.state.catpaw.run_id):null;
      check(run?.frozen_request?.scope,409,'unmanaged_task');
      await tx.withScope(run.frozen_request.scope.scope_id,async scoped=>{const row=await scoped.scope();check(row.identity.owner===owner&&row.generation===run.frozen_request.memory_generation,409,'memory_generation_superseded');});
    }
    return super.admittedTask(tx,owner,id,options);
  }
  async publishArtifact(owner,taskID,artifact,leaseID){return this.repository.transaction(tx=>this.publishArtifactInTransaction(tx,owner,taskID,artifact,leaseID));}
  async publishArtifactInTransaction(tx,owner,taskID,artifact,leaseID,{assertLive=()=>{}}={}) {
      // Only the bounded composition injects this step permission. All writes stay in the supplied transaction.
      const waited=async operation=>{assertLive();const result=await operation();assertLive();return result;};
      const {task,run}=await waited(()=>this.admittedTask(tx,owner,taskID,{running:true}));check(task.leaseId===leaseID,409,'lease_lost');
      check(['plan','report','comparison'].includes(artifact.kind),422,'schema_invalid');
      const artifactID=hash(`${taskID}:synthetic-report`),body=immutableBody(artifact),contentHash=hash(body);
      const previous=await waited(()=>tx.get(owner,'catpaw-artifact-heads',artifactID));
      if(previous?.content_hash===contentHash)return previous;
      const ref={artifact_id:artifactID,version:(previous?.version??0)+1,content_hash:contentHash};
      const version={id:`${artifactID}:${ref.version}`,...ref,mime_type:'application/json',body,run_id:run.id,task_id:taskID,created_at:iso()};
      check(await waited(()=>tx.insertIfAbsent(owner,'catpaw-artifact-versions',version)),409,'revision_conflict');
      await waited(()=>tx.put(owner,'catpaw-artifact-heads',{id:artifactID,...ref}));
      await waited(()=>tx.put(owner,'agent-artifacts',{id:artifactID,taskId:taskID,...artifact,createdAt:version.created_at}));
      const refs=run.artifact_references.filter(r=>r.artifact_id!==artifactID);refs.push(ref);
      await waited(()=>tx.put(owner,'catpaw-runs',{...run,artifact_references:refs}));
      await waited(()=>tx.put(owner,'tasks',{...task,artifactIds:[...new Set([...task.artifactIds,artifactID])],updatedAt:iso()}));
      for(const b of await waited(()=>tx.list(owner,'catpaw-approval-bindings')))if(b.artifact_reference.artifact_id===artifactID&&b.artifact_reference.version!==ref.version){
        const a=await waited(()=>tx.get(owner,'actions',b.id));
        if(a?.status==='awaiting_review')await waited(()=>this.decideInTransaction(tx,owner,a,'deny'));
      }
      assertLive();return ref;
  }
  async assertTaskCompletion(owner,taskID,reference,leaseID,{receipt=false}={}) {
    return this.repository.transaction(async tx=>{
      const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});check(task.leaseId===leaseID,409,'lease_lost');
      check(reference,422,'artifact_required_before_finish');
      const current=run.artifact_references.find(r=>r.artifact_id===reference.artifact_id);
      check(current&&current.version===reference.version&&current.content_hash===reference.content_hash,409,'completion_artifact_superseded');
      const artifact=await tx.get(owner,'catpaw-artifact-versions',`${reference.artifact_id}:${reference.version}`);
      check(artifact?.task_id===taskID&&artifact.run_id===run.id&&artifact.content_hash===reference.content_hash&&hash(artifact.body)===reference.content_hash,409,'completion_artifact_binding_conflict');
      const frozen=run.frozen_request,contract=frozen.completion_contract;
      check(frozen.run_binding?.run_id===run.id&&frozen.run_binding.task_id===taskID&&frozen.run_binding.operation_id===run.operation_id&&frozen.run_binding.delegation_id===run.delegation_id,409,'completion_run_binding_conflict');
      check(contract?.schema_version===1&&contract.version===1,422,'completion_contract_required');
      let body;try{body=JSON.parse(artifact.body);}catch{throw new ApiError(422,'invalid_completion_artifact');}
      check(body.kind==='report'&&typeof body.data?.content==='string'&&body.data.content.trim().length>0,422,'invalid_completion_artifact');
      if(contract.mode==='model_finish_local_artifact'){check(!receipt,422,'structured_completion_intent_required');return {valid:true,mode:contract.mode,artifact_reference:clone(current)};}
      check(contract.mode==='single_local_report'&&completionAuthorityValid(frozen),422,'structured_completion_intent_required');
      const validation=evaluateReport(frozen,{title:body.title,summary:body.summary,content:body.data.content});
      check(validation.valid,422,'report_completion_condition_not_met');return validation;
    });
  }
  async admitChatTask(tx,{owner,scope,conversation,turn,call}) {
    const ids=Object.fromEntries(['delegation_id','operation_id','run_id'].map(k=>[k,stableUUID(`${turn.id}:${call.id}:${k}`)]));
    let memoryGeneration=null;if(this.memoryGenerationEnabled)await tx.withScope(scope.scope_id,async scoped=>{memoryGeneration=(await scoped.scope()).generation;});
    const taskID=hash(`catpaw-task:${owner}:${ids.operation_id}`),runBinding={...ids,task_id:taskID};
    const intent=turn.completion_intent;
    const completionContract={schema_version:1,version:1,mode:this.completionPolicy?(intent?'single_local_report':'explicit_intent_required'):'model_finish_local_artifact'};
    const authority=intent?{...clone(intent),...runBinding}:null;
    const frozen={...turn.source_auth?{source_auth:clone(turn.source_auth)}:{},completion_contract:completionContract,run_binding:runBinding,current_input_hash:hash(turn.input),...authority?{completion_authority:authority}:{},...memoryGeneration?{memory_generation:memoryGeneration}:{},scope,subject_id:conversation.subject_id,conversation_id:conversation.id,conversation_epoch:conversation.grant_epoch,
      turn_id:turn.id,user_message_id:turn.input.message.id,call_id:call.id,args:clone(call.arguments),messages:clone(turn.history),context:clone(turn.input.context),
      model_configuration:this.modelConfiguration,policy:LOCAL_POLICY,...this.completionPolicy?{completion_policy:clone(this.completionPolicy)}:{}};
    const requestHash=hash(frozen),prior=await tx.get(owner,'catpaw-operations',ids.operation_id);
    if(prior){check(prior.request_hash===requestHash,409,'tool_call_conflict');return this.binding(scope,conversation,turn,call,await tx.get(owner,'catpaw-runs',prior.run_id));}
    check(!await tx.get(owner,'catpaw-runs',ids.run_id),409,'run_conflict');
    const now=iso();
    const d={id:ids.delegation_id,revision:1,grant_epoch:1,state:'active',request_hash:hash({...frozen,kind:'delegation'}),
      ...call.arguments,policy:LOCAL_POLICY,subject_id:conversation.subject_id,conversation_id:conversation.id,created_at:now};
    const tag={...ids,delegation_revision:1,grant_epoch:1,request_hash:requestHash};
    const task={id:taskID,title:d.title,prompt:d.goal,kind:'agent',status:'queued',plan:[],evidence:[],input:{policy:LOCAL_POLICY},state:{catpaw:tag},
      createdAt:now,updatedAt:now,attempts:0,leaseId:null,leaseUntil:null,artifactIds:[]};
    const run={id:ids.run_id,...tag,task_id:taskID,frozen_request:frozen,artifact_references:[],approval_ids:[],created_at:now};
    check(await tx.insertIfAbsent(owner,'catpaw-delegations',d),409,'operation_conflict');
    check(await tx.insertIfAbsent(owner,'catpaw-operations',{id:ids.operation_id,run_id:ids.run_id,request_hash:requestHash}),409,'operation_conflict');
    check(await tx.insertIfAbsent(owner,'catpaw-runs',run),409,'run_conflict');
    check(await tx.insertIfAbsent(owner,'tasks',task),409,'operation_conflict');
    return this.binding(scope,conversation,turn,call,run);
  }
  binding(scope,c,t,call,r){return {scope_id:scope.scope_id,conversation_id:c.id,turn_id:t.id,call_id:call.id,delegation_id:r.delegation_id,
    operation_id:r.operation_id,run_id:r.id,task_id:r.task_id,request_hash:r.request_hash,delegation_revision:r.delegation_revision,grant_epoch:r.grant_epoch,
    projection_url:`/catpaw/v1/scopes/${scope.scope_id}/runs/${r.id}`};}
}
