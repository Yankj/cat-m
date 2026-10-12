import {check,hash} from './core/facade-r2/src/common.mjs';
export const SECRET_NAMES=['CATPAW_DATABASE_URL','CATPAW_PRIVATE_MODEL_KEY','CATPAW_TICK_HMAC_KEY','CATPAW_MEMORY_GUARD_KEY'];
export const CONFIG_NAMES=['SUPABASE_URL','CATPAW_PUBLISHABLE_KEY'];
const PROJECT_URL='';
const PROJECT_PUBLISHABLE_KEY='';
export function readConfig(get){
 const projectUrl=get('SUPABASE_URL')||PROJECT_URL;
 const publishableKey=get('CATPAW_PUBLISHABLE_KEY')||(projectUrl===PROJECT_URL?PROJECT_PUBLISHABLE_KEY:undefined);
 const resolved=name=>name==='SUPABASE_URL'?projectUrl:name==='CATPAW_PUBLISHABLE_KEY'?publishableKey:get(name);
 const missing=[...SECRET_NAMES,...CONFIG_NAMES].filter(name=>!resolved(name));
 const base={projectUrl,publishableKey,databaseUrl:get('CATPAW_DATABASE_URL')};
 const route={id:'catpaw-free-consented-v1',free:true,provider:'OpenRouter',downstream_provider:'Novita',model:'apodex/apodex-1.1-mini:free',endpoint:'https://openrouter.ai/api/v1/chat/completions',routing_policy:{only:['novita/bf16'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}},data_fields:['current_message_text','conversation_text_history_max_40_messages_80kB','explicit_context_text','local_report_task_instructions_and_feedback'],purposes:['chat_reply','local_report'],excluded_fields:['automatic_email_access','calendar','photos','contacts','other_apps','auth_tokens'],policy_url:'https://openrouter.ai/privacy',history_limit:40,sensitive_requires_separate_confirmation:true};
 return {...base,ready:missing.length===0,missing,authReady:!!base.projectUrl&&!!base.publishableKey&&!!base.databaseUrl,modelKey:get('CATPAW_PRIVATE_MODEL_KEY'),tickKey:get('CATPAW_TICK_HMAC_KEY'),guardKey:get('CATPAW_MEMORY_GUARD_KEY'),route,routeHash:hash(route),chatBudgetMs:50000,chatFinalizationReserveMs:5000,tickBudgetMs:30000,modelTimeoutMs:20000,dailyCallLimit:20};
}
