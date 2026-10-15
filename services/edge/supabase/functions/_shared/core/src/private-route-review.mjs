import {canonical,check} from '../facade-r2/src/common.mjs';
// Inactive review identity, never an environment/default/provider-router selector.
export const GEMMA_PRIVATE_REVIEW_ID='catpaw-gemma-private-review-20261015-v1';
export const GEMMA_PRIVATE_REVIEW_MODEL='google/gemma-4-31b-it:free';
export const GEMMA_PRIVATE_REVIEW_PROVIDER='Google AI Studio';
export function gemmaPrivateReviewPolicy(){return {only:['google-ai-studio'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}};}
export function matchesGemmaPrivateReview({reviewID,model,expectedProviderDisplay,routingPolicy}){
 return reviewID===GEMMA_PRIVATE_REVIEW_ID&&model===GEMMA_PRIVATE_REVIEW_MODEL&&expectedProviderDisplay===GEMMA_PRIVATE_REVIEW_PROVIDER&&canonical(routingPolicy)===canonical(gemmaPrivateReviewPolicy());
}

// Only the exact named review calls this guard. Default/received provider paths
// retain their original protocol; later chunks cannot erase earlier identity.
export function checkGemmaReviewFrame(chunk,state){
 state.validation.frames++;
 if(Object.hasOwn(chunk,'model'))check(chunk.model===GEMMA_PRIVATE_REVIEW_MODEL,503,'private_provider_receipt_mismatch',{reconciliation:true});
 if(Object.hasOwn(chunk,'provider'))check(typeof chunk.provider==='string'&&chunk.provider.toLowerCase()===GEMMA_PRIVATE_REVIEW_PROVIDER.toLowerCase(),503,'private_provider_receipt_mismatch',{reconciliation:true});
 if(chunk.usage&&Object.hasOwn(chunk.usage,'cost'))check(chunk.usage.cost===0,503,'private_provider_receipt_mismatch',{reconciliation:true});
 for(const key of ['id','model','provider','object','created','system_fingerprint']){
  const value=chunk[key];if(value===undefined||value===null||value==='')continue;
  check(key==='created'?typeof value==='number'&&Number.isFinite(value)&&value>=0:typeof value==='string'&&value.length<=512,503,'private_review_metadata_invalid',{reconciliation:true});
  const normalized=key==='provider'?value.toLowerCase():value;
  check(!Object.hasOwn(state.seen,key)||state.seen[key]===normalized,503,'private_review_metadata_changed',{reconciliation:true});state.seen[key]=normalized;
 }
}
