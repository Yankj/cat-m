import {lockTaskWorkSourceInTransaction,revokeTaskWorkGrantsForSourceInTransaction} from './core/src/task-work-grant-lifecycle.mjs';
import {ApiError,check,shape,hash,iso} from './core/facade-r2/src/common.mjs';import {stableUUID} from './core/src/local-output-facade.mjs';
export const consentId=(subject,cid)=>stableUUID(`private-model-consent:${subject}:${cid}`);
/** v1.1 Round 2: the consent that actually applies to a conversation. A row materialized from the account consent
 * (source:'account') is only valid while the account consent for (subject, current route_hash) still allows, and its
 * sensitive_confirmed is the stricter (AND) of the conversation copy and the account's current value. Every consumer
 * (assertConsent → task/revision/work-grant paths, plan read, observation, turn admission) goes through here. */
export async function effectiveConsent(tx,owner,subject,conversationId,routeHash){const row=await tx.get(owner,'provider-consents',consentId(subject,conversationId));
 if(row?.source!=='account')return row;const account=await tx.get(owner,'provider-consents',accountConsentId(subject,routeHash));
 if(!accountAllows(account,row.scope_id,subject,routeHash))return {...row,decision:'account_revoked'};
 return {...row,sensitive_confirmed:row.sensitive_confirmed===true&&account.sensitive_confirmed===true};}
export async function assertConsent(tx,owner,source,conversationId,routeHash){const row=await effectiveConsent(tx,owner,source.subject_id,conversationId,routeHash);check(row?.decision==='allow'&&row.scope_id===source.scope_id&&row.route_hash===routeHash&&row.revision===source.consent_revision,403,'provider_consent_required');return row;}
export async function consentRead(runtime,auth,scopeId,cid){const {owner,principal}=await runtime.facade.scoped(auth,scopeId);return runtime.repository.transaction(async tx=>{await runtime.chat.conversation(tx,owner,cid,principal.subject_id,scopeId);return await tx.get(owner,'provider-consents',consentId(principal.subject_id,cid));});}
export async function consentWrite(runtime,auth,scopeId,cid,input,config,{sourceChecker}={}){check(input&&Object.keys(input).every(k=>['decision','expected_revision','route_hash','sensitive_confirmed','apply_to','expected_account_revision'].includes(k))&&(input.apply_to===undefined&&input.expected_account_revision===undefined||input.apply_to==='account'&&input.decision==='allow'&&Number.isInteger(input.expected_account_revision)&&input.expected_account_revision>=0)&&['decision','expected_revision','route_hash'].every(k=>k in input)&&(input.sensitive_confirmed===undefined||typeof input.sensitive_confirmed==='boolean'),422,'invalid_consent');check(['allow','deny'].includes(input.decision)&&Number.isInteger(input.expected_revision)&&input.expected_revision>=0&&input.route_hash===config.routeHash,422,'invalid_consent');const {owner,principal}=await runtime.facade.scoped(auth,scopeId);
 const value=await runtime.repository.transaction(async tx=>{await checkWriterSession(tx,scopeId,principal,sourceChecker);if(runtime.facade.workGrantService)await lockTaskWorkSourceInTransaction(tx,{scope_id:scopeId,owner,source:{subject_id:principal.subject_id,scope_id:scopeId,session_id:principal.session_id,issuer:principal.issuer,issued_at:principal.issued_at}});await tx.lock(owner,'native-chat-conversations',cid);const conversation=await runtime.chat.conversation(tx,owner,cid,principal.subject_id,scopeId);const id=consentId(principal.subject_id,cid);const old=await tx.get(owner,'provider-consents',id);check((old?.revision??0)===input.expected_revision,409,'revision_conflict');
  const row={id,scope_id:scopeId,conversation_id:cid,subject_id:principal.subject_id,route_hash:config.routeHash,revision:(old?.revision??0)+1,decision:input.decision,sensitive_confirmed:input.sensitive_confirmed===true,updated_at:iso()};await tx.put(owner,'provider-consents',row);
  // v1.1 (b): {apply_to:'account'} also grants this route for every conversation of the account (same disclosure, one tap).
  // Account grant is CAS-checked against expected_account_revision. It never widens sensitive_confirmed to the whole account
  // (a sensitive confirmation given in one conversation stays in that conversation); use the account endpoint for that.
  if(input.apply_to==='account')await putAccountConsent(tx,owner,principal,scopeId,{decision:'allow',expected_revision:input.expected_account_revision,keepSensitive:true},config);
  if(input.decision==='deny'){
   await revokeTaskWorkGrantsForSourceInTransaction(tx,{owner,scope_id:scopeId,subject_id:principal.subject_id,conversation_id:cid});
   // Same authority reducer as conversation control, under the same scope/conversation lock.
   const next={...conversation,state:'revoked',revision:conversation.revision+1,grant_epoch:conversation.grant_epoch+1};await tx.put(owner,'native-chat-conversations',next);
   for(const d of await tx.list(owner,'catpaw-delegations'))if(d.conversation_id===cid&&d.state==='active'){await tx.put(owner,'catpaw-delegations',{...d,state:'revoked',revision:d.revision+1,grant_epoch:d.grant_epoch+1});for(const task of await tx.list(owner,'tasks'))if(task.state?.catpaw?.delegation_id===d.id&&!['succeeded','failed','cancelled'].includes(task.status))await tx.put(owner,'tasks',{...task,status:'cancelled',leaseId:null,leaseUntil:null,updatedAt:iso()});}
   if(conversation.last_turn_id){const turn=await tx.get(owner,'native-chat-turns',conversation.last_turn_id);if(turn?.state==='running'){const error={code:'provider_consent_revoked',retryable:false,reconciliation_required:false};await tx.put(owner,'native-chat-turns',{...turn,state:'failed',error,events:[...turn.events,runtime.chat.event(turn,'turn_failed',error)]});}}
  }
  return row;
 });
 if(value.decision==='deny')for(const entry of runtime.chat.active.values())if(entry.subject_id===principal.subject_id&&entry.conversation_id===cid)entry.controller.abort();return value;
}

