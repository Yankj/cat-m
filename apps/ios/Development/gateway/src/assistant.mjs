import { randomUUID } from 'node:crypto';
import { clone, fail, freezeRequest, hash, ModelRegistry, canonicalJSON } from './models.mjs';

export const scopeKey = scope => {
  const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if(!uuid.test(scope?.profile_id??'')||!uuid.test(scope?.workspace_id??'')) throw fail('invalid_scope');
  return `${scope.profile_id.toLowerCase()}:${scope.workspace_id.toLowerCase()}`;
};
const terminal = new Set(['succeeded','cancelled','failed','outcome_unknown']);
const item=(s,table,id,scope)=> {const value=s[table][id]; if(!value) throw fail('missing'); if(scopeKey(value.scope)!==scopeKey(scope)) throw fail('scope_mismatch'); return value;};
const iso = now => new Date(now).toISOString();
function revision(value,expected) {if(value.revision!==expected) throw fail('conflict');}
function touch(s,kind,id,now) {s.outbox.push({sequence:s.sequence+1,kind,id,at:iso(now)});}
function idempotent(s,scope,key,verb,input,fn) {
  if(typeof key!=='string'||key.length<1||key.length>200) throw fail('idempotency_key_required');
  const index=hash(`${scopeKey(scope)}:${verb}:${key}`), digest=hash(canonicalJSON(input));
  const previous=s.idempotency[index];
  if(previous) {if(previous.digest!==digest) throw fail('idempotency_conflict'); return previous.result;}
  const result=fn(); s.idempotency[index]={digest,result}; return result;
}
function staleApprovals(s,delegationID) {
  for(const a of Object.values(s.approvals)) if(a.delegation_id===delegationID&&['pending','approved'].includes(a.status)) {a.status='invalidated'; a.revision++;}
}

