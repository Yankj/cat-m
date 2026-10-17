// Free vision chain (image-upload-bug hotfix): Gemini 3.5 Flash-Lite → OpenRouter Gemma 4, failover only before output.
// Prod 2026-10-17: OpenRouter google/gemma-4-31b-it:free answered 429 to every request since 13:00 (UTC+8) on the key it
// shares with the text chain, so a single-route image turn could not succeed. Gemini has its own free quota (per project
// and per model; the per-model cooldown lives in GeminiRateGuard, shared with the text chain of this isolate).
// Keys come from the composition root (env); they are never logged and never part of the consented route.
import {ApiError,check,clone} from '../facade-r2/src/common.mjs';
import {LIVE_VISION_ROUTE,VISION_CHAIN_ROUTE,VISION_CHAIN_ROUTE_HASH,VISION_GEMINI_MODEL,VISION_GEMINI_ENDPOINT} from './live-vision-route.mjs';
import {mapVisionMessages} from './vision-contract.mjs';
import {OpenRouterProvider,DEFAULT_RATE_LIMIT_RETRY_SECONDS} from './openrouter-provider.mjs';
import {GeminiInteractionsRoute} from './gemini-interactions-route.mjs';
import {FAILOVER_CODES,routeTimeouts,sharedGeminiGuard} from './free-route-chain.mjs';

// A key/config/request fault (not "busy") still falls back for the user, but must not hide behind the next hop's 429:
// it gets failure_class=provider_config_error on the attempt line plus its own warning event (no bodies, no secrets).
export const CONFIG_ERROR_CODES=Object.freeze(['unauthorized','forbidden','provider_request_invalid','free_model_unavailable','not_configured','vision_route_not_configured','endpoint_not_allowed','invalid_credential']);
const failureClass=code=>code==='ok'?null:CONFIG_ERROR_CODES.includes(code)?'provider_config_error':code==='rate_limited'||code==='quota_exhausted'?'provider_busy':'provider_error';
const log=(evidence,startedAt,outcome)=>{try{const cls=failureClass(outcome);if(cls==='provider_config_error')console.warn(JSON.stringify({event:'catpaw_vision_route_config_error',route:'vision-'+evidence.route,model:String(evidence.requested_model??'').slice(0,120),code:outcome,http_status:evidence.http_status??null}));console.info(JSON.stringify({event:'catpaw_route_attempt',failure_class:cls,route:'vision-'+evidence.route,model:String(evidence.requested_model??'').slice(0,120),attempt:evidence.attempt,outcome,http_status:evidence.http_status??null,timeout_phase:evidence.timeout_phase??null,retry_after_seconds:Number.isFinite(evidence.retry_after_seconds)?evidence.retry_after_seconds:null,elapsed_ms:Date.now()-startedAt}));}catch{}};