// v1.1 (b) account-level model-route consent (catpaw.model-consent.v2). Same records table (kind provider-consents, owner
// partition of the account scope) — no migration. Keyed by (subject_id, route_hash): a new route_hash has no row, so it
// needs a fresh consent (Gemini option A: route change ⇒ re-consent). A conversation without its own row is materialized
// from the account row at turn admission (source:'account'), so every existing per-conversation check (revision binding of
// tasks/revisions/work grants, observation, plan reads) keeps working unchanged. A conversation's own deny always wins.
export const accountConsentId=(subject,routeHash)=>stableUUID(`private-model-consent-account:${subject}:${routeHash}`);
const accountAllows=(row,scopeId,subject,routeHash)=>row?.decision==='allow'&&row.consent_scope==='account'&&row.scope_id===scopeId&&row.subject_id===subject&&row.route_hash===routeHash;
async function checkWriterSession(tx,scopeId,principal,sourceChecker){
 // P2: consent writes require a live (not signed-out / revoked) session, like the other authority-bearing endpoints.
 await tx.withScope(scopeId,async scoped=>{if(!sourceChecker)return;const identity=(await scoped.scope()).identity;await sourceChecker(tx,{subject_id:principal.subject_id,scope_id:scopeId,issuer:principal.issuer,session_id:principal.session_id,issued_at:principal.issued_at},identity);});
}
async function putAccountConsent(tx,owner,principal,scopeId,{decision,sensitive_confirmed,expected_revision,keepSensitive=false},config){
 const id=accountConsentId(principal.subject_id,config.routeHash);await tx.lock(owner,'provider-consents',id);const old=await tx.get(owner,'provider-consents',id);
 if(keepSensitive)sensitive_confirmed=old?.decision==='allow'&&old.sensitive_confirmed===true;
 if(expected_revision!==undefined)check((old?.revision??0)===expected_revision,409,'revision_conflict');
 const row={id,consent_scope:'account',scope_id:scopeId,subject_id:principal.subject_id,route_hash:config.routeHash,revision:(old?.revision??0)+1,decision,sensitive_confirmed:sensitive_confirmed===true,updated_at:iso()};
 await tx.put(owner,'provider-consents',row);return row;
}
export async function accountConsentRead(runtime,auth,scopeId,config){const {owner,principal}=await runtime.facade.scoped(auth,scopeId);
 const row=await runtime.repository.transaction(async tx=>tx.get(owner,'provider-consents',accountConsentId(principal.subject_id,config.routeHash)));
 return {route_hash:config.routeHash,granted:accountAllows(row,scopeId,principal.subject_id,config.routeHash),applies_to:'all_conversations',consent:row??null};}
