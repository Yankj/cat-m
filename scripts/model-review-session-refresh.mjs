import {randomUUID} from 'node:crypto';
import {parseStrictObjectJSON} from '../services/edge/supabase/functions/_shared/core/src/strict-json.mjs';

export const SAME_IDENTITY_REFRESH_APPROVAL='catpaw-review-same-identity-refresh-20261015-v1';
const ORIGIN='https://dbyklgxdvjbutxzsjeth.supabase.co';
const ROUTE_HASH='181199268207fc3256b821ee13b046700a162d657adb3acd1c66d6f930870956';
const ID='catpaw-gemma-private-review-20261015-v1';
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(v);
export class SameIdentityRefreshError extends Error {constructor(code){super(code);this.code=code;}}
const require=(ok,code)=>{if(!ok)throw new SameIdentityRefreshError(code);};
/// Operator library only. Its trusted journal port must durably serialize update()
/// before fetch. The caller must also hold the original session store journal lock
/// throughout this operation, including saveVault, so a newer session is not overwritten.
/// This function never signs up, creates a scope, sends model text,
/// deploys, exports a session, or retries an attempted refresh.
export async function refreshSameReviewIdentity({existingSessionStore,refreshJournal,fetchImpl,execute=false,approval=null,clock=Date.now}={}){
 require(execute===true&&approval===SAME_IDENTITY_REFRESH_APPROVAL,'same_identity_refresh_not_approved');
 require(existingSessionStore&&['load','vault','saveVault'].every(k=>typeof existingSessionStore[k]==='function')&&refreshJournal&&typeof refreshJournal.update==='function'&&typeof fetchImpl==='function','same_identity_refresh_dependencies_missing');
 let old,v;try{old=await existingSessionStore.load();v=await existingSessionStore.vault();}catch{throw new SameIdentityRefreshError('original_session_store_unavailable_stop');}
 require(old?.review_id===ID&&old.route_hash===ROUTE_HASH&&old.auth?.known===true&&uuid(old.auth.subject_id)&&uuid(old.scope?.scope_id)&&v?.subject_id===old.auth.subject_id&&v.attempt_id===old.auth.attempt_id&&v.is_anonymous===true&&v.issuer===ORIGIN+'/auth/v1','original_identity_binding_invalid');
 require(Number.isFinite(v.expires_at)&&typeof v.refresh_token==='string'&&v.refresh_token.length>=10&&v.refresh_token.length<=8192&&!/[\r\n]/.test(v.refresh_token)&&typeof v.publishable_key==='string'&&/^sb_publishable_[A-Za-z0-9_-]{10,2000}$/.test(v.publishable_key),'original_session_unavailable_stop');
 if(v.expires_at>clock())return {state:'original_session_still_valid_no_refresh',auth_requests:0,model_requests:0,credentials_exposed:false};
 const attemptID=randomUUID();
 // There is intentionally no recovery POST. Losing a rotated refresh response or
 // failing its local save needs operator reconciliation, never a second refresh.
 await refreshJournal.update(previous=>{require(previous===null||previous===undefined,'refresh_already_attempted_no_retry');return {schema_version:1,contract:SAME_IDENTITY_REFRESH_APPROVAL,attempt_id:attemptID,attempted:true,status:'unknown',subject_id:v.subject_id,scope_id:old.scope.scope_id,session_attempt_id:v.attempt_id,previous_expires_at:v.expires_at};});
 let response;
 try{response=await fetchImpl(ORIGIN+'/auth/v1/token?grant_type=refresh_token',{method:'POST',redirect:'error',signal:AbortSignal.timeout(10000),headers:{apikey:v.publishable_key,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:v.refresh_token})});}
 catch{throw new SameIdentityRefreshError('refresh_transport_unknown_no_retry');}
 require(response?.url===ORIGIN+'/auth/v1/token?grant_type=refresh_token'&&!response.redirected&&response.status===200&&response.headers.get('content-type')?.split(';')[0]==='application/json','refresh_response_failed_stop_no_retry');
 let data;try{data=parseStrictObjectJSON(await response.text(),{maxBytes:32768,maxDepth:10});}catch{throw new SameIdentityRefreshError('refresh_response_invalid_stop_no_retry');}
 require(data.token_type?.toLowerCase()==='bearer'&&data.user?.id===v.subject_id&&data.user.is_anonymous===true&&Number.isInteger(data.expires_in)&&data.expires_in>=1&&data.expires_in<=86400&&['access_token','refresh_token'].every(k=>typeof data[k]==='string'&&data[k].length>=10&&data[k].length<=8192&&!/[\r\n]/.test(data[k])),'refresh_identity_or_session_changed_stop');
 const expires=clock()+data.expires_in*1000;
 try{await existingSessionStore.saveVault({...v,access_token:data.access_token,refresh_token:data.refresh_token,expires_at:expires});}
 catch{throw new SameIdentityRefreshError('refresh_local_save_unknown_no_retry');}
 await refreshJournal.update(previous=>{require(previous?.attempt_id===attemptID&&previous.status==='unknown'&&previous.subject_id===v.subject_id&&previous.session_attempt_id===v.attempt_id,'refresh_journal_changed_stop');return {...previous,status:'same_identity_session_saved',new_expires_at:expires};});
 return {state:'same_identity_session_refreshed_once',auth_requests:1,model_requests:0,new_identity:false,changed_scope:false,credentials_exposed:false};
}
