import {check,shape,hash,clone} from '../facade-r2/src/common.mjs';

export const SOURCE_CONTRACT='catpaw.public-sources.v1';
export const SOURCE_POLICY_CONTRACT='catpaw.public-web-policy.v1';
export const SOURCE_IDS=['source-1','source-2','source-3'];
export const SOURCE_LIMITS=Object.freeze({url:2048,body:256000,text:12000,excerpt:1000,headers:16384,redirects:2});
const credentialQueryKeys=new Set(['accesstoken','refreshtoken','idtoken','clientsecret','apikey','authorization','auth','password','passwd','token','secret','signature','sig','xamzsignature','xamzcredential','xamzsecuritytoken','xgoogsignature','xgoogcredential','xgoogsecuritytoken','awsaccesskeyid','oauthtoken','oauthsignature','sessiontoken','sastoken']);
export function canonicalPublicURL(value){
 check(typeof value==='string'&&value.length>0&&value.length<=SOURCE_LIMITS.url&&!/[\u0000-\u0020\u007f\\]/.test(value)&&!/%(?:00|0a|0d)/i.test(value)&&!/%(?![a-f0-9]{2})/i.test(value),422,'source_url_invalid');
 let url;try{url=new URL(value);}catch{check(false,422,'source_url_invalid');}
 check(url.protocol==='https:'&&!url.username&&!url.password&&(!url.port||url.port==='443'),422,'source_url_invalid');
 for(let key of url.searchParams.keys()){
  // URLSearchParams already decoded once. Detect common double-encoded keys too;
  // this is a conservative public-document gate, not a general secret classifier.
  for(let pass=0;pass<2&&/%[a-f0-9]{2}/i.test(key);pass++)try{key=decodeURIComponent(key);}catch{break;}
  check(!credentialQueryKeys.has(key.trim().toLowerCase().replace(/[-_]/g,'')),422,'source_url_credential_not_allowed');
 }
 const host=url.hostname;
 check(host.length<=253&&host.includes('.')&&host.split('.').every(label=>/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label))&&!/^\d+(?:\.\d+){3}$/.test(host)&&!/(?:^|\.)(?:localhost|local|internal|home|invalid|test)$/.test(host),422,'source_url_invalid');
 url.hash='';check(url.href.length<=SOURCE_LIMITS.url,422,'source_url_invalid');return url.href;
}
export function canonicalUserSourceURLs(userTexts){
 check(Array.isArray(userTexts)&&userTexts.length>0&&userTexts.length<=40&&userTexts.every(v=>typeof v==='string')&&userTexts.reduce((n,v)=>n+new TextEncoder().encode(v).length,0)<=80000,422,'source_user_text_invalid');
 const urls=[];
 for(const text of userTexts)for(const match of text.matchAll(/https:\/\/[^\s<>"'`]+/giu)){
  let value=match[0].replace(/[.,;!?，。；！？]+$/u,'');
  while(value.endsWith(')')&&(value.match(/\)/g)?.length??0)>(value.match(/\(/g)?.length??0))value=value.slice(0,-1);
  while(value.endsWith(']')&&(value.match(/\]/g)?.length??0)>(value.match(/\[/g)?.length??0))value=value.slice(0,-1);
  try{value=canonicalPublicURL(value);if(!urls.includes(value))urls.push(value);}catch{/* unsupported user URL grants no network authority */}
 }
 check(urls.length<=100,422,'source_user_text_invalid');return urls;
}
export function freezePublicSourceCatalog({runID,selectedURLs,userTexts,policyHash}){
 check(typeof runID==='string'&&/^[a-f0-9-]{36}$/i.test(runID)&&/^[a-f0-9]{64}$/.test(policyHash),422,'source_catalog_invalid');
 check(Array.isArray(selectedURLs)&&selectedURLs.length>0&&selectedURLs.length<=3,422,'source_catalog_invalid');
 const allowed=new Set(canonicalUserSourceURLs(userTexts)),selected=selectedURLs.map(canonicalPublicURL);
 check(new Set(selected).size===selected.length&&selected.every(url=>allowed.has(url)),403,'source_not_user_provided');
 return {schema_version:1,contract:SOURCE_CONTRACT,policy_hash:policyHash,sources:selected.map((requested_url,index)=>({source_id:SOURCE_IDS[index],requested_url}))};
}
export function validateFrozenSourceCatalog(catalog){
 shape(catalog,['schema_version','contract','policy_hash','sources']);check(catalog.schema_version===1&&catalog.contract===SOURCE_CONTRACT&&/^[a-f0-9]{64}$/.test(catalog.policy_hash)&&Array.isArray(catalog.sources)&&catalog.sources.length>0&&catalog.sources.length<=3,422,'source_catalog_invalid');
 catalog.sources.forEach((source,index)=>{shape(source,['source_id','requested_url']);check(source.source_id===SOURCE_IDS[index]&&canonicalPublicURL(source.requested_url)===source.requested_url,422,'source_catalog_invalid');});
 check(new Set(catalog.sources.map(s=>s.requested_url)).size===catalog.sources.length,422,'source_catalog_invalid');return clone(catalog);
}
export function isPublicIPv4(value){
 if(typeof value!=='string'||!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(value))return false;
 const n=value.split('.').map(Number);if(n.some(v=>v>255)||n.join('.')!==value)return false;
 const [a,b,c]=n;
 return !(a===0||a===10||a===127||a>=224||value==='168.63.129.16'||(a===100&&b>=64&&b<=127)||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&((b===0&&(c===0||c===2))||(b===88&&c===99)||b===168))||(a===198&&(b===18||b===19||(b===51&&c===100)))||(a===203&&b===0&&c===113));
}
export function validatePublicSourcePolicy(policy){
 check(policy,503,'public_source_policy_not_configured');shape(policy,['schema_version','contract','origins']);
 check(policy.schema_version===1&&policy.contract===SOURCE_POLICY_CONTRACT&&Array.isArray(policy.origins)&&policy.origins.length>0&&policy.origins.length<=8,422,'source_policy_invalid');
 for(const target of policy.origins){
  shape(target,['origin','connect_ipv4','path_prefixes']);
  const url=new URL(canonicalPublicURL(target.origin+'/'));
  check(url.origin===target.origin&&isPublicIPv4(target.connect_ipv4)&&Array.isArray(target.path_prefixes)&&target.path_prefixes.length>0&&target.path_prefixes.length<=8,422,'source_policy_invalid');
  for(const prefix of target.path_prefixes)check(typeof prefix==='string'&&prefix.startsWith('/')&&prefix.length<=500&&!/[\u0000-\u0020\u007f\\%?#]/.test(prefix)&&!prefix.split('/').includes('..')&&!prefix.split('/').includes('.')&&!prefix.includes('//'),422,'source_policy_invalid');
 }
 check(new Set(policy.origins.map(o=>o.origin)).size===policy.origins.length,422,'source_policy_invalid');return clone(policy);
}
export function policyTargetForURL(policy,value){
 const canonical=canonicalPublicURL(value),url=new URL(canonical),target=policy.origins.find(o=>o.origin===url.origin);
 check(target,403,'source_origin_not_allowed');
 check(isPublicIPv4(target.connect_ipv4),403,'source_pin_not_public');
 check(!/%(?:25|2f|5c|2e)/i.test(url.pathname),403,'source_path_not_allowed');
 let path;try{path=decodeURIComponent(url.pathname);}catch{check(false,403,'source_path_not_allowed');}
 check(target.path_prefixes.some(prefix=>prefix==='/'||path===prefix||path.startsWith(prefix.endsWith('/')?prefix:prefix+'/')),403,'source_path_not_allowed');
 return {url:canonical,hostname:url.hostname,connect_ipv4:target.connect_ipv4,path:url.pathname+url.search};
}
export function sourceReadIdentity(runID,planReference,sourceID){
 check(SOURCE_IDS.includes(sourceID)&&Number.isSafeInteger(planReference?.revision)&&planReference.revision>0&&/^[a-f0-9]{64}$/.test(planReference.plan_hash),422,'source_binding_invalid');
 const h=hash({contract:'catpaw.public-source-read.v1',run_id:runID,plan_reference:planReference,source_id:sourceID});
 return `${h.slice(0,8)}-${h.slice(8,12)}-4${h.slice(13,16)}-8${h.slice(17,20)}-${h.slice(20,32)}`;
}
export const sourcePolicyHash=policy=>hash(validatePublicSourcePolicy(policy));
