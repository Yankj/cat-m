import {check,UUID,ApiError,hash} from './core/facade-r2/src/common.mjs';
import {parseStrictObjectJSON} from './core/src/strict-json.mjs';
import {prepareGemmaRouteReview,createGemmaReviewProvider,GEMMA_PRIVATE_REVIEW_ID} from './model-route-review.mjs';
import {GEMMA_REVIEW_CONVERSATION_ID,GEMMA_REVIEW_TEXT} from './model-route-review-probe.mjs';
import {createCloudRuntime} from './api.mjs';

// A new request identity under the original project binding and frozen route.
// Never selected by the default App, old review prefix, tick or route factory.
export const GEMMA_NEXT_REVIEW_ID='catpaw-gemma-private-review-20261015-v2';
export const GEMMA_NEXT_REVIEW_PREFIX='/route-review/'+GEMMA_NEXT_REVIEW_ID;
export const GEMMA_NEXT_REVIEW_CONVERSATION_ID='72000000-0000-4000-8000-000000000001';
export const GEMMA_NEXT_REVIEW_TURN_ID='72000000-0000-4000-8000-000000000002';
export const GEMMA_NEXT_REVIEW_MESSAGE_ID='72000000-0000-4000-8000-000000000003';
export const GEMMA_NEXT_REVIEW_TEXT=GEMMA_REVIEW_TEXT;
export const GEMMA_NEXT_REVIEW_ROUTE_HASH='181199268207fc3256b821ee13b046700a162d657adb3acd1c66d6f930870956';
const canonicalUUID=value=>typeof value==='string'&&UUID.test(value)&&value===value.toLowerCase();
const denied=(code,status=403)=>Response.json({schema_version:1,error:{code,retryable:false}},{status,headers:{'Cache-Control':'no-store'}});

export function selectGemmaNextReviewRequest(request,get,kind){
 const url=new URL(request.url),part=url.pathname.indexOf('/route-review/');
 if(part<0||!url.pathname.slice(part).startsWith(GEMMA_NEXT_REVIEW_PREFIX+'/'))return {review:false,request};
 check(kind==='api',403,'review_tick_not_authorized');
 const subjectID=get('CATPAW_REVIEW_PROBE_SUBJECT_ID'),scopeID=get('CATPAW_REVIEW_PROBE_SCOPE_ID');
 // These are the existing r7 bindings; v2 is not a new environment selector.
 check(get('CATPAW_REVIEW_PROBE_ID')===GEMMA_PRIVATE_REVIEW_ID&&canonicalUUID(subjectID)&&canonicalUUID(scopeID),503,'review_probe_not_configured');
 url.pathname=url.pathname.slice(0,part)+url.pathname.slice(part+GEMMA_NEXT_REVIEW_PREFIX.length);
 return {review:true,subjectID,scopeID,request:new Request(url,request)};
}