export class AssistantService {
  constructor(store,{clock=()=>Date.now(),registry=new ModelRegistry(),realEnabled=false,protectionFor=()=>null}={}) {
    this.store=store; this.clock=clock; this.registry=registry; this.realEnabled=realEnabled; this.protectionFor=protectionFor;
  }
  createDelegation(scope,input,key) {
    const now=this.clock(); this.registry.select(input.model_id);
    if(!input.goal?.trim()||!input.title?.trim()||!Array.isArray(input.stop_conditions)||!input.stop_conditions.length||input.stop_conditions.some(x=>typeof x!=='string'||!x.trim())) throw fail('goal_and_stop_required');
    if(input.interval_ms!=null&&(!Number.isSafeInteger(input.interval_ms)||input.interval_ms<3600000)) throw fail('invalid_interval');
    const id=this.store.transact(s=>idempotent(s,scope,key,'create_delegation',input,()=>{
      const id=randomUUID(); s.delegations[id]={id,scope:clone(scope),revision:1,title:input.title,goal:input.goal,
        requirements:input.requirements??'',stop_conditions:clone(input.stop_conditions),model_id:input.model_id,
        interval_ms:input.interval_ms??null,state:'active',context_epoch:0,next_check_at:input.interval_ms?now+input.interval_ms:null,
        health:'local_worker_only',source_ids:[],artifact_id:null,created_at:iso(now),updated_at:iso(now)};
      touch(s,'delegation',id,now); return id;
    }));
    return this.getDelegation(scope,id);
  }
  getDelegation(scope,id) {return clone(item(this.store.read(),'delegations',id,scope));}
  getRun(scope,id) {return clone(item(this.store.read(),'runs',id,scope));}
  getArtifact(scope,id) {return clone(item(this.store.read(),'artifacts',id,scope));}
  control(scope,id,state,expected,key) {
    const now=this.clock(); this.store.transact(s=>idempotent(s,scope,key,'control',{id,state,expected},()=>{
      const d=item(s,'delegations',id,scope); revision(d,expected);
      if(!((d.state==='active'&&['paused','cancelled','completed'].includes(state))||(d.state==='paused'&&['active','cancelled','completed'].includes(state)))) throw fail('invalid_transition');
      d.state=state; d.revision++; d.context_epoch++; d.updated_at=iso(now);
      // Resume schedules the next future check; it never revives an invalidated run or restores a source grant.
      d.next_check_at=state==='active'&&d.interval_ms?now+d.interval_ms:null;
      this.invalidate(s,d.id,'delegation_changed',now); touch(s,'delegation',id,now); return id;
    })); return this.getDelegation(scope,id);
  }
  editDelegation(scope,id,patch,expected,key) {
    const now=this.clock();
    this.store.transact(s=>idempotent(s,scope,key,'edit_delegation',{id,patch,expected},()=>{
      const d=item(s,'delegations',id,scope); revision(d,expected);
      if(!['active','paused'].includes(d.state)||Object.keys(patch).some(k=>!['goal','requirements','model_id'].includes(k))) throw fail('invalid_edit');
      if(patch.goal!==undefined&&!patch.goal.trim()) throw fail('invalid_goal');
      if(patch.model_id) this.registry.select(patch.model_id);
      Object.assign(d,patch); d.revision++; d.context_epoch++; d.updated_at=iso(now);
      this.invalidate(s,id,'delegation_changed',now); touch(s,'delegation',id,now); return id;
    })); return this.getDelegation(scope,id);
  }
  invalidate(s,delegationID,reason,now) {
    for(const run of Object.values(s.runs)) if(run.delegation_id===delegationID&&!terminal.has(run.state)) {
      run.state='cancelled'; run.invalidated_reason=reason; run.fencing_token++; run.lease=null; run.revision++; run.updated_at=iso(now); touch(s,'run',run.id,now);
    }
    staleApprovals(s,delegationID);
  }
  addSource(scope,delegationID,url,key) {
    const parsed=new URL(url); if(parsed.protocol!=='https:'||parsed.username||parsed.password) throw fail('invalid_source');
    const now=this.clock(); const id=this.store.transact(s=>idempotent(s,scope,key,'add_source',{delegationID,url},()=>{
      const d=item(s,'delegations',delegationID,scope); const id=randomUUID();
      s.sources[id]={id,scope:clone(scope),delegation_id:delegationID,url,allowed:true,revision:1};
      d.source_ids.push(id); d.revision++; d.context_epoch++; this.invalidate(s,delegationID,'source_changed',now); touch(s,'source',id,now); return id;
    })); return clone(item(this.store.read(),'sources',id,scope));
  }
  sourcePermission(scope,id,allowed,expected,key) {
    if(typeof allowed!=='boolean') throw fail('invalid_permission'); const now=this.clock();
    this.store.transact(s=>idempotent(s,scope,key,'source_permission',{id,allowed,expected},()=>{
      const source=item(s,'sources',id,scope); revision(source,expected); source.allowed=allowed; source.revision++;
      const d=s.delegations[source.delegation_id]; d.context_epoch++; d.revision++;
      this.invalidate(s,d.id,'source_revoked_or_changed',now); touch(s,'source',id,now); return id;
    })); return clone(item(this.store.read(),'sources',id,scope));
  }
  addMemory(scope,delegationID,content,sourceMessageID,key) {
    if(!content?.trim()) throw fail('invalid_memory'); const now=this.clock();
    const id=this.store.transact(s=>idempotent(s,scope,key,'add_memory',{delegationID,content,sourceMessageID},()=>{
      const d=item(s,'delegations',delegationID,scope);
      if(!sourceMessageID||Object.values(s.suppressions).some(p=>p.delegation_id===delegationID&&p.source_message_ids.includes(sourceMessageID))) throw fail('memory_source_suppressed');
      const id=randomUUID(); s.memories[id]={id,scope:clone(scope),delegation_id:delegationID,content,
        source_message_id:sourceMessageID,status:'active',revision:1,deletion_epoch:0};
      d.context_epoch++; this.invalidate(s,d.id,'memory_changed',now); touch(s,'memory',id,now); return id;
    })); return clone(item(this.store.read(),'memories',id,scope));
  }
  forgetMemory(scope,id,expected,key) {
    const now=this.clock();
    this.store.transact(s=>idempotent(s,scope,key,'forget_memory',{id,expected},()=>{
      const memory=item(s,'memories',id,scope); revision(memory,expected);
      memory.status='deleted'; memory.content=''; memory.deletion_epoch++; memory.revision++;
      const d=s.delegations[memory.delegation_id]; d.context_epoch++;
      s.suppressions[id]={deleted_memory_id:id,delegation_id:d.id,source_message_ids:[memory.source_message_id],deletion_epoch:memory.deletion_epoch,at:iso(now)};
      this.invalidate(s,d.id,'memory_deleted',now);
      for(const run of Object.values(s.runs)) if(run.delegation_id===d.id&&run.context.memory_ids.includes(id)) {
        run.frozen_request=null; run.context.memories=[]; run.context.redacted=true; // no deleted text in persisted replay context
        if(run.artifact_ids.length) for(const artifactID of run.artifact_ids) {s.artifacts[artifactID].state='stale'; touch(s,'artifact',artifactID,now);}
      }
      touch(s,'memory',id,now); return id;
    })); return {id,status:'deleted',online_context:'purged',derived_artifacts:'marked_stale',backup_purge:'not_implemented'};
  }
  freezeRun(s,d,triggerID,now) {
    if(d.state!=='active') throw fail('delegation_inactive');
    const sources=d.source_ids.map(id=>s.sources[id]).filter(x=>x.allowed);
    const memories=Object.values(s.memories).filter(x=>x.delegation_id===d.id&&x.status==='active');
    const prompt=`Synthetic local preparation only. Do not fetch sources or execute external actions.\nGoal: ${d.goal}\nRequirements: ${d.requirements}\nStop conditions: ${d.stop_conditions.join('; ')}\nSynthetic memory: ${memories.map(x=>x.content).join('\n')}`;
    const id=randomUUID();
    const frozen=freezeRequest(this.registry.select(d.model_id),{messages:[{role:'user',content:prompt}],max_tokens:1024},
      {real:this.realEnabled,evidence:this.protectionFor(d.model_id),now,taskID:id});
    const run={id,scope:clone(d.scope),delegation_id:d.id,delegation_revision:d.revision,revision:1,
      task_id:randomUUID(),conversation_id:randomUUID(),operation_id:randomUUID(),trigger_event_ids:[triggerID],
      state:'queued',context:{epoch:d.context_epoch,memory_ids:memories.map(x=>x.id),memories:clone(memories),
        source_revisions:Object.fromEntries(sources.map(x=>[x.id,x.revision]))},
      frozen_request:frozen,artifact_ids:[],lease:null,fencing_token:0,attempt_count:0,model_calls:0,
      reality:this.realEnabled?'unknown':'simulated',created_at:iso(now),updated_at:iso(now)};
    s.runs[id]=run; touch(s,'run',id,now); return id;
  }
  enqueue(scope,delegationID,key) {
    const now=this.clock(); const id=this.store.transact(s=>idempotent(s,scope,key,'enqueue',{delegationID},()=>
      this.freezeRun(s,item(s,'delegations',delegationID,scope),`manual:${key}`,now)));
    return this.getRun(scope,id);
  }
  scheduleDue() {
    const now=this.clock(); return this.store.transact(s=>{
      const result=[];
      for(const d of Object.values(s.delegations)) if(d.state==='active'&&d.next_check_at!=null&&d.next_check_at<=now) {
        const due=d.next_check_at;
        // Coalesce overdue intervals into one explicit check, then skip to the next future interval.
        const key=`scheduled:${d.id}:${due}`;
        const id=idempotent(s,d.scope,key,'schedule',{id:d.id,due},()=>this.freezeRun(s,d,key,now));
        result.push(id); d.next_check_at=now+d.interval_ms; touch(s,'delegation',d.id,now);
      }
      return result;
    });
  }
  validContext(s,run) {
    const d=s.delegations[run.delegation_id];
    if(d.state!=='active'||d.revision!==run.delegation_revision||d.context_epoch!==run.context.epoch) throw fail('context_invalidated');
    for(const [id,rev] of Object.entries(run.context.source_revisions)) if(!s.sources[id]?.allowed||s.sources[id].revision!==rev) throw fail('context_invalidated');
  }
  claim(workerID,leaseMs=30000) {
    if(typeof workerID!=='string'||!workerID||!Number.isSafeInteger(leaseMs)||leaseMs<1||leaseMs>60000) throw fail('invalid_lease');
    const now=this.clock(); return this.store.transact(s=>{
      for(const run of Object.values(s.runs)) {
        if(terminal.has(run.state)||run.state==='waiting_approval'||run.lease?.expires_at>now) continue;
        try {this.validContext(s,run);} catch {run.state='cancelled'; run.invalidated_reason='context_invalidated'; run.lease=null; continue;}
        // A real transport started before a crash has an unknown outcome. Never automatically replay it.
        if(run.frozen_request?.real&&run.model_calls>0) {run.state='outcome_unknown'; run.lease=null; touch(s,'run',run.id,now); continue;}
        if(run.attempt_count>=3) {run.state='failed'; run.failure_code='attempt_limit'; run.lease=null; touch(s,'run',run.id,now); continue;}
        run.fencing_token++; run.attempt_count++; run.state='running'; run.revision++; run.updated_at=iso(now);
        run.lease={owner:workerID,expires_at:now+leaseMs};
        touch(s,'run',run.id,now); return {run:clone(run),workerID,token:run.fencing_token};
      }
      return null;
    });
  }
  requireLease(s,claim,now) {
    const run=s.runs[claim.run.id];
    if(!run||run.fencing_token!==claim.token||run.lease?.owner!==claim.workerID||run.lease.expires_at<=now||run.state!=='running') throw fail('lease_lost');
    this.validContext(s,run); return run;
  }
  renew(claim,leaseMs=30000) {
    if(!Number.isInteger(leaseMs)||leaseMs<1||leaseMs>60000) throw fail('invalid_lease');
    const now=this.clock(); return this.store.transact(s=>{const run=this.requireLease(s,claim,now);run.lease.expires_at=now+leaseMs;return run.lease;});
  }
  beginModelCall(claim) {
    const now=this.clock(); return this.store.transact(s=>{
      const run=this.requireLease(s,claim,now);
      if(!run.frozen_request||run.model_calls>=3) throw fail('call_limit');
      run.model_calls++; touch(s,'run',run.id,now); return run.frozen_request;
    });
  }
  failRun(claim,code) {
    const now=this.clock(); return this.store.transact(s=>{const run=this.requireLease(s,claim,now);
      run.state=code==='tool_requires_policy'?'waiting_approval':'failed'; run.failure_code=code; run.lease=null;run.revision++;
      touch(s,'run',run.id,now);return run;});
  }
  publish(claim,body) {
    if(typeof body!=='string'||Buffer.byteLength(body)>1024*1024) throw fail('invalid_artifact');
    const now=this.clock(); return this.store.transact(s=>{
      const run=s.runs[claim.run.id];
      // Duplicate completion may return the existing artifact only for the original winning token/body.
      if(run?.state==='succeeded'&&run.winning_token===claim.token&&run.result_hash===hash(body)) return s.artifacts[run.artifact_ids[0]];
      const current=this.requireLease(s,claim,now),d=s.delegations[current.delegation_id];
      let artifact=d.artifact_id?s.artifacts[d.artifact_id]:null;
      if(artifact?.current_reference.content_hash===hash(body)&&artifact.state==='ready') {
        current.state='succeeded';current.outcome='no_change'; current.artifact_ids=[artifact.id];current.result_reference=clone(artifact.current_reference);current.winning_token=claim.token;current.result_hash=hash(body);current.lease=null;
        touch(s,'run',run.id,now);return artifact;
      }
      if(!artifact) {const id=randomUUID(); artifact={id,scope:clone(d.scope),delegation_id:d.id,title:d.title,
        kind:'research_brief',document_id:randomUUID(),versions:[],state:'ready'}; s.artifacts[id]=artifact; d.artifact_id=id;}
      const version=artifact.versions.length+1,contentHash=hash(body);
      artifact.versions.push({version,content_hash:contentHash,body,generated_from_run_id:run.id,at:iso(now)});
      artifact.current_reference={artifact_id:artifact.id,version,content_hash:contentHash}; artifact.state='ready';
      artifact.evidence_ids=[]; artifact.configured_source_ids=Object.keys(run.context.source_revisions); artifact.generated_from_run_id=run.id;
      current.state='succeeded';current.outcome='changed';current.artifact_ids=[artifact.id];current.result_reference=clone(artifact.current_reference);current.winning_token=claim.token;
      current.result_hash=contentHash;current.lease=null;current.revision++;current.updated_at=iso(now);
      staleApprovals(s,d.id);touch(s,'artifact',artifact.id,now);touch(s,'run',run.id,now);return artifact;
    });
  }
  editArtifact(scope,id,baseVersion,body,key) {
    const now=this.clock();
    if(typeof body!=='string'||Buffer.byteLength(body)>1024*1024) throw fail('invalid_artifact');
    this.store.transact(s=>idempotent(s,scope,key,'edit_artifact',{id,baseVersion,body},()=>{
      const a=item(s,'artifacts',id,scope); if(a.current_reference.version!==baseVersion) throw fail('conflict');
      const version=baseVersion+1,contentHash=hash(body);
      a.versions.push({version,content_hash:contentHash,body,generated_from_run_id:a.generated_from_run_id,at:iso(now),user_edit:true});
      a.current_reference={artifact_id:id,version,content_hash:contentHash};a.state='ready';
      staleApprovals(s,a.delegation_id);touch(s,'artifact',id,now);return id;
    }));return this.getArtifact(scope,id);
  }
  prepareApproval(scope,id,reference,target,key) {
    const now=this.clock(); if(!target?.trim()) throw fail('target_required');
    const approvalID=this.store.transact(s=>idempotent(s,scope,key,'prepare_approval',{id,reference,target},()=>{
      const a=item(s,'artifacts',id,scope),d=s.delegations[a.delegation_id];
      if(a.state!=='ready'||reference.artifact_id!==id||reference.version!==a.current_reference.version||reference.content_hash!==a.current_reference.content_hash) throw fail('approval_stale');
      const envelope={artifact:clone(reference),target,effect_class:'review_only',delegation_revision:d.revision,context_epoch:d.context_epoch};
      const aid=randomUUID();s.approvals[aid]={id:aid,scope:clone(scope),delegation_id:d.id,artifact_id:id,revision:1,status:'pending',
        envelope,action_digest:hash(JSON.stringify(envelope)),expires_at:now+600000,receipt:'not_started'};touch(s,'approval',aid,now);return aid;
    }));return clone(item(this.store.read(),'approvals',approvalID,scope));
  }
  decideApproval(scope,id,expected,digest,decision,key) {
    const now=this.clock();if(!['approve','reject'].includes(decision)) throw fail('invalid_decision');
    this.store.transact(s=>idempotent(s,scope,key,'decide_approval',{id,expected,digest,decision},()=>{
      const a=item(s,'approvals',id,scope);revision(a,expected);
      const artifact=s.artifacts[a.artifact_id],d=s.delegations[a.delegation_id],ref=a.envelope.artifact;
      if(a.status!=='pending'||a.expires_at<=now||a.action_digest!==digest||artifact.state!=='ready'||
        artifact.current_reference.version!==ref.version||artifact.current_reference.content_hash!==ref.content_hash||
        d.state!=='active'||d.revision!==a.envelope.delegation_revision||d.context_epoch!==a.envelope.context_epoch) throw fail('approval_stale');
      a.status=decision==='approve'?'approved':'rejected';a.revision++;a.decided_at=iso(now);touch(s,'approval',id,now);return id;
    }));return clone(item(this.store.read(),'approvals',id,scope));
  }
  projection(scope,cursor=0) {
    const s=this.store.read();if(!Number.isSafeInteger(cursor)||cursor<0||cursor>s.sequence) throw fail('invalid_cursor');
    const scoped = table=>Object.values(s[table]).filter(x=>scopeKey(x.scope)===scopeKey(scope));
    // Projection is built from current records, not old payloads in outbox. Tombstones survive reconnect.
    return {schema_version:1,mode:'local_synthetic',sync_cursor:s.sequence,scope:clone(scope),
      delegations:scoped('delegations'),runs:scoped('runs').map(({frozen_request,context,lease,...run})=>({...run,context_epochs:[{scope_kind:'delegation',scope_id:run.delegation_id,epoch:context.epoch}]})),
      artifacts:scoped('artifacts'),sources:scoped('sources'),memories:scoped('memories'),approvals:scoped('approvals')};
  }
}
