// Advisory retry delay of an error, in whole seconds (1..3600) or null. ApiError.retryAfterSec (HTTP busy codes) or
// provider-style retryAfterSeconds (rate_limited from a model route). Used for the Retry-After header and the
// error body field retry_after_seconds (same name as the SSE turn_failed field the iOS client already decodes).
export function retryAfterOf(e){
  const v=Number.isFinite(e?.retryAfterSec)?e.retryAfterSec:Number.isFinite(e?.retryAfterSeconds)?e.retryAfterSeconds:null;
  return v===null||v<0?null:Math.max(1,Math.min(3600,Math.ceil(v)));
}
/** Header + body fragment for an HTTP error response. */
export const retryAfterParts=e=>{const s=retryAfterOf(e);return s===null?{headers:{},body:{}}:{headers:{'Retry-After':String(s)},body:{retry_after_seconds:s}};};
