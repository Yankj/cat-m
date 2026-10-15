import {check,hash,clone} from './core/facade-r2/src/common.mjs';
import {readConfig} from './config.mjs';
import {OpenRouterProvider,OPENROUTER_ENDPOINT} from './core/src/openrouter-provider.mjs';
import {GEMMA_PRIVATE_REVIEW_ID,GEMMA_PRIVATE_REVIEW_MODEL,GEMMA_PRIVATE_REVIEW_PROVIDER,gemmaPrivateReviewPolicy} from './core/src/private-route-review.mjs';
export {GEMMA_PRIVATE_REVIEW_ID};
export const GEMMA_REVIEW_BASE_ROUTE_HASH='eef4100e83db1b2ab5ea9a7efd4818e97dcd90c819f056b54082fbdf5cd5e305';
// Copy only the exact current text/local-report data contract. The default config
// and Edge entrypoints never import this module and remain on apodex/Novita.
export function gemmaRouteReviewManifest(){
 const baseline=readConfig(()=>undefined).route;
 check(hash(baseline)===GEMMA_REVIEW_BASE_ROUTE_HASH,409,'private_route_review_baseline_changed');
 const route={...clone(baseline),id:GEMMA_PRIVATE_REVIEW_ID,model:GEMMA_PRIVATE_REVIEW_MODEL,downstream_provider:GEMMA_PRIVATE_REVIEW_PROVIDER,routing_policy:gemmaPrivateReviewPolicy()};
 return {schema_version:1,review_id:GEMMA_PRIVATE_REVIEW_ID,activation:'inactive_explicit_injection_only',route,route_hash:hash(route),supersedes_route_hash:GEMMA_REVIEW_BASE_ROUTE_HASH,requires_new_conversation_consent:true,live_verified:false,unknowns:['data_collection_deny_endpoint_eligibility','account_endpoint_eligibility','request_and_image_price_fields','actual_stream_model_provider_cost_receipt'],native_json_schema_enforcement:false,local_strict_tool_validation:true};
}
export function prepareGemmaRouteReview(baseConfig,{reviewID}={}){
 const manifest=gemmaRouteReviewManifest();
 check(reviewID===GEMMA_PRIVATE_REVIEW_ID&&(baseConfig.publicSourcePolicy??null)===null&&hash(baseConfig.route)===manifest.supersedes_route_hash&&baseConfig.routeHash===manifest.supersedes_route_hash,422,'private_route_review_input_invalid');
 return {manifest,config:{...baseConfig,route:clone(manifest.route),routeHash:manifest.route_hash}};
}
// Callers must explicitly supply an already prepared candidate and a transport.
// No key/env/file lookup, provider registration, live enablement or API activation.
export function createGemmaReviewProvider({reviewID,manifest,secret,fetchImpl,liveNetworkEnabled=false,beforeStream,maxTokens=2048,timeoutMs=20000}){
 const expected=gemmaRouteReviewManifest();
 check(reviewID===GEMMA_PRIVATE_REVIEW_ID&&hash(manifest)===hash(expected)&&typeof fetchImpl==='function'&&typeof beforeStream==='function',422,'private_route_review_input_invalid');
 return new OpenRouterProvider({model:expected.route.model,secret,endpoint:OPENROUTER_ENDPOINT,liveNetworkEnabled,fetchImpl,maxTokens,timeoutMs,privateRoutingPolicy:expected.route.routing_policy,expectedProviderDisplay:expected.route.downstream_provider,privateRouteReviewID:reviewID,beforeStream});
}
