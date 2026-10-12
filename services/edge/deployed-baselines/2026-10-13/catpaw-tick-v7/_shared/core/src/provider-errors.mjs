const boundedString=(v,max=240)=>typeof v==='string'?v.slice(0,max):null;
export function classify429(error,headers,now=Date.now()){
 const message=[error?.message,error?.provider_message].filter(Boolean).join(' ').toLowerCase(),meta=error?.metadata??{};
 const daily=/free.models.per.day|daily|per.day|day.{0,20}quota/.test(message)||meta.reason==='free_model_daily_limit';
 const upstream=Boolean(meta.provider_name||meta.provider_code)||/upstream|provider|capacity|overloaded/.test(message);
 const category=daily?'account_daily_quota':upstream?'provider_capacity_or_rate':(/per.minute|minute|requests per|rate.limit/.test(message)||headers.rate_limit_remaining!==null)?'platform_short_rate':'unknown_429';
 return {category,retry_after_seconds:headers.retry_after_seconds,retry_at:headers.retry_after_seconds!==null?new Date(now+headers.retry_after_seconds*1000).toISOString():null,retry_allowed:!daily&&headers.retry_after_seconds!==null,account_daily_reset_utc:daily?new Date(Date.UTC(new Date(now).getUTCFullYear(),new Date(now).getUTCMonth(),new Date(now).getUTCDate()+1)).toISOString():null};
}
export async function safeProviderFailure(response,{redact=v=>v,now=Date.now()}={}){
 const numberHeader=name=>{const s=response.headers.get(name);return s!==null&&/^\d+(?:\.\d+)?$/.test(s)?Number(s):null;};
 const retry=response.headers.get('retry-after');let seconds=null;
 if(retry!==null){if(/^\d+(?:\.\d+)?$/.test(retry))seconds=Number(retry);else{const date=Date.parse(retry);if(Number.isFinite(date))seconds=Math.max(0,Math.ceil((date-now)/1000));}}
 const headers={retry_after_seconds:seconds,rate_limit_limit:numberHeader('x-ratelimit-limit'),rate_limit_remaining:numberHeader('x-ratelimit-remaining'),rate_limit_reset:numberHeader('x-ratelimit-reset')};
 let raw='',overLimit=false;
 if(response.body){const reader=response.body.getReader(),decoder=new TextDecoder();try{while(true){const {done,value}=await reader.read();if(done)break;raw+=decoder.decode(value,{stream:true});if(raw.length>32768){overLimit=true;await reader.cancel();break;}}raw+=decoder.decode();}finally{reader.releaseLock();}}
 let parsed;try{parsed=overLimit?{}:JSON.parse(raw);}catch{parsed={};}const e=parsed.error??{},m=e.metadata??{};
 const clean=v=>{const s=boundedString(v,512);return s===null?null:redact(s).replace(/Bearer\s+[^\s"']+/gi,'Bearer [REDACTED]').replace(/sk-[a-zA-Z0-9_-]+/g,'[REDACTED]');};
 const metadata={};for(const k of ['limit_source','reason','error_type','provider_name','provider_code'])if(typeof m[k]==='number'||typeof m[k]==='string')metadata[k]=clean(String(m[k]));
 let providerMessage=null;if(typeof m.raw==='string'){try{const r=JSON.parse(m.raw);providerMessage=clean(r.error?.message??r.message);}catch{providerMessage=null;}}
 const error={code:typeof e.code==='number'||typeof e.code==='string'?clean(String(e.code)):null,message:clean(e.message),metadata,provider_message:providerMessage};
 return {headers,error,...response.status===429?classify429(error,headers,now):{category:response.status===404?'no_eligible_endpoint':response.status===401?'authentication':response.status===402?'account_credit':'other_provider_error'}};
}
