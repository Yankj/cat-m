import {Buffer} from 'node:buffer';
import {check,shape,hash,clone,UUID} from '../facade-r2/src/common.mjs';
import {samePlan} from './plan-contract.mjs';
import {SOURCE_IDS,SOURCE_LIMITS,validateFrozenSourceCatalog,sourceReadIdentity,policyTargetForURL,canonicalPublicURL} from './public-source-contract.mjs';
import {sourceBodyHash,extractPublicSourceText} from '../../public-web-reader.mjs';

export const SOURCE_READS='catpaw-task-source-reads',SOURCE_RECEIPTS='catpaw-task-source-receipts';
export async function hasUnresolvedSourceReads(tx,owner,runID){return (await tx.list(owner,SOURCE_READS)).some(r=>r.run_id===runID&&['dispatched','unknown'].includes(r.state));}
const iso=clock=>new Date(clock()).toISOString();
const publicSource=r=>({source_id:r.source_id,read_id:r.id,requested_url:r.requested_url,final_url:r.final_url,read_at:r.read_at,content_hash:r.content_hash,excerpt:r.excerpt});
const resultFor=r=>({...publicSource(r),text:r.text,text_hash:r.text_hash,receipt_hash:r.receipt_hash,plan_reference:clone(r.plan_reference)});
async function taskBinding(tx,owner,run,task){
 check(task?.id===run.task_id&&task.state?.catpaw?.run_id===run.id&&['operation_id','delegation_id','request_hash','grant_epoch','delegation_revision'].every(k=>task.state.catpaw[k]===run[k])&&hash(run.frozen_request)===run.request_hash,409,'source_binding_conflict');
 const head=await tx.get(owner,'catpaw-task-plan-heads',run.id),planReference=task.state.plan_binding;
 check(head?.run_id===run.id&&head.task_id===task.id&&head.scope_id===run.frozen_request.scope.scope_id&&head.subject_id===run.frozen_request.subject_id&&head.conversation_id===run.frozen_request.conversation_id&&Number.isSafeInteger(head.applied_revision)&&head.applied_revision>0&&Number.isSafeInteger(head.accepted_revision)&&head.accepted_revision>=head.applied_revision&&/^[a-f0-9]{64}$/.test(head.applied_plan_hash)&&samePlan(planReference,{revision:head.applied_revision,plan_hash:head.applied_plan_hash}),409,'source_plan_binding_conflict');
 const version=await tx.get(owner,'catpaw-task-plan-versions',`${run.id}:${head.applied_revision}`);check(version?.run_id===run.id&&version.revision===head.applied_revision&&version.plan_hash===head.applied_plan_hash&&hash(version.content)===head.applied_plan_hash,409,'source_plan_binding_conflict');return planReference;
}
function receiptValid(receipt,context){
 check(receipt?.id===context.readID&&receipt.run_id===context.run.id&&receipt.task_id===context.task.id&&receipt.conversation_id===context.run.frozen_request.conversation_id&&receipt.source_id===context.source.source_id&&receipt.requested_url===context.source.requested_url&&receipt.canonical_url===context.source.requested_url&&samePlan(receipt.plan_reference,context.planReference)&&receipt.policy_hash===context.catalog.policy_hash&&receipt.request_hash===context.requestHash,409,'source_receipt_binding_conflict');
 check(typeof receipt.body_base64==='string'&&receipt.body_base64.length<=Math.ceil(SOURCE_LIMITS.body/3)*4&&Number.isSafeInteger(receipt.byte_count)&&receipt.byte_count>0&&receipt.byte_count<=SOURCE_LIMITS.body,409,'source_receipt_corrupt');
 const {receipt_hash,...frozen}=receipt;check(hash(frozen)===receipt_hash,409,'source_receipt_corrupt');
 const bytes=new Uint8Array(Buffer.from(receipt.body_base64,'base64'));
 check(bytes.length===receipt.byte_count&&sourceBodyHash(bytes)===receipt.content_hash&&extractPublicSourceText(bytes,receipt.media_type)===receipt.text&&hash(receipt.text)===receipt.text_hash&&receipt.excerpt===receipt.text.slice(0,SOURCE_LIMITS.excerpt),409,'source_receipt_corrupt');
 check(canonicalPublicURL(receipt.final_url)===receipt.final_url&&/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(receipt.read_at)&&Number.isFinite(Date.parse(receipt.read_at))&&new Date(receipt.read_at).toISOString()===receipt.read_at,409,'source_receipt_corrupt');return receipt;
}
export class TaskSourceService {
 constructor({facade,reader,clock=Date.now}){check(facade?.repository&&reader,503,'source_service_not_configured');Object.assign(this,{facade,reader,clock});}
 async admitted(tx,owner,taskID,leaseID,assertLive){
  assertLive();const initial=await tx.get(owner,'tasks',taskID),runHint=initial?.state?.catpaw?await tx.get(owner,'catpaw-runs',initial.state.catpaw.run_id):null;assertLive();check(runHint?.frozen_request?.scope,409,'unmanaged_task');
  await tx.withScope(runHint.frozen_request.scope.scope_id,async scoped=>{check((await scoped.scope()).identity.owner===owner,403,'scope_forbidden');});assertLive();
  const admitted=await this.facade.admittedTask(tx,owner,taskID,{running:true});assertLive();await tx.lock(owner,'tasks',taskID);assertLive();const task=await tx.get(owner,'tasks',taskID),run=admitted.run;
  check(task?.status==='running'&&task.leaseId===leaseID&&Date.parse(task.leaseUntil)>this.clock(),409,'lease_lost');
  check(hash(task.state.catpaw)===hash(admitted.task.state.catpaw)&&run.task_id===taskID,409,'source_binding_conflict');
  const catalog=validateFrozenSourceCatalog(run.frozen_request.public_sources);
  await tx.lock(owner,'catpaw-task-plan-heads',run.id);assertLive();const planReference=await taskBinding(tx,owner,run,task);assertLive();
  return {task,run,catalog,planReference};
 }
 context(admitted,sourceID){
  check(SOURCE_IDS.includes(sourceID),422,'source_id_invalid');const source=admitted.catalog.sources.find(s=>s.source_id===sourceID);check(source,404,'source_not_admitted');
  const readID=sourceReadIdentity(admitted.run.id,admitted.planReference,sourceID),requestHash=hash({run_id:admitted.run.id,task_id:admitted.task.id,run_request_hash:admitted.run.request_hash,source,plan_reference:admitted.planReference,policy_hash:admitted.catalog.policy_hash});
  return {...admitted,source,readID,requestHash};
 }
 async guardRead(owner,taskID,leaseID,sourceID,readID,{assertLive}){
  return this.facade.repository.transaction(async tx=>{const context=this.context(await this.admitted(tx,owner,taskID,leaseID,assertLive),sourceID);check(context.readID===readID,409,'source_plan_binding_conflict');await tx.lock(owner,SOURCE_READS,readID);assertLive();const read=await tx.get(owner,SOURCE_READS,readID);check(read?.state==='dispatched'&&read.request_hash===context.requestHash&&read.dispatch_lease_id===leaseID,409,'source_read_conflict');assertLive();await this.admitted(tx,owner,taskID,leaseID,assertLive);assertLive();return context;});
 }
 async readSource(owner,taskID,leaseID,sourceID,{assertLive,signal,commitCallback}={}){
  check(typeof assertLive==='function'&&signal&&typeof signal.addEventListener==='function',503,'source_step_permission_not_configured');
  const callerLive=assertLive;assertLive=()=>{callerLive();check(!signal.aborted,409,'source_read_cancelled');};assertLive();
  const begun=await this.facade.repository.transaction(async tx=>{
   const context=this.context(await this.admitted(tx,owner,taskID,leaseID,assertLive),sourceID);await tx.lock(owner,SOURCE_READS,context.readID);assertLive();const previous=await tx.get(owner,SOURCE_READS,context.readID);
   if(previous){check(previous.request_hash===context.requestHash,409,'source_read_conflict');return {context,state:previous.state};}
   this.reader.assertReady();check(this.reader.policyHash===context.catalog.policy_hash,409,'source_policy_changed');policyTargetForURL(this.reader.policy,context.source.requested_url);assertLive();
   const read={id:context.readID,run_id:context.run.id,task_id:taskID,conversation_id:context.run.frozen_request.conversation_id,source_id:sourceID,requested_url:context.source.requested_url,plan_reference:clone(context.planReference),policy_hash:context.catalog.policy_hash,request_hash:context.requestHash,state:'dispatched',dispatch_lease_id:leaseID,dispatched_at:iso(this.clock)};
   check(await tx.insertIfAbsent(owner,SOURCE_READS,read),409,'source_read_conflict');assertLive();await this.admitted(tx,owner,taskID,leaseID,assertLive);assertLive();return {context,state:'new'};
  });
  const {context}=begun;
  if(['dispatched','unknown'].includes(begun.state))return {state:'unknown',read_id:context.readID,source_id:sourceID};
  if(begun.state==='failed')return {state:'failed',read_id:context.readID,source_id:sourceID};
  if(begun.state==='received')return this.commitReceived(owner,taskID,leaseID,sourceID,context.readID,null,{assertLive,commitCallback});
  let received;
  try{
   await this.guardRead(owner,taskID,leaseID,sourceID,context.readID,{assertLive});assertLive();signal.throwIfAborted?.();
   received=await this.reader.read(context.source.requested_url,{signal,assertLive,expectedPolicyHash:context.catalog.policy_hash,beforeSend:async()=>{await this.guardRead(owner,taskID,leaseID,sourceID,context.readID,{assertLive});assertLive();signal.throwIfAborted?.();}});assertLive();
  }catch(error){
   if(error?.status===422||error?.status===413||error?.status===403){
    try{await this.facade.repository.transaction(async tx=>{const current=this.context(await this.admitted(tx,owner,taskID,leaseID,assertLive),sourceID);check(current.readID===context.readID,409,'source_plan_binding_conflict');await tx.lock(owner,SOURCE_READS,current.readID);const read=await tx.get(owner,SOURCE_READS,current.readID);check(read?.state==='dispatched'&&read.request_hash===current.requestHash,409,'source_read_conflict');await tx.put(owner,SOURCE_READS,{...read,state:'failed',error_code:error.code,failed_at:iso(this.clock)});assertLive();await this.admitted(tx,owner,taskID,leaseID,assertLive);assertLive();});return {state:'failed',read_id:context.readID,source_id:sourceID};}catch{/* denied/late failure metadata cannot override the original dispatch */}
   }
   return {state:'unknown',read_id:context.readID,source_id:sourceID};
  }
  try{return await this.commitReceived(owner,taskID,leaseID,sourceID,context.readID,received,{assertLive,commitCallback});}
  catch{return {state:'unknown',read_id:context.readID,source_id:sourceID};}
 }
 async commitReceived(owner,taskID,leaseID,sourceID,readID,received,{assertLive,commitCallback}){
  return this.facade.repository.transaction(async tx=>{
   const context=this.context(await this.admitted(tx,owner,taskID,leaseID,assertLive),sourceID);check(context.readID===readID,409,'source_plan_binding_conflict');await tx.lock(owner,SOURCE_READS,readID);assertLive();let read=await tx.get(owner,SOURCE_READS,readID);check(read?.request_hash===context.requestHash,409,'source_read_conflict');let receipt;
   if(read.state==='received')receipt=receiptValid(await tx.get(owner,SOURCE_RECEIPTS,readID),context);
   else{
    check(read.state==='dispatched'&&read.dispatch_lease_id===leaseID&&received,409,'source_read_conflict');
    check(received.requested_url===context.source.requested_url&&received.canonical_url===context.source.requested_url&&received.body_bytes instanceof Uint8Array&&received.content_hash===sourceBodyHash(received.body_bytes)&&received.byte_count===received.body_bytes.length&&received.text===extractPublicSourceText(received.body_bytes,received.media_type)&&received.text_hash===hash(received.text),409,'source_transport_receipt_invalid');
    check(this.reader.policyHash===context.catalog.policy_hash,409,'source_policy_changed');policyTargetForURL(this.reader.policy,received.final_url);
    check(Array.isArray(received.redirect_chain)&&received.redirect_chain.length>0&&received.redirect_chain.length<=SOURCE_LIMITS.redirects+1&&received.redirect_chain[0]===context.source.requested_url&&received.redirect_chain.at(-1)===received.final_url,409,'source_transport_receipt_invalid');for(const url of received.redirect_chain)check(policyTargetForURL(this.reader.policy,url).url===url,409,'source_transport_receipt_invalid');
    const fields={id:readID,run_id:context.run.id,task_id:taskID,conversation_id:context.run.frozen_request.conversation_id,source_id:sourceID,requested_url:context.source.requested_url,canonical_url:received.canonical_url,final_url:received.final_url,redirect_chain:clone(received.redirect_chain),read_at:received.read_at,committed_at:iso(this.clock),content_hash:received.content_hash,text_hash:received.text_hash,text:received.text,excerpt:received.text.slice(0,SOURCE_LIMITS.excerpt),media_type:received.media_type,byte_count:received.byte_count,body_base64:Buffer.from(received.body_bytes).toString('base64'),policy_hash:context.catalog.policy_hash,request_hash:context.requestHash,plan_reference:clone(context.planReference),transport_reality:received.transport_reality};
    receipt=receiptValid({...fields,receipt_hash:hash(fields)},context);check(await tx.insertIfAbsent(owner,SOURCE_RECEIPTS,receipt),409,'source_receipt_conflict');assertLive();read={...read,state:'received',receipt_hash:receipt.receipt_hash,received_at:receipt.committed_at};await tx.put(owner,SOURCE_READS,read);assertLive();
   }
   const toolResult=resultFor(receipt);if(commitCallback)await commitCallback(tx,{task:context.task,run:context.run,receipt:clone(receipt),toolResult:clone(toolResult)});assertLive();
   const fresh=await this.admitted(tx,owner,taskID,leaseID,assertLive);check(samePlan(fresh.planReference,context.planReference),409,'source_plan_binding_conflict');assertLive();
   return {state:'received',read_id:readID,source_id:sourceID,receipt:clone(receipt),toolResult,task:fresh.task};
  });
 }
 async requiredReceipts(tx,owner,run,task){
  const catalog=validateFrozenSourceCatalog(run.frozen_request.public_sources),planReference=await taskBinding(tx,owner,run,task);
  const receipts=[];
  for(const source of catalog.sources){const context=this.context({run,task,catalog,planReference},source.source_id),read=await tx.get(owner,SOURCE_READS,context.readID);check(read?.state==='received'&&read.request_hash===context.requestHash,409,'required_source_receipt_missing');receipts.push(receiptValid(await tx.get(owner,SOURCE_RECEIPTS,context.readID),context));}
  return receipts;
 }
 async publicCatalogInTransaction(tx,owner,run,task){return (await this.requiredReceipts(tx,owner,run,task)).map(publicSource);}
 async validateCitationsInTransaction(tx,owner,run,task,citations){
  check(Array.isArray(citations)&&citations.length>0&&citations.length<=12,422,'source_citations_invalid');const receipts=await this.requiredReceipts(tx,owner,run,task),covered=new Set(),validated=[];
  for(const citation of citations){shape(citation,['source_id','quote']);const receipt=receipts.find(r=>r.source_id===citation.source_id);check(receipt&&typeof citation.quote==='string'&&citation.quote.trim().length>=10&&citation.quote.length<=500,422,'source_citations_invalid');const quote=citation.quote.replace(/\s+/gu,' ').trim();check(receipt.text.includes(quote),422,'source_quote_not_supported');covered.add(citation.source_id);validated.push({...clone(citation),quote,read_id:receipt.id,content_hash:receipt.content_hash});}
  check(receipts.every(r=>covered.has(r.source_id)),422,'source_citations_incomplete');return {sources:receipts.map(publicSource),citations:validated,receipt_references:receipts.map(r=>({source_id:r.source_id,read_id:r.id,receipt_hash:r.receipt_hash,plan_reference:clone(r.plan_reference)}))};
 }
 async readCatalog(auth,scopeID,runID){
  check(UUID.test(runID),422,'schema_invalid');const scoped=await this.facade.scoped(auth,scopeID);
  return this.facade.repository.transaction(async tx=>{
   await tx.withScope(scopeID,async()=>{});const run=await this.facade.ownedRun(tx,scoped.owner,runID,scoped.principal,scopeID);await tx.lock(scoped.owner,'catpaw-delegations',run.delegation_id);await tx.lock(scoped.owner,'tasks',run.task_id);const task=await tx.get(scoped.owner,'tasks',run.task_id);check(task,404,'not_found');
   const context={...scoped,run,task};check(typeof this.facade.beforeSourceRead==='function',503,'source_viewer_authority_not_configured');await this.facade.beforeSourceRead(tx,context);await tx.lock(scoped.owner,'catpaw-task-plan-heads',run.id);await taskBinding(tx,scoped.owner,run,task);
   const catalog=validateFrozenSourceCatalog(run.frozen_request.public_sources),reads=[];for(const source of catalog.sources){const bound=this.context({run,task,catalog,planReference:task.state.plan_binding},source.source_id),read=await tx.get(scoped.owner,SOURCE_READS,bound.readID);reads.push({source_id:source.source_id,read_id:bound.readID,requested_url:source.requested_url,state:read?.state==='dispatched'?'unknown':read?.state??'not_started',...read?.state==='failed'?{error_code:read.error_code}:{},...read?.state==='received'?{source:publicSource(receiptValid(await tx.get(scoped.owner,SOURCE_RECEIPTS,bound.readID),bound))}:{}});}
   await this.facade.beforeSourceRead(tx,context);return {schema_version:1,contract:'catpaw.task-public-sources.v1',run_id:run.id,task_id:task.id,plan_reference:clone(task.state.plan_binding),reads};
  });
 }
}
