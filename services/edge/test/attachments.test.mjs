import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {deflateSync} from 'node:zlib';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {crc32} from '../supabase/functions/_shared/core/src/vision-contract.mjs';
import {createStorageAdapter} from '../supabase/functions/_shared/attachments.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const sha=b=>createHash('sha256').update(b).digest('hex');
function png(w=2,h=2){const chunk=(type,data)=>{const len=Buffer.alloc(4);len.writeUInt32BE(data.length);const td=Buffer.concat([Buffer.from(type),data]);const crc=Buffer.alloc(4);crc.writeUInt32BE(crc32(td));return Buffer.concat([len,td,crc]);};
 const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(w,0);ihdr.writeUInt32BE(h,4);ihdr[8]=8;ihdr[9]=2;const raw=Buffer.alloc((1+w*3)*h);
 return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',ihdr),chunk('IDAT',deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);}
// In-memory private bucket standing in for Supabase Storage (signed PUT → object).
function memoryStorage(){const objects=new Map(),signed=new Map(),removed=[];return {objects,removed,bucket:'chat-attachments',
 async signUpload(path){const token=randomUUID();signed.set(token,path);return `https://storage.example.invalid/storage/v1/object/upload/sign/chat-attachments/${path}?token=${token}`;},
 put(url,bytes){const token=new URL(url).searchParams.get('token');assert.ok(signed.has(token));objects.set(signed.get(token),Buffer.from(bytes));},
 async download(path){const b=objects.get(path);return b?Buffer.from(b):null;},async remove(path){removed.push(path);objects.delete(path);}};}
async function setup(stream){
 const storage=memoryStorage(),calls=[];const f=await fixture({vision:true,attachmentStorage:storage,stream:stream??async function*(input){calls.push(input);yield {type:'text_delta',text:'a small red square'};yield {type:'done',finish_reason:'stop'};}});
 const chat=`/catpaw/chat/v1/scopes/${f.scope.scope_id}`;return {f,storage,chat,calls};
}
async function consented(f,chat){
 const cid=await f.newConversation(),p=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
 await f.json(await f.req(p+'/model-consent',{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const route=await f.json(await f.req('/catpaw/privacy/v1/image-model-route'));
 await f.json(await f.req(p+'/image-model-consent',{decision:'allow',expected_revision:0,route_hash:route.route_hash,non_sensitive_confirmed:true}));
 return cid;
}
const turnBody=async(f,chat,cid,extra)=>{const c=(await f.json(await f.req(`${chat}/conversations/${cid}`))).conversation;return {schema_version:2,turn_id:randomUUID(),expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'What is in this picture?',...extra},context:[]};};

test('signed upload → complete → turn by attachment_ids; object deleted after the turn is accepted',async()=>{
 const {f,storage,chat,calls}=await setup();const bytes=png(),id=randomUUID();
 const ready=await f.json(await f.req('/readyz'));assert.deepEqual(ready.chat_capabilities.attachments.mime_types,['image/png','image/jpeg']);assert.equal(ready.chat_capabilities.attachments.available,true);assert.equal(ready.chat_capabilities.turn_cancel,true);
 const create={attachment_id:id,mime_type:'image/png',size_bytes:bytes.length,sha256:sha(bytes)};
 const r1=await f.req(chat+'/attachments',create);assert.equal(r1.status,201);const c1=await r1.json();
 assert.equal(c1.attachment.state,'pending');assert.equal(c1.upload.method,'PUT');assert.equal(c1.upload.headers['Content-Type'],'image/png');
 const r2=await (await f.req(chat+'/attachments',create)).json();assert.equal(r2.attachment.id,id,'idempotent create');
 assert.equal((await f.req(chat+'/attachments',{...create,size_bytes:bytes.length+1})).status,409);
 assert.equal((await f.req(chat+`/attachments/${id}/complete`,'{}')).status,409,'nothing uploaded yet');
 storage.put(c1.upload.url,bytes);
 const done=await f.json(await f.req(chat+`/attachments/${id}/complete`,''));assert.equal(done.attachment.state,'ready');assert.equal(done.attachment.width,2);
 assert.equal((await f.json(await f.req(chat+`/attachments/${id}/complete`,'{}'))).attachment.state,'ready','complete is idempotent');
 const cid=await consented(f,chat),body=await turnBody(f,chat,cid,{attachment_ids:[id]});
 const res=await f.req(`${chat}/conversations/${cid}/turns`,body);assert.equal(res.status,200);const sse=await res.text();assert.match(sse,/turn_completed/);await f.runtime.chat.waitIdle();
 const last=calls.at(-1);assert.equal(last.image_attachments.length,1);assert.equal(last.image_attachments[0].receipt.sha256,sha(bytes));
 assert.ok(last.image_attachments[0].bytes.every(b=>b===0),'bytes zeroed after the turn');
 assert.equal(storage.objects.size,0);assert.deepEqual(storage.removed,[`${f.principal.subject_id}/${id}`]);
 assert.equal((await f.json(await f.req(chat+`/attachments/${id}`))).attachment.state,'consumed');
 const replay=await f.json(await f.req(`${chat}/conversations/${cid}/turns`,body));assert.equal(replay.replayed,true);
 const again=await f.req(`${chat}/conversations/${cid}/turns`,await turnBody(f,chat,cid,{attachment_ids:[id]}));assert.equal(again.status,409);assert.equal((await again.json()).error.code,'attachment_consumed');
});
test('rejected upload: wrong bytes are rejected and deleted; whitelist and ownership enforced',async()=>{
 const {f,storage,chat}=await setup();const good=png(),id=randomUUID();
 const c=await (await f.req(chat+'/attachments',{attachment_id:id,mime_type:'image/png',size_bytes:good.length,sha256:sha(good)})).json();
 storage.put(c.upload.url,Buffer.alloc(good.length,7));
 const done=await f.json(await f.req(chat+`/attachments/${id}/complete`,'{}'));assert.equal(done.attachment.state,'rejected');assert.equal(done.attachment.reason,'image_hash_mismatch');assert.equal(storage.objects.size,0);
 assert.equal((await f.req(chat+'/attachments',{attachment_id:randomUUID(),mime_type:'image/gif',size_bytes:10,sha256:'a'.repeat(64)})).status,422);
 assert.equal((await f.req(chat+'/attachments',{attachment_id:randomUUID(),mime_type:'image/png',size_bytes:6*1024*1024,sha256:'a'.repeat(64)})).status,413);
 assert.equal((await f.req(chat+`/attachments/${id}`,undefined,'Bearer foreign-fixture')).status,404);
 const cid=await consented(f,chat);const r=await f.req(`${chat}/conversations/${cid}/turns`,await turnBody(f,chat,cid,{attachment_ids:[id]}));assert.equal(r.status,409);assert.equal((await r.json()).error.code,'attachment_not_ready');
});
test('legacy inline base64 image turns still work',async()=>{
 const {f,chat,calls}=await setup();const bytes=png(),cid=await consented(f,chat);
 const res=await f.req(`${chat}/conversations/${cid}/turns`,await turnBody(f,chat,cid,{attachments:[{id:randomUUID(),mime_type:'image/png',sha256:sha(bytes),base64:bytes.toString('base64')}]}));
 assert.equal(res.status,200);assert.match(await res.text(),/turn_completed/);await f.runtime.chat.waitIdle();assert.equal(calls.at(-1).image_attachments.length,1);
});
test('storage adapter: signed upload path, service auth header, bounded download, delete by prefix',async()=>{
 const seen=[];const fetchImpl=async(url,init)=>{seen.push({url,method:init.method,auth:init.headers.Authorization?.startsWith('Bearer ')});
  if(url.includes('/upload/sign/'))return Response.json({url:'/object/upload/sign/chat-attachments/u/a?token=t'});
  if(init.method==='GET')return new Response(new Uint8Array(10));return Response.json([]);};
 const s=createStorageAdapter({url:'https://p.supabase.co',serviceKey:'x'.repeat(40),fetchImpl});
 assert.equal(await s.signUpload('u/a'),'https://p.supabase.co/storage/v1/object/upload/sign/chat-attachments/u/a?token=t');
 assert.equal((await s.download('u/a',100)).length,10);await assert.rejects(s.download('u/a',5),e=>e.code==='image_too_large');
 await s.remove('u/a');assert.deepEqual(seen.map(x=>x.method),['POST','GET','GET','DELETE']);assert.ok(seen.every(x=>x.auth));
 assert.throws(()=>createStorageAdapter({url:'http://x',serviceKey:'k'}));
});
test('a late PUT on a still-valid signed URL after consumption is deleted again once the URLs expire',async()=>{
 const {f,storage,chat}=await setup();let now=Date.now();f.runtime.chat.attachments.now=()=>now;const bytes=png(),id=randomUUID();
 const create={attachment_id:id,mime_type:'image/png',size_bytes:bytes.length,sha256:sha(bytes)};
 const c=await (await f.req(chat+'/attachments',create)).json();storage.put(c.upload.url,Buffer.from([1,2,3]));
 assert.equal((await f.json(await f.req(chat+`/attachments/${id}/complete`,'{}'))).attachment.state,'rejected');
 storage.put(c.upload.url,Buffer.from([4]));assert.equal(storage.objects.size,1,'late PUT recreated the object');
 await f.req(chat+'/attachments',{...create,attachment_id:randomUUID()});assert.equal(storage.objects.has(`${f.principal.subject_id}/${id}`),true,'URL still valid: not yet');
 now+=7201*1000;await f.req(chat+'/attachments',{...create,attachment_id:randomUUID()});assert.equal(storage.objects.has(`${f.principal.subject_id}/${id}`),false);
});
