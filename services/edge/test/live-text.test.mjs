// Live SSE text previews (opt-in X-Catpaw-Live-Text: 1): first delta immediate, ~100 ms cadence after, DB text commits
// unchanged (TextBatcher 512 chars / 250 ms), replay/reconnect exact via the offset contract (live-text.mjs, IOS-NOTE.md).
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {LiveText,liveTextIntervalMs,LIVE_TEXT_PREVIEW_MAX_CHARS} from '../supabase/functions/_shared/core/src/live-text.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));

test('interval: CATPAW_SSE_TEXT_INTERVAL_MS clamped to 80..120, default 100; config threads it; route_hash unchanged',()=>{
 assert.deepEqual([undefined,'','abc','100','50','80','95.4','120','500'].map(liveTextIntervalMs),[100,100,100,100,80,80,95,120,120]);
 const base={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};
 const a=readConfig(k=>base[k]),b=readConfig(k=>({...base,CATPAW_SSE_TEXT_INTERVAL_MS:'90'})[k]);
 assert.equal(a.sseTextIntervalMs,100);assert.equal(b.sseTextIntervalMs,90);
 assert.equal(a.routeHash,'ff91db5a87dd3885936c92fe8ef7b917d4e643fe0198e3a7509405d7e389629f');assert.equal(b.routeHash,a.routeHash);
});

test('LiveText unit: first delta of each step emits synchronously; follow-ons coalesce to one emit per interval',async()=>{
 const lt=new LiveText({messageID:'m',envelope:{},intervalMs:100}),emits=[];lt.listeners.add(()=>emits.push(Date.now()));
 lt.push('a');assert.equal(emits.length,1,'first delta immediate');
 const t0=Date.now();while(Date.now()-t0<550){lt.push('x');await sleep(10);}
 await sleep(130);lt.close();
 const gaps=emits.slice(1,-1).map((t,i)=>t-emits[i]);
 assert.ok(emits.length>=5&&emits.length<=9,`~one emit per 100 ms (${emits.length})`);
 assert.ok(gaps.slice(1).every(g=>g>=85),`no emit closer than the interval: ${gaps}`);
 lt.startStep();const before=emits.length;lt.closed=false;lt.push('b');assert.equal(emits.length,before+1,'first delta of a new step immediate');lt.close();
 const quiet=new LiveText({messageID:'m',envelope:{}});quiet.push('a');quiet.push('b');assert.equal(quiet.timer,null,'no observer → no timers');
});

test('LiveText unit: offset never exceeds the persisted text the observer has; cap keeps surrogate pairs whole',()=>{
 const lt=new LiveText({messageID:'m',envelope:{turn_id:'t'},persisted:'旧',startSequence:3});
 assert.equal(lt.baseAt(2),null,'before the first checkpoint the base is unknown → no preview');assert.equal(lt.preview(2),null);
 lt.push('新的');assert.deepEqual(lt.preview(3),{offset:1,text:'新的',end:3});
 lt.persisted(5,2);assert.equal(lt.baseAt(4),1);assert.equal(lt.baseAt(5),3);assert.equal(lt.preview(5),null,'all persisted → nothing to send');
 lt.push('😀'.repeat(LIVE_TEXT_PREVIEW_MAX_CHARS));const p=lt.preview(5);assert.ok(p.text.length<=LIVE_TEXT_PREVIEW_MAX_CHARS&&p.text.length%2===0);
 assert.equal(lt.preview(5,p.end),null,'cap reached and sent: wait for the next DB batch');
 lt.persisted(6,p.text.length);const q=lt.preview(6,p.end);assert.equal(q.offset,3+p.text.length,'cumulative tail from the new persisted base');
});

