import {check,UUID,ApiError,hash} from './core/facade-r2/src/common.mjs';
import {prepareGemmaRouteReview,createGemmaReviewProvider,GEMMA_PRIVATE_REVIEW_ID} from './model-route-review.mjs';
import {createCloudRuntime} from './api.mjs';
export const GEMMA_REVIEW_PREFIX='/route-review/'+GEMMA_PRIVATE_REVIEW_ID;
export const GEMMA_REVIEW_CONVERSATION_ID='71000000-0000-4000-8000-000000000001';
export const GEMMA_REVIEW_TURN_ID='71000000-0000-4000-8000-000000000002';
export const GEMMA_REVIEW_MESSAGE_ID='71000000-0000-4000-8000-000000000003';
export const GEMMA_REVIEW_TEXT='Reply only: received.';
const denied=(code,status=403)=>Response.json({schema_version:1,error:{code,retryable:false}},{status,headers:{'Cache-Control':'no-store'}});
// Deployment copies opt into this prefix only. Existing function paths never
// change route, model, consent, image processing, scheduler or original IDs.
export function selectGemmaReviewRequest(request,get,kind){
 const url=new URL(request.url),part=url.pathname.indexOf('/route-review/');
 if(part<0)return {review:false,request};
 check(kind==='api',403,'review_tick_not_authorized');
 check(url.pathname.slice(part).startsWith(GEMMA_REVIEW_PREFIX+'/'),404,'review_candidate_not_found');
 const subjectID=get('CATPAW_REVIEW_PROBE_SUBJECT_ID'),scopeID=get('CATPAW_REVIEW_PROBE_SCOPE_ID');
 check(get('CATPAW_REVIEW_PROBE_ID')===GEMMA_PRIVATE_REVIEW_ID&&UUID.test(subjectID??'')&&UUID.test(scopeID??''),503,'review_probe_not_configured');
 url.pathname=url.pathname.slice(0,part)+url.pathname.slice(part+GEMMA_REVIEW_PREFIX.length);
 return {review:true,subjectID,scopeID,request:new Request(url,request)};
}
export async function createGemmaShortTextProbeRuntime({repository,authenticate,config,retain,verifyToken,subjectID,scopeID,fetchImpl,liveNetworkEnabled=false}){
 check(UUID.test(subjectID??'')&&UUID.test(scopeID??''),422,'review_probe_identity_invalid');
 const prepared=prepareGemmaRouteReview(config,{reviewID:GEMMA_PRIVATE_REVIEW_ID});
 const transport=createGemmaReviewProvider({reviewID:GEMMA_PRIVATE_REVIEW_ID,manifest:prepared.manifest,secret:config.modelKey,fetchImpl,liveNetworkEnabled,maxTokens:32,timeoutMs:20000,beforeStream:async()=>{}});
 let runtime,probeOwner=null;
 const persistReceipt=async()=>{
  const observation=transport.observations[0];if(!probeOwner||!observation)return;
  try{await repository.transaction(async tx=>{
   const original=await tx.get(probeOwner,'native-chat-turns',GEMMA_REVIEW_TURN_ID);
   if(!original||original.content_redacted||original.subject_id!==subjectID||original.scope_id!==scopeID||original.conversation_id!==GEMMA_REVIEW_CONVERSATION_ID)return;
   const row={id:GEMMA_REVIEW_TURN_ID,schema_version:1,contract:'catpaw.model-route-review-receipt.v1',review_id:GEMMA_PRIVATE_REVIEW_ID,route_hash:prepared.manifest.route_hash,turn_id:GEMMA_REVIEW_TURN_ID,conversation_id:GEMMA_REVIEW_CONVERSATION_ID,scope_id:scopeID,request_hash:original.request_hash,input_hash:hash(original.input),attempts:transport.observations.length,limits:{max_completion_tokens:transport.maxTokens,provider_timeout_ms:transport.timeoutMs,tool_count:0},http_status:observation.http_status,requested_model:observation.requested_model,actual_model:observation.actual_model,actual_provider:observation.actual_provider,cost:observation.usage?.cost??null,review_frame_validation:observation.review_frame_validation??null,terminal_validated:observation.terminal_validated===true,error:observation.error??null};
   const previous=await tx.get(probeOwner,'model-route-review-provider-receipts',GEMMA_REVIEW_TURN_ID);check(!previous||hash(previous)===hash(row),409,'review_provider_receipt_conflict');
   if(!previous)await tx.put(probeOwner,'model-route-review-provider-receipts',row);
  });}catch{/* Missing technical evidence stays unavailable; it never grants completion or resend. */}
 };
 const provider={identity:transport.identity,get reality(){return transport.reality;},assertReady:()=>transport.assertReady(),async *stream(input){try{yield*transport.stream({...input,tools:[]});}finally{await persistReceipt();}}};
 // Text probe only. Original API image runtime/config remain untouched.
 runtime=await createCloudRuntime({repository,authenticate,config:{...prepared.config,visionContractEnabled:false,visionLiveEnabled:false},retain,verifyToken,provider,autoKick:false});
 const base=`/catpaw/chat/v1/scopes/${scopeID}/conversations`,conversation=`${base}/${GEMMA_REVIEW_CONVERSATION_ID}`,turn=`${conversation}/turns/${GEMMA_REVIEW_TURN_ID}`,consent=`/catpaw/privacy/v1/scopes/${scopeID}/conversations/${GEMMA_REVIEW_CONVERSATION_ID}/model-consent`;
 const receiptPath=`/catpaw/review/v1/scopes/${scopeID}/turns/${GEMMA_REVIEW_TURN_ID}/provider-receipt`;
 const exact=(value,keys)=>value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length===keys.length&&keys.every(k=>Object.hasOwn(value,k));
 const requestBody=async request=>{check(Number(request.headers.get('content-length')??0)<=2048,413,'review_probe_body_too_large');const raw=await request.clone().text();check(new TextEncoder().encode(raw).byteLength<=2048,413,'review_probe_body_too_large');try{return JSON.parse(raw);}catch{throw new ApiError(422,'review_probe_body_invalid');}};
 const api=async request=>{
  try{
   const url=new URL(request.url),path=url.pathname.replace(/^\/(?:functions\/v1\/)?catpaw-api(?=\/|$)/,'')||'/';
   const trusted=await runtime.facade.scoped(request.headers.get('authorization'),scopeID);
   check(trusted.principal.subject_id===subjectID,403,'review_probe_subject_conflict');probeOwner=trusted.owner;
   if(request.method!=='GET')await repository.transaction(async tx=>{
    const conversations=await tx.list(trusted.owner,'native-chat-conversations');check(conversations.every(c=>c.id===GEMMA_REVIEW_CONVERSATION_ID&&c.subject_id===subjectID),409,'review_probe_scope_not_empty');
    for(const kind of ['tasks','catpaw-runs','catpaw-delegations'])check((await tx.list(trusted.owner,kind)).length===0,409,'review_probe_scope_not_empty');
   });
   const get=request.method==='GET',post=request.method==='POST';
   const allowedRead=get&&['/readyz','/catpaw/privacy/v1/model-route','/catpaw/account/v1/session',conversation,consent,turn,turn+'/events',receiptPath].includes(path);
   check(allowedRead||post&&[base,consent,conversation+'/turns'].includes(path),403,'review_probe_path_denied');
   check(!url.search||get&&[turn,turn+'/events'].includes(path)&&/^\?after_sequence=\d+$/.test(url.search),422,'review_probe_query_denied');
   if(post){const input=await requestBody(request);
    if(path===base)check(exact(input,['conversation_id'])&&input.conversation_id===GEMMA_REVIEW_CONVERSATION_ID,422,'review_probe_conversation_denied');
    else if(path===consent)check(exact(input,['decision','expected_revision','route_hash'])&&input.decision==='allow'&&input.expected_revision===0&&input.route_hash===prepared.manifest.route_hash,422,'review_probe_consent_denied');
    else{
     check(exact(input,['turn_id','expected_revision','expected_grant_epoch','message','context'])&&input.turn_id===GEMMA_REVIEW_TURN_ID&&input.expected_revision===1&&input.expected_grant_epoch===1&&exact(input.message,['id','text'])&&input.message.id===GEMMA_REVIEW_MESSAGE_ID&&input.message.text===GEMMA_REVIEW_TEXT&&Array.isArray(input.context)&&input.context.length===0,422,'review_probe_turn_denied');
     const exists=await repository.transaction(tx=>tx.get(trusted.owner,'native-chat-turns',GEMMA_REVIEW_TURN_ID));check(!exists,409,'review_probe_original_GET_only');
    }
   }
   if(get&&path===receiptPath){const row=await repository.transaction(tx=>tx.get(trusted.owner,'model-route-review-provider-receipts',GEMMA_REVIEW_TURN_ID));return row?Response.json(row,{headers:{'Cache-Control':'no-store'}}):denied('review_provider_receipt_not_ready',404);}
   return runtime.api(request);
  }catch(error){return denied(error instanceof ApiError?error.code:'review_probe_denied',error instanceof ApiError?error.status:403);}
 };
 return {api,runtime,manifest:prepared.manifest,transport};
}
