import {createHash} from 'node:crypto';
import {ApiError,check,hash,clone} from './core/facade-r2/src/common.mjs';
import {SOURCE_LIMITS,validatePublicSourcePolicy,policyTargetForURL,canonicalPublicURL} from './core/src/public-source-contract.mjs';

const encoder=new TextEncoder(),decoder=new TextDecoder('utf-8',{fatal:true});
export const sourceBodyHash=bytes=>createHash('sha256').update(bytes).digest('hex');
const hiddenTags=new Set(['script','style','noscript','template']);
function tagEnd(text,start){
 let quote=null;
 for(let i=start+1;i<text.length;i++){const c=text[i];if(quote){if(c===quote)quote=null;}else if(c==='"'||c==="'")quote=c;else if(c==='>')return i;}
 return -1;
}
function hiddenEnd(text,name,start){
 const prefix='</'+name;let cursor=start;
 for(;;){const at=text.indexOf('<',cursor);if(at<0)return -1;
  // Lowercase only the small ASCII tag candidate, never the whole Unicode body:
  // lowercasing some letters changes their length and would invalidate offsets.
  if(text.slice(at,at+prefix.length).toLowerCase()===prefix&&/[\s>/]/.test(text[at+prefix.length]??''))return tagEnd(text,at);
  cursor=at+1;
 }
}
export function publicHTMLVisibleText(text){
 const visible=[];let cursor=0;
 for(;;){const at=text.indexOf('<',cursor);if(at<0){visible.push(text.slice(cursor));break;}visible.push(text.slice(cursor,at),' ');
  if(text.startsWith('<!--',at)){const end=text.indexOf('-->',at+4);if(end<0)break;cursor=end+3;continue;}
  const end=tagEnd(text,at);if(end<0)break;
  const tag=/^<\s*(\/?)\s*([a-z][a-z0-9:-]*)/i.exec(text.slice(at,end+1));cursor=end+1;
  if(tag&&!tag[1]&&hiddenTags.has(tag[2].toLowerCase())){const close=hiddenEnd(text,tag[2].toLowerCase(),cursor);if(close<0)break;cursor=close+1;}
 }
 return visible.join(' ');
}
export function extractPublicSourceText(bytes,mediaType){
 check(bytes instanceof Uint8Array&&bytes.length>0&&bytes.length<=SOURCE_LIMITS.body,413,'source_body_limit');
 let text;try{text=decoder.decode(bytes);}catch{throw new ApiError(422,'source_utf8_invalid');}
 check(!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text),422,'source_text_invalid');
 if(mediaType==='text/html'){
  text=publicHTMLVisibleText(text);
  text=text.replace(/&(?:#(\d{1,7})|#x([a-f0-9]{1,6})|(amp|lt|gt|quot|apos|nbsp));/gi,(all,decimal,hex,name)=>{
   if(name)return {amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",nbsp:' '}[name.toLowerCase()];
   const code=parseInt(decimal??hex,decimal?10:16);return code>0&&code<=0x10ffff&&!(code>=0xd800&&code<=0xdfff)?String.fromCodePoint(code):'�';
  });
 }else check(mediaType==='text/plain',422,'source_media_type_not_supported');
 text=text.replace(/\s+/gu,' ').trim();check(text.length>0&&text.length<=SOURCE_LIMITS.text,413,'source_text_limit');
 check(!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text),422,'source_text_invalid');return text;
}
function bytesIndex(bytes,pattern,start=0){outer:for(let i=start;i<=bytes.length-pattern.length;i++){for(let j=0;j<pattern.length;j++)if(bytes[i+j]!==pattern[j])continue outer;return i;}return -1;}
const CRLF=new Uint8Array([13,10]),HEAD_END=new Uint8Array([13,10,13,10]);
function ascii(bytes){check(bytes.every(c=>c===13||c===10||(c>=32&&c<=126)),422,'source_http_invalid');return String.fromCharCode(...bytes);}
export function parsePublicHTTPResponse(raw){
 check(raw instanceof Uint8Array,422,'source_http_invalid');const at=bytesIndex(raw,HEAD_END);
 check(at>=0&&at<=SOURCE_LIMITS.headers,413,'source_header_limit');
 const lines=ascii(raw.subarray(0,at)).split('\r\n'),status=/^HTTP\/1\.[01] ([1-5][0-9]{2})(?: [\x20-\x7e]*)?$/.exec(lines.shift());check(status,422,'source_http_invalid');
 const headers={};
 for(const line of lines){const match=/^([!#$%&'*+.^_`|~0-9A-Za-z-]+): *([\x20-\x7e]*)$/.exec(line);check(match,422,'source_http_invalid');const name=match[1].toLowerCase();check(!(name in headers),422,'source_http_ambiguous');headers[name]=match[2].trim();}
 check(!headers['content-encoding']||headers['content-encoding'].toLowerCase()==='identity',422,'source_compression_not_supported');
 check(!(headers['transfer-encoding']&&headers['content-length']),422,'source_http_ambiguous');
 const code=Number(status[1]),redirect=[301,302,303,307,308].includes(code);check(redirect||code===200,422,'source_http_status');
 const contentType=/^(text\/(?:plain|html))(?:\s*;\s*charset\s*=\s*"?(utf-8|us-ascii)"?)?\s*$/i.exec(headers['content-type']??'');if(!redirect)check(contentType,422,'source_media_type_not_supported');
 const encoded=raw.subarray(at+4);let bytes;
 if(headers['transfer-encoding']){
  check(headers['transfer-encoding'].toLowerCase()==='chunked',422,'source_transfer_encoding_not_supported');
  const chunks=[];let cursor=0,size=0,count=0;
  for(;;){const end=bytesIndex(encoded,CRLF,cursor);check(end>=cursor&&end-cursor<=16,422,'source_chunk_invalid');const line=ascii(encoded.subarray(cursor,end));check(/^[a-f0-9]{1,8}$/i.test(line),422,'source_chunk_invalid');const length=parseInt(line,16);cursor=end+2;
   if(length===0){check(cursor+2===encoded.length&&encoded[cursor]===13&&encoded[cursor+1]===10,422,'source_chunk_trailers_not_supported');break;}
   size+=length;check(size<=SOURCE_LIMITS.body&&++count<=1024,413,'source_body_limit');check(cursor+length+2<=encoded.length&&encoded[cursor+length]===13&&encoded[cursor+length+1]===10,422,'source_chunk_invalid');chunks.push(encoded.subarray(cursor,cursor+length));cursor+=length+2;
  }
  bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 }else{
  if(headers['content-length']){check(/^(?:0|[1-9][0-9]{0,8})$/.test(headers['content-length']),422,'source_http_invalid');check(Number(headers['content-length'])===encoded.length,422,'source_http_length_mismatch');}
  bytes=new Uint8Array(encoded);
 }
 check((redirect||bytes.length>0)&&bytes.length<=SOURCE_LIMITS.body,413,'source_body_limit');
 if(redirect){check(headers.location,422,'source_redirect_invalid');return {status:code,location:headers.location,headers,bytes};}
 return {status:code,headers,media_type:contentType[1].toLowerCase(),bytes};
}
function closed(conn){try{conn?.close();}catch{/* closing is idempotent across abort and cleanup */}}
async function writeAll(conn,bytes,live){let written=0;while(written<bytes.length){live();const n=await conn.write(bytes.subarray(written));live();check(Number.isSafeInteger(n)&&n>0,422,'source_transport_failed');written+=n;}}
async function readToEOF(conn,live){
 const chunks=[];let length=0,headersComplete=false;const max=SOURCE_LIMITS.body+SOURCE_LIMITS.headers+32768;
 for(;;){live();const buffer=new Uint8Array(8192),n=await conn.read(buffer);live();if(n===null)break;check(Number.isSafeInteger(n)&&n>0&&n<=buffer.length,422,'source_transport_failed');length+=n;check(length<=max,413,'source_body_limit');chunks.push(buffer.subarray(0,n));
  if(!headersComplete){const probe=new Uint8Array(length);let offset=0;for(const chunk of chunks){probe.set(chunk,offset);offset+=chunk.length;}const at=bytesIndex(probe,HEAD_END);headersComplete=at>=0;check(headersComplete||length<=SOURCE_LIMITS.headers,413,'source_header_limit');}
 }
 const bytes=new Uint8Array(length);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return bytes;
}
// No fetch, resolver, proxy, redirect engine, Cookie jar or environment lookup.
// The TCP destination is a reviewed literal public IPv4; startTls only upgrades
// that existing connection and validates the requested origin's hostname.
export class PublicWebReader {
 constructor({policy=null,net=globalThis.Deno,clock=Date.now,timeoutMs=5000}={}){
  this.policy=policy?validatePublicSourcePolicy(policy):null;this.policyHash=this.policy?hash(this.policy):null;this.net=net;this.clock=clock;
  check(Number.isSafeInteger(timeoutMs)&&timeoutMs>=100&&timeoutMs<=5000,422,'source_timeout_invalid');this.timeoutMs=timeoutMs;
  this.reality=net===globalThis.Deno?'pinned_tls_capability_unverified':'injected_offline_only';
 }
 assertReady(){check(this.policy,503,'public_source_policy_not_configured');check(typeof this.net?.connect==='function'&&typeof this.net?.startTls==='function',503,'public_source_transport_not_supported');}
 async read(value,{signal,assertLive=()=>{},beforeSend=async()=>{},expectedPolicyHash=this.policyHash}={}){
  this.assertReady();check(expectedPolicyHash===this.policyHash,409,'source_policy_changed');const requested=canonicalPublicURL(value),controller=new AbortController();let tcp=null,tls=null,timer,rejectAbort;
  const aborted=new Promise((_,reject)=>{rejectAbort=reject;});aborted.catch(()=>{});
  const fail=reason=>{if(controller.signal.aborted)return;controller.abort(reason);closed(tls);closed(tcp);rejectAbort(reason);};
  const abort=()=>fail(signal?.reason??new ApiError(409,'source_read_cancelled'));
  signal?.addEventListener('abort',abort,{once:true});if(signal?.aborted)abort();
  timer=setTimeout(()=>fail(new ApiError(504,'source_read_timeout',{reconciliation:true})),this.timeoutMs);
  const live=()=>{assertLive();if(controller.signal.aborted)throw controller.signal.reason;check(hash(this.policy)===expectedPolicyHash,409,'source_policy_changed');};
  const wait=operation=>Promise.race([operation,aborted]);
  const connection=operation=>Promise.resolve(operation).then(conn=>{if(controller.signal.aborted){closed(conn);throw controller.signal.reason;}return conn;});
  const chain=[];let current=requested;
  try{
   for(let hop=0;hop<=SOURCE_LIMITS.redirects;hop++){
    live();const target=policyTargetForURL(this.policy,current);await wait(beforeSend(clone(target)));live();
    tcp=await wait(connection(this.net.connect({hostname:target.connect_ipv4,port:443,transport:'tcp'})));live();check(tcp.remoteAddr?.hostname===target.connect_ipv4&&tcp.remoteAddr?.port===443,409,'source_peer_binding_invalid');
    tls=await wait(connection(this.net.startTls(tcp,{hostname:target.hostname,alpnProtocols:['http/1.1']})));tcp=null;live();
    check(tls.remoteAddr?.hostname===target.connect_ipv4&&tls.remoteAddr?.port===443,409,'source_peer_binding_invalid');
    check(typeof tls.handshake==='function',503,'public_source_transport_not_supported');const handshake=await wait(tls.handshake());live();check(handshake.alpnProtocol===null||handshake.alpnProtocol==='http/1.1',422,'source_http_protocol_not_supported');
    // Recheck scoped execution after connection/TLS waits, immediately before GET.
    await wait(beforeSend(clone(target)));live();
    await wait(writeAll(tls,encoder.encode(`GET ${target.path} HTTP/1.1\r\nHost: ${target.hostname}\r\nAccept: text/plain, text/html\r\nAccept-Encoding: identity\r\nUser-Agent: Catpaw-Public-Source/1\r\nConnection: close\r\n\r\n`),live));
    const response=parsePublicHTTPResponse(await wait(readToEOF(tls,live)));closed(tls);tls=null;chain.push(target.url);live();
    if(response.location){check(hop<SOURCE_LIMITS.redirects,422,'source_redirect_limit');let next;try{next=new URL(response.location,target.url).href;}catch{throw new ApiError(422,'source_redirect_invalid');}current=policyTargetForURL(this.policy,next).url;check(!chain.includes(current),422,'source_redirect_loop');continue;}
    const text=extractPublicSourceText(response.bytes,response.media_type),date=new Date(this.clock()).toISOString();live();
    return {requested_url:requested,canonical_url:requested,final_url:target.url,redirect_chain:chain,read_at:date,media_type:response.media_type,body_bytes:response.bytes,byte_count:response.bytes.length,content_hash:sourceBodyHash(response.bytes),text,text_hash:hash(text),excerpt:text.slice(0,SOURCE_LIMITS.excerpt),transport_reality:this.reality};
   }
   throw new ApiError(422,'source_redirect_limit');
  }catch(error){if(error instanceof ApiError)throw error;throw new ApiError(502,'source_transport_failed',{reconciliation:true});}
  finally{clearTimeout(timer);signal?.removeEventListener('abort',abort);closed(tls);closed(tcp);}
 }
}
