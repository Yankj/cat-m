import {check,shape,hash,clone} from '../facade-r2/src/common.mjs';
import {FOLLOWUP_TRIGGER_CONTRACT as C,FOLLOWUP_DUE_CONTRACT,FOLLOWUP_TRIGGER_KINDS as K,FOLLOWUP_TRIGGER_LIMITS as L,validateFollowupIdentity,validateFollowupConfiguration,validateFollowupCreate,validateFollowupCommand,followupUUID,followupHash,followupInstant,followupDueID,followupQuietAt,followupReceiptHash} from './followup-trigger-contract.mjs';
const same=(a,b)=>a!==undefined&&b!==undefined&&hash(a)===hash(b),iso=ms=>new Date(ms).toISOString();
const capability=()=>({execution_authorized:false,scheduler_connected:false});

/** Durable configuration and non-executable due inventory in the existing
 * records transaction. No Task, worker, model, grant, effect, or outbox is created.
 * A future occurrence needs a separately versioned explicit execution authority. */
export class FollowupTriggerService {
 constructor({repository,authorize,now=Date.now}){Object.assign(this,{repository,authorize,now});}
 live(signal){const start=this.now();check(Number.isSafeInteger(start),409,'followup_write_deadline');let last=start;return()=>{const at=this.now();check(!signal?.aborted,409,'followup_cancelled');check(Number.isSafeInteger(at)&&at>=last&&at-start<L.write_ms,409,'followup_write_deadline');last=at;};}
 async scope(tx,identity,live){await tx.withScope(identity.scope_id,async scoped=>{const row=await scoped.scope();check(row.identity.owner===identity.owner&&row.identity.scope_id===identity.scope_id,403,'followup_scope_conflict');});live();}
 async authority(tx,identity,origin,purpose,live,requireCurrent=false){
  live();check(typeof this.authorize==='function',503,'followup_authority_not_configured');const result=await this.authorize(tx,clone(identity),clone(origin),{purpose});live();check(typeof result?.source_current==='boolean',503,'followup_authority_result_required');if(requireCurrent)check(result.source_current,403,'followup_source_not_current');return result.source_current;
 }
 validateRow(row,identity,id){
  check(row&&row.subject_id===identity.subject_id&&row.scope_id===identity.scope_id,404,'followup_not_found');
  try{shape(row,['id','schema_version','contract','scope_id','subject_id','configuration','configuration_hash','schedule_revision','revision','status','next_due_at','materialized_count','reserved_execution_ms','created_at','updated_at']);validateFollowupConfiguration(row.configuration);}catch{check(false,409,'followup_record_corrupt');}
  check(row.id===id&&followupUUID(id)&&row.schema_version===1&&row.contract===C&&hash(row.configuration)===row.configuration_hash&&row.schedule_revision===1&&Number.isSafeInteger(row.revision)&&row.revision>0&&['configured','paused','revoked'].includes(row.status)&&Number.isSafeInteger(row.materialized_count)&&row.materialized_count>=0&&row.materialized_count<=row.configuration.end.max_occurrences&&row.reserved_execution_ms===row.materialized_count*row.configuration.budget.per_due_execution_ms&&row.reserved_execution_ms<=row.configuration.budget.total_execution_ms&&followupInstant(row.created_at)&&followupInstant(row.updated_at)&&row.updated_at>=row.created_at&&row.next_due_at===iso(Date.parse(row.configuration.schedule.first_due_at)+row.materialized_count*row.configuration.schedule.interval_seconds*1000),409,'followup_record_corrupt');return row;
 }
 async current(tx,identity,id,purpose,live,{requireCurrent=false}={}){
  check(followupUUID(id),422,'followup_schema_invalid');await this.scope(tx,identity,live);
  // Immutable origin is a hint only. Source/delegation/task locks must precede
  // trigger/op/due locks, matching the existing global source-first lock order.
  const hint=this.validateRow(await tx.get(identity.owner,K.triggers,id),identity,id);live();
  const sourceCurrent=await this.authority(tx,identity,hint.configuration.origin,purpose,live,requireCurrent);
  await tx.lock(identity.owner,K.triggers,id);live();const row=this.validateRow(await tx.get(identity.owner,K.triggers,id),identity,id);live();
  check(same(row.configuration,hint.configuration),409,'followup_binding_conflict');return {row,sourceCurrent};
 }
 reason(row,at,sourceCurrent=true){
  if(!sourceCurrent)return 'source_not_current';if(row.status!=='configured')return row.status;
  if(at>=Date.parse(row.configuration.end.not_after))return 'ended';
  if(row.materialized_count>=row.configuration.end.max_occurrences)return 'occurrence_limit';
  if(row.reserved_execution_ms+row.configuration.budget.per_due_execution_ms>row.configuration.budget.total_execution_ms)return 'budget_exhausted';
  if(Date.parse(row.next_due_at)>=Date.parse(row.configuration.end.not_after))return 'ended';return null;
 }
 projection(row,sourceCurrent){return {id:row.id,scope_id:row.scope_id,subject_id:row.subject_id,configuration:clone(row.configuration),configuration_hash:row.configuration_hash,schedule_revision:row.schedule_revision,revision:row.revision,status:row.status,next_due_at:row.next_due_at,materialized_count:row.materialized_count,reserved_execution_ms:row.reserved_execution_ms,source_current:sourceCurrent,capability:capability(),blocked_reason:this.reason(row,this.now(),sourceCurrent)??'execution_authorization_required',created_at:row.created_at,updated_at:row.updated_at};}
 envelope(row,sourceCurrent,extra={}){return {schema_version:1,contract:C,trigger:this.projection(row,sourceCurrent),...extra};}
 receipt(input,row,action,at){const fields={schema_version:1,contract:C,operation_id:input.operation_id,trigger_id:row.id,action,revision:row.revision,configuration_hash:row.configuration_hash,status:row.status,recorded_at:iso(at),execution_authorized:false};return {...fields,receipt_hash:followupReceiptHash(fields)};}
 async operation(tx,identity,id,row,live){
  const op=await tx.get(identity.owner,K.operations,id);live();if(!op)return null;
  try{shape(op,['id','scope_id','subject_id','trigger_id','input','request_hash','receipt']);shape(op.receipt,['schema_version','contract','operation_id','trigger_id','action','revision','configuration_hash','status','recorded_at','execution_authorized','receipt_hash']);if(op.receipt.action==='create')validateFollowupCreate(op.input);else validateFollowupCommand(op.input);}catch{check(false,409,'followup_operation_corrupt');}
  check(op.receipt.schema_version===1&&op.receipt.contract===C&&['create','pause','resume','revoke'].includes(op.receipt.action)&&op.receipt.action===(op.input.action??'create')&&op.receipt.status==={create:'configured',pause:'paused',resume:'configured',revoke:'revoked'}[op.receipt.action]&&Number.isSafeInteger(op.receipt.revision)&&op.receipt.revision>0&&followupInstant(op.receipt.recorded_at)&&op.receipt.recorded_at>=row.created_at,409,'followup_operation_corrupt');
  check(op.scope_id===identity.scope_id&&op.subject_id===identity.subject_id&&op.trigger_id===row.id&&op.id===id&&op.request_hash===hash({identity,trigger_id:row.id,input:op.input})&&op.receipt?.receipt_hash===followupReceiptHash(op.receipt)&&op.receipt.operation_id===id&&op.receipt.trigger_id===row.id&&op.receipt.configuration_hash===row.configuration_hash&&op.receipt.execution_authorized===false&&op.receipt.revision<=row.revision,409,'followup_operation_corrupt');return op;
 }
 async create(identity,input,{signal}={}){
  identity=validateFollowupIdentity(identity);input=validateFollowupCreate(input);const live=this.live(signal),id=input.trigger_id,requestHash=hash({identity,trigger_id:id,input});
  return this.repository.transaction(async tx=>{
   await this.scope(tx,identity,live);await this.authority(tx,identity,input.configuration.origin,'create',live,true);
   await tx.lock(identity.owner,K.triggers,id);await tx.lock(identity.owner,K.operations,input.operation_id);live();
   const old=await tx.get(identity.owner,K.triggers,id),existing=await tx.get(identity.owner,K.operations,input.operation_id);live();
   if(existing){const row=this.validateRow(old,identity,id),op=await this.operation(tx,identity,input.operation_id,row,live);check(op.request_hash===requestHash,409,'followup_operation_conflict');const current=await this.authority(tx,identity,row.configuration.origin,'create',live,true);return this.envelope(row,current,{receipt:clone(op.receipt),created:false});}
   check(!old,409,'followup_trigger_exists');const at=this.now();check(at<Date.parse(input.configuration.end.not_after),409,'followup_ended');
   const row={id,schema_version:1,contract:C,scope_id:identity.scope_id,subject_id:identity.subject_id,configuration:clone(input.configuration),configuration_hash:hash(input.configuration),schedule_revision:1,revision:1,status:'configured',next_due_at:input.configuration.schedule.first_due_at,materialized_count:0,reserved_execution_ms:0,created_at:iso(at),updated_at:iso(at)},receipt=this.receipt(input,row,'create',at);
   check(await tx.insertIfAbsent(identity.owner,K.triggers,row),409,'followup_operation_conflict');live();
   check(await tx.insertIfAbsent(identity.owner,K.operations,{id:input.operation_id,scope_id:identity.scope_id,subject_id:identity.subject_id,trigger_id:id,input:clone(input),request_hash:requestHash,receipt}),409,'followup_operation_conflict');live();
   const current=await this.authority(tx,identity,row.configuration.origin,'create',live,true);check(this.now()<Date.parse(row.configuration.end.not_after),409,'followup_ended');live();return this.envelope(row,current,{receipt,created:true});
  });
 }
 async read(identity,id,{signal}={}){identity=validateFollowupIdentity(identity);const live=this.live(signal);return this.repository.transaction(async tx=>{const {row}=await this.current(tx,identity,id,'read',live),dues=await this.dues(tx,identity,row,live),current=await this.authority(tx,identity,row.configuration.origin,'read',live);return this.envelope(row,current,{dues});});}
 async readOperation(identity,operationID,{signal}={}){
  identity=validateFollowupIdentity(identity);check(followupUUID(operationID),422,'followup_schema_invalid');const live=this.live(signal);
  return this.repository.transaction(async tx=>{await this.scope(tx,identity,live);const hint=await tx.get(identity.owner,K.operations,operationID);live();check(hint?.scope_id===identity.scope_id&&hint.subject_id===identity.subject_id,404,'followup_not_found');const {row}=await this.current(tx,identity,hint.trigger_id,'read_operation',live);await tx.lock(identity.owner,K.operations,operationID);const op=await this.operation(tx,identity,operationID,row,live);check(op,404,'followup_not_found');const current=await this.authority(tx,identity,row.configuration.origin,'read_operation',live);return this.envelope(row,current,{receipt:clone(op.receipt)});});
 }
 async list(identity,{signal}={}){
  identity=validateFollowupIdentity(identity);const live=this.live(signal);
  return this.repository.transaction(async tx=>{await this.scope(tx,identity,live);const rows=(await tx.list(identity.owner,K.triggers)).filter(r=>r.subject_id===identity.subject_id&&r.scope_id===identity.scope_id).sort((a,b)=>a.id.localeCompare(b.id));live();check(rows.length<=1000,413,'followup_catalog_too_large');const prepared=[];for(const hint of rows){this.validateRow(hint,identity,hint.id);await this.authority(tx,identity,hint.configuration.origin,'list',live);}for(const hint of rows){await tx.lock(identity.owner,K.triggers,hint.id);live();const row=this.validateRow(await tx.get(identity.owner,K.triggers,hint.id),identity,hint.id);live();check(same(row.configuration,hint.configuration),409,'followup_binding_conflict');prepared.push(row);}const result=[];for(const row of prepared){const current=await this.authority(tx,identity,row.configuration.origin,'list',live);result.push(this.projection(row,current));}live();return {schema_version:1,contract:C,scope_id:identity.scope_id,subject_id:identity.subject_id,triggers:result};});
 }
 async command(identity,id,input,{signal}={}){
  identity=validateFollowupIdentity(identity);input=validateFollowupCommand(input);const live=this.live(signal),requestHash=hash({identity,trigger_id:id,input});
  return this.repository.transaction(async tx=>{const {row}=await this.current(tx,identity,id,input.action,live,{requireCurrent:input.action==='resume'});await tx.lock(identity.owner,K.operations,input.operation_id);const prior=await this.operation(tx,identity,input.operation_id,row,live);
   if(prior){check(prior.request_hash===requestHash,409,'followup_operation_conflict');const current=await this.authority(tx,identity,row.configuration.origin,input.action,live,input.action==='resume');return this.envelope(row,current,{receipt:clone(prior.receipt),created:false});}
   check(row.revision===input.expected_revision,409,'followup_revision_conflict');check(input.action==='pause'?row.status==='configured':input.action==='resume'?row.status==='paused':row.status!=='revoked',409,'followup_state_conflict');
   if(input.action==='resume')check(!['ended','occurrence_limit','budget_exhausted'].includes(this.reason({...row,status:'configured'},this.now())),409,'followup_ended');
   const at=this.now();check(at>=Date.parse(row.updated_at),409,'followup_write_deadline');const next={...row,status:{pause:'paused',resume:'configured',revoke:'revoked'}[input.action],revision:row.revision+1,updated_at:iso(at)},receipt=this.receipt(input,next,input.action,at);
   check(await tx.compareAndSwap(identity.owner,K.triggers,id,{revision:row.revision,status:row.status},{status:next.status,revision:next.revision,updated_at:next.updated_at}),409,'followup_revision_conflict');live();
   check(await tx.insertIfAbsent(identity.owner,K.operations,{id:input.operation_id,scope_id:identity.scope_id,subject_id:identity.subject_id,trigger_id:id,input:clone(input),request_hash:requestHash,receipt}),409,'followup_operation_conflict');live();const current=await this.authority(tx,identity,next.configuration.origin,input.action,live,input.action==='resume');if(input.action==='resume')check(this.now()<Date.parse(next.configuration.end.not_after),409,'followup_ended');live();return this.envelope(next,current,{receipt,created:true});
  });
 }
 async materialize(identity,id,{now,limit=1,signal}={}){
  identity=validateFollowupIdentity(identity);check(Number.isSafeInteger(limit)&&limit>=1&&limit<=L.materialize&&(now===undefined||Number.isSafeInteger(now)),422,'followup_schema_invalid');const live=this.live(signal),at=now??this.now();check(at>=0&&at<=this.now(),422,'followup_schema_invalid');
  return this.repository.transaction(async tx=>{let {row}=await this.current(tx,identity,id,'materialize',live,{requireCurrent:true});const origin=clone(row.configuration.origin),dues=[];let created=0;
   check(at>=Date.parse(row.created_at),422,'followup_schema_invalid');const history=await this.dues(tx,identity,row,live);
   for(let i=0;i<limit;i++){
    if(this.reason(row,at)||Date.parse(row.next_due_at)>at)break;
    const scheduled=row.next_due_at,dueID=followupDueID(id,row.schedule_revision,scheduled);await tx.lock(identity.owner,K.dues,dueID);live();check(!await tx.get(identity.owner,K.dues,dueID),409,'followup_due_corrupt');
    const fields={schema_version:1,contract:FOLLOWUP_DUE_CONTRACT,id:dueID,trigger_id:id,schedule_revision:row.schedule_revision,scope_id:identity.scope_id,subject_id:identity.subject_id,configuration_hash:row.configuration_hash,scheduled_at:scheduled,observed_at:iso(at),quiet_at_due:followupQuietAt(scheduled,row.configuration.schedule.time_zone,row.configuration.quiet_hours),reserved_execution_ms:row.configuration.budget.per_due_execution_ms,state:'blocked_authorization',run_id:null},due={...fields,due_hash:hash(fields)};
    check(await tx.insertIfAbsent(identity.owner,K.dues,due),409,'followup_due_conflict');live();dues.push(due);created++;
    const next={...row,materialized_count:row.materialized_count+1,reserved_execution_ms:row.reserved_execution_ms+due.reserved_execution_ms,next_due_at:iso(Date.parse(scheduled)+row.configuration.schedule.interval_seconds*1000),updated_at:iso(at)};
    check(await tx.compareAndSwap(identity.owner,K.triggers,id,{revision:row.revision,status:'configured',materialized_count:row.materialized_count,next_due_at:scheduled},{materialized_count:next.materialized_count,reserved_execution_ms:next.reserved_execution_ms,next_due_at:next.next_due_at,updated_at:next.updated_at}),409,'followup_due_conflict');live();row=next;
   }
   const current=await this.authority(tx,identity,origin,'materialize',live,true);if(created)check(this.now()<Date.parse(row.configuration.end.not_after),409,'followup_ended');live();
   // Repeating an observed instant reads the original due facts, never allocates
   // replacement IDs/budgets or dispatches an unknown original operation.
   if(!created)dues.push(...history.filter(d=>Date.parse(d.scheduled_at)<=at).sort((a,b)=>b.scheduled_at.localeCompare(a.scheduled_at)).slice(0,limit));
   return this.envelope(row,current,{dues:clone(dues),created_count:created,blocked_reason:this.reason(row,at)??(created?'execution_authorization_required':'not_due')});
  });
 }
 async dues(tx,identity,row,live){
  const dues=(await tx.list(identity.owner,K.dues)).filter(d=>d.trigger_id===row.id).sort((a,b)=>String(a.scheduled_at).localeCompare(String(b.scheduled_at)));live();
  check(dues.length===row.materialized_count&&dues.reduce((sum,d)=>sum+d.reserved_execution_ms,0)===row.reserved_execution_ms,409,'followup_due_corrupt');
  for(const [index,due] of dues.entries()){this.validateDue(due,row,identity);check(due.scheduled_at===iso(Date.parse(row.configuration.schedule.first_due_at)+index*row.configuration.schedule.interval_seconds*1000)&&Date.parse(due.scheduled_at)<Date.parse(row.configuration.end.not_after),409,'followup_due_corrupt');}return clone(dues);
 }
 validateDue(due,row,identity){
  try{shape(due,['schema_version','contract','id','trigger_id','schedule_revision','scope_id','subject_id','configuration_hash','scheduled_at','observed_at','quiet_at_due','reserved_execution_ms','state','run_id','due_hash']);}catch{check(false,409,'followup_due_corrupt');}const {due_hash,...fields}=due;
  check(due_hash===hash(fields)&&due.schema_version===1&&due.contract===FOLLOWUP_DUE_CONTRACT&&due.id===followupDueID(row.id,row.schedule_revision,due.scheduled_at)&&due.trigger_id===row.id&&due.scope_id===identity.scope_id&&due.subject_id===identity.subject_id&&due.schedule_revision===row.schedule_revision&&due.configuration_hash===row.configuration_hash&&followupInstant(due.observed_at)&&Date.parse(due.observed_at)>=Date.parse(due.scheduled_at)&&due.quiet_at_due===followupQuietAt(due.scheduled_at,row.configuration.schedule.time_zone,row.configuration.quiet_hours)&&due.reserved_execution_ms===row.configuration.budget.per_due_execution_ms&&due.state==='blocked_authorization'&&due.run_id===null,409,'followup_due_corrupt');
 }
}