export async function createGemmaNextShortTextProbeRuntime({repository,authenticate,config,retain,verifyToken,subjectID,scopeID,fetchImpl,liveNetworkEnabled=false}){
 check(canonicalUUID(subjectID)&&canonicalUUID(scopeID),422,'review_probe_identity_invalid');
 const prepared=prepareGemmaRouteReview(config,{reviewID:GEMMA_PRIVATE_REVIEW_ID});
 check(prepared.manifest.route_hash===GEMMA_NEXT_REVIEW_ROUTE_HASH,409,'review_probe_route_changed');
 const transport=createGemmaReviewProvider({reviewID:GEMMA_PRIVATE_REVIEW_ID,manifest:prepared.manifest,secret:config.modelKey,fetchImpl,liveNetworkEnabled,maxTokens:512,timeoutMs:30000,beforeStream:async()=>{}});
 let probeOwner=null;
 const persistReceipt=async()=>{
  const observation=transport.observations[0];if(!probeOwner||!observation)return;
  try{await repository.transaction(async tx=>{
   const original=await tx.get(probeOwner,'native-chat-turns',GEMMA_NEXT_REVIEW_TURN_ID);
   if(!original||original.content_redacted||original.subject_id!==subjectID||original.scope_id!==scopeID||original.conversation_id!==GEMMA_NEXT_REVIEW_CONVERSATION_ID)return;
   const row={id:GEMMA_NEXT_REVIEW_TURN_ID,schema_version:1,contract:'catpaw.model-route-review-receipt.v1',review_id:GEMMA_NEXT_REVIEW_ID,route_review_id:GEMMA_PRIVATE_REVIEW_ID,route_hash:prepared.manifest.route_hash,turn_id:GEMMA_NEXT_REVIEW_TURN_ID,conversation_id:GEMMA_NEXT_REVIEW_CONVERSATION_ID,scope_id:scopeID,request_hash:original.request_hash,input_hash:hash(original.input),attempts:transport.observations.length,limits:{max_completion_tokens:transport.maxTokens,provider_timeout_ms:transport.timeoutMs,tool_count:0},http_status:observation.http_status,requested_model:observation.requested_model,actual_model:observation.actual_model,actual_provider:observation.actual_provider,cost:observation.usage?.cost??null,review_frame_validation:observation.review_frame_validation??null,terminal_validated:observation.terminal_validated===true,error:observation.error??null};
   await tx.lock(probeOwner,'model-route-review-provider-receipts',GEMMA_NEXT_REVIEW_TURN_ID);
   const previous=await tx.get(probeOwner,'model-route-review-provider-receipts',GEMMA_NEXT_REVIEW_TURN_ID);check(!previous||hash(previous)===hash(row),409,'review_provider_receipt_conflict');
   if(!previous)check(await tx.insertIfAbsent(probeOwner,'model-route-review-provider-receipts',row),409,'review_provider_receipt_conflict');
  });}catch{/* A missing technical receipt grants neither success nor a second POST. */}
 };
 const provider={identity:transport.identity,get reality(){return transport.reality;},assertReady:()=>transport.assertReady(),async *stream(input){try{yield*transport.stream({...input,tools:[]});}finally{await persistReceipt();}}};
 const runtime=await createCloudRuntime({repository,authenticate,config:{...prepared.config,modelTimeoutMs:30000,visionContractEnabled:false,visionLiveEnabled:false},retain,verifyToken,provider,autoKick:false});
 const base=`/catpaw/chat/v1/scopes/${scopeID}/conversations`,conversation=`${base}/${GEMMA_NEXT_REVIEW_CONVERSATION_ID}`,turn=`${conversation}/turns/${GEMMA_NEXT_REVIEW_TURN_ID}`,consent=`/catpaw/privacy/v1/scopes/${scopeID}/conversations/${GEMMA_NEXT_REVIEW_CONVERSATION_ID}/model-consent`;
 const receiptPath=`/catpaw/review/v1/scopes/${scopeID}/turns/${GEMMA_NEXT_REVIEW_TURN_ID}/provider-receipt`;
 const exact=(value,keys)=>value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length===keys.length&&keys.every(k=>Object.hasOwn(value,k));
 const scopeEmpty=async(tx,owner)=>{
  await tx.withScope(scopeID,async scoped=>check((await scoped.scope()).identity.owner===owner,403,'review_probe_scope_conflict'));
  const conversations=await tx.list(owner,'native-chat-conversations');
  check(conversations.every(c=>[GEMMA_REVIEW_CONVERSATION_ID,GEMMA_NEXT_REVIEW_CONVERSATION_ID].includes(c.id)&&c.subject_id===subjectID&&c.scope_id===scopeID),409,'review_probe_scope_not_empty');
  for(const kind of ['tasks','catpaw-runs','catpaw-delegations'])check((await tx.list(owner,kind)).length===0,409,'review_probe_scope_not_empty');
 };
 // The original turn/conversation transaction is the durable one-execution gate.
 // Recheck the empty-scope condition inside that same transaction before admission,
 // rather than relying on an HTTP pre-read or an in-process set/cache.
 const beforeAdmission=runtime.chat.beforeTurnAdmission;
 runtime.chat.beforeTurnAdmission=async(tx,context)=>{await scopeEmpty(tx,context.scope.owner??runtime.facade.owner(context.scope));return beforeAdmission(tx,context);};
 const requestBody=async request=>{
  const length=request.headers.get('content-length');check(length===null||/^(0|[1-9][0-9]*)$/.test(length)&&Number(length)<=2048,413,'review_probe_body_too_large');
  return parseStrictObjectJSON(await request.clone().text(),{maxBytes:2048,maxDepth:8,sizeCode:'review_probe_body_too_large',schemaCode:'review_probe_body_invalid',duplicateCode:'review_probe_duplicate_key'});
 };
 const api=async request=>{
  try{
   const url=new URL(request.url),path=url.pathname.replace(/^\/(?:functions\/v1\/)?catpaw-api(?=\/|$)/,'')||'/';
   const trusted=await runtime.facade.scoped(request.headers.get('authorization'),scopeID);
   check(trusted.principal.subject_id===subjectID,403,'review_probe_subject_conflict');probeOwner=trusted.owner;
   const get=request.method==='GET',post=request.method==='POST';
   const allowedRead=get&&['/readyz','/catpaw/privacy/v1/model-route','/catpaw/account/v1/session',conversation,consent,turn,turn+'/events',receiptPath].includes(path);
   check(allowedRead||post&&[base,consent,conversation+'/turns'].includes(path),403,'review_probe_path_denied');
   check(!url.search||get&&[turn,turn+'/events'].includes(path)&&/^\?after_sequence=(0|[1-9][0-9]{0,5})$/.test(url.search),422,'review_probe_query_denied');
   if(post){
    check(!request.headers.has('X-Catpaw-Memory-Proposal-Contract'),422,'review_probe_turn_denied');
    const input=await requestBody(request);
    if(path===base)check(exact(input,['conversation_id'])&&input.conversation_id===GEMMA_NEXT_REVIEW_CONVERSATION_ID,422,'review_probe_conversation_denied');
    else if(path===consent)check(exact(input,['decision','expected_revision','route_hash'])&&input.decision==='allow'&&input.expected_revision===0&&input.route_hash===prepared.manifest.route_hash,422,'review_probe_consent_denied');
    else check(exact(input,['turn_id','expected_revision','expected_grant_epoch','message','context'])&&input.turn_id===GEMMA_NEXT_REVIEW_TURN_ID&&input.expected_revision===1&&input.expected_grant_epoch===1&&exact(input.message,['id','text'])&&input.message.id===GEMMA_NEXT_REVIEW_MESSAGE_ID&&input.message.text===GEMMA_NEXT_REVIEW_TEXT&&Array.isArray(input.context)&&input.context.length===0,422,'review_probe_turn_denied');
    await repository.transaction(async tx=>{
     await scopeEmpty(tx,trusted.owner);
     if(path===conversation+'/turns')check(!await tx.get(trusted.owner,'native-chat-turns',GEMMA_NEXT_REVIEW_TURN_ID),409,'review_probe_original_GET_only');
    });
   }
   // Historical GET is never gated on current scope emptiness; adding a later
   // allowed probe cannot make the original request or receipt unrecoverable.
   if(get&&path===receiptPath){const row=await repository.transaction(tx=>tx.get(trusted.owner,'model-route-review-provider-receipts',GEMMA_NEXT_REVIEW_TURN_ID));return row?Response.json(row,{headers:{'Cache-Control':'no-store'}}):denied('review_provider_receipt_not_ready',404);}
   return runtime.api(request);
  }catch(error){return denied(error instanceof ApiError?error.code:'review_probe_denied',error instanceof ApiError?error.status:403);}
 };
 return {api,runtime,manifest:prepared.manifest,transport};
}
