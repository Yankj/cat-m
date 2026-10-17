import {Buffer} from 'node:buffer';
import {createHash} from 'node:crypto';
import {ApiError,check,shape,UUID,iso} from './core/facade-r2/src/common.mjs';
import {VISION_LIMITS,validateImageBytes} from './core/src/vision-contract.mjs';

// R3 chat attachments: private Storage bucket + signed upload URLs.
// Records live in the existing per-owner record store (kind 'chat-attachments');
// image bytes live only in the private bucket until one turn consumes them,
// then the object is deleted (v22 rule: no persistent image history).
export const ATTACHMENT_CONTRACT='catpaw.chat-attachments.v1';
export const ATTACHMENT_BUCKET='chat-attachments';
export const ATTACHMENT_LIMITS=Object.freeze({max_count:VISION_LIMITS.max_count,max_bytes:VISION_LIMITS.max_image_bytes,mime_types:VISION_LIMITS.mime_types,upload_url_ttl_seconds:7200,pending_ttl_seconds:7200,ready_ttl_seconds:86400});
const KIND='chat-attachments';
const sha=b=>createHash('sha256').update(b).digest('hex');
const objectPath=(subject,id)=>`${subject}/${id}`;

/** Storage REST adapter (service role; never exposed to clients or logs). */
export function createStorageAdapter({url,serviceKey,bucket=ATTACHMENT_BUCKET,fetchImpl=globalThis.fetch}){
  check(typeof url==='string'&&url.startsWith('https://')&&typeof serviceKey==='string'&&serviceKey.length>20,503,'attachments_not_configured');
  const base=url.replace(/\/$/,'')+'/storage/v1',headers=extra=>({Authorization:`Bearer ${serviceKey}`,apikey:serviceKey,...extra});
  const enc=p=>p.split('/').map(encodeURIComponent).join('/');
  return {
    bucket,
    async signUpload(path){
      const r=await fetchImpl(`${base}/object/upload/sign/${bucket}/${enc(path)}`,{method:'POST',headers:headers({'Content-Type':'application/json'}),body:'{}'});
      check(r.ok,503,'attachment_storage_unavailable');const v=await r.json();check(typeof v?.url==='string'&&v.url.startsWith('/object/upload/sign/'),503,'attachment_storage_unavailable');
      return `${base}${v.url}`;
    },
    async download(path,maxBytes){
      const r=await fetchImpl(`${base}/object/authenticated/${bucket}/${enc(path)}`,{method:'GET',headers:headers()});
      if(r.status===400||r.status===404){await r.body?.cancel?.();return null;}
      check(r.ok&&r.body,503,'attachment_storage_unavailable');
      const reader=r.body.getReader(),chunks=[];let size=0;
      try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>maxBytes){await reader.cancel();throw new ApiError(413,'image_too_large');}chunks.push(Buffer.from(value));}}finally{reader.releaseLock?.();}
      return Buffer.concat(chunks);
    },
    async remove(path){
      const r=await fetchImpl(`${base}/object/${bucket}`,{method:'DELETE',headers:headers({'Content-Type':'application/json'}),body:JSON.stringify({prefixes:[path]})});
      await r.body?.cancel?.();check(r.ok,503,'attachment_storage_unavailable');
    }
  };
}

