import {ApiError,check,hash} from './core/facade-r2/src/common.mjs';
import {Buffer} from 'node:buffer';
import {validatePublicSourcePolicy} from './core/src/public-source-contract.mjs';
import {readFreeRouteChain} from './core/src/free-route-chain.mjs';
import {liveTextIntervalMs} from './core/src/live-text.mjs';
import {readApnsConfig,APNS_ENV_NAMES} from './core/src/apns.mjs';
export const SECRET_NAMES=['CATPAW_DATABASE_URL','CATPAW_PRIVATE_MODEL_KEY','CATPAW_TICK_HMAC_KEY','CATPAW_MEMORY_GUARD_KEY'];
export const CONFIG_NAMES=['SUPABASE_URL','CATPAW_PUBLISHABLE_KEY'];
export const OPTIONAL_CONFIG_NAMES=['CATPAW_PUBLIC_SOURCE_POLICY','CATPAW_GEMINI_API_KEY','CATPAW_GROQ_API_KEY','CATPAW_AGNES_API_KEY','CATPAW_AGNES_MODEL','CATPAW_MODEL_ROUTE_ORDER','CATPAW_THINKING_SUMMARY','CATPAW_MODEL_AUTO_FAILOVER','CATPAW_VISION_LIVE_ENABLED','CATPAW_VISION_CONTRACT_ENABLED','CATPAW_VISION_ROUTE',...APNS_ENV_NAMES,'CATPAW_APNS_ENV'];
// Version-controlled release capability (from live v22); never overrides an explicit nonempty disable/invalid setting.
export const RELEASE_VISION_LIVE_DEFAULT=true;
/** CATPAW_VISION_ROUTE: chain (default once a Gemini interactions key is deployed: Gemini 3.5 Flash-Lite → OpenRouter Gemma 4)
 * | legacy (single Gemma route, unchanged hash). Without a usable Gemini key the legacy route stays. */
