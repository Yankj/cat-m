import {hash} from '../facade-r2/src/common.mjs';
// One explicitly selected free recipient. No router, fallback or paid alternative.
export const LIVE_VISION_ROUTE=Object.freeze({
 id:'catpaw-gemma4-image-consented-v1',free:true,provider:'OpenRouter',downstream_provider:'Google AI Studio',provider_tag:'google-ai-studio',model:'google/gemma-4-31b-it:free',endpoint:'https://openrouter.ai/api/v1/chat/completions',
 routing_policy:{only:['google-ai-studio'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}},
 data_fields:['user_selected_image_bytes','current_message_text','conversation_text_history','explicit_context_text'],purposes:['chat_reply'],zero_retention_claim:false,
 retention:{days:55,purpose:'Google abuse and safety monitoring',human_review_possible:true,local_image_bytes:'current_request_only',local_text_and_receipts:'persisted_until_source_deletion'},
 training_policy:'Request OpenRouter data_collection=deny; never loosen when no endpoint qualifies. Policy-enforcement processing is distinct from general model training.',
 policy_urls:['https://openrouter.ai/privacy','https://openrouter.ai/docs/guides/privacy/provider-logging','https://ai.google.dev/gemini-api/docs/usage-policies','https://ai.google.dev/gemini-api/terms'],
 privacy_notice_version:1
});
export const LIVE_VISION_ROUTE_HASH=hash(LIVE_VISION_ROUTE);
export const VISION_CATALOG_URL='https://openrouter.ai/api/v1/models/google/gemma-4-31b-it:free/endpoints';
export const VISION_CONSENT_UI=Object.freeze({title:'允许发送这张图片到云端模型？',body:'图片、本轮文字、最近文字会话及主动加入的文字上下文将发送给 OpenRouter 和 Google AI Studio，使用固定的免费 Gemma 4 31B 路线。请求禁止训练、限制费用为0并禁止回退；路线不可用时拒绝发送。Google 安全策略会为安全审查保留输入、上下文和输出55天，并可能人工审核；这不是零保留。服务器不保存图片字节历史，但保存文字回复和附件回执，直到你删除来源。请勿发送敏感、机密或含凭据的图片。撤销不能收回已发出的数据；断开流也不保证上游停止处理。',allow:'允许此会话图片传输',deny:'暂不允许',content_confirmation:'我确认所发图片不包含敏感、机密或凭据信息'});

// v1.1 hotfix (image-upload-bug): ordered FREE vision chain. The legacy route above stays byte-identical so
// CATPAW_VISION_ROUTE=legacy (or no Gemini key) keeps its hash and every image consent given for it.
// Order by capability among free options: Gemini 3.5 Flash-Lite (natively multimodal, the large free daily quota already
// used by text) first, OpenRouter Gemma 4 31B as the busy fallback. Failover only before any output. A different
// recipient set means a different hash, so each conversation is asked for image consent once more (VISION_CHAIN_CONSENT_UI).
export const VISION_GEMINI_MODEL='gemini-3.5-flash-lite';
export const VISION_GEMINI_ENDPOINT='https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse';
export const VISION_CHAIN_ROUTE=Object.freeze({
 id:'catpaw-image-free-chain-v2',free:true,provider:'Google Gemini API (free tier) → OpenRouter',downstream_provider:'Google Gemini API、Google AI Studio',model:VISION_GEMINI_MODEL,endpoint:VISION_GEMINI_ENDPOINT,
 routing_policy:{chain:[
  {id:'gemini',provider:'Google Gemini API (free tier)',model:VISION_GEMINI_MODEL,endpoint:VISION_GEMINI_ENDPOINT,store:false,tools:'none'},
  {id:'openrouter',provider:LIVE_VISION_ROUTE.provider,downstream_provider:LIVE_VISION_ROUTE.downstream_provider,model:LIVE_VISION_ROUTE.model,endpoint:LIVE_VISION_ROUTE.endpoint,routing_policy:LIVE_VISION_ROUTE.routing_policy,tools:'none'}],
  failover:'before_first_output_only',max_price:{prompt:0,completion:0,request:0,image:0}},
 data_fields:LIVE_VISION_ROUTE.data_fields,purposes:LIVE_VISION_ROUTE.purposes,zero_retention_claim:false,
 retention:{gemini:'Gemini API free tier: content may be used to improve Google products and may be reviewed by humans',openrouter:LIVE_VISION_ROUTE.retention,local_image_bytes:'current_request_only',local_text_and_receipts:'persisted_until_source_deletion'},
 training_policy:'Gemini API free tier may use inputs and outputs to improve products (training). OpenRouter hop requests data_collection=deny.',
 policy_urls:['https://ai.google.dev/gemini-api/terms','https://ai.google.dev/gemini-api/docs/pricing',...LIVE_VISION_ROUTE.policy_urls],
 privacy_notice_version:2
});
export const VISION_CHAIN_ROUTE_HASH=hash(VISION_CHAIN_ROUTE);
export const VISION_CHAIN_CONSENT_UI=Object.freeze({title:'允许把这张图片发送到云端模型？',body:'图片、本轮文字、最近文字会话及主动加入的文字上下文会发送给云端模型来理解图片，只使用免费模型。默认使用 Google Gemini API 免费层（Gemini 3.5 Flash-Lite）：Google 可能保留这些内容并用于改进产品和训练模型，也可能由人工审核。Gemini 繁忙或额度用完时，改用 OpenRouter 上由 Google AI Studio 提供的免费 Gemma 4 31B（请求禁止训练、费用为0；Google 会为安全审查保留约55天，可能人工审核）。两条都不可用时拒绝发送。这不是零保留。服务器不保存图片字节历史，但保存文字回复和附件回执，直到你删除来源。请勿发送敏感、机密或含凭据的图片。撤销不能收回已发出的数据；断开流也不保证上游停止处理。',allow:'允许此会话图片传输',deny:'暂不允许',content_confirmation:'我确认所发图片不包含敏感、机密或凭据信息'});
export const VISION_ROUTE_HASHES=Object.freeze([LIVE_VISION_ROUTE_HASH,VISION_CHAIN_ROUTE_HASH]);
