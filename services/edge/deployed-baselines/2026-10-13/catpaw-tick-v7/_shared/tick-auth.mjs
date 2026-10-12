import {check,hash,UUID,iso} from './core/facade-r2/src/common.mjs';
const encode=new TextEncoder();const audience='catpaw.tick.v1';
const hex=bytes=>Array.from(new Uint8Array(bytes),x=>x.toString(16).padStart(2,'0')).join('');
export async function signTick(secret,{timestamp,nonce,body}){const key=await crypto.subtle.importKey('raw',encode.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);return hex(await crypto.subtle.sign('HMAC',key,encode.encode(`${audience}\nPOST\n${timestamp}\n${nonce}\n${hash(body)}`)));}
export async function authorizeTick(request,{secret,repository,clock=Date.now}){
 check(typeof secret==='string'&&secret.length>=32,503,'tick_signing_not_configured');check(request.method==='POST',405,'method_not_allowed');const text=await request.text();check(text.length<2048,413,'request_too_large');let body;try{body=JSON.parse(text);}catch{check(false,422,'invalid_tick');}
 check(body&&Object.keys(body).length===0,422,'invalid_tick');const token=request.headers.get('authorization')??'',m=/^CatpawTick v1:(\d{10}):([a-f0-9-]{36}):([a-f0-9]{64})$/.exec(token);check(m&&UUID.test(m[2])&&Math.abs(clock()/1000-Number(m[1]))<=60,403,'tick_unauthorized');
 const expected=await signTick(secret,{timestamp:m[1],nonce:m[2],body});let mismatch=0;for(let i=0;i<64;i++)mismatch|=expected.charCodeAt(i)^m[3].charCodeAt(i);check(mismatch===0,403,'tick_unauthorized');
 await repository.transaction(async tx=>{check(await tx.insertIfAbsent('system:edge-tick','tick-nonces',{id:m[2],expires_at:new Date(clock()+120000).toISOString()}),403,'tick_replayed');});return {authorized:true};
}