export function readVisionRouteMode(get,freeChain){
 const raw=String(get('CATPAW_VISION_ROUTE')??'').trim().toLowerCase()||'chain';
 if(raw!=='chain')return 'legacy'; // legacy or an unknown value: keep the old single route (never break boot)
 const gemini=freeChain?.routes?.find(r=>r.id==='gemini'),key=freeChain?.secrets?.gemini;
 return gemini?.protocol==='interactions'&&typeof key==='string'&&key.trim()!==''?'chain':'legacy';
}
const PROJECT_URL='';
const PROJECT_PUBLISHABLE_KEY='';
// Supabase-hosted functions inject SUPABASE_PUBLISHABLE_KEYS ({"default":...}) / legacy SUPABASE_ANON_KEY;
// live v22 fell back to them when CATPAW_PUBLISHABLE_KEY is unset. Never accept a secret key.
const validPublicKey=v=>typeof v==='string'&&v.length>0&&v===v.trim()&&!/[\r\n]/.test(v)&&!v.startsWith('sb_secret_');
export function platformPublishableKey(get){
 const encoded=get('SUPABASE_PUBLISHABLE_KEYS');
 if(encoded){try{const keys=JSON.parse(encoded);if(keys&&typeof keys==='object'&&!Array.isArray(keys)&&validPublicKey(keys.default))return keys.default;}catch{}return undefined;}
 const legacy=get('SUPABASE_ANON_KEY');return validPublicKey(legacy)?legacy:undefined;
}
// JSON.parse alone silently accepts duplicate object keys. Reviewed network policy must have one meaning.
function publicSourcePolicyJSON(raw){
 check(typeof raw==='string'&&Buffer.byteLength(raw)<=16384,422,'source_policy_invalid');let parsed;
 try{parsed=JSON.parse(raw);}catch{throw new ApiError(422,'source_policy_invalid');}
 let cursor=0;const whitespace=()=>{while(/\s/.test(raw[cursor]??'')&&cursor<raw.length)cursor++;};
 const string=()=>{const start=cursor++;while(cursor<raw.length){const character=raw[cursor++];if(character==='\\'){cursor++;continue;}if(character==='"')return JSON.parse(raw.slice(start,cursor));}throw new ApiError(422,'source_policy_invalid');};
 const value=depth=>{
  check(depth<=16,422,'source_policy_invalid');whitespace();const character=raw[cursor];
  if(character==='"'){string();return;}
  if(character==='{'){
   cursor++;whitespace();const keys=new Set();if(raw[cursor]==='}'){cursor++;return;}
   for(;;){const key=string();check(!keys.has(key),422,'source_policy_duplicate_key');keys.add(key);whitespace();check(raw[cursor++]===':',422,'source_policy_invalid');value(depth+1);whitespace();const separator=raw[cursor++];if(separator==='}')return;check(separator===',',422,'source_policy_invalid');whitespace();}
  }
  if(character==='['){cursor++;whitespace();if(raw[cursor]===']'){cursor++;return;}for(;;){value(depth+1);whitespace();const separator=raw[cursor++];if(separator===']')return;check(separator===',',422,'source_policy_invalid');}}
  const token=/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(raw.slice(cursor));check(token,422,'source_policy_invalid');cursor+=token[0].length;
 };
 value(0);whitespace();check(cursor===raw.length,422,'source_policy_invalid');return validatePublicSourcePolicy(parsed);
}
// W1: Gemini free tier is the auto default; Google may retain prompts and use them to improve products (incl. training),
// with possible human review. Part of the consented route, so changing this text changes routeHash and forces re-consent.
export const GEMINI_FREE_TIER_DISCLOSURE='If the Google Gemini route is used (the default first route), your messages, conversation history and memory context are sent to the Google Gemini API free tier. Google may retain this content and use it to provide, improve and develop its products and models (including training), and human reviewers may read it. Do not send sensitive or personal information you do not want Google to see. 使用 Google Gemini 路由（默认首选）时，你的消息、对话历史和记忆上下文会发送到 Google Gemini API 免费层；Google 可能保留这些内容并用于改进产品和模型（包括训练），也可能有人工审核。请勿发送你不希望 Google 看到的敏感或个人信息。See https://ai.google.dev/gemini-api/terms.';
export function readConfig(get){
 const projectUrl=get('SUPABASE_URL')||PROJECT_URL;
 const configurationIssues=[];
 const publicKey=()=>{
  const explicit=get('CATPAW_PUBLISHABLE_KEY');
  if(explicit){if(validPublicKey(explicit))return explicit;configurationIssues.push('custom_public_key_invalid');return undefined;}
  const encoded=get('SUPABASE_PUBLISHABLE_KEYS');
  if(encoded!==undefined&&encoded!==null){
   let keys;try{keys=JSON.parse(encoded);}catch{configurationIssues.push('platform_public_key_map_invalid_json');return undefined;}
   if(!keys||typeof keys!=='object'||Array.isArray(keys)||!Object.hasOwn(keys,'default')){configurationIssues.push('platform_public_key_default_missing');return undefined;}
   if(!validPublicKey(keys.default)){configurationIssues.push('platform_public_key_default_invalid');return undefined;}
   return keys.default;
  }
  const legacy=get('SUPABASE_ANON_KEY');
  if(legacy){if(validPublicKey(legacy))return legacy;configurationIssues.push('legacy_public_key_invalid');}
  return undefined;
 };
 const publishableKey=publicKey()||(projectUrl===PROJECT_URL?PROJECT_PUBLISHABLE_KEY:undefined);
 const visionLiveSetting=get('CATPAW_VISION_LIVE_ENABLED');
 const resolved=name=>name==='SUPABASE_URL'?projectUrl:name==='CATPAW_PUBLISHABLE_KEY'?publishableKey:get(name);
 const missing=[...SECRET_NAMES,...CONFIG_NAMES].filter(name=>!resolved(name));
 const base={projectUrl,publishableKey,databaseUrl:get('CATPAW_DATABASE_URL')};
 const sourcePolicyText=get('CATPAW_PUBLIC_SOURCE_POLICY');
 const publicSourcePolicy=sourcePolicyText===undefined||sourcePolicyText===null||sourcePolicyText===''?null:publicSourcePolicyJSON(sourcePolicyText);
 const route={id:'catpaw-free-consented-v1',free:true,provider:'OpenRouter',downstream_provider:'Novita',model:'apodex/apodex-1.1-mini:free',endpoint:'https://openrouter.ai/api/v1/chat/completions',routing_policy:{only:['novita/bf16'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}},data_fields:['current_message_text','conversation_text_history_max_40_messages_80kB','explicit_context_text','local_report_task_instructions_and_feedback','user_confirmed_memory_with_source_references'],purposes:['chat_reply','local_report','user_enabled_memory_personalization'],excluded_fields:['automatic_email_access','calendar','photos','contacts','other_apps','auth_tokens'],policy_url:'https://openrouter.ai/privacy',history_limit:40,sensitive_requires_separate_confirmation:true};
 // R7 MVP: when a Gemini/Groq free-tier key is deployed, the consented route becomes the ordered free chain.
 // Without it the frozen single route above stays unchanged (switching is an explicit deploy act).
 const chain=readFreeRouteChain(get);let freeChain=null,activeRoute=route;
 if(chain){freeChain=chain;activeRoute={...route,id:'catpaw-free-chain-v1',provider:chain.routes.map(r=>r.provider).join(' → '),downstream_provider:chain.routes.map(r=>r.provider).join('、'),model:chain.routes[0].model,endpoint:chain.routes[0].endpoint,routing_policy:{chain:chain.routes.map(r=>({id:r.id,model:r.model,models:r.models,endpoint:r.endpoint})),failover:chain.autoFailover?'before_first_output_only':'disabled',max_price:{prompt:0,completion:0,request:0,image:0},billing:chain.routes.map(r=>({id:r.id,billing:r.billing}))},policy_url:chain.routes[0].policy_url,policy_urls:chain.routes.map(r=>r.policy_url),thinking_summary:chain.routes.some(r=>r.thinking_summary)};;if(chain.routes.some(r=>r.id==='opencode')){activeRoute.data_fields=[...activeRoute.data_fields,'prompt_and_history_sent_to_opencode_zen_free_models'];activeRoute.opencode_disclosure='If the OpenCode Zen route is used, your messages and conversation history are sent to OpenCode Zen (opencode.ai), which serves the selected free model from US/EU providers. The default free models are documented as zero-retention and not used for training; see https://opencode.ai/legal/privacy-policy and https://opencode.ai/docs/zen/#privacy.';}if(chain.routes.some(r=>r.id==='gemini')){activeRoute.data_fields=[...activeRoute.data_fields,'prompt_and_history_sent_to_google_gemini_free_tier'];activeRoute.gemini_disclosure=GEMINI_FREE_TIER_DISCLOSURE;}}
 const finalRoute=activeRoute;
 if(publicSourcePolicy){finalRoute.data_fields=[...finalRoute.data_fields,'user_provided_public_urls_and_received_source_text'];finalRoute.purposes=[...finalRoute.purposes,'user_url_sourced_report'];}
 // Supabase injects the service-role key into hosted functions; used only server-side for the private attachment bucket.
 const serviceRoleKey=get('SUPABASE_SERVICE_ROLE_KEY');
 // Unset gate → 'on' for everyone (user decision 2026-10-17 08:51). 'allowlist' → env allowlist OR DB enrollment;
 // explicit 'false'/'off' → off. CATPAW_FEATURE_BLOCKLIST_SUBJECTS turns every feature off for the listed subjects.
 const G=n=>readFeatureGate(get(n),'on');
 const generativeUI=G('CATPAW_GENERATIVE_UI_ENABLED'),taskTools=G('CATPAW_TASK_TOOLS_ENABLED'),featureAllowlist=withBlocklist(readAllowlist(get('CATPAW_FEATURE_ALLOWLIST_SUBJECTS')),readAllowlist(get('CATPAW_FEATURE_BLOCKLIST_SUBJECTS'))),agentMemory=G('CATPAW_AGENT_MEMORY_ENABLED'),deviceTools=G('CATPAW_DEVICE_TOOLS_ENABLED'),proactiveSuggestionsSSE=G('CATPAW_PROACTIVE_SUGGESTIONS_SSE_ENABLED'),proactive=G('CATPAW_PROACTIVE_ENABLED');
 return {...base,sseTextIntervalMs:liveTextIntervalMs(get('CATPAW_SSE_TEXT_INTERVAL_MS')),generativeUI,taskTools,featureAllowlist,agentMemory,deviceTools,proactiveSuggestionsSSE,proactive,schedulerSecret:get('CATPAW_SCHEDULER_SECRET')||null,attachmentStorage:typeof serviceRoleKey==='string'&&serviceRoleKey.length>20&&!/[\r\n]/.test(serviceRoleKey)?{url:projectUrl,serviceKey:serviceRoleKey}:null,publicSourcePolicy,visionContractEnabled:get('CATPAW_VISION_CONTRACT_ENABLED')==='true',visionRoute:readVisionRouteMode(get,freeChain),visionLiveEnabled:visionLiveSetting===undefined||visionLiveSetting===null||visionLiveSetting===''?RELEASE_VISION_LIVE_DEFAULT:visionLiveSetting==='true',ready:missing.length===0&&configurationIssues.length===0,missing,configurationIssues,authReady:!!base.projectUrl&&!!base.publishableKey&&!!base.databaseUrl,modelKey:get('CATPAW_PRIVATE_MODEL_KEY'),tickKey:get('CATPAW_TICK_HMAC_KEY'),guardKey:get('CATPAW_MEMORY_GUARD_KEY'),route:finalRoute,routeHash:hash(finalRoute),freeChain,apns:readApnsConfig(get),chatBudgetMs:freeChain?.routes?.some(r=>r.id==='agnes')?120000:50000,chatFinalizationReserveMs:5000,tickBudgetMs:30000,modelTimeoutMs:20000,dailyCallLimit:readDailyCallLimit(get('CATPAW_DAILY_CALL_LIMIT')),dailyCallExempt:readAllowlist(get('CATPAW_DAILY_MODEL_CALL_EXEMPT_SUBJECTS'))};
}

