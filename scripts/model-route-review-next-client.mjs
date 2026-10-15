import {readFile,rename,mkdir,open,lstat,unlink} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {Buffer} from 'node:buffer';
import {hash,clone,canonical} from '../services/edge/supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {parseStrictObjectJSON} from '../services/edge/supabase/functions/_shared/core/src/strict-json.mjs';
import {GEMMA_PRIVATE_REVIEW_ID,GEMMA_PRIVATE_REVIEW_MODEL,GEMMA_PRIVATE_REVIEW_PROVIDER,gemmaPrivateReviewPolicy} from '../services/edge/supabase/functions/_shared/core/src/private-route-review.mjs';
import {GEMMA_NEXT_REVIEW_ID,GEMMA_NEXT_REVIEW_PREFIX,GEMMA_NEXT_REVIEW_CONVERSATION_ID as CID,GEMMA_NEXT_REVIEW_TURN_ID as TID,GEMMA_NEXT_REVIEW_MESSAGE_ID as MID,GEMMA_NEXT_REVIEW_TEXT as TEXT,GEMMA_NEXT_REVIEW_ROUTE_HASH as ROUTE_HASH} from '../services/edge/supabase/functions/_shared/model-route-review-probe-next.mjs';

const ORIGIN='https://dbyklgxdvjbutxzsjeth.supabase.co',API=ORIGIN+'/functions/v1/catpaw-api';
const JOURNAL_CONTRACT='catpaw.model-route-next-operation.v1';
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(v);
const sha=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const exact=(v,keys)=>v&&Object.getPrototypeOf(v)===Object.prototype&&Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
export class NextProbeClientError extends Error {constructor(code){super(code);this.code=code;}}
const require=(ok,code)=>{if(!ok)throw new NextProbeClientError(code);};
const input=()=>({turn_id:TID,expected_revision:1,expected_grant_epoch:1,message:{id:MID,text:TEXT},context:[]});
export function nextReviewProbePlan(){return {schema_version:1,review_id:GEMMA_NEXT_REVIEW_ID,route_review_id:GEMMA_PRIVATE_REVIEW_ID,execution:'disabled_until_specific_execution_approval',api:API,prefix:GEMMA_NEXT_REVIEW_PREFIX,route_hash:ROUTE_HASH,model:GEMMA_PRIVATE_REVIEW_MODEL,provider:GEMMA_PRIVATE_REVIEW_PROVIDER,routing_policy:gemmaPrivateReviewPolicy(),conversation_id:CID,turn_id:TID,message_id:MID,text:TEXT,input_hash:hash(input()),max_model_attempts:1,max_completion_tokens:512,provider_timeout_ms:30000,client_timeout_ms:35000,max_observation_stages:12,tools:0,context:0,attachments:0,memory:0,existing_identity_only:true,unknown:'GET the same original only; no POST retry, Auth refresh, signup, scope bootstrap, route switch or deployment',product_acceptance:false};}
export function newNextProbeJournal(){return {schema_version:1,contract:JOURNAL_CONTRACT,review_id:GEMMA_NEXT_REVIEW_ID,route_review_id:GEMMA_PRIVATE_REVIEW_ID,route_hash:ROUTE_HASH,plan_hash:hash(nextReviewProbePlan()),input_hash:hash(input()),identity:null,conversation:{attempted:false,known:false},consent:{attempted:false,known:false},turn:{attempted:false,state:'not_sent',server_request_hash:null,first_delta_seen:false,events_hash:null},get_count:0,last_result:null};}
function validateJournal(j){
 const base=newNextProbeJournal();require(exact(j,Object.keys(base)),'probe_operation_journal_invalid');
 for(const key of ['schema_version','contract','review_id','route_review_id','route_hash','plan_hash','input_hash'])require(j[key]===base[key],'probe_operation_journal_binding_invalid');
 require(j.identity===null||exact(j.identity,['subject_id','scope_id'])&&uuid(j.identity.subject_id)&&uuid(j.identity.scope_id),'probe_operation_identity_invalid');
 for(const key of ['conversation','consent'])require(exact(j[key],['attempted','known'])&&typeof j[key].attempted==='boolean'&&typeof j[key].known==='boolean'&&(!j[key].known||j[key].attempted),'probe_operation_journal_invalid');
 require(exact(j.turn,Object.keys(base.turn))&&typeof j.turn.attempted==='boolean'&&['not_sent','unknown','running','completed','failed','outcome_unknown'].includes(j.turn.state)&&(j.turn.server_request_hash===null||sha(j.turn.server_request_hash))&&typeof j.turn.first_delta_seen==='boolean'&&(j.turn.events_hash===null||sha(j.turn.events_hash)),'probe_operation_journal_invalid');
 require(Number.isInteger(j.get_count)&&j.get_count>=0&&j.get_count<=12,'probe_operation_journal_invalid');
 require(j.last_result===null||exact(j.last_result,['state','turn_state','first_delta_seen','actual_model','actual_provider','cost','terminal_validated','attempts','product_acceptance'])&&['bounded_text_route_probe_pass','probe_FAIL_or_unknown_stop'].includes(j.last_result.state)&&['running','completed','failed','outcome_unknown'].includes(j.last_result.turn_state)&&typeof j.last_result.first_delta_seen==='boolean'&&[null,GEMMA_PRIVATE_REVIEW_MODEL].includes(j.last_result.actual_model)&&[null,GEMMA_PRIVATE_REVIEW_PROVIDER].includes(j.last_result.actual_provider)&&(j.last_result.cost===null||j.last_result.cost===0)&&typeof j.last_result.terminal_validated==='boolean'&&j.last_result.attempts===1&&j.last_result.product_acceptance===false,'probe_operation_journal_invalid');
 return j;
}
function strict(raw,maxBytes=262144){try{return parseStrictObjectJSON(raw,{maxBytes,maxDepth:12});}catch{throw new NextProbeClientError('probe_json_invalid');}}

