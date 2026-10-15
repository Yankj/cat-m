import {randomUUID} from 'node:crypto';
import {Buffer} from 'node:buffer';
import {ApiError,check,shape,UUID,canonical,hash,clone} from '../facade-r2/src/common.mjs';

export const MEMORY_PROPOSAL_CONTRACT='catpaw.memory-proposal.v1';
export const MEMORY_PROPOSAL_MAX_CANDIDATES=6;
const extractorVersion='extract-v1';
const referenceKeys=['schema_version','contract','scope_id','subject_id','conversation_id','turn_id','source_id','source_hash','job_id','lease_id','memory_generation','extractor_version'];
const receiptKeys=['schema_version','contract','scope_id','conversation_id','turn_id','source_id','source_hash','memory_generation','job_id','candidates','status','confirmed'];
const positive=value=>Number.isSafeInteger(value)&&value>0;
const callHash=call=>hash({id:call.id,name:call.name,arguments:call.arguments});
const normalize=async fn=>{try{return await fn();}catch(error){if(error?.name==='Error'&&error.code&&Number.isInteger(error.status))throw new ApiError(error.status,error.code);throw error;}};

// Models select bounded data, never source IDs, trust, assertion, generation or authority.
export function validateConversationMemoryProposalCall(call){
 shape(call,['id','name','arguments']);
 check(typeof call.id==='string'&&call.id.trim().length>0&&call.id.length<=160&&call.name==='propose_memory_v1',422,'invalid_tool_call');
 shape(call.arguments,['candidates']);const values=call.arguments.candidates;
 check(Array.isArray(values)&&values.length>=1&&values.length<=MEMORY_PROPOSAL_MAX_CANDIDATES,422,'invalid_tool_arguments');
 for(const value of values){
  shape(value,['kind','predicate','value','scope','evidence']);
  check(['fact','preference'].includes(value.kind)&&typeof value.predicate==='string'&&/^[a-z][a-z0-9_.]{0,79}$/.test(value.predicate)&&['conversation','workspace'].includes(value.scope),422,'invalid_tool_arguments');
  let encoded;try{encoded=canonical(value.value);}catch{check(false,422,'invalid_tool_arguments');}
  check(Buffer.byteLength(encoded)<=1000,422,'invalid_tool_arguments');
  shape(value.evidence,['span_start','span_end']);
  check(Number.isSafeInteger(value.evidence.span_start)&&value.evidence.span_start>=0&&Number.isSafeInteger(value.evidence.span_end)&&value.evidence.span_end>value.evidence.span_start,422,'invalid_tool_arguments');
 }
 return clone(call);
}
function referenceMatches(reference,scope,principal,turn,source){
 shape(reference,referenceKeys);
 check(reference.schema_version===1&&reference.contract===MEMORY_PROPOSAL_CONTRACT&&reference.scope_id===scope.scope_id&&reference.subject_id===principal.subject_id&&reference.conversation_id===turn.conversation_id&&reference.turn_id===turn.id&&reference.source_id===source.id&&reference.source_hash===source.content_hash&&reference.memory_generation===source.memory_generation&&reference.extractor_version===extractorVersion&&UUID.test(reference.job_id)&&UUID.test(reference.lease_id),409,'memory_proposal_binding_conflict');
}
async function currentBinding(runtime,records,tx,{principal,scope,conversation,turn}){
 const foundation=runtime.foundation,row=await tx.scope(),identity=foundation.identity(principal,scope.scope_id);
 check(hash(row.identity)===hash(identity)&&tx.scopeId===scope.scope_id,403,'scope_forbidden');
 check(row.enabled===true&&row.memory_user_enabled===true,409,'memory_disabled');
 check(row.memory_subject_id===principal.subject_id,403,'memory_scope_subject_conflict');
 check(typeof runtime.memoryAuthority==='function',503,'memory_authority_not_configured');
 await runtime.memoryAuthority(tx,principal,identity);
 const current=await records.get(identity.owner,'native-chat-turns',turn.id);
 check(current&&current.id===turn.id&&current.scope_id===scope.scope_id&&current.subject_id===principal.subject_id&&current.conversation_id===conversation.id&&current.conversation_id===turn.conversation_id,409,'memory_proposal_binding_conflict');
 check(current.state==='running'&&!current.content_redacted&&!current.work_intent&&!current.revision_target,409,'memory_proposal_turn_fenced');
 check(current.memory_proposal_contract===MEMORY_PROPOSAL_CONTRACT,409,'memory_proposal_not_negotiated');
 check(current.source_auth?.subject_id===principal.subject_id&&current.source_auth.scope_id===scope.scope_id&&hash(current.source_auth)===hash(turn.source_auth)&&current.source_auth.session_id===principal.session_id&&current.source_auth.issuer===principal.issuer,403,'memory_proposal_source_required');
 const c=await foundation.authoritativeConversation(tx,principal,scope.scope_id,current.conversation_id);
 check(c.state==='active'&&c.grant_epoch===current.grant_epoch&&c.revision===current.conversation_revision,409,'grant_conflict');
 const source=await foundation.required(tx,'sources',current.input.message.id);
 check(source.scope_id===scope.scope_id&&source.conversation_id===c.id&&source.turn_id===current.id&&source.id===current.input.message.id&&source.type==='user_message'&&source.trust==='user_direct'&&source.authenticated_actor_id===principal.subject_id,409,'untrusted_source');
 check(!source.deleted_at&&!source.suppressed_for_memory&&source.memory_generation===row.generation&&source.content_hash===hash(source.text)&&source.content_hash===hash(current.input.message.text),409,'source_fenced');
 check(['low','sensitive'].includes(source.sensitivity)&&source.data_class===runtime.dataClass,409,'memory_proposal_source_required');
 return {row,identity,turn:current,source,conversation:c};
}
async function scoped(runtime,records,args,fn){
 check(runtime.memoryContextEnabled===true,503,'memory_proposal_not_configured');
 return normalize(()=>records.withScope(args.scope.scope_id,tx=>fn(tx),{reuseLockedScope:true}));
}
export async function stageConversationMemoryExtraction(runtime,records,args){
 if(runtime.memoryContextEnabled!==true||args.turn.memory_proposal_contract!==MEMORY_PROPOSAL_CONTRACT||args.turn.work_intent||args.turn.revision_target)return null;
 return scoped(runtime,records,args,async tx=>{
  const row=await tx.scope();if(row.enabled!==true||row.memory_user_enabled!==true)return null;
  const bound=await currentBinding(runtime,records,tx,args);
  if(bound.turn.memory_extraction){referenceMatches(bound.turn.memory_extraction,args.scope,args.principal,bound.turn,bound.source);return clone(bound.turn.memory_extraction);}
  const {job}=await runtime.foundation.stageExtractionInTransaction(tx,args.principal,args.scope.scope_id,{source_id:bound.source.id,extractor_version:extractorVersion});
  const ref={schema_version:1,contract:MEMORY_PROPOSAL_CONTRACT,scope_id:args.scope.scope_id,subject_id:args.principal.subject_id,conversation_id:bound.turn.conversation_id,turn_id:bound.turn.id,source_id:bound.source.id,source_hash:bound.source.content_hash,job_id:job.id,lease_id:randomUUID(),memory_generation:bound.row.generation,extractor_version:extractorVersion};
  await currentBinding(runtime,records,tx,args);return ref;
 });
}
// The chat owner MUST save this receipt and {id:call.id,hash:callHash(call)} on
// the same turn and in this same transaction before COMMIT. This function opens no transaction.
export async function commitConversationMemoryCandidates(runtime,records,args){
 validateConversationMemoryProposalCall(args.call);
 return scoped(runtime,records,args,async tx=>{
  const bound=await currentBinding(runtime,records,tx,args),reference=bound.turn.memory_extraction;
  check(reference,409,'memory_proposal_binding_conflict');referenceMatches(reference,args.scope,args.principal,bound.turn,bound.source);
  const prior=bound.turn.memory_proposal_receipt,priorCall=bound.turn.memory_proposal_call,digest=callHash(args.call);
  if(prior||priorCall){
   check(prior&&priorCall?.id===args.call.id&&priorCall.hash===digest,409,'memory_proposal_operation_conflict');shape(prior,receiptKeys);
   check(prior.schema_version===1&&prior.contract===MEMORY_PROPOSAL_CONTRACT&&prior.scope_id===args.scope.scope_id&&prior.conversation_id===bound.turn.conversation_id&&prior.turn_id===bound.turn.id&&prior.source_id===bound.source.id&&prior.source_hash===bound.source.content_hash&&prior.memory_generation===bound.row.generation&&prior.job_id===reference.job_id&&prior.status==='proposed'&&prior.confirmed===false&&Array.isArray(prior.candidates)&&prior.candidates.length<=MEMORY_PROPOSAL_MAX_CANDIDATES&&prior.candidates.every(c=>UUID.test(c.id)&&positive(c.version)),409,'memory_proposal_binding_conflict');
   await currentBinding(runtime,records,tx,args);return clone(prior);
  }
  const candidates=args.call.arguments.candidates.map(value=>{
   check(value.evidence.span_end<=bound.source.text.length&&bound.source.text.slice(value.evidence.span_start,value.evidence.span_end).trim().length>0,422,'evidence_invalid');
   return {kind:value.kind,predicate:value.predicate,value:clone(value.value),conditions:value.scope==='workspace'?{}:{conversation_id:bound.turn.conversation_id},assertion:'inferred',evidence:clone(value.evidence)};
  });
  await runtime.foundation.claimExtractionJobInTransaction(tx,args.principal,args.scope.scope_id,reference);
  const result=await runtime.foundation.submitCandidatesInTransaction(tx,args.principal,args.scope.scope_id,{job_id:reference.job_id,lease_id:reference.lease_id,memory_generation:reference.memory_generation,candidates});
  const receipt={schema_version:1,contract:MEMORY_PROPOSAL_CONTRACT,scope_id:args.scope.scope_id,conversation_id:bound.turn.conversation_id,turn_id:bound.turn.id,source_id:bound.source.id,source_hash:bound.source.content_hash,memory_generation:reference.memory_generation,job_id:reference.job_id,candidates:result.candidates.map(candidate=>({id:candidate.id,version:candidate.version})),status:'proposed',confirmed:false};
  await currentBinding(runtime,records,tx,args);return receipt;
 });
}