export class AttachmentService{
  constructor({chat,storage,now=()=>Date.now()}){this.chat=chat;this.storage=storage;this.now=now;}
  get repository(){return this.chat.repository;}
  public(a){return {id:a.id,state:a.state,mime_type:a.mime_type,size_bytes:a.size_bytes,sha256:a.sha256,expires_at:a.expires_at,...a.width?{width:a.width,height:a.height}:{},...a.reason?{reason:a.reason}:{}};}
  async owned(tx,trusted,scopeID,id){const a=await tx.get(trusted.owner,KIND,id);check(a&&a.subject_id===trusted.principal.subject_id&&a.scope_id===scopeID,404,'attachment_not_found');return a;}
  async sweep(trusted){
    // Best-effort: expire this owner's stale uploads and delete their objects.
    const now=this.now(),mine=(await this.repository.transaction(tx=>tx.list(trusted.owner,KIND))).filter(a=>a.subject_id===trusted.principal.subject_id);
    // A signed upload URL stays valid for 2 h even after the object was deleted, so a late or
    // repeated PUT can recreate it: delete again once every issued URL has expired.
    for(const a of mine.filter(a=>['consumed','rejected','expired'].includes(a.state)&&!a.object_cleared&&Date.parse(a.upload_expires_at??a.created_at)<=now).slice(0,8)){try{await this.storage.remove(a.object_path);await this.repository.transaction(async tx=>{await tx.lock(trusted.owner,KIND,a.id);const cur=await tx.get(trusted.owner,KIND,a.id);if(cur&&!cur.object_cleared&&cur.state===a.state)await tx.put(trusted.owner,KIND,{...cur,object_cleared:true,updated_at:iso()});});}catch{}}
    const stale=mine.filter(a=>['pending','ready'].includes(a.state)&&Date.parse(a.expires_at)<=now);
    for(const a of stale.slice(0,8)){try{await this.storage.remove(a.object_path);await this.repository.transaction(async tx=>{await tx.lock(trusted.owner,KIND,a.id);const cur=await tx.get(trusted.owner,KIND,a.id);if(cur&&['pending','ready'].includes(cur.state))await tx.put(trusted.owner,KIND,{...cur,state:'expired',updated_at:iso()});});}catch{}}
  }
  async create(auth,scopeID,input){
    shape(input,['attachment_id','mime_type','size_bytes','sha256']);
    check(UUID.test(input.attachment_id),422,'attachment_id_invalid');
    check(ATTACHMENT_LIMITS.mime_types.includes(input.mime_type),422,'image_mime_unsupported');
    check(Number.isSafeInteger(input.size_bytes)&&input.size_bytes>0,422,'schema_invalid');check(input.size_bytes<=ATTACHMENT_LIMITS.max_bytes,413,'image_too_large');
    check(typeof input.sha256==='string'&&/^[a-f0-9]{64}$/.test(input.sha256),422,'image_hash_invalid');
    const trusted=await this.chat.scoped(auth,scopeID),{owner,principal}=trusted;await this.sweep(trusted);
    const record=await this.repository.transaction(async tx=>{
      await tx.lock(owner,KIND,input.attachment_id);const old=await tx.get(owner,KIND,input.attachment_id);
      if(old){
        check(old.subject_id===principal.subject_id&&old.scope_id===scopeID,404,'attachment_not_found');
        check(old.mime_type===input.mime_type&&old.size_bytes===input.size_bytes&&old.sha256===input.sha256,409,'attachment_conflict');
        return old;
      }
      const a={id:input.attachment_id,contract:ATTACHMENT_CONTRACT,subject_id:principal.subject_id,scope_id:scopeID,mime_type:input.mime_type,size_bytes:input.size_bytes,sha256:input.sha256,state:'pending',object_path:objectPath(principal.subject_id,input.attachment_id),created_at:iso(),updated_at:iso(),expires_at:new Date(this.now()+ATTACHMENT_LIMITS.pending_ttl_seconds*1000).toISOString()};
      await tx.put(owner,KIND,a);return a;
    });
    if(record.state!=='pending')return {attachment:this.public(record),upload:null};
    const url=await this.storage.signUpload(record.object_path),uploadExpires=new Date(this.now()+ATTACHMENT_LIMITS.upload_url_ttl_seconds*1000).toISOString();
    await this.repository.transaction(async tx=>{await tx.lock(owner,KIND,record.id);const cur=await tx.get(owner,KIND,record.id);if(cur)await tx.put(owner,KIND,{...cur,upload_expires_at:uploadExpires});});
    return {attachment:this.public(record),upload:{method:'PUT',url,headers:{'Content-Type':record.mime_type,'x-upsert':'false'},expires_at:uploadExpires}};
  }
  async read(auth,scopeID,id){check(UUID.test(id),422,'attachment_id_invalid');const trusted=await this.chat.scoped(auth,scopeID);return {attachment:this.public(await this.repository.transaction(tx=>this.owned(tx,trusted,scopeID,id)))};}
  async complete(auth,scopeID,id){
    check(UUID.test(id),422,'attachment_id_invalid');const trusted=await this.chat.scoped(auth,scopeID),{owner}=trusted;
    const a=await this.repository.transaction(tx=>this.owned(tx,trusted,scopeID,id));
    if(a.state!=='pending')return {attachment:this.public(a)};
    check(Date.parse(a.expires_at)>this.now(),410,'attachment_expired');
    const bytes=await this.storage.download(a.object_path,ATTACHMENT_LIMITS.max_bytes);
    check(bytes,409,'attachment_upload_missing');
    let update;
    try{check(bytes.length===a.size_bytes,422,'image_size_mismatch');check(sha(bytes)===a.sha256,422,'image_hash_mismatch');const size=validateImageBytes(bytes,a.mime_type);update={state:'ready',...size,expires_at:new Date(this.now()+ATTACHMENT_LIMITS.ready_ttl_seconds*1000).toISOString()};}
    catch(e){if(!(e instanceof ApiError))throw e;update={state:'rejected',reason:e.code};await this.storage.remove(a.object_path).catch(()=>{});}
    finally{bytes.fill(0);}
    const saved=await this.repository.transaction(async tx=>{await tx.lock(owner,KIND,id);const cur=await this.owned(tx,trusted,scopeID,id);if(cur.state!=='pending')return cur;const next={...cur,...update,updated_at:iso()};await tx.put(owner,KIND,next);return next;});
    return {attachment:this.public(saved)};
  }
  /** Turn input with attachment_ids → the v22 inline form (validated again by the vision contract). */
  async resolveTurnInput(auth,scopeID,input){
    const ids=input?.message?.attachment_ids;if(ids===undefined)return {input,consume:async()=>{}};
    check(input.schema_version===2&&Array.isArray(ids)&&ids.length>0&&ids.length<=ATTACHMENT_LIMITS.max_count&&ids.every(id=>UUID.test(id))&&new Set(ids).size===ids.length&&!input.message.attachments,422,'schema_invalid');
    const trusted=await this.chat.scoped(auth,scopeID);const loaded=[];
    for(const id of ids){
      const a=await this.repository.transaction(tx=>this.owned(tx,trusted,scopeID,id));
      if(a.state==='consumed'&&a.turn_id===input.turn_id&&UUID.test(input.turn_id??''))return {replay:true,input,consume:async()=>{}};
      check(a.state==='ready',409,a.state==='consumed'?'attachment_consumed':'attachment_not_ready');check(Date.parse(a.expires_at)>this.now(),410,'attachment_expired');
      const bytes=await this.storage.download(a.object_path,ATTACHMENT_LIMITS.max_bytes);check(bytes&&bytes.length===a.size_bytes&&sha(bytes)===a.sha256,409,'attachment_upload_missing');
      loaded.push({a,base64:bytes.toString('base64')});bytes.fill(0);
    }
    const {attachment_ids:_,...message}=input.message;
    const resolved={...input,message:{...message,attachments:loaded.map(({a,base64})=>({id:a.id,mime_type:a.mime_type,sha256:a.sha256,base64}))}};
    // After the turn is accepted the bytes exist only in the running turn's memory.
    const consume=async()=>{for(const {a} of loaded){try{await this.storage.remove(a.object_path);}catch{}await this.repository.transaction(async tx=>{await tx.lock(trusted.owner,KIND,a.id);const cur=await tx.get(trusted.owner,KIND,a.id);if(cur?.state==='ready')await tx.put(trusted.owner,KIND,{...cur,state:'consumed',turn_id:input.turn_id,updated_at:iso()});});}};
    return {input:resolved,consume};
  }
}
