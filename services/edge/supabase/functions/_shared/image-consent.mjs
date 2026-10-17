import {check,shape,hash,iso} from './core/facade-r2/src/common.mjs';
import {consentId} from './consent.mjs';
export async function assertImageConsent(tx,owner,source,cid,routeHash){
 const row=await tx.get(owner,'image-provider-consents',consentId(source.subject_id,cid));
 check(routeHash&&source.image_route_hash===routeHash&&row?.decision==='allow'&&row.non_sensitive_confirmed===true&&row.subject_id===source.subject_id&&row.scope_id===source.scope_id&&row.conversation_id===cid&&row.route_hash===routeHash&&row.revision===source.image_consent_revision,403,'provider_image_consent_required');return row;
}
export async function imageConsent(runtime,sourceChecker,auth,scopeID,cid,input=null){
 const {owner,principal,scope}=await runtime.facade.scoped(auth,scopeID),source={subject_id:principal.subject_id,scope_id:scopeID,issuer:principal.issuer,session_id:principal.session_id,issued_at:principal.issued_at};
 if(input){check(input&&Object.keys(input).every(k=>['decision','expected_revision','route_hash','non_sensitive_confirmed'].includes(k))&&['decision','expected_revision','route_hash'].every(k=>Object.hasOwn(input,k)),422,'invalid_consent');check(['allow','deny'].includes(input.decision)&&Number.isInteger(input.expected_revision)&&input.expected_revision>=0&&typeof input.route_hash==='string',422,'invalid_consent');check(input.decision==='deny'||runtime.vision.enabled,503,'image_input_unavailable');check(input.decision==='deny'||input.non_sensitive_confirmed===true,403,'image_safety_confirmation_required');}
 const value=await runtime.repository.transaction(async tx=>{
  await tx.withScope(scopeID,async scoped=>{check((await scoped.scope()).identity.owner===owner,403,'scope_forbidden');});await sourceChecker(tx,source,scope);
  await tx.lock(owner,'native-chat-conversations',cid);await runtime.chat.conversation(tx,owner,cid,principal.subject_id,scopeID);
  const id=consentId(principal.subject_id,cid),old=await tx.get(owner,'image-provider-consents',id);if(!input)return old;
  check((old?.revision??0)===input.expected_revision,409,'revision_conflict');check(input.route_hash===(input.decision==='deny'&&old?old.route_hash:runtime.vision.routeHash),422,'invalid_consent');
  const row={id,scope_id:scopeID,conversation_id:cid,subject_id:principal.subject_id,route_hash:input.route_hash,decision:input.decision,non_sensitive_confirmed:input.decision==='allow'&&input.non_sensitive_confirmed===true,revision:(old?.revision??0)+1,updated_at:iso()};await tx.put(owner,'image-provider-consents',row);
  if(input.decision==='deny')for(const turn of await tx.list(owner,'native-chat-turns'))if(turn.conversation_id===cid&&turn.subject_id===principal.subject_id&&turn.state==='running'&&turn.image_attachments?.length){
   const error={code:'image_consent_revoked',retryable:false,reconciliation_required:false};await tx.put(owner,'native-chat-turns',{...turn,state:'failed',error,finished_at:iso(),events:[...turn.events,runtime.chat.event(turn,'turn_failed',error)]});
  }
  return row;
 });
 if(value?.decision==='deny')for(const active of runtime.chat.active.values())if(active.subject_id===principal.subject_id&&active.conversation_id===cid&&active.has_images)active.controller.abort();return value;
}
