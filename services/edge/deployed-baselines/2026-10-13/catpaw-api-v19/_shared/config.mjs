import {check,hash} from './core/facade-r2/src/common.mjs';
export const SECRET_NAMES=['CATPAW_DATABASE_URL','CATPAW_PRIVATE_MODEL_KEY','CATPAW_TICK_HMAC_KEY','CATPAW_MEMORY_GUARD_KEY'];
export const CONFIG_NAMES=['SUPABASE_URL','CATPAW_PUBLISHABLE_KEY'];
// Version-controlled release capability; never overrides an explicit nonempty disable/invalid setting.
export const RELEASE_VISION_LIVE_DEFAULT=true;
const PROJECT_URL='';
export function readConfig(get){
 const projectUrl=get('SUPABASE_URL')||PROJECT_URL;
 const configurationIssues=[];
 const validPublicKey=value=>typeof value==='string'&&value.trim().length>0&&value===value.trim()&&!/[\r\n]/.test(value)&&!value.startsWith('sb_secret_');
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
 const publishableKey=publicKey();
 const resolved=name=>name==='SUPABASE_URL'?projectUrl:name==='CATPAW_PUBLISHABLE_KEY'?publishableKey:get(name);
 const missing=[...SECRET_NAMES,...CONFIG_NAMES].filter(name=>!resolved(name));
 const base={projectUrl,publishableKey,databaseUrl:get('CATPAW_DATABASE_URL')};
 const visionLiveSetting=get('CATPAW_VISION_LIVE_ENABLED');
 const route={id:'catpaw-free-consented-v1',free:true,provider:'OpenRouter',downstream_provider:'Novita',model:'apodex/apodex-1.1-mini:free',endpoint:'https://openrouter.ai/api/v1/chat/completions',routing_policy:{only:['novita/bf16'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}},data_fields:['current_message_text','conversation_text_history_max_40_messages_80kB','explicit_context_text','local_report_task_instructions_and_feedback'],purposes:['chat_reply','local_report'],excluded_fields:['automatic_email_access','calendar','photos','contacts','other_apps','auth_tokens'],policy_url:'https://openrouter.ai/privacy',history_limit:40,sensitive_requires_separate_confirmation:true};
 return {...base,visionContractEnabled:get('CATPAW_VISION_CONTRACT_ENABLED')==='true',visionLiveEnabled:visionLiveSetting===undefined||visionLiveSetting===null||visionLiveSetting===''?RELEASE_VISION_LIVE_DEFAULT:visionLiveSetting==='true',ready:missing.length===0&&configurationIssues.length===0,missing,configurationIssues,authReady:!!base.projectUrl&&!!base.publishableKey&&!!base.databaseUrl,modelKey:get('CATPAW_PRIVATE_MODEL_KEY'),tickKey:get('CATPAW_TICK_HMAC_KEY'),guardKey:get('CATPAW_MEMORY_GUARD_KEY'),route,routeHash:hash(route),chatBudgetMs:50000,chatFinalizationReserveMs:5000,tickBudgetMs:30000,modelTimeoutMs:20000,dailyCallLimit:20};
}