export async function accountConsentWrite(runtime,auth,scopeId,input,config,{sourceChecker}={}){
 check(input&&Object.keys(input).every(k=>['decision','expected_revision','route_hash','sensitive_confirmed'].includes(k))&&['decision','expected_revision','route_hash'].every(k=>k in input)&&(input.sensitive_confirmed===undefined||typeof input.sensitive_confirmed==='boolean'),422,'invalid_consent');
 check(['allow','deny'].includes(input.decision)&&Number.isInteger(input.expected_revision)&&input.expected_revision>=0&&input.route_hash===config.routeHash,422,'invalid_consent');
 const {owner,principal}=await runtime.facade.scoped(auth,scopeId);
 const affected=[];
 const row=await runtime.repository.transaction(async tx=>{await checkWriterSession(tx,scopeId,principal,sourceChecker);
  if(input.decision==='deny'&&runtime.facade.workGrantService)await lockTaskWorkSourceInTransaction(tx,{scope_id:scopeId,owner,source:{subject_id:principal.subject_id,scope_id:scopeId,session_id:principal.session_id,issuer:principal.issuer,issued_at:principal.issued_at}});
  const row=await putAccountConsent(tx,owner,principal,scopeId,input,config);
  // B1: an account deny takes effect immediately for every conversation relying on it — same reducer as a conversation
  // deny (work grants, delegations + their tasks, running turn) minus closing the conversation, so the user can re-consent.
  // Bumping the materialized row's revision also invalidates every frozen consent_revision (tasks, revisions, work grants).
  if(input.decision==='deny'){
   const relying=(await tx.list(owner,'provider-consents')).filter(r=>r.source==='account'&&r.subject_id===principal.subject_id&&r.scope_id===scopeId&&r.route_hash===config.routeHash).sort((a,b)=>a.conversation_id.localeCompare(b.conversation_id));
   for(const r of relying){const cid=r.conversation_id;affected.push(cid);await tx.lock(owner,'native-chat-conversations',cid);
    await tx.put(owner,'provider-consents',{...r,revision:r.revision+1,account_revoked_at:iso(),updated_at:iso()});
    await revokeTaskWorkGrantsForSourceInTransaction(tx,{owner,scope_id:scopeId,subject_id:principal.subject_id,conversation_id:cid});
    for(const d of await tx.list(owner,'catpaw-delegations'))if(d.conversation_id===cid&&d.state==='active'){await tx.put(owner,'catpaw-delegations',{...d,state:'revoked',revision:d.revision+1,grant_epoch:d.grant_epoch+1});for(const task of await tx.list(owner,'tasks'))if(task.state?.catpaw?.delegation_id===d.id&&!['succeeded','failed','cancelled'].includes(task.status))await tx.put(owner,'tasks',{...task,status:'cancelled',leaseId:null,leaseUntil:null,updatedAt:iso()});}
    const conversation=await tx.get(owner,'native-chat-conversations',cid);
    if(conversation?.last_turn_id){const turn=await tx.get(owner,'native-chat-turns',conversation.last_turn_id);if(turn?.state==='running'){const error={code:'provider_consent_revoked',retryable:false,reconciliation_required:false};await tx.put(owner,'native-chat-turns',{...turn,state:'failed',error,events:[...turn.events,runtime.chat.event(turn,'turn_failed',error)]});}}
   }
  }
  return row;});
 for(const entry of runtime.chat.active.values())if(entry.subject_id===principal.subject_id&&affected.includes(entry.conversation_id))entry.controller.abort();
 return {route_hash:config.routeHash,granted:accountAllows(row,scopeId,principal.subject_id,config.routeHash),applies_to:'all_conversations',consent:row};
}
/** Turn admission: the conversation's consent row, materialized from the account consent when the conversation has none
 * (or only an allow for an older route). A materialized row stays valid only while the account consent allows this route. */
export async function admissionConsentRow(tx,owner,principal,scopeId,cid,config){
 let row=await tx.get(owner,'provider-consents',consentId(principal.subject_id,cid));
 const account=await tx.get(owner,'provider-consents',accountConsentId(principal.subject_id,config.routeHash));
 const allows=accountAllows(account,scopeId,principal.subject_id,config.routeHash);
 if(row?.source==='account'&&row.route_hash===config.routeHash&&!allows)throw new ApiError(403,'provider_consent_required');
 if(allows&&row?.source==='account'&&row.route_hash===config.routeHash&&row.sensitive_confirmed!==(account.sensitive_confirmed===true)){
  // P1-2: resync the account's current sensitive_confirmed at every admission (narrowing and widening both apply).
  row={...row,sensitive_confirmed:account.sensitive_confirmed===true,updated_at:iso()};await tx.put(owner,'provider-consents',row);}
 if(allows&&(!row||row.decision==='allow'&&row.route_hash!==config.routeHash)){
  row={id:consentId(principal.subject_id,cid),scope_id:scopeId,conversation_id:cid,subject_id:principal.subject_id,route_hash:config.routeHash,revision:(row?.revision??0)+1,decision:'allow',sensitive_confirmed:account.sensitive_confirmed===true,source:'account',account_consent_revision:account.revision,updated_at:iso()};
  await tx.put(owner,'provider-consents',row);
 }
 return row?.source==='account'?effectiveConsent(tx,owner,principal.subject_id,cid,config.routeHash):row;
}
