import {LIVE_VISION_ROUTE,LIVE_VISION_ROUTE_HASH,VISION_CATALOG_URL} from './live-vision-route.mjs';
import {mapVisionMessages} from './vision-contract.mjs';
import { safeProviderFailure } from './provider-errors.mjs';
import {matchesGemmaPrivateReview,checkGemmaReviewFrame} from './private-route-review.mjs';
import { ApiError,check,clone,hash } from '../facade-r2/src/common.mjs';
export const OPENROUTER_ENDPOINT='https://openrouter.ai/api/v1/chat/completions';
export const FREE_MODEL='google/gemma-4-31b-it:free';
export const FREE_ROUTER='openrouter/free';
export const APPROVED_ROUTER_MODELS=Object.freeze(["apodex/apodex-1.1-mini:free", "dots-studio/dots-3-note-preview:free", "liquid/lfm-2.5-2.6b:free", "nvidia/nemotron-3.5-lightning:free", "poolside/laguna-s-2.1:free", "poolside/laguna-xs-2.1:free", "cohere/north-mini-code:free", "nvidia/nemotron-3-ultra-550b-a55b:free", "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "google/gemma-4-26b-a4b-it:free", "google/gemma-4-31b-it:free", "nvidia/nemotron-3-super-120b-a12b:free"]);
export const SUCCESSFUL_FREE_MODEL='apodex/apodex-1.1-mini:free';
export const ALTERNATE_FREE_MODEL='nvidia/nemotron-3-super-120b-a12b:free';
export const FREE_PROVIDER_ROUTES=Object.freeze({[FREE_MODEL]:['google-ai-studio'],[ALTERNATE_FREE_MODEL]:['nvidia'],[FREE_ROUTER]:[],[SUCCESSFUL_FREE_MODEL]:['novita/bf16']});
export const ZERO_PRICE=Object.freeze({only:['google-ai-studio'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}});
// No env/file lookup. The composition root supplies a manually configured secret later.
export class OpenRouterProvider {
  #secret;
  #observations=[];
  #catalog=null;
  constructor({model=null,secret=null,endpoint=OPENROUTER_ENDPOINT,liveNetworkEnabled=false,allowFreeRouter=false,fetchImpl=globalThis.fetch,maxTokens=2048,timeoutMs=30000,privateRoutingPolicy=null,beforeStream=null,expectedProviderDisplay=null,allowImageInput=false,privateRouteReviewID=null}={}){
    this.allowImageInput=allowImageInput===true;
    this.model=model;this.endpoint=endpoint;this.#secret=secret;this.liveNetworkEnabled=liveNetworkEnabled;this.allowFreeRouter=allowFreeRouter;this.fetchImpl=fetchImpl;
    check(Number.isInteger(maxTokens)&&maxTokens>0&&maxTokens<=2048&&Number.isInteger(timeoutMs)&&timeoutMs>0&&timeoutMs<=60000,422,'invalid_provider_limits');
    this.maxTokens=maxTokens;this.timeoutMs=timeoutMs;
    this.privateRoutingPolicy=privateRoutingPolicy;this.privateRouteReviewID=privateRouteReviewID;this.beforeStream=beforeStream;this.expectedProviderDisplay=expectedProviderDisplay;
    this.routingPolicy={...clone(ZERO_PRICE),only:clone(FREE_PROVIDER_ROUTES[model]??[])};if(model===FREE_ROUTER)delete this.routingPolicy.only;
    if(privateRoutingPolicy)this.routingPolicy=clone(privateRoutingPolicy);
    if(this.allowImageInput){check(model===LIVE_VISION_ROUTE.model&&privateRoutingPolicy&&hash(privateRoutingPolicy)===hash(LIVE_VISION_ROUTE.routing_policy)&&expectedProviderDisplay===LIVE_VISION_ROUTE.downstream_provider,503,'vision_route_not_configured');this.visionContract={execution_layer:'live_image_adapter',route:clone(LIVE_VISION_ROUTE)};}
    this.identity={provider:'openrouter',model,endpoint,free_only:model?.endsWith(':free')===true,max_tokens:maxTokens,adapter_version:4,routing_policy:clone(this.routingPolicy)};
  }
  get observations(){return clone(this.#observations);}
  get reality(){return this.#secret&&this.model?'provider_unverified':'not_configured';}
  assertReady(){
    check(typeof this.model==='string'&&typeof this.#secret==='string'&&this.#secret.trim(),503,'not_configured');
    check(this.endpoint===OPENROUTER_ENDPOINT,422,'endpoint_not_allowed');
    if(this.privateRoutingPolicy&&this.allowImageInput){check(this.model===LIVE_VISION_ROUTE.model&&hash(this.routingPolicy)===hash(LIVE_VISION_ROUTE.routing_policy)&&typeof this.beforeStream==='function',503,'vision_route_not_configured');}else if(this.privateRoutingPolicy){const original=this.privateRouteReviewID===null&&this.model===SUCCESSFUL_FREE_MODEL&&JSON.stringify(this.routingPolicy.only)===JSON.stringify(['novita/bf16'])&&Object.values(this.routingPolicy.max_price).every(v=>v===0)&&this.routingPolicy.only.length===1&&this.routingPolicy.allow_fallbacks===false&&this.routingPolicy.data_collection==='deny';const review=matchesGemmaPrivateReview({reviewID:this.privateRouteReviewID,model:this.model,expectedProviderDisplay:this.expectedProviderDisplay,routingPolicy:this.routingPolicy});check((original||review)&&typeof this.beforeStream==='function',503,'private_route_not_configured');}else check(Object.hasOwn(FREE_PROVIDER_ROUTES,this.model)&&(this.model!==FREE_ROUTER||this.allowFreeRouter===true),422,'paid_or_router_model_denied');
    check(!/[\r\n]/.test(this.#secret),422,'invalid_credential');
    check(this.liveNetworkEnabled===true,503,'live_calls_not_authorized');
  }
  get catalogEvidence(){return clone(this.#catalog);}
  async assertImageAvailable(signal){
    check(this.allowImageInput,503,'image_live_route_disabled');if(this.#catalog&&Date.now()-this.#catalog.checked_at<300000)return this.catalogEvidence;
    let response;try{response=await this.fetchImpl(VISION_CATALOG_URL,{method:'GET',redirect:'error',signal:signal?AbortSignal.any([signal,AbortSignal.timeout(5000)]):AbortSignal.timeout(5000)});}catch{throw new ApiError(503,'vision_catalog_unavailable');}
    check(response.status===200&&response.body,503,'vision_catalog_unavailable');let text='',data,total=0;const reader=response.body.getReader(),decoder=new TextDecoder();try{while(true){const r=await reader.read();if(r.done)break;total+=r.value.byteLength;check(total<=100000,503,'vision_catalog_invalid');text+=decoder.decode(r.value,{stream:true});}text+=decoder.decode();}catch(e){await reader.cancel().catch(()=>{});throw e instanceof ApiError?e:new ApiError(503,'vision_catalog_unavailable');}finally{reader.releaseLock();}
    try{data=JSON.parse(text).data;}catch{throw new ApiError(503,'vision_catalog_invalid');}
    check(Array.isArray(data?.endpoints),503,'vision_catalog_invalid');
    const eligible=data.endpoints.find(e=>e?.tag===LIVE_VISION_ROUTE.provider_tag&&e.provider_name===LIVE_VISION_ROUTE.downstream_provider&&e.model_id===this.model&&e.status===0&&e.pricing?.prompt==='0'&&e.pricing?.completion==='0');
    check(data?.id===this.model&&data.architecture?.input_modalities?.includes('image')&&data.architecture?.output_modalities?.includes('text')&&eligible,503,'free_vision_endpoint_unavailable');
    this.#catalog={checked_at:Date.now(),model:this.model,provider:eligible.provider_name,provider_tag:eligible.tag,prompt_price:0,completion_price:0,training_filter_required:'deny',zero_retention_claim:false};return this.catalogEvidence;
  }
  async *stream({messages,system_prompt,tools,signal,provider_context,assertDispatchReady,image_attachments,vision_user_index}){
    const images=image_attachments??[];
    check(!messages.some(m=>Array.isArray(m.content))&&(!images.length||this.allowImageInput),503,'image_live_route_disabled');
    if(images.length){check(provider_context?.image_route_hash===LIVE_VISION_ROUTE_HASH,403,'provider_image_context_required');await this.assertImageAvailable(signal);}
    this.assertReady();signal?.throwIfAborted();await this.beforeStream?.(provider_context);signal?.throwIfAborted();assertDispatchReady?.();
    const controller=new AbortController(),cancel=()=>controller.abort();
    signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
    let timedOut=false;const timer=setTimeout(()=>{timedOut=true;cancel();},this.timeoutMs);
    let response;
    const evidence={attempt:this.#observations.length+1,requested_model:this.model,endpoint:this.endpoint,request_policy:clone(this.routingPolicy),http_status:null,actual_model:null,actual_provider:null,response_id:null,usage:null,terminal_validated:false};
    if(images.length){evidence.image_count=images.length;evidence.image_hashes=images.map(a=>a.receipt.sha256);evidence.image_bytes=images.reduce((n,a)=>n+a.receipt.size_bytes,0);}const reviewFrames=matchesGemmaPrivateReview({reviewID:this.privateRouteReviewID,model:this.model,expectedProviderDisplay:this.expectedProviderDisplay,routingPolicy:this.routingPolicy})?{seen:{},validation:{schema_version:1,review_id:this.privateRouteReviewID,frames:0,passed:false}}:null;
    if(reviewFrames)evidence.review_frame_validation=reviewFrames.validation;
    this.#observations.push(evidence);
    try {
      const modelMessages=images.length?mapVisionMessages(messages,images,vision_user_index):clone(messages);
      const payload={model:this.model,messages:[{role:'system',content:system_prompt},...modelMessages],...tools.length?{tools:clone(tools),tool_choice:'auto'}:{},stream:true,max_tokens:this.maxTokens,provider:clone(this.routingPolicy)};
      const fetchStarted=this.chatMetrics?.now();let firstText=false;
      response=await this.fetchImpl(this.endpoint,{method:'POST',redirect:'error',signal:controller.signal,
        headers:{Authorization:`Bearer ${this.#secret}`,'Content-Type':'application/json',Accept:'text/event-stream'},body:JSON.stringify(payload)});
      evidence.http_status=response.status;
      if(response.status!==200){const failure=await safeProviderFailure(response,{redact:text=>text.replaceAll(this.#secret,'[REDACTED]').replace(/data:image\/[^;,\s]+;base64,[A-Za-z0-9+/=]+/gi,'[IMAGE_REDACTED]')});evidence.failure=images.length?Object.fromEntries(Object.entries(failure).filter(([key])=>['headers','category','retry_after_seconds','retry_at','retry_allowed','account_daily_reset_utc'].includes(key))):failure;}
      const codes={401:'unauthorized',402:'quota_exhausted',403:'forbidden',404:'free_model_unavailable',429:'rate_limited'};
      check(response.status===200,response.status===429?429:503,codes[response.status]??'provider_failed');
      check(response.headers.get('content-type')?.startsWith('text/event-stream')&&response.body,503,'invalid_provider_stream');
      let finish=null,done=false,responseID=null,textBytes=0;const calls=new Map();
      for await(const data of sseData(response.body)){
        if(data==='[DONE]'){done=true;break;}
        let chunk;try{chunk=JSON.parse(data);}catch{throw new ApiError(503,'malformed_provider_json');}
        check(!chunk.error,503,Number(chunk.error?.code)===429?'rate_limited':'provider_stream_error');
        if(chunk.model){const allowed=this.model===FREE_ROUTER?APPROVED_ROUTER_MODELS.flatMap(m=>[m,m.replace(/:free$/,'')]):[this.model,this.model.replace(/:free$/,'')];check(allowed.includes(chunk.model),503,'response_model_mismatch',{reconciliation:images.length>0});}
        if(reviewFrames)checkGemmaReviewFrame(chunk,reviewFrames);
        if(typeof chunk.model==='string')evidence.actual_model=chunk.model.slice(0,200);
        if(typeof chunk.provider==='string')evidence.actual_provider=chunk.provider.slice(0,160);
        if(typeof chunk.id==='string'){responseID=chunk.id.slice(0,200);evidence.response_id=responseID;}
        if(chunk.usage&&typeof chunk.usage==='object'){
          const usage={};
          for(const k of ['prompt_tokens','completion_tokens','total_tokens','cost','is_byok']){
            const v=chunk.usage[k];if((typeof v==='number'&&Number.isFinite(v)&&v>=0)||typeof v==='boolean')usage[k]=v;
          }
          if(Object.keys(usage).length)evidence.usage=usage;
        }
        check(Array.isArray(chunk.choices),503,'invalid_provider_chunk');
        const c=chunk.choices.find(x=>x.index===0);if(!c)continue;
        const delta=c.delta??{};
        check(!finish||(!delta.content&&!delta.tool_calls?.length),503,'delta_after_terminal');
        if(delta.content){check(typeof delta.content==='string',503,'invalid_provider_chunk');textBytes+=Buffer.byteLength(delta.content);check(textBytes<=64000,503,'output_too_large');if(!firstText){firstText=true;this.chatMetrics?.record('provider_first_delta',fetchStarted);}yield {type:'text_delta',text:delta.content};}
        for(const part of delta.tool_calls??[]){
          check(Number.isInteger(part.index)&&part.index>=0&&part.index<4,503,'invalid_tool_index');
          const t=calls.get(part.index)??{id:'',name:'',raw:''};
          if(part.id){check(!t.id||t.id===part.id,503,'tool_id_changed');t.id=part.id;}
          if(part.type)check(part.type==='function',503,'invalid_tool_type');
          const f=part.function??{};check((f.name===undefined||typeof f.name==='string')&&(f.arguments===undefined||typeof f.arguments==='string'),503,'invalid_tool_delta');
          t.name+=f.name??'';t.raw+=f.arguments??'';check(t.name.length<=80&&t.raw.length<=24000&&t.id.length<=160,503,'tool_too_large');calls.set(part.index,t);
        }
        if(c.finish_reason){check(!finish||finish===c.finish_reason,503,'finish_changed');finish=c.finish_reason;}
      }
      check(done&&['stop','tool_calls'].includes(finish),503,'incomplete_provider_terminal',{reconciliation:true});
      check((finish==='tool_calls')===(calls.size>0),503,'tool_finish_mismatch');
      if(this.privateRoutingPolicy)check((evidence.actual_model===this.model||images.length&&evidence.actual_model===this.model.replace(/:free$/,''))&&evidence.actual_provider?.toLowerCase()===this.expectedProviderDisplay?.toLowerCase()&&evidence.usage?.cost===0,503,'private_provider_receipt_mismatch',{reconciliation:true});
      for(const [,t] of [...calls.entries()].sort(([a],[b])=>a-b)){
        check(t.id&&tools.some(x=>x.function.name===t.name),503,'tool_not_allowed');
        let args;try{args=JSON.parse(t.raw);}catch{throw new ApiError(503,'invalid_tool_arguments');}
        yield {type:'tool_call',id:t.id,name:t.name,arguments:args};
      }
      if(reviewFrames)reviewFrames.validation.passed=true;
      evidence.terminal_validated=true;
      yield {type:'done',finish_reason:finish,response_id:responseID,...images.length?{provider_receipt:{requested_model:this.model,actual_model:evidence.actual_model,actual_provider:evidence.actual_provider,cost:evidence.usage.cost,image_count:evidence.image_count,image_hashes:clone(evidence.image_hashes),image_bytes:evidence.image_bytes,route_hash:LIVE_VISION_ROUTE_HASH,terminal_validated:true,response_id:responseID}}:{}};
    } catch(e){
      if(timedOut){evidence.error='provider_timeout';throw new ApiError(503,evidence.error,{reconciliation:true});}
      if(e instanceof ApiError){evidence.error=e.code;throw e;}
      evidence.error=controller.signal.aborted?'provider_interrupted':'provider_transport_failed';
      throw new ApiError(503,evidence.error,{reconciliation:true});
    } finally {
      clearTimeout(timer);signal?.removeEventListener('abort',cancel);controller.abort();
      try{await response?.body?.cancel();}catch{} // no transport auto retry
    }
  }
}
export async function* sseData(body,{maxBytes=256000}={}){
  const decoder=new TextDecoder('utf-8',{fatal:true});let buffer='',lines=[],bytes=0;
  for await(const chunk of body){
    const text=typeof chunk==='string'?chunk:decoder.decode(chunk,{stream:true});bytes+=Buffer.byteLength(text);check(bytes<=maxBytes,503,'stream_too_large');buffer+=text;
    let m;
    while((m=/\r\n|\n|\r(?!$)/.exec(buffer))){
      const line=buffer.slice(0,m.index);buffer=buffer.slice(m.index+m[0].length);
      if(line===''){if(lines.length){yield lines.join('\n');lines=[];}}
      else if(line.startsWith('data:'))lines.push(line.slice(5).replace(/^ /,''));
      check(Buffer.byteLength(buffer)+Buffer.byteLength(lines.join('\n'))<=64000,503,'sse_frame_too_large');
    }
  }
  buffer+=decoder.decode();
  // A CR held across chunks may itself be the final complete line separator.
  if(buffer.endsWith('\r')){
    const line=buffer.slice(0,-1);buffer='';
    if(line===''){if(lines.length){yield lines.join('\n');lines=[];}}
    else if(line.startsWith('data:'))lines.push(line.slice(5).replace(/^ /,''));
  }
  check(!buffer&&!lines.length,503,'incomplete_provider_terminal',{reconciliation:true});
}
export async function collectRound(provider,input,onText=async()=>{}){
  let text='',terminal=false,finish=null,providerReceipt=null,routeInfo=null;const calls=[];
  for await(const e of provider.stream(input)){
    check(!terminal,503,'event_after_terminal');
    if(e.type==='route_info'){routeInfo={route:e.route,model:e.model??null,requested_route:e.requested_route??'auto',failover:e.failover===true,from:Array.isArray(e.from)?e.from.slice(0,8):[],switches:Array.isArray(e.switches)?e.switches.slice(0,8):[],attempt:e.attempt??1};await input.onRoute?.(routeInfo);}
    else if(e.type==='text_delta'){check(typeof e.text==='string'&&Buffer.byteLength(text+e.text)<=64000,503,'invalid_provider_text');text+=e.text;await onText(e.text);}
    else if(e.type==='tool_call'){check(calls.length<4&&!calls.some(c=>c.id===e.id),503,'duplicate_tool_call');calls.push({id:e.id,name:e.name,arguments:clone(e.arguments)});}
    else if(e.type==='thinking_delta'){check(typeof e.text==='string',503,'invalid_provider_text');await input.onThinking?.(e.text);}
    else if(e.type==='done'){terminal=true;finish=e.finish_reason;providerReceipt=e.provider_receipt??null;}
    else check(false,503,'unsupported_provider_event');
  }
  check(terminal&&['stop','tool_calls'].includes(finish)&&(finish==='tool_calls')===(calls.length>0),503,'incomplete_provider_terminal',{reconciliation:true});
  check(calls.length>0||text.trim().length>0,503,'empty_provider_response');
  return {text,calls,...providerReceipt?{provider_receipt:clone(providerReceipt)}:{},...routeInfo?{route_info:clone(routeInfo)}:{}};
}