export class VisionChainProvider{
  #gemini;#geminiReady;#openrouter;#observations=[];
  constructor({geminiSecret,openRouterSecret,fetchImpl=globalThis.fetch,timeoutMs=20000,geminiRpm=10,geminiGuard=null,beforeStream=null}={}){
    this.#geminiReady=typeof geminiSecret==='string'&&!!geminiSecret.trim()&&!/[\r\n]/.test(geminiSecret);
    const geminiRoute={id:'gemini',provider:'Google Gemini API (free tier)',model:VISION_GEMINI_MODEL,endpoint:VISION_GEMINI_ENDPOINT,protocol:'interactions',thinking_summary:false};
    this.#gemini=new GeminiInteractionsRoute(geminiRoute,geminiSecret,{fetchImpl,timeouts:routeTimeouts(geminiRoute,timeoutMs),guard:geminiGuard??sharedGeminiGuard(geminiRpm),thinkingVisible:()=>false});
    this.#openrouter=new OpenRouterProvider({model:LIVE_VISION_ROUTE.model,secret:openRouterSecret,liveNetworkEnabled:true,fetchImpl,timeoutMs,privateRoutingPolicy:LIVE_VISION_ROUTE.routing_policy,beforeStream:async()=>{},expectedProviderDisplay:LIVE_VISION_ROUTE.downstream_provider,allowImageInput:true,imageRouteHash:VISION_CHAIN_ROUTE_HASH});
    this.beforeStream=beforeStream;this.liveNetworkEnabled=true;this.routeHash=VISION_CHAIN_ROUTE_HASH;
    this.visionContract={execution_layer:'live_image_adapter',route:clone(VISION_CHAIN_ROUTE)};
    this.identity={provider:'vision-free-chain',routes:[{id:'gemini',model:VISION_GEMINI_MODEL},{id:'openrouter',model:LIVE_VISION_ROUTE.model}],free_only:true,adapter_version:1};
  }
  set chatMetrics(m){this.#openrouter.chatMetrics=m;}
  get reality(){return 'provider_unverified';}
  get observations(){return clone(this.#observations);}
  get catalogEvidence(){return {chain:['gemini','openrouter'],gemini:{configured:this.#geminiReady,model:VISION_GEMINI_MODEL,prompt_price:0,completion_price:0},openrouter:this.#openrouter.catalogEvidence};}
  assertReady(){check(typeof this.beforeStream==='function'&&(this.#geminiReady||this.#openrouter.reality!=='not_configured'),503,'vision_route_not_configured');}
  /** Available when Gemini is keyed (image input is part of its free tier), otherwise only if the Gemma catalog qualifies. */
  async assertImageAvailable(signal){if(this.#geminiReady){await this.#openrouter.assertImageAvailable(signal).catch(()=>null);return this.catalogEvidence;}await this.#openrouter.assertImageAvailable(signal);return this.catalogEvidence;}
  async *stream(input){
    const images=input.image_attachments??[];
    check(images.length>0,503,'image_live_route_disabled');
    check(input.provider_context?.image_route_hash===VISION_CHAIN_ROUTE_HASH,403,'provider_image_context_required');
    input.signal?.throwIfAborted();await this.beforeStream?.(input.provider_context);input.signal?.throwIfAborted();input.assertDispatchReady?.();
    const receiptBase={image_count:images.length,image_hashes:images.map(a=>a.receipt.sha256),image_bytes:images.reduce((n,a)=>n+a.receipt.size_bytes,0),route_hash:VISION_CHAIN_ROUTE_HASH};
    const failures=[];
    const hops=[['gemini',VISION_GEMINI_MODEL],['openrouter',LIVE_VISION_ROUTE.model]];
    for(const [id,model] of hops){
      if(id==='gemini'&&!this.#geminiReady)continue;
      const evidence={attempt:this.#observations.length+1,route:id,requested_model:model,http_status:null,actual_model:null,terminal_validated:false};
      this.#observations.push(evidence);const startedAt=Date.now();let emitted=false;
      try{
        // The consented route says tools:'none' for both hops; enforce it here instead of trusting the caller (chat-service sends [] today).
        const events=id==='gemini'?this.#gemini.stream({...input,messages:mapVisionMessages(input.messages,images,input.vision_user_index),tools:[]},evidence):this.#openrouter.stream({...input,tools:[]});
        for await(const e of events){
          if(e.type==='thinking_delta')continue;
          if(e.type==='done'){
            evidence.terminal_validated=true;log(evidence,startedAt,'ok');
            yield id==='gemini'?{...e,provider_receipt:{requested_model:model,actual_model:evidence.actual_model??model,actual_provider:'Google Gemini API',cost:0,...receiptBase,route:'gemini',terminal_validated:true,response_id:e.response_id??null}}:{...e,...e.provider_receipt?{provider_receipt:{...e.provider_receipt,route:'openrouter'}}:{}};
            return;
          }
          emitted=true;yield e;
        }
        throw new ApiError(503,'incomplete_provider_terminal',{reconciliation:emitted});
      }catch(e){
        const code=e instanceof ApiError?e.code:'provider_failed';evidence.error=code;evidence.failure_class=failureClass(code);
        if(Number.isFinite(e?.retryAfterSeconds))evidence.retry_after_seconds=Math.ceil(e.retryAfterSeconds);
        log(evidence,startedAt,code);input.signal?.throwIfAborted();
        // Fail over only before any output, and never after an uncertain dispatch (reconciliation) unless it is a busy code.
        if(emitted||!(e instanceof ApiError)||(!FAILOVER_CODES.has(code)&&e.reconciliation))throw e;
        failures.push({route:id,code,retryAfterSeconds:evidence.retry_after_seconds,error:e});
      }
    }
    // Every free vision route is busy: report rate_limited with the earliest advisory retry so the client can count down.
    const last=failures.at(-1)?.error??new ApiError(503,'image_input_unavailable');
    const busy=failures.filter(f=>f.code==='rate_limited'||f.code==='quota_exhausted');
    if(!busy.length)throw last;
    const waits=busy.map(f=>f.retryAfterSeconds).filter(Number.isFinite);
    throw Object.assign(new ApiError(429,'rate_limited'),{retryAfterSeconds:Math.max(1,Math.min(3600,waits.length?Math.min(...waits):DEFAULT_RATE_LIMIT_RETRY_SECONDS))});
  }
}
