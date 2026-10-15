import {ApiError,check,hash} from './core/facade-r2/src/common.mjs';
import {Buffer} from 'node:buffer';
import {validatePublicSourcePolicy} from './core/src/public-source-contract.mjs';
import {readFreeRouteChain} from './core/src/free-route-chain.mjs';
import {readApnsConfig,APNS_ENV_NAMES} from './core/src/apns.mjs';
export const SECRET_NAMES=['CATPAW_DATABASE_URL','CATPAW_PRIVATE_MODEL_KEY','CATPAW_TICK_HMAC_KEY','CATPAW_MEMORY_GUARD_KEY'];
export const CONFIG_NAMES=['SUPABASE_URL','CATPAW_PUBLISHABLE_KEY'];
export const OPTIONAL_CONFIG_NAMES=['CATPAW_PUBLIC_SOURCE_POLICY','CATPAW_GEMINI_API_KEY','CATPAW_GROQ_API_KEY','CATPAW_AGNES_API_KEY','CATPAW_AGNES_MODEL','CATPAW_MODEL_ROUTE_ORDER','CATPAW_THINKING_SUMMARY','CATPAW_MODEL_AUTO_FAILOVER',...APNS_ENV_NAMES,'CATPAW_APNS_ENV'];
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
export function readConfig(get){
 const projectUrl=get('SUPABASE_URL')||PROJECT_URL;
 const publishableKey=get('CATPAW_PUBLISHABLE_KEY')||platformPublishableKey(get)||(projectUrl===PROJECT_URL?PROJECT_PUBLISHABLE_KEY:undefined);
 const resolved=name=>name==='SUPABASE_URL'?projectUrl:name==='CATPAW_PUBLISHABLE_KEY'?publishableKey:get(name);
 const missing=[...SECRET_NAMES,...CONFIG_NAMES].filter(name=>!resolved(name));
 const base={projectUrl,publishableKey,databaseUrl:get('CATPAW_DATABASE_URL')};
 const sourcePolicyText=get('CATPAW_PUBLIC_SOURCE_POLICY');
 const publicSourcePolicy=sourcePolicyText===undefined||sourcePolicyText===null||sourcePolicyText===''?null:publicSourcePolicyJSON(sourcePolicyText);
 const route={id:'catpaw-free-consented-v1',free:true,provider:'OpenRouter',downstream_provider:'Novita',model:'apodex/apodex-1.1-mini:free',endpoint:'https://openrouter.ai/api/v1/chat/completions',routing_policy:{only:['novita/bf16'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}},data_fields:['current_message_text','conversation_text_history_max_40_messages_80kB','explicit_context_text','local_report_task_instructions_and_feedback','user_confirmed_memory_with_source_references'],purposes:['chat_reply','local_report','user_enabled_memory_personalization'],excluded_fields:['automatic_email_access','calendar','photos','contacts','other_apps','auth_tokens'],policy_url:'https://openrouter.ai/privacy',history_limit:40,sensitive_requires_separate_confirmation:true};
 // R7 MVP: when a Gemini/Groq free-tier key is deployed, the consented route becomes the ordered free chain.
 // Without it the frozen single route above stays unchanged (switching is an explicit deploy act).
 const chain=readFreeRouteChain(get);let freeChain=null,activeRoute=route;
 if(chain){freeChain=chain;activeRoute={...route,id:'catpaw-free-chain-v1',provider:chain.routes.map(r=>r.provider).join(' → '),downstream_provider:chain.routes.map(r=>r.provider).join('、'),model:chain.routes[0].model,endpoint:chain.routes[0].endpoint,routing_policy:{chain:chain.routes.map(r=>({id:r.id,model:r.model,endpoint:r.endpoint})),failover:chain.autoFailover?'before_first_output_only':'disabled',max_price:{prompt:0,completion:0,request:0,image:0},billing:chain.routes.map(r=>({id:r.id,billing:r.billing}))},policy_url:chain.routes[0].policy_url,policy_urls:chain.routes.map(r=>r.policy_url),thinking_summary:chain.routes.some(r=>r.thinking_summary)};}
 const finalRoute=activeRoute;
 if(publicSourcePolicy){finalRoute.data_fields=[...finalRoute.data_fields,'user_provided_public_urls_and_received_source_text'];finalRoute.purposes=[...finalRoute.purposes,'user_url_sourced_report'];}
 return {...base,publicSourcePolicy,ready:missing.length===0,missing,authReady:!!base.projectUrl&&!!base.publishableKey&&!!base.databaseUrl,modelKey:get('CATPAW_PRIVATE_MODEL_KEY'),tickKey:get('CATPAW_TICK_HMAC_KEY'),guardKey:get('CATPAW_MEMORY_GUARD_KEY'),route:finalRoute,routeHash:hash(finalRoute),freeChain,apns:readApnsConfig(get),chatBudgetMs:50000,chatFinalizationReserveMs:5000,tickBudgetMs:30000,modelTimeoutMs:20000,dailyCallLimit:20};
}