/// Contains noncredential operation facts only. The existing session store is never copied or modified.
export class NextProbeFileJournal {
 constructor({namespace='v2'}={}){require(namespace==='v2'||/^client-test-[a-f0-9-]{36}$/.test(namespace),'probe_operation_path_denied');const root=fileURLToPath(new URL('../services/edge/build/model-route-review-next-20261015/operations/',import.meta.url));this.directory=resolve(root,namespace);}
 path(name){require(['operation.json','operation.lock'].includes(name),'probe_operation_path_denied');return resolve(this.directory,name);}
 async load(){try{const stat=await lstat(this.path('operation.json'));require(stat.isFile()&&!stat.isSymbolicLink()&&(stat.mode&0o077)===0&&stat.size<=65536,'probe_operation_file_invalid');return validateJournal(strict(await readFile(this.path('operation.json'),'utf8'),65536));}catch(e){if(e.code==='ENOENT')return null;if(e instanceof NextProbeClientError)throw e;throw new NextProbeClientError('probe_operation_read_failed');}}
 async update(fn){
  await mkdir(this.directory,{recursive:true,mode:0o700});const parent=await lstat(this.directory);require(parent.isDirectory()&&!parent.isSymbolicLink()&&(parent.mode&0o077)===0,'probe_operation_directory_invalid');
  let lock;try{lock=await open(this.path('operation.lock'),'wx',0o600);}catch{throw new NextProbeClientError('probe_operation_busy_no_retry');}
  let temporary;
  try{const previous=await this.load()??newNextProbeJournal(),next=validateJournal(await fn(clone(previous)));const bytes=JSON.stringify(next)+'\n';require(Buffer.byteLength(bytes)<=65536,'probe_operation_too_large');temporary=this.path('operation.json')+'.writing-'+randomUUID();const file=await open(temporary,'wx',0o600);try{await file.writeFile(bytes);await file.sync();}finally{await file.close();}await rename(temporary,this.path('operation.json'));temporary=null;const directory=await open(this.directory,'r');try{await directory.sync();}finally{await directory.close();}return clone(next);
  }catch(e){if(e instanceof NextProbeClientError)throw e;throw new NextProbeClientError('probe_operation_save_failed_no_post');}
  finally{if(temporary)await unlink(temporary).catch(()=>{});await lock.close();await unlink(this.path('operation.lock'));}
 }
}