/** Feature gate: 'true'|'1' → on for everyone, 'allowlist' → env allowlist + DB-enrolled subjects, unset/empty → `unset` (readConfig passes 'on'), anything else → off. */
export function readFeatureGate(value,unset='off'){const v=String(value??'').trim().toLowerCase();return v===''?unset:v==='true'||v==='1'?'on':v==='allowlist'?'allowlist':'off';}
export function readAllowlist(value){const UUIDRE=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;return new Set(String(value??'').split(',').map(x=>x.trim().toLowerCase()).filter(x=>UUIDRE.test(x)));}
/** The allowlist Set carries the blocklist (`.blocked`), so every existing featureAllows caller honours it. */
export function withBlocklist(allowlist,blocked){Object.defineProperty(allowlist,'blocked',{value:blocked instanceof Set?blocked:new Set(),enumerable:false});return allowlist;}
/** True when the subject is blocklisted (invalid UUIDs were dropped by readAllowlist; a blocklisted subject is off for every feature). */
export const featureBlocked=(allowlist,subjectID,blocklist=null)=>{const b=blocklist instanceof Set?blocklist:allowlist?.blocked;return b instanceof Set&&b.size>0&&subjectID!=null&&b.has(String(subjectID).toLowerCase());};
/** enrolled: optional {has(subjectID, feature)} (enrollment registry); an enrolled subject counts as allowlisted for that feature.
 *  The blocklist wins over 'on', the allowlist and enrollment. */
export const featureAllows=(gate,allowlist,subjectID,enrolled=null,feature=null,blocklist=null)=>!featureBlocked(allowlist,subjectID,blocklist)&&(gate==='on'||(gate==='allowlist'&&subjectID!=null&&((allowlist instanceof Set&&allowlist.has(String(subjectID).toLowerCase()))||(typeof enrolled?.has==='function'&&enrolled.has(subjectID,feature)))));

/** Optional per-subject daily model dispatch quota. Unset/empty/invalid → null = unlimited (no counting). Only a positive integer enables it. */
export function readDailyCallLimit(value){const v=String(value??'').trim();if(!v)return null;const n=Number(v);return /^\d+$/.test(v)&&Number.isSafeInteger(n)&&n>=1?n:null;}
