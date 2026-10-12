import { ApiError,check,shape,UUID,hash,iso,clone,immutableBody,COMMIT } from './common.mjs';
import { AppError } from '../patched-openmuse/apps/server/src/errors.ts';
const fixtures=['report','preview','preview_unknown'];
const int=v=>Number.isSafeInteger(v)&&v>0;
export class Facade {
  constructor({repository,authenticate,actionsFor,modelConfiguration={backend:'synthetic',model:null},executionLayer='facade_inprocess_test_double',abortTask=()=>{}}) {
    Object.assign(this,{repository,authenticate,actionsFor,modelConfiguration,executionLayer,abortTask});
  }
  owner(scope) { return `catpaw:${hash({profile:scope.profile_id,workspace:scope.workspace_id})}`; }
  async scoped(authorization,scopeID) {
    const principal=await this.authenticate(authorization);
    const scope=principal.scopes.find(s=>s.scope_id===scopeID);
    check(scope,403,'scope_forbidden');return {owner:this.owner(scope),scope,principal};
  }
  envelope(value) { return {schema_version:1,...value,execution_layer:this.executionLayer}; }
  async capabilities(authorization) {
    const p=await this.authenticate(authorization);
    return this.envelope({contract:'catpaw.facade.v1',upstream_commit:COMMIT,allowed_scopes:p.scopes,
      supports:{task_status_read:true,stable_run_read:true,artifact_versions:true,approval_projection:true,grant_revoke:true,sse_replay:false,external_writes:false}});
  }
  async delegation(tx,owner,id,{lock=false}={}) {
    if(lock)await tx.lock(owner,'catpaw-delegations',id);
    const d=await tx.get(owner,'catpaw-delegations',id);check(d,404,'not_found');return d;
  }
  async admittedTask(tx,owner,id,{running=false}={}) {
    let task=await tx.get(owner,'tasks',id);check(task?.state?.catpaw,409,'unmanaged_task');
    const tag=task.state.catpaw;
    const d=await this.delegation(tx,owner,tag.delegation_id,{lock:true});
    task=await tx.get(owner,'tasks',id);
    check(d.state==='active'&&d.grant_epoch===tag.grant_epoch&&d.revision===tag.delegation_revision,409,'grant_conflict');
    check(task.state.catpaw.request_hash===tag.request_hash,409,'operation_conflict');
    if(running)check(task.status==='running'&&task.leaseId,409,'lease_lost');
    const run=await tx.get(owner,'catpaw-runs',tag.run_id);
    check(run?.task_id===id&&run.request_hash===tag.request_hash,409,'operation_conflict');
    return {task,d,run,tag};
  }
  async createDelegation(auth,scopeID,input) {
    shape(input,['delegation_id','title','goal','requirements','stop_conditions','synthetic_fixture_id']);
    check(UUID.test(input.delegation_id)&&typeof input.title==='string'&&input.title.trim().length>0&&input.title.length<=160&&
      typeof input.goal==='string'&&input.goal.trim().length>0&&input.goal.length<=4000&&typeof input.requirements==='string'&&input.requirements.length<=4000&&
      Array.isArray(input.stop_conditions)&&input.stop_conditions.length>0&&input.stop_conditions.length<=10&&input.stop_conditions.every(x=>typeof x==='string'&&x.trim()&&x.length<=300),422,'schema_invalid');
    check(fixtures.includes(input.synthetic_fixture_id),422,'unsupported_fixture');
    const {owner,scope}=await this.scoped(auth,scopeID), requestHash=hash({...input,scope,model_configuration:this.modelConfiguration});
    return this.repository.transaction(async tx=>{
      const value={id:input.delegation_id,revision:1,grant_epoch:1,state:'active',request_hash:requestHash,...input,created_at:iso()};
      const inserted=await tx.insertIfAbsent(owner,'catpaw-delegations',value);
      const d=inserted??await this.delegation(tx,owner,input.delegation_id);
      check(d.request_hash===requestHash,409,'operation_conflict');return this.envelope({delegation:d});
    });
  }
  async readDelegation(auth,scopeID,id) { const {owner}=await this.scoped(auth,scopeID);return this.repository.transaction(async tx=>this.envelope({delegation:await this.delegation(tx,owner,id)})); }
  async createRun(auth,scopeID,id,input) {
    shape(input,['operation_id','run_id','expected_revision','expected_grant_epoch']);
    check(UUID.test(input.operation_id)&&UUID.test(input.run_id)&&input.operation_id!==input.run_id&&int(input.expected_revision)&&int(input.expected_grant_epoch),422,'schema_invalid');
    const {owner,scope}=await this.scoped(auth,scopeID);
    return this.repository.transaction(async tx=>{
      const d=await this.delegation(tx,owner,id,{lock:true});
      check(d.revision===input.expected_revision,409,'revision_conflict');check(d.state==='active'&&d.grant_epoch===input.expected_grant_epoch,409,'grant_conflict');
      const frozen={scope,delegation:d,admission:input,model_configuration:this.modelConfiguration,policy:'synthetic-only-v1'},requestHash=hash(frozen);
      const prior=await tx.get(owner,'catpaw-operations',input.operation_id);
      if(prior){check(prior.request_hash===requestHash&&prior.run_id===input.run_id,409,'operation_conflict');return {...await this.runProjection(tx,owner,prior.run_id),idempotent:true};}
      check(!await tx.get(owner,'catpaw-runs',input.run_id),409,'run_conflict');
      const taskID=hash(`catpaw-task:${owner}:${input.operation_id}`),now=iso();
      const tag={run_id:input.run_id,operation_id:input.operation_id,delegation_id:id,delegation_revision:d.revision,grant_epoch:d.grant_epoch,request_hash:requestHash};
      const task={id:taskID,title:d.title,prompt:d.goal,kind:'agent',status:'queued',plan:[],evidence:[],input:{synthetic_fixture_id:d.synthetic_fixture_id},state:{catpaw:tag},createdAt:now,updatedAt:now,attempts:0,leaseId:null,leaseUntil:null,artifactIds:[]};
      const run={id:input.run_id,...tag,task_id:taskID,frozen_request:frozen,artifact_references:[],approval_ids:[],created_at:now};
      // Reserve unique business identities BEFORE creating a Task. SQL unique insert
      // waits for a competing transaction; every losing insertion must be checked.
      const operation=await tx.insertIfAbsent(owner,'catpaw-operations',{id:input.operation_id,run_id:input.run_id,request_hash:requestHash});
      if(!operation){
        const existing=await tx.get(owner,'catpaw-operations',input.operation_id);
        check(existing?.request_hash===requestHash&&existing.run_id===input.run_id,409,'operation_conflict');
        return {...await this.runProjection(tx,owner,input.run_id),idempotent:true};
      }
      check(await tx.insertIfAbsent(owner,'catpaw-runs',run),409,'run_conflict');
      const savedTask=await tx.insertIfAbsent(owner,'tasks',task);
      if(!savedTask){const existing=await tx.get(owner,'tasks',taskID);check(hash(existing?.state?.catpaw??{})===hash(tag),409,'operation_conflict');}
      return this.runProjection(tx,owner,input.run_id);
    });
  }
  async runProjection(tx,owner,id) {
    const run=await tx.get(owner,'catpaw-runs',id);check(run,404,'not_found');
    const d=await this.delegation(tx,owner,run.delegation_id),task=await tx.get(owner,'tasks',run.task_id);
    const attempts=(await tx.list(owner,'runs')).filter(r=>r.taskId===run.task_id).map(r=>({upstream_run_id:r.id,started_at:r.startedAt,...r.finishedAt?{finished_at:r.finishedAt}:{},status:r.status}));
    const authorizationState=d.state==='active'&&d.grant_epoch===run.grant_epoch&&d.revision===run.delegation_revision?'current':'superseded';
    let state=task?.status??'outcome_unknown';
    for(const id of run.approval_ids){const a=await tx.get(owner,'actions',id);if(a?.status==='outcome_unknown')state='outcome_unknown';}
    const {frozen_request,...view}=run;return this.envelope({run:{...view,state,authorization_state:authorizationState,attempts},task:{id:task.id,status:task.status,attempts:task.attempts}});
  }
  async readRun(auth,scopeID,id) { const {owner}=await this.scoped(auth,scopeID);return this.repository.transaction(tx=>this.runProjection(tx,owner,id)); }
  async readOperation(auth,scopeID,id) { const {owner}=await this.scoped(auth,scopeID);return this.repository.transaction(async tx=>{const o=await tx.get(owner,'catpaw-operations',id);check(o,404,'not_found');return this.runProjection(tx,owner,o.run_id);}); }
  async control(auth,scopeID,id,input) {
    shape(input,['action','expected_revision','expected_grant_epoch']);check(['pause','resume','revoke'].includes(input.action)&&int(input.expected_revision)&&int(input.expected_grant_epoch),422,'schema_invalid');
    const {owner}=await this.scoped(auth,scopeID);
    const result=await this.repository.transaction(async tx=>{
      const d=await this.delegation(tx,owner,id,{lock:true});check(d.revision===input.expected_revision,409,'revision_conflict');check(d.grant_epoch===input.expected_grant_epoch,409,'grant_conflict');
      check(d.state!=='revoked'&&((input.action==='resume'&&d.state==='paused')||(input.action!=='resume'&&d.state==='active')),409,'grant_conflict');
      const next={...d,revision:d.revision+1,grant_epoch:d.grant_epoch+1,state:{pause:'paused',resume:'active',revoke:'revoked'}[input.action]};
      await tx.put(owner,'catpaw-delegations',next);const stopped=[];
      for(const task of await tx.list(owner,'tasks'))if(task.state?.catpaw?.delegation_id===id&&!['succeeded','failed','cancelled'].includes(task.status)){
        await tx.put(owner,'tasks',{...task,status:input.action==='revoke'?'cancelled':'paused',leaseId:null,leaseUntil:null,updatedAt:iso()});stopped.push(task.id);
      }
      return {envelope:this.envelope({delegation:next}),stopped};
    });
    for(const id of result.stopped)this.abortTask(id);return result.envelope;
  }
  async publishArtifact(owner,taskID,artifact,leaseID) {
    return this.repository.transaction(async tx=>{
      const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});check(task.leaseId===leaseID,409,'lease_lost');
      check(['plan','report','comparison'].includes(artifact.kind),422,'schema_invalid');
      const artifactID=hash(`${taskID}:synthetic-report`),body=immutableBody(artifact),contentHash=hash(body);
      const previous=await tx.get(owner,'catpaw-artifact-heads',artifactID);
      if(previous?.content_hash===contentHash)return previous;
      const ref={artifact_id:artifactID,version:(previous?.version??0)+1,content_hash:contentHash};
      const version={id:`${artifactID}:${ref.version}`,...ref,mime_type:'application/json',body,run_id:run.id,task_id:taskID,created_at:iso()};
      check(await tx.insertIfAbsent(owner,'catpaw-artifact-versions',version),409,'revision_conflict');await tx.put(owner,'catpaw-artifact-heads',{id:artifactID,...ref});
      await tx.put(owner,'agent-artifacts',{id:artifactID,taskId:taskID,...artifact,createdAt:version.created_at});
      const refs=run.artifact_references.filter(r=>r.artifact_id!==artifactID);refs.push(ref);await tx.put(owner,'catpaw-runs',{...run,artifact_references:refs});
      await tx.put(owner,'tasks',{...task,artifactIds:[...new Set([...task.artifactIds,artifactID])],updatedAt:iso()});
      // Old approval cannot authorize a newer output. Authority remains upstream actions table.
      for(const b of await tx.list(owner,'catpaw-approval-bindings'))if(b.artifact_reference.artifact_id===artifactID&&b.artifact_reference.version!==ref.version){
        const a=await tx.get(owner,'actions',b.id);
        if(a?.status==='awaiting_review')await this.decideInTransaction(tx,owner,a,'deny');
      }
      return ref;
    });
  }
  async publishEvent(owner,taskID,leaseID,event) {
    return this.repository.transaction(async tx=>{
      const {task}=await this.admittedTask(tx,owner,taskID,{running:true});check(task.leaseId===leaseID,409,'lease_lost');
      return tx.put(owner,'run-events',{id:hash(`${leaseID}:${event.kind}:${event.title}`),taskId:taskID,leaseId:leaseID,date:iso(),...event});
    });
  }
  async readArtifact(auth,scopeID,id,version) {
    const {owner}=await this.scoped(auth,scopeID);check(int(version),422,'schema_invalid');return this.repository.transaction(async tx=>{
      const a=await tx.get(owner,'catpaw-artifact-versions',`${id}:${version}`);check(a,404,'not_found');check(hash(a.body)===a.content_hash,409,'artifact_corrupt');return this.envelope({artifact:a});
    });
  }
  async proposePreview(owner,taskID,ref,leaseID) {
    return this.repository.transaction(async tx=>{
      const {task,run}=await this.admittedTask(tx,owner,taskID,{running:true});check(task.leaseId===leaseID,409,'lease_lost');
      const head=await tx.get(owner,'catpaw-artifact-heads',ref.artifact_id);check(head&&head.content_hash===ref.content_hash&&head.version===ref.version,409,'approval_stale');
      const data={artifactId:ref.artifact_id,version:ref.version,contentHash:ref.content_hash,title:'Synthetic preview only'};
      const proposal=await this.actionsFor(tx).propose(owner,{kind:'catpaw.preview',data},`${taskID}:${ref.version}:${ref.content_hash}:preview`,taskID);
      const frozen={id:proposal.id,run_id:run.id,operation_id:run.operation_id,task_id:taskID,delegation_id:run.delegation_id,delegation_revision:run.delegation_revision,grant_epoch:run.grant_epoch,
        artifact_reference:ref,arguments_hash:hash(data),upstream_hash:proposal.hash,policy:'synthetic-only-v1',expires_at:proposal.expiresAt};
      await tx.insertIfAbsent(owner,'catpaw-approval-bindings',{...frozen,action_digest:hash(frozen),reconciliation_state:'not_needed'});
      await tx.put(owner,'catpaw-runs',{...run,approval_ids:[...new Set([...run.approval_ids,proposal.id])]});
      await tx.put(owner,'tasks',{...task,actionId:proposal.id,updatedAt:iso()});return proposal;
    });
  }
  async approvalProjection(tx,owner,id) {
    const b=await tx.get(owner,'catpaw-approval-bindings',id),a=await tx.get(owner,'actions',id);check(b&&a,404,'not_found');
    const receipt={awaiting_review:'not_started',executing:'accepted',succeeded:'accepted',outcome_unknown:'unknown',failed:'unknown',denied:'cancelled_before_dispatch',expired:'cancelled_before_dispatch'}[a.status]??'unknown';
    return this.envelope({approval:{...b,status:a.status,receipt_status:receipt,reconciliation:{state:a.status==='outcome_unknown'?(['resolved_local','unresolved'].includes(b.reconciliation_state)?b.reconciliation_state:'needed'):b.reconciliation_state,can_retry:false}}});
  }
  async readApproval(auth,scopeID,id) { const {owner}=await this.scoped(auth,scopeID);return this.repository.transaction(tx=>this.approvalProjection(tx,owner,id)); }
  async decideInTransaction(tx,owner,proposal,decision) {
    try {
      const current=await this.actionsFor(tx).decide(owner,proposal.id,proposal.hash,decision);
      return {proposal:current,expired:current.status==='expired'};
    }
    catch(error) {
      // Upstream expires via CAS and then throws AppError(409). Only that verified
      // state transition is a committable error; all unrelated errors roll back.
      if(error instanceof AppError&&error.status===409&&proposal.status==='awaiting_review'&&Date.parse(proposal.expiresAt)<=Date.now()){
        const current=await tx.get(owner,'actions',proposal.id);
        if(current?.status==='expired'&&current.hash===proposal.hash&&current.expiresAt===proposal.expiresAt&&current.taskId===proposal.taskId)return {proposal:current,expired:true};
      }
      if(error instanceof AppError){const code={400:'schema_invalid',401:'session_required',403:'scope_forbidden',404:'not_found',409:'approval_stale',413:'request_too_large',422:'schema_invalid',503:'dependency_not_ready'}[error.status];if(code)throw new ApiError(error.status,code);}
      throw error;
    }
  }
  async decide(auth,scopeID,id,input) {
    shape(input,['decision','upstream_hash','action_digest','expected_grant_epoch']);check(['approve','deny'].includes(input.decision)&&int(input.expected_grant_epoch),422,'schema_invalid');
    const {owner}=await this.scoped(auth,scopeID);const result=await this.repository.transaction(async tx=>{
      const b=await tx.get(owner,'catpaw-approval-bindings',id),a=await tx.get(owner,'actions',id);check(b&&a,404,'not_found');
      const {d}=await this.admittedTask(tx,owner,b.task_id);
      check(d.grant_epoch===input.expected_grant_epoch&&b.grant_epoch===d.grant_epoch,409,'grant_conflict');
      const head=await tx.get(owner,'catpaw-artifact-heads',b.artifact_reference.artifact_id);
      check(head?.version===b.artifact_reference.version&&head?.content_hash===b.artifact_reference.content_hash,409,'approval_stale');
      check(a.kind==='catpaw.preview',422,'external_write_denied');
      check(input.action_digest===b.action_digest&&input.upstream_hash===b.upstream_hash&&a.hash===b.upstream_hash&&hash(a.data)===b.arguments_hash,409,'approval_stale');
      check(a.status!=='outcome_unknown',409,'outcome_unknown',{reconciliation:true});check(a.status==='awaiting_review',409,'approval_consumed');
      const outcome=await this.decideInTransaction(tx,owner,a,input.decision);
      if(outcome.expired)return new ApiError(409,'approval_consumed');
      return this.approvalProjection(tx,owner,id);
    });
    if(result instanceof ApiError)throw result;return result;
  }
  async reconcile(auth,scopeID,id) {
    const {owner}=await this.scoped(auth,scopeID);return this.repository.transaction(async tx=>{
      const b=await tx.get(owner,'catpaw-approval-bindings',id),a=await tx.get(owner,'actions',id);check(b&&a,404,'not_found');
      check(a.status==='outcome_unknown',409,'reconciliation_not_needed');
      const marker=await tx.get(owner,'catpaw-preview-effects',id);
      await tx.put(owner,'catpaw-approval-bindings',{...b,reconciliation_state:marker?.arguments_hash===b.arguments_hash?'resolved_local':'unresolved',reconciliation_checked_at:iso()});
      return this.approvalProjection(tx,owner,id); // no dispatch, and upstream proposal still outcome_unknown.
    });
  }
  async previewEffect(tx,owner,input) {
    check(input.kind==='catpaw.preview',422,'external_write_denied');
    const actions=await tx.list(owner,'actions'),a=actions.find(x=>x.kind===input.kind&&hash(x.data)===hash(input.data)&&x.status==='executing');check(a?.taskId,409,'approval_consumed');
    const {task}=await this.admittedTask(tx,owner,a.taskId);
    const b=await tx.get(owner,'catpaw-approval-bindings',a.id);check(b,409,'approval_stale');
    check(await tx.insertIfAbsent(owner,'catpaw-preview-effects',{id:a.id,arguments_hash:hash(input.data),committed_at:iso()}),409,'approval_consumed');
    if(task.input.synthetic_fixture_id==='preview_unknown'){const e=new Error('Synthetic acknowledgement loss');e.outcomeUnknown=true;throw e;}
    return 'Synthetic local preview recorded; no external write';
  }
}