export class ModelRouteReviewNextClient {
 #existing; #store; #fetch; #clock; #enabled;
 constructor({existingSessionStore,operationJournal,fetchImpl,execute=false,approval=null,clock=Date.now}={}){
  this.#existing=existingSessionStore;this.#store=operationJournal;this.#fetch=fetchImpl;this.#clock=clock;this.#enabled=execute===true&&approval===GEMMA_NEXT_REVIEW_ID;
 }
 plan(){return nextReviewProbePlan();}
 #enabledStage(){require(this.#enabled,'probe_execution_not_approved');require(this.#existing&&typeof this.#existing.load==='function'&&typeof this.#existing.vault==='function'&&this.#store&&typeof this.#store.load==='function'&&typeof this.#store.update==='function'&&typeof this.#fetch==='function','probe_dependencies_missing');}
 async #journal(){this.#enabledStage();return validateJournal(await this.#store.load()??newNextProbeJournal());}
 async #update(fn){this.#enabledStage();return this.#store.update(j=>{validateJournal(j);return validateJournal(fn(j));});}
 async #existingSession(){
  this.#enabledStage();let original,v;
  try{original=await this.#existing.load();v=await this.#existing.vault();}catch{throw new NextProbeClientError('probe_existing_session_unavailable_no_refresh');}
  require(original?.review_id===GEMMA_PRIVATE_REVIEW_ID&&original.route_hash===ROUTE_HASH&&original.auth?.known===true&&uuid(original.auth.attempt_id)&&uuid(original.auth.subject_id)&&uuid(original.scope?.scope_id),'probe_existing_identity_invalid');
  require(v&&v.subject_id===original.auth.subject_id&&v.attempt_id===original.auth.attempt_id&&v.is_anonymous===true&&v.issuer===ORIGIN+'/auth/v1','probe_existing_identity_invalid');
  require(Number.isFinite(v.expires_at)&&v.expires_at>this.#clock(),'probe_existing_session_expired_no_refresh');
  require(typeof v.access_token==='string'&&v.access_token.length>10&&v.access_token.length<8192&&!/[\r\n]/.test(v.access_token)&&typeof v.publishable_key==='string'&&/^sb_publishable_[A-Za-z0-9_-]{10,2000}$/.test(v.publishable_key),'probe_existing_session_invalid');
  const identity={subject_id:v.subject_id,scope_id:original.scope.scope_id};
  await this.#update(j=>{require(j.identity===null||canonical(j.identity)===canonical(identity),'probe_existing_partition_changed');j.identity=identity;return j;});
  return {vault:v,identity};
 }
 #paths(identity){const base=`/catpaw/chat/v1/scopes/${identity.scope_id}/conversations`,conversation=base+'/'+CID;return {base,conversation,turn:conversation+'/turns/'+TID,consent:`/catpaw/privacy/v1/scopes/${identity.scope_id}/conversations/${CID}/model-consent`,receipt:`/catpaw/review/v1/scopes/${identity.scope_id}/turns/${TID}/provider-receipt`};}
 async #request(path,{method='GET',body,session}={}){
  this.#enabledStage();require(session?.vault?.expires_at>this.#clock(),'probe_existing_session_expired_no_refresh');const p=this.#paths(session.identity);
  const allowed=method==='GET'&&['/catpaw/privacy/v1/model-route',p.conversation,p.consent,p.turn,p.turn+'/events',p.receipt].includes(path)||method==='POST'&&[p.base,p.consent,p.conversation+'/turns'].includes(path);require(allowed,'probe_resource_denied');
  const url=API+GEMMA_NEXT_REVIEW_PREFIX+path;let response;
  try{response=await this.#fetch(url,{method,headers:{'Content-Type':'application/json',Accept:'application/json, text/event-stream',Authorization:'Bearer '+session.vault.access_token,apikey:session.vault.publishable_key},redirect:'error',signal:AbortSignal.timeout(35000),...body===undefined?{}:{body:JSON.stringify(body)}});}catch{throw new NextProbeClientError('probe_transport_unknown_no_retry');}
  require(response&&(!response.url||response.url===url)&&!response.redirected,'probe_response_origin_invalid');require(response.status>=200&&response.status<300,'probe_http_'+response.status+'_stop');return response;
 }
 async #json(response){
  require(response.headers.get('content-type')?.split(';')[0]==='application/json'&&response.body,'probe_json_type_invalid');
  const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});let raw='',bytes=0;
  try{while(true){const next=await reader.read();if(next.done)break;bytes+=next.value.byteLength;require(bytes<=262144,'probe_json_too_large');raw+=decoder.decode(next.value,{stream:true});}raw+=decoder.decode();return strict(raw);}
  catch(e){if(e instanceof NextProbeClientError)throw e;throw new NextProbeClientError('probe_transport_unknown_no_retry');}
  finally{await reader.cancel().catch(()=>{});}
 }
 async #notice(session){const value=await this.#json(await this.#request('/catpaw/privacy/v1/model-route',{session}));require(value.schema_version===1&&value.route_hash===ROUTE_HASH&&hash(value.route)===ROUTE_HASH&&value.consent_default==='deny','probe_route_changed');return value;}
 #conversation(value,identity){const c=value.conversation;require(value.schema_version===1&&value.contract==='catpaw.native-chat.v1'&&c?.id===CID&&c.scope_id===identity.scope_id&&c.subject_id===identity.subject_id&&c.state==='active'&&c.grant_epoch===1&&c.policy==='conversation-local-output-v1'&&Array.isArray(c.messages),'probe_conversation_binding_invalid');return c;}
 #consentRow(value,identity){const row=value.consent;require(value.schema_version===1&&row?.decision==='allow'&&row.subject_id===identity.subject_id&&row.scope_id===identity.scope_id&&row.conversation_id===CID&&row.route_hash===ROUTE_HASH&&row.revision===1,'probe_consent_binding_invalid');return row;}
 async prepareConversation(){const session=await this.#existingSession(),p=this.#paths(session.identity);await this.#notice(session);let j=await this.#journal();
  if(j.conversation.attempted){const value=await this.#json(await this.#request(p.conversation,{session}));this.#conversation(value,session.identity);await this.#update(x=>{x.conversation.known=true;return x;});return {state:'original_next_conversation_found_GET_only'};}
  await this.#update(x=>{require(!x.conversation.attempted,'probe_conversation_already_attempted_GET_only');x.conversation.attempted=true;return x;});
  const value=await this.#json(await this.#request(p.base,{method:'POST',body:{conversation_id:CID},session})),c=this.#conversation(value,session.identity);require(c.revision===1&&c.messages.length===0,'probe_fresh_conversation_required');await this.#update(x=>{x.conversation.known=true;return x;});return {state:'new_check_conversation_created_existing_identity'};
 }
 async consent({allowRouteHash}={}){require(allowRouteHash===ROUTE_HASH,'probe_normal_consent_not_explicit');const session=await this.#existingSession(),p=this.#paths(session.identity);require((await this.#journal()).conversation.known,'probe_conversation_not_prepared');await this.#notice(session);const value=await this.#json(await this.#request(p.consent,{session}));
  if((await this.#journal()).consent.attempted){this.#consentRow(value,session.identity);await this.#update(x=>{x.consent.known=true;return x;});return {state:'original_next_consent_found_GET_only'};}
  require(value.schema_version===1&&value.consent===null,'probe_fresh_consent_required');await this.#update(x=>{require(!x.consent.attempted,'probe_consent_already_attempted_GET_only');x.consent.attempted=true;return x;});const granted=await this.#json(await this.#request(p.consent,{method:'POST',body:{decision:'allow',expected_revision:0,route_hash:ROUTE_HASH},session}));this.#consentRow(granted,session.identity);await this.#update(x=>{x.consent.known=true;return x;});return {state:'new_check_consent_allowed_no_model_call'};
 }
 #validateEvents(events,identity,{terminal=false}={}){
  require(Array.isArray(events)&&events.length>0&&events.length<=2048,'probe_events_missing');let sequence=0,text='',messageID=null,requestHash=null,ended=null;
  for(const event of events){require(event.schema_version===1&&event.contract==='catpaw.native-chat.v1'&&event.scope_id===identity.scope_id&&event.conversation_id===CID&&event.turn_id===TID&&event.grant_epoch===1&&event.sequence===++sequence&&event.cursor===TID+':'+sequence&&event.model_reality==='provider_unverified'&&!ended,'probe_event_binding_invalid');const d=event.data;
   if(event.type==='turn_started'){require(sequence===1&&exact(d,['request_hash','conversation_revision'])&&sha(d.request_hash)&&d.conversation_revision===2,'probe_acceptance_invalid');requestHash=d.request_hash;}
   else if(event.type==='text_delta'){require(requestHash&&exact(d,['message_id','text'])&&uuid(d.message_id)&&typeof d.text==='string'&&Buffer.byteLength(d.text)<=32768&&(messageID===null||messageID===d.message_id),'probe_text_invalid');messageID=d.message_id;text+=d.text;require(Buffer.byteLength(text)<=32768,'probe_text_too_large');}
   else if(event.type==='turn_completed'){require(requestHash&&exact(d,['message_id','final_text_hash','task_bindings'])&&uuid(d.message_id)&&(messageID===null||messageID===d.message_id)&&d.final_text_hash===hash(text)&&Array.isArray(d.task_bindings)&&d.task_bindings.length===0,'probe_terminal_invalid');messageID=d.message_id;ended='completed';}
   else if(event.type==='turn_failed'){require(requestHash&&exact(d,['code','retryable','reconciliation_required'])&&typeof d.code==='string'&&d.code.length<=160&&typeof d.retryable==='boolean'&&typeof d.reconciliation_required==='boolean','probe_failure_invalid');ended=d.reconciliation_required?'outcome_unknown':'failed';}
   else throw new NextProbeClientError('probe_tool_or_unknown_event_denied');
  }
  require(requestHash&&(!terminal||ended),'probe_incomplete_terminal');return {requestHash,text,ended,firstDelta:events.some(x=>x.type==='text_delta')};
 }
 async #rememberEvents(events,identity){const checked=this.#validateEvents(events,identity);await this.#update(j=>{require(j.turn.attempted&&(!j.turn.server_request_hash||j.turn.server_request_hash===checked.requestHash),'probe_original_request_changed');j.turn.server_request_hash=checked.requestHash;j.turn.first_delta_seen ||= checked.firstDelta;j.turn.events_hash=hash(events);return j;});return checked;}
 async #sse(response,identity){
  require(response.headers.get('content-type')?.split(';')[0]==='text/event-stream'&&response.body,'probe_sse_type_invalid');const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});let buffer='',packet=[],events=[],bytes=0;
  const line=async text=>{if(text===''){if(packet.length){const value=strict(packet.join('\n'));events.push(value);await this.#rememberEvents(events,identity);packet=[];}}else if(text.startsWith(':')){}else if(text.startsWith('data:')){packet.push(text.slice(5).replace(/^ /,''));}else throw new NextProbeClientError('probe_sse_frame_invalid');};
  try{while(true){const next=await reader.read();if(next.done)break;bytes+=next.value.byteLength;require(bytes<=262144,'probe_sse_too_large');buffer+=decoder.decode(next.value,{stream:true});let split;while((split=/\r\n|\n|\r(?!$)/.exec(buffer))){const text=buffer.slice(0,split.index);buffer=buffer.slice(split.index+split[0].length);await line(text);}}buffer+=decoder.decode();if(buffer.endsWith('\r')){await line(buffer.slice(0,-1));buffer='';}require(!buffer&&!packet.length,'probe_incomplete_sse_frame');this.#validateEvents(events,identity,{terminal:true});return events;}catch(e){if(e instanceof NextProbeClientError)throw e;throw new NextProbeClientError('probe_sse_interrupted_no_retry');}finally{await reader.cancel().catch(()=>{});}
 }
 async send(){const session=await this.#existingSession(),p=this.#paths(session.identity);let j=await this.#journal();require(j.conversation.known&&j.consent.known,'probe_admission_not_prepared');require(!j.turn.attempted,'probe_original_GET_only');await this.#notice(session);const c=this.#conversation(await this.#json(await this.#request(p.conversation,{session})),session.identity);require(c.revision===1&&c.messages.length===0,'probe_fresh_conversation_required');this.#consentRow(await this.#json(await this.#request(p.consent,{session})),session.identity);
  await this.#update(x=>{require(!x.turn.attempted,'probe_original_GET_only');x.turn.attempted=true;x.turn.state='unknown';return x;});
  try{await this.#sse(await this.#request(p.conversation+'/turns',{method:'POST',body:input(),session}),session.identity);return await this.observe();}catch(e){return {state:'unknown_or_failed_stop_POST',code:e instanceof NextProbeClientError?e.code:'probe_unexpected_failure',next:'observe_original_GET_only',product_acceptance:false};}
 }
 async observe(){const session=await this.#existingSession(),p=this.#paths(session.identity);require((await this.#journal()).turn.attempted,'probe_original_not_attempted');await this.#update(j=>{require(j.get_count<12,'probe_observation_budget_exhausted');j.get_count++;return j;});
  const snapshot=await this.#json(await this.#request(p.turn,{session})),turn=snapshot.turn;require(snapshot.schema_version===1&&snapshot.contract==='catpaw.native-chat.v1'&&turn?.id===TID&&turn.conversation_id===CID&&turn.scope_id===session.identity.scope_id&&turn.grant_epoch===1&&sha(turn.request_hash)&&['running','completed','failed','outcome_unknown'].includes(turn.state),'probe_original_binding_invalid');const checked=await this.#rememberEvents(turn.events,session.identity);require(turn.request_hash===checked.requestHash&&(!checked.ended||turn.state===checked.ended)&&(!['completed','failed','outcome_unknown'].includes(turn.state)||checked.ended===turn.state),'probe_snapshot_terminal_mismatch');
  const replay=await this.#sse(await this.#request(p.turn+'/events',{session}),session.identity);require(hash(replay)===hash(turn.events),'probe_snapshot_advanced_read_original_only');
  const receipt=await this.#json(await this.#request(p.receipt,{session}));require(receipt.schema_version===1&&receipt.contract==='catpaw.model-route-review-receipt.v1'&&receipt.id===TID&&receipt.review_id===GEMMA_NEXT_REVIEW_ID&&receipt.route_review_id===GEMMA_PRIVATE_REVIEW_ID&&receipt.route_hash===ROUTE_HASH&&receipt.turn_id===TID&&receipt.conversation_id===CID&&receipt.scope_id===session.identity.scope_id&&receipt.request_hash===turn.request_hash&&receipt.input_hash===hash(input())&&receipt.attempts===1&&exact(receipt.limits,['max_completion_tokens','provider_timeout_ms','tool_count'])&&receipt.limits.max_completion_tokens===512&&receipt.limits.provider_timeout_ms===30000&&receipt.limits.tool_count===0&&receipt.requested_model===GEMMA_PRIVATE_REVIEW_MODEL,'probe_provider_receipt_binding_invalid');
  const frame=receipt.review_frame_validation,success=turn.state==='completed'&&checked.ended==='completed'&&checked.text==='received.'&&receipt.http_status===200&&receipt.error===null&&receipt.terminal_validated===true&&frame?.schema_version===1&&frame.review_id===GEMMA_PRIVATE_REVIEW_ID&&frame.passed===true&&Number.isSafeInteger(frame.frames)&&frame.frames>0&&receipt.actual_model===GEMMA_PRIVATE_REVIEW_MODEL&&typeof receipt.actual_provider==='string'&&receipt.actual_provider.toLowerCase()===GEMMA_PRIVATE_REVIEW_PROVIDER.toLowerCase()&&receipt.cost===0;
  const result={state:success?'bounded_text_route_probe_pass':'probe_FAIL_or_unknown_stop',turn_state:turn.state,first_delta_seen:checked.firstDelta,actual_model:receipt.actual_model===GEMMA_PRIVATE_REVIEW_MODEL?GEMMA_PRIVATE_REVIEW_MODEL:null,actual_provider:typeof receipt.actual_provider==='string'&&receipt.actual_provider.toLowerCase()===GEMMA_PRIVATE_REVIEW_PROVIDER.toLowerCase()?GEMMA_PRIVATE_REVIEW_PROVIDER:null,cost:receipt.cost===0?0:null,terminal_validated:receipt.terminal_validated===true,attempts:1,product_acceptance:false};await this.#update(j=>{j.turn.state=turn.state;j.last_result=result;return j;});return result;
 }
}
