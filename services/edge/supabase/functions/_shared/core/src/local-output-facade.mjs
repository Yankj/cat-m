import {evaluateReport,completionAuthorityValid} from './report-completion.mjs';
import { Facade } from '../facade-r2/src/facade.mjs';
import { ApiError,check,hash,iso,clone,shape,immutableBody } from '../facade-r2/src/common.mjs';
import {samePlan} from './plan-contract.mjs';
import {freezePublicSourceCatalog,policyTargetForURL} from './public-source-contract.mjs';
import {invalidatePendingTaskActionsInTransaction} from './task-action-service.mjs';
import {createTaskPlan,planSnapshot,readTaskPlan,amendTaskPlan,applyPendingPlan,effectiveTaskRequest,recordPlanReceipt,completionPlanCheck,taskPlanCheckpointReady,taskPlanExecutionDisposition} from './task-plan-service.mjs';
import {taskRevisionContextInTransaction,recordTaskRevisionResultInTransaction,recordTaskRevisionArtifactReceiptInTransaction} from './task-revision-service.mjs';
import {workerExecutionContext} from './task-control-contract.mjs';
export const LOCAL_POLICY='conversation-local-output-v1';
export function stableUUID(text) {
  const h=hash(text);return `${h.slice(0,8)}-${h.slice(8,12)}-4${h.slice(13,16)}-8${h.slice(17,20)}-${h.slice(20,32)}`;
}
export class LocalOutputFacade extends Facade {
  async readPlan(auth,scope,runID){return readTaskPlan(this,auth,scope,runID);}
  async readPlanAmendment(auth,scope,runID,operationID){return readTaskPlan(this,auth,scope,runID,operationID);}
  async amendPlan(auth,scope,runID,input){return amendTaskPlan(this,auth,scope,runID,input);}
  async effectiveRequest(owner,taskID){return this.repository.transaction(async tx=>{const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true}),frozen=await effectiveTaskRequest(tx,owner,run,task),revision=await taskRevisionContextInTransaction(this,tx,owner,run,task);return {...frozen,task_execution:workerExecutionContext(run,task),...revision?{task_revision_context:revision}:{}};});}
  async planCheckpointReady(owner,taskID,leaseID){return this.repository.transaction(async tx=>{const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});check(task.leaseId===leaseID,409,'lease_lost');return taskPlanCheckpointReady(tx,owner,run,task);});}
  async planExecutionDisposition(owner,taskID,leaseID){return this.repository.transaction(async tx=>{const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});check(task.leaseId===leaseID,409,'lease_lost');return taskPlanExecutionDisposition(tx,owner,run,task);});}
  async applyPlanCheckpoint(tx,owner,taskID,leaseID,{assertLive=()=>{}}={}){
    assertLive();const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});assertLive();check(task.leaseId===leaseID,409,'lease_lost');
    await tx.lock(owner,'catpaw-task-plan-heads',run.id);assertLive();const head=await tx.get(owner,'catpaw-task-plan-heads',run.id);
    const result=await applyPendingPlan(tx,owner,run,task,head,{running:true});assertLive();await this.admittedTask(tx,owner,taskID,{running:true});assertLive();return result;
  }
  async recordModelPlanReceipt(owner,taskID,leaseID,{assertLive=()=>{}}={}){return this.repository.transaction(async tx=>{
    assertLive();const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});assertLive();check(task.leaseId===leaseID,409,'lease_lost');
    const round=task.state.local_model?.round;check(round?.state==='received',409,'model_response_receipt_required');
    // A received model plan is not evidence that public documents were read or composed.
    if(run.frozen_request.public_sources)return;
    await recordPlanReceipt(tx,owner,run,task,'compose',{request_hash:round.request_hash??hash({messages:task.state.local_model.messages}),text:round.text,calls:round.calls});assertLive();await this.admittedTask(tx,owner,taskID,{running:true});assertLive();
  });}
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
    // The historical delegation route cannot resume an immutable admitted grant.
    // Native task execution control uses the additive, recoverable task contract.
    check(input.action!=='resume',409,'control_resume_requires_task_contract');
    const {owner,principal}=await this.scoped(auth,scopeID);
    const result=await this.repository.transaction(async tx=>{
      const d=await this.ownedDelegation(tx,owner,id,principal,{lock:true,scopeID});
      check(d.revision===input.expected_revision,409,'revision_conflict');check(d.grant_epoch===input.expected_grant_epoch,409,'grant_conflict');
      check(d.state!=='revoked'&&((input.action==='resume'&&d.state==='paused')||(input.action!=='resume'&&d.state==='active')),409,'grant_conflict');
      const next={...d,revision:d.revision+1,grant_epoch:d.grant_epoch+1,state:{pause:'paused',resume:'active',revoke:'revoked'}[input.action]};
      await tx.put(owner,'catpaw-delegations',next);const stopped=[];
      for(const run of await tx.list(owner,'catpaw-runs'))if(run.delegation_id===id)await invalidatePendingTaskActionsInTransaction(tx,owner,{run_id:run.id,task_id:run.task_id,reason:'grant_changed'});
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
    const projection=await super.runProjection(tx,owner,id);if(!generationCurrent)projection.run.authorization_state='superseded';
    const run=await tx.get(owner,'catpaw-runs',id),task=await tx.get(owner,'tasks',run.task_id),plan=await planSnapshot(tx,owner,run,task);if(plan)projection.plan=plan;return projection;
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
      const revision=await waited(()=>taskRevisionContextInTransaction(this,tx,owner,run,task,{assertLive}));
      if(revision){
        check(artifact.kind==='report',409,'revision_result_kind_conflict');
        const {operation_id,operation_hash,base_reference,plan_reference,instruction_hash}=revision;
        artifact={...clone(artifact),data:{...clone(artifact.data),model_revision:{operation_id,operation_hash,base_reference,plan_reference,instruction_hash}}};
      }
      const artifactID=hash(`${taskID}:synthetic-report`),body=immutableBody(artifact),contentHash=hash(body);
      const previous=await waited(()=>tx.get(owner,'catpaw-artifact-heads',artifactID));
      const planReference=task.state.plan_binding;
      if(revision){
        check(artifactID===revision.base_reference.artifact_id&&previous&&previous.version>=revision.base_reference.version,409,'revision_artifact_conflict');
        if(previous.version===revision.base_reference.version)check(previous.content_hash===revision.base_reference.content_hash,409,'revision_artifact_conflict');
        else {
          const prior=await waited(()=>tx.get(owner,'catpaw-artifact-versions',`${artifactID}:${previous.version}`));
          let body;try{body=JSON.parse(prior?.body);}catch{throw new ApiError(409,'revision_result_binding_conflict');}
          check(hash(prior.body)===prior.content_hash&&samePlan(prior.plan_reference,revision.plan_reference)&&hash(body.data?.model_revision)===hash(artifact.data.model_revision),409,'revision_result_binding_conflict');
        }
      }
      if(previous?.content_hash===contentHash&&(!planReference||samePlan(previous.plan_reference,planReference))){await waited(()=>recordPlanReceipt(tx,owner,run,task,'save',{artifact_reference:previous}));if(revision){const row=await waited(()=>tx.get(owner,'catpaw-artifact-versions',`${artifactID}:${previous.version}`));await waited(()=>recordTaskRevisionArtifactReceiptInTransaction(this,tx,owner,run,task,row,{assertLive}));}return {artifact_id:previous.artifact_id,version:previous.version,content_hash:previous.content_hash};}
      const ref={artifact_id:artifactID,version:(previous?.version??0)+1,content_hash:contentHash};
      const version={id:`${artifactID}:${ref.version}`,...ref,...planReference?{plan_reference:clone(planReference)}:{},mime_type:'application/json',body,run_id:run.id,task_id:taskID,created_at:iso()};
      check(await waited(()=>tx.insertIfAbsent(owner,'catpaw-artifact-versions',version)),409,'revision_conflict');
      await waited(()=>tx.put(owner,'catpaw-artifact-heads',{id:artifactID,...ref,...planReference?{plan_reference:clone(planReference)}:{}}));
      await waited(()=>tx.put(owner,'agent-artifacts',{id:artifactID,taskId:taskID,...artifact,createdAt:version.created_at}));
      const refs=run.artifact_references.filter(r=>r.artifact_id!==artifactID);refs.push(ref);
      await waited(()=>tx.put(owner,'catpaw-runs',{...run,artifact_references:refs}));
      await waited(()=>tx.put(owner,'tasks',{...task,artifactIds:[...new Set([...task.artifactIds,artifactID])],updatedAt:iso()}));
      await waited(()=>recordPlanReceipt(tx,owner,run,task,'save',{artifact_reference:ref}));
      await waited(()=>recordTaskRevisionArtifactReceiptInTransaction(this,tx,owner,run,task,version,{assertLive}));
      await waited(()=>invalidatePendingTaskActionsInTransaction(tx,owner,{run_id:run.id,task_id:taskID,reason:'artifact_changed'}));
      for(const b of await waited(()=>tx.list(owner,'catpaw-approval-bindings')))if(b.artifact_reference.artifact_id===artifactID&&b.artifact_reference.version!==ref.version){
        const a=await waited(()=>tx.get(owner,'actions',b.id));
        if(a?.status==='awaiting_review')await waited(()=>this.decideInTransaction(tx,owner,a,'deny'));
      }
      await waited(()=>this.admittedTask(tx,owner,taskID,{running:true}));assertLive();return ref;
  }
  async publishSourcedReportInTransaction(tx,owner,taskID,args,leaseID,{assertLive=()=>{}}={}){
    assertLive();const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});assertLive();
    check(task.leaseId===leaseID&&this.sourceService&&run.frozen_request.public_sources,409,'source_service_not_configured');
    const bound=await this.sourceService.validateCitationsInTransaction(tx,owner,run,task,args.citations);assertLive();
    await recordPlanReceipt(tx,owner,run,task,'compose',{source_receipts:bound.receipt_references,report_hash:hash(args)});assertLive();
    return this.publishArtifactInTransaction(tx,owner,taskID,{kind:'report',title:args.title,summary:args.summary,data:{content:args.content,source:'public_sources',source_contract:'sourced-report-v1',conversation_id:run.frozen_request.conversation_id,updated_at:iso(),sources:bound.sources,citations:bound.citations,source_receipt_references:bound.receipt_references}},leaseID,{assertLive});
  }
  async assertTaskCompletion(owner,taskID,reference,leaseID,{receipt=false,assertLive=()=>{}}={}) {
    return this.repository.transaction(async tx=>{
      assertLive();const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});assertLive();check(task.leaseId===leaseID,409,'lease_lost');
      const completed=async validation=>{await recordPlanReceipt(tx,owner,run,task,'verify',validation);assertLive();const fresh=await this.admittedTask(tx,owner,taskID,{running:true});assertLive();await recordTaskRevisionResultInTransaction(this,tx,owner,fresh.run,fresh.task,artifact,{assertLive});assertLive();await this.admittedTask(tx,owner,taskID,{running:true});assertLive();return validation;};
      check(reference,422,'artifact_required_before_finish');
      const current=run.artifact_references.find(r=>r.artifact_id===reference.artifact_id);
      check(current&&current.version===reference.version&&current.content_hash===reference.content_hash,409,'completion_artifact_superseded');
      const artifact=await tx.get(owner,'catpaw-artifact-versions',`${reference.artifact_id}:${reference.version}`);
      check(artifact?.task_id===taskID&&artifact.run_id===run.id&&artifact.content_hash===reference.content_hash&&hash(artifact.body)===reference.content_hash,409,'completion_artifact_binding_conflict');
      await completionPlanCheck(tx,owner,run,task,artifact);
      const frozen=await effectiveTaskRequest(tx,owner,run,task),contract=frozen.completion_contract;
      check(frozen.run_binding?.run_id===run.id&&frozen.run_binding.task_id===taskID&&frozen.run_binding.operation_id===run.operation_id&&frozen.run_binding.delegation_id===run.delegation_id,409,'completion_run_binding_conflict');
      check(contract?.schema_version===1&&contract.version===1,422,'completion_contract_required');
      let body;try{body=JSON.parse(artifact.body);}catch{throw new ApiError(422,'invalid_completion_artifact');}
      check(body.kind==='report'&&typeof body.data?.content==='string'&&body.data.content.trim().length>0,422,'invalid_completion_artifact');
      if(frozen.public_sources){
        check(this.sourceService&&body.data.source_contract==='sourced-report-v1',409,'source_completion_receipt_required');
        const bound=await this.sourceService.validateCitationsInTransaction(tx,owner,run,task,body.data.citations.map(({source_id,quote})=>({source_id,quote})));assertLive();
        check(hash(bound.sources)===hash(body.data.sources)&&hash(bound.citations)===hash(body.data.citations)&&hash(bound.receipt_references)===hash(body.data.source_receipt_references),409,'source_completion_receipt_conflict');
      }
      if(contract.mode==='model_finish_local_artifact'){check(!receipt,422,'structured_completion_intent_required');return completed({valid:true,mode:contract.mode,artifact_reference:clone(current)});}
      check(contract.mode==='single_local_report'&&completionAuthorityValid(frozen),422,'structured_completion_intent_required');
      const validation=evaluateReport(frozen,{title:body.title,summary:body.summary,content:body.data.content});
      check(validation.valid,422,'report_completion_condition_not_met');return completed(validation);
    });
  }
  async admitChatTask(tx,{owner,scope,conversation,turn,call}) {
    const ids=Object.fromEntries(['delegation_id','operation_id','run_id'].map(k=>[k,stableUUID(`${turn.id}:${call.id}:${k}`)]));
    let memoryGeneration=null;if(this.memoryGenerationEnabled)await tx.withScope(scope.scope_id,async scoped=>{memoryGeneration=(await scoped.scope()).generation;});
    const taskID=hash(`catpaw-task:${owner}:${ids.operation_id}`),runBinding={...ids,task_id:taskID};
    const intent=turn.completion_intent;
    const completionContract={schema_version:1,version:1,mode:this.completionPolicy?(intent?'single_local_report':'explicit_intent_required'):'model_finish_local_artifact'};
    const authority=intent?{...clone(intent),...runBinding}:null;
    const args=clone(call.arguments);let publicSources=null;
    if(call.name==='delegate_sources_v1'){
      check(this.publicSourcesEnabled&&this.sourceService?.reader,503,'public_source_policy_not_configured');
      const reader=this.sourceService.reader;reader.assertReady();
      publicSources=freezePublicSourceCatalog({runID:ids.run_id,selectedURLs:args.source_urls,userTexts:turn.history.filter(m=>m.role==='user').map(m=>m.content),policyHash:reader.policyHash});
      for(const source of publicSources.sources)policyTargetForURL(reader.policy,source.requested_url);
      delete args.source_urls;
    }
    const frozen={...turn.source_auth?{source_auth:clone(turn.source_auth)}:{},completion_contract:completionContract,run_binding:runBinding,current_input_hash:hash(turn.input),...authority?{completion_authority:authority}:{},...memoryGeneration?{memory_generation:memoryGeneration}:{},...publicSources?{public_sources:publicSources}:{},scope,subject_id:conversation.subject_id,conversation_id:conversation.id,conversation_epoch:conversation.grant_epoch,
      turn_id:turn.id,user_message_id:turn.input.message.id,call_id:call.id,args,messages:clone(turn.history),context:clone(turn.input.context),
      model_configuration:this.modelConfiguration,policy:LOCAL_POLICY,...this.completionPolicy?{completion_policy:clone(this.completionPolicy)}:{}};
    const requestHash=hash(frozen),prior=await tx.get(owner,'catpaw-operations',ids.operation_id);
    if(prior){check(prior.request_hash===requestHash,409,'tool_call_conflict');return this.binding(scope,conversation,turn,call,await tx.get(owner,'catpaw-runs',prior.run_id));}
    check(!await tx.get(owner,'catpaw-runs',ids.run_id),409,'run_conflict');
    const now=iso();
    const d={id:ids.delegation_id,revision:1,grant_epoch:1,state:'active',request_hash:hash({...frozen,kind:'delegation'}),
      ...args,policy:LOCAL_POLICY,subject_id:conversation.subject_id,conversation_id:conversation.id,created_at:now};
    const tag={...ids,delegation_revision:1,grant_epoch:1,request_hash:requestHash};
    let task={id:taskID,title:d.title,prompt:d.goal,kind:'agent',status:'queued',plan:[],evidence:[],input:{policy:LOCAL_POLICY},state:{catpaw:tag},
      createdAt:now,updatedAt:now,attempts:0,leaseId:null,leaseUntil:null,artifactIds:[]};
    const run={id:ids.run_id,...tag,task_id:taskID,frozen_request:frozen,artifact_references:[],approval_ids:[],created_at:now};
    check(await tx.insertIfAbsent(owner,'catpaw-delegations',d),409,'operation_conflict');
    check(await tx.insertIfAbsent(owner,'catpaw-operations',{id:ids.operation_id,run_id:ids.run_id,request_hash:requestHash}),409,'operation_conflict');
    check(await tx.insertIfAbsent(owner,'catpaw-runs',run),409,'run_conflict');
    task=await createTaskPlan(tx,owner,run,task);
    check(await tx.insertIfAbsent(owner,'tasks',task),409,'operation_conflict');
    return this.binding(scope,conversation,turn,call,run);
  }
  binding(scope,c,t,call,r){return {scope_id:scope.scope_id,conversation_id:c.id,turn_id:t.id,call_id:call.id,delegation_id:r.delegation_id,
    operation_id:r.operation_id,run_id:r.id,task_id:r.task_id,request_hash:r.request_hash,delegation_revision:r.delegation_revision,grant_epoch:r.grant_epoch,
    projection_url:`/catpaw/v1/scopes/${scope.scope_id}/runs/${r.id}`};}
}