// ---------- HTTP integration ----------
const FINAL_CHUNKS=Array.from({length:60},(_,i)=>`第${i}段🙂ab `);const FINAL=FINAL_CHUNKS.join('');
async function setup({gapMs=15}={}){
 const probe={firstYieldAt:null};
 const f=await fixture({stream:async function*(){for(const [i,c] of FINAL_CHUNKS.entries()){if(i===0)probe.firstYieldAt=Date.now();yield {type:'text_delta',text:c};await sleep(gapMs);}yield {type:'done',finish_reason:'stop'};}});
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 return {f,probe,cid,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
}
async function* frames(response){
 const reader=response.body.getReader(),dec=new TextDecoder();let buf='';
 try{for(;;){const {value,done}=await reader.read();if(done)return;buf+=dec.decode(value,{stream:true});let i;while((i=buf.indexOf('\n\n'))>=0){const raw=buf.slice(0,i);buf=buf.slice(i+2);if(raw.startsWith('data: '))yield {at:Date.now(),e:JSON.parse(raw.slice(6))};}}}
 finally{try{await reader.cancel();}catch{}}
}
// The client contract from IOS-NOTE.md, verbatim: persisted text from text_delta; preview = (offset, cumulative tail).
class Client{
 constructor(){this.persisted='';this.preview=null;this.lastSeq=0;this.shown=[];}
 apply(e){
  if(e.type==='text_preview'){assert.ok(e.data.offset<=this.persisted.length,'offset never beyond persisted');assert.equal(e.sequence,this.lastSeq,'preview carries the last persisted sequence');this.preview={offset:e.data.offset,text:e.data.text};}
  else{assert.equal(e.sequence,this.lastSeq+1,'persisted events contiguous: no dup, no gap');this.lastSeq=e.sequence;
   if(e.type==='text_delta')this.persisted+=e.data.text;
   if(e.type==='turn_completed'||e.type==='turn_failed')this.preview=null;}
  this.shown.push(this.display());
 }
 display(){if(!this.preview)return this.persisted;const skip=this.persisted.length-this.preview.offset;return this.persisted+(skip<this.preview.text.length?this.preview.text.slice(skip):'');}
}
async function startTurn(s,headers){
 const c=s.f.runtime.chat.readConversation('Bearer memory-fixture',s.f.scope.scope_id,s.cid),cv=await c,tid=randomUUID();
 const r=await s.f.req(s.path+'/turns',{turn_id:tid,expected_revision:cv.revision,expected_grant_epoch:cv.grant_epoch,message:{id:randomUUID(),text:'讲个长故事'},context:[]},'Bearer memory-fixture',headers);
 assert.equal(r.status,200);return {r,tid};
}
const storedTurn=(s,tid)=>s.f.runtime.chat.readTurn('Bearer memory-fixture',s.f.scope.scope_id,s.cid,tid);

test('opted-in stream: first text arrives immediately as a preview, then ~100 ms frames; display always a prefix; exact final text',async()=>{
 const s=await setup(),{r,tid}=await startTurn(s,{'X-Catpaw-Live-Text':'1'}),client=new Client(),previewAt=[];let firstTextAt=null;
 for await(const {at,e} of frames(r)){client.apply(e);if(e.type==='text_preview'){previewAt.push(at);}if((e.type==='text_preview'||e.type==='text_delta')&&firstTextAt===null)firstTextAt={at,type:e.type};}
 await s.f.runtime.chat.waitIdle();
 assert.equal(firstTextAt.type,'text_preview','the first text the client sees is the live preview, not the 250 ms DB batch');
 assert.ok(firstTextAt.at-s.probe.firstYieldAt<60,`first delta immediate (${firstTextAt.at-s.probe.firstYieldAt} ms)`);
 const gaps=previewAt.slice(1).map((t,i)=>t-previewAt[i]);
 assert.ok(previewAt.length>=6,`previews flow during the ~900 ms stream (${previewAt.length})`);
 const median=[...gaps].sort((x,y)=>x-y)[gaps.length>>1];assert.ok(median>=80&&median<=200,`cadence ~100 ms (median ${median}): ${gaps}`);
 for(const d of client.shown)assert.ok(FINAL.startsWith(d),'never a duplicate or out-of-order text');
 assert.equal(client.display(),FINAL);
 const t=await storedTurn(s,tid);assert.equal(t.events.filter(e=>e.type==='text_delta').map(e=>e.data.text).join(''),FINAL);
 assert.ok(!t.events.some(e=>e.type==='text_preview'),'previews are never persisted');
});

test('DB text commits unchanged: previews add no text_delta events or commits for a long stream',async()=>{
 const count=async headers=>{const s=await setup({gapMs:12}),{r,tid}=await startTurn(s,headers);let previews=0,deltaFrames=0;
  for await(const {e} of frames(r)){if(e.type==='text_preview')previews++;if(e.type==='text_delta')deltaFrames++;}
  await s.f.runtime.chat.waitIdle();const t=await storedTurn(s,tid);return {previews,deltaFrames,persisted:t.events.filter(e=>e.type==='text_delta').length,events:t.events.length};};
 const legacy=await count({}),live=await count({'X-Catpaw-Live-Text':'1'});
 assert.equal(legacy.previews,0,'old clients (no header) get exactly the old frames');
 assert.equal(live.deltaFrames,live.persisted);assert.equal(legacy.deltaFrames,legacy.persisted);
 // ~750 ms at 250 ms / 512 chars → a handful of commits either way; previews never add commits.
 assert.ok(Math.abs(live.persisted-legacy.persisted)<=1,`same DB cadence (${legacy.persisted} vs ${live.persisted})`);
 assert.ok(live.persisted<=6,`batched commits (${live.persisted})`);assert.ok(live.previews>live.persisted,`more SSE frames than commits (${live.previews} > ${live.persisted})`);
});

test('reconnect mid-stream (after_sequence = last persisted sequence): exact text, no duplicate, no loss',async()=>{
 const s=await setup({gapMs:20}),{r,tid}=await startTurn(s,{'X-Catpaw-Live-Text':'1'}),client=new Client();let previews=0;
 for await(const {e} of frames(r)){client.apply(e);if(e.type==='text_preview')previews++;if(previews>=3&&client.persisted.length>0)break;} // drop the connection mid-stream
 const cut=client.display();assert.ok(cut.length>0&&cut.length<FINAL.length,'cut in the middle');
 await sleep(150); // text keeps flowing while disconnected
 const again=await s.f.req(`${s.path}/turns/${tid}/events?after_sequence=${client.lastSeq}`,undefined,'Bearer memory-fixture',{'X-Catpaw-Live-Text':'1'});
 assert.equal(again.status,200);
 for await(const {e} of frames(again))client.apply(e);
 await s.f.runtime.chat.waitIdle();
 for(const d of client.shown)assert.ok(FINAL.startsWith(d),'every rendered state is a prefix of the final text');
 assert.equal(client.display(),FINAL);assert.equal(client.persisted,FINAL,'persisted text exactly once across both connections');
 // a legacy reconnect (no header) replays only persisted events and also yields the exact text
 const legacy=new Client();for await(const {e} of frames(await s.f.req(`${s.path}/turns/${tid}/events?after_sequence=0`,undefined,'Bearer memory-fixture')))legacy.apply(e);
 assert.equal(legacy.display(),FINAL);
});

test('failed turn: preview tail is dropped at turn_failed (display = persisted only)',async()=>{
 const f=await fixture({stream:async function*(){yield {type:'text_delta',text:'半句'};await sleep(30);throw Object.assign(new Error('x'),{code:'provider_failed'});}});
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const s={f,cid,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`},{r}=await startTurn(s,{'X-Catpaw-Live-Text':'1'}),client=new Client();let sawPreview=false;
 for await(const {e} of frames(r)){client.apply(e);if(e.type==='text_preview')sawPreview=true;}
 await f.runtime.chat.waitIdle();assert.ok(sawPreview);assert.equal(client.display(),client.persisted);
});
