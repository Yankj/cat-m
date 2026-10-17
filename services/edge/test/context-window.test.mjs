// context-window v1.1.x (context-memory PLAN.md Rev 2): sliding window with server-only turn markers, full history kept,
// over-budget order, storage caps, GET projection, B5 erasure, Gemini thought-signature placeholder + 400 classification.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {beforeEach} from 'node:test';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {hash,ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {CONTEXT_LIMITS,WINDOW_NOTE,packWindow,mergeModelMessages,resolveMeta,metaFor,metaValid,boundariesOf,isLegacyBoundary,admitModelHistory,elideOldToolResults,assertStorageLimits,estimateTokens,projectConversation} from '../supabase/functions/_shared/core/src/context-window.mjs';
import {eraseChatSource} from '../supabase/functions/_shared/core/src/source-erasure.mjs';
import {FreeRouteChainProvider,readFreeRouteChain,_routeHealthForTests as health} from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
import {toSteps,geminiRejectReason,GEMINI_SKIP_SIGNATURE,GEMINI_SIGNATURE_FIELD,_signatureCacheForTests} from '../supabase/functions/_shared/core/src/gemini-interactions-route.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
beforeEach(()=>health.clear());

// ---------- consent: the window keeps the consented wording (40 messages / 80 kB), so route_hash is unchanged vs prod v52 ----------
test('route_hash unchanged vs main ef947921 / prod v52 (pinned for base, gemini-primary and prod-order fallback chains)',()=>{
 const base={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};
 const keys={CATPAW_GEMINI_API_KEY:'offline-gemini-key-placeholder',CATPAW_AGNES_API_KEY:'offline-agnes-key-placeholder'};
 const cases=[[base,'ff91db5a87dd3885936c92fe8ef7b917d4e643fe0198e3a7509405d7e389629f'],[{...base,...keys},'508f5072148ce8e5de53649d460e8b7cdd7e79b16214918be541f204b4234337'],[{...base,...keys,CATPAW_GEMINI_ROUTE:'fallback'},'0478b1a71616e5cb4168c4561f5204734e28c5eccdcc52011ec8627afff60c2c']];
 for(const [env,expected] of cases){const c=readConfig(k=>env[k]);assert.equal(c.routeHash,expected);assert.equal(c.route.history_limit,CONTEXT_LIMITS.window_max_visible_messages);assert.ok(c.route.data_fields.some(f=>f.includes('history_max_40_messages_80kB')));}
});

// ---------- unit: aligned meta, boundaries, packing ----------
// Build [message, meta entry] pairs. U(text,tid,visible) = user entry; A(text) = assistant.
const U=(text,tid,visible=true)=>[{role:'user',content:text},{turn_id:tid,visible}];
const A=text=>[{role:'assistant',content:text},null];
const M=pairs=>({full:pairs.map(p=>p[0]),entries:pairs.map(p=>p[1])});
const noUnderscore=list=>list.every(m=>Object.keys(m).every(k=>!k.startsWith('_')));
test('meta: bound to the exact model_messages by length + hash; legacy rule skips the revision payload',()=>{
 const {full,entries}=M([U('你好','t1'),A('好'),U(JSON.stringify({selected_report:{},instruction:'改'}),'t1',false)]);
 const meta=metaFor(full,entries);assert.ok(metaValid(meta,full));assert.deepEqual(boundariesOf(entries),[0]);
 assert.equal(metaValid(meta,[...full,{role:'assistant',content:'x'}]),false,'v52 append (rollback window) invalidates it');
 assert.equal(metaValid(meta,[{...full[0],content:'changed'},...full.slice(1)]),false,'same length, different content invalidates it');
 assert.equal(metaValid({...meta,entries:entries.slice(1)},full),false);assert.equal(metaValid(undefined,full),false);
 const legacy=[{role:'user',content:'a'},{role:'assistant',content:'b'},{role:'user',content:JSON.stringify({selected_report:{x:1},instruction:'y'})},{role:'user',content:'{"not":"revision"}'}];
 assert.deepEqual(legacy.map(isLegacyBoundary),[true,false,false,true]);
});
test('packing: short conversation keeps everything (start 0, empty prefix hash), prefix hash covers exactly the dropped part',()=>{
 const {full,entries}=M([U('一','t1'),A('a'),U('二','t2')]),history=[{id:'1',role:'user',content:'一'},{id:'2',role:'assistant',content:'a'},{id:'3',role:'user',content:'二'}];
 const p=packWindow({full,entries,history});assert.equal(p.start,0);assert.equal(p.full_length,3);assert.equal(p.prefix_hash,hash([]));assert.equal(p.kept_turns,2);assert.deepEqual(p.window,full);
});
const big=(n,ch='长')=>ch.repeat(n);
function conv(turns,{userChars=7000}={}){const pairs=[],history=[];for(let i=0;i<turns;i++){pairs.push(U(big(userChars)+i,'t'+i),A('答'+i));history.push({id:'u'+i,role:'user',content:big(userChars)+i},{id:'a'+i,role:'assistant',content:'答'+i});}pairs.pop();history.pop();return {...M(pairs),history};}
test('packing: the consented 80 kB visible limit cuts at whole user turns; the current turn is always the last entry',()=>{
 const {full,entries,history}=conv(5),p=packWindow({full,entries,history});
 assert.equal(p.kept_turns,3);assert.equal(entries[p.start].visible,true);assert.equal(p.window.at(-1),full.at(-1));
 assert.equal(p.prefix_hash,hash(full.slice(0,p.start)));
});
test('packing: 40 visible messages is a window limit, no longer a wall (61 messages stored, 39 sent)',()=>{
 const {full,entries,history}=conv(31,{userChars:3});assert.equal(history.length,61);const p=packWindow({full,entries,history});
 assert.equal(p.kept_turns,20);assert.equal(p.window.length,39);
});
test('packing: synthetic revision user (visible:false) and consecutive users of failed turns map correctly',()=>{
 const {full,entries}=M([U('a','t1'),U('{"selected_report":{},"instruction":"x"}','t1',false),A('r'),U('failed turn','t2'),U('again','t3')]);
 assert.deepEqual(boundariesOf(entries),[0,3,4]);
 const history=[{id:1,role:'user',content:'a'},{id:2,role:'assistant',content:'r'},{id:3,role:'user',content:'failed turn'},{id:4,role:'user',content:'again'}];
 const p=packWindow({full,entries,history});assert.equal(p.start,0);assert.equal(p.kept_turns,3);
});
test('recovery: missing or misaligned meta is recomputed from user-visible messages; if impossible, one window + over-budget order',()=>{
 const models=[{role:'user',content:'一'},{role:'assistant',content:'a'},{role:'user',content:'{"selected_report":{},"instruction":"x"}'},{role:'assistant',content:'b'}];
 const visible=[{id:1,role:'user',content:'一'},{id:2,role:'assistant',content:'a'},{id:3,role:'assistant',content:'b'}];
 const good=metaFor(models,[{turn_id:'t1',visible:true},null,{turn_id:'t1',visible:false},null]);
 assert.equal(resolveMeta(models,good,visible).source,'stored');
 const missing=resolveMeta(models,undefined,visible);assert.equal(missing.source,'recomputed');assert.deepEqual(boundariesOf(missing.entries),[0]);
 // rollback to v52 appended a turn without meta, then roll-forward: stale meta → recomputed
 const rolled=[...models,{role:'user',content:'二'},{role:'assistant',content:'c'}],v2=[...visible,{id:4,role:'user',content:'二'},{id:5,role:'assistant',content:'c'}];
 const r=resolveMeta(rolled,good,v2);assert.equal(r.source,'recomputed');assert.deepEqual(boundariesOf(r.entries),[0,4]);
 // counts cannot be reconciled (e.g. a legacy synthetic entry that does not look like a revision payload) → none
 const none=resolveMeta([...rolled,{role:'user',content:'synthetic but unrecognisable'}],good,v2);assert.equal(none.source,'none');assert.ok(none.entries.every(e=>e===null));
 // "none" packs as one window or the current turn only; the over-budget order still applies
 const full=[...rolled,{role:'user',content:'synthetic'},{role:'user',content:'三'}],entries=[...none.entries,{turn_id:'t9',visible:true}];
 const h=[...v2,{id:6,role:'user',content:'三'}];
 const whole=packWindow({full,entries,history:h});assert.equal(whole.start,0);assert.equal(whole.window.length,full.length);
 const cur=packWindow({full,entries,history:h,limits:{...CONTEXT_LIMITS,history_budget_tokens:5}});assert.equal(cur.start,full.length-1);assert.equal(cur.window.length,1);
 assert.throws(()=>packWindow({full,entries,history:h,extraTokens:500000}),e=>e.code==='conversation_too_long');
});
test('admitModelHistory: v52-shape model_messages + aligned meta; works with no model_messages (derived from messages)',()=>{
 const c={messages:[{id:'1',role:'user',content:'a'},{id:'2',role:'assistant',content:'b'}]};
 const a=admitModelHistory(c,{role:'user',content:'c'},'t2');
 assert.deepEqual(a.full,[{role:'user',content:'a'},{role:'assistant',content:'b'},{role:'user',content:'c'}]);
 assert.equal(a.meta_source,'recomputed');assert.ok(metaValid(a.meta,a.full));assert.deepEqual(boundariesOf(a.entries),[0,2]);assert.equal(a.entries[2].turn_id,'t2');
});
test('over-budget order: (1) old tool results elided, (2) window shrinks by turns, (3) 413 conversation_too_long; current turn never dropped',()=>{
 const toolBlob=JSON.stringify({rows:big(30000,'x')}),limits={...CONTEXT_LIMITS};
 const {full,entries}=M([U('q1','t1'),[{role:'assistant',content:'',tool_calls:[{id:'c1',type:'function',function:{name:'search',arguments:'{}'}}]},null],[{role:'tool',tool_call_id:'c1',content:toolBlob},null],A('a1'),U('q2','t2')]);
 const history=[{id:1,role:'user',content:'q1'},{id:2,role:'assistant',content:'a1'},{id:3,role:'user',content:'q2'}];
 const p=packWindow({full,entries,history,limits});assert.equal(p.kept_turns,2,'step 1: eliding the old result is enough, the turn stays');
 assert.equal(p.elided,1);assert.equal(JSON.parse(p.window[2].content).status,'elided');assert.equal(full[2].content,toolBlob,'stored history untouched');
 // current-turn tool results are never elided
 assert.equal(elideOldToolResults(full,1)[2].content,toolBlob);
 // step 2: tight history budget → older turn dropped, current kept
 const p2=packWindow({full,entries,history,limits:{...limits,history_budget_tokens:50}});assert.equal(p2.kept_turns,1);assert.equal(p2.window.length,1);
 // reservations count: explicit context tokens shrink the window too
 const {full:f3,entries:e3,history:h3}=conv(3,{userChars:5000});
 assert.equal(packWindow({full:f3,entries:e3,history:h3}).kept_turns,3);
 assert.equal(packWindow({full:f3,entries:e3,history:h3,extraTokens:100000}).kept_turns,1);
 // step 3: the current turn alone does not fit the request budget → 413, never a silent drop
 assert.throws(()=>packWindow({full:f3,entries:e3,history:h3,extraTokens:200000}),e=>e instanceof ApiError&&e.status===413&&e.code==='conversation_too_long');
});
test('storage caps replace the 40 / 80 kB wall: 413 conversation_too_long',()=>{
 assertStorageLimits(Array(200).fill({role:'user',content:'x'}),[]);
 assert.throws(()=>assertStorageLimits(Array(201).fill({role:'user',content:'x'}),[]),e=>e.status===413&&e.code==='conversation_too_long');
 assert.throws(()=>assertStorageLimits([{content:big(300001,'x')}],[]),e=>e.code==='conversation_too_long');
 assert.throws(()=>assertStorageLimits([],[{content:big(1500001,'x')}]),e=>e.code==='conversation_too_long');
 assert.ok(estimateTokens('你好')===2&&estimateTokens('abcdefg')===2);
});
test('mergeModelMessages: prefix + new entries + aligned meta, never a truncated history; frozen prefix mismatch → 409',()=>{
 const {full,entries,history}=conv(5),p=packWindow({full,entries,history}),meta=metaFor(full,entries);
 const turn={id:'t4',model_window_start:p.start,model_prefix_hash:p.prefix_hash,model_full_length:p.full_length,model_history:p.window};
 const loop=[...p.window,{role:'user',content:'{"selected_report":{},"instruction":"x"}'},{role:'assistant',content:'new answer'}],out=mergeModelMessages(full,meta,turn,loop);
 assert.equal(out.messages.length,full.length+2);assert.deepEqual(out.messages.slice(0,full.length),full,'elided window copies never overwrite stored originals');
 assert.ok(metaValid(out.meta,out.messages));assert.deepEqual(out.meta.entries.slice(-2),[{turn_id:'t4',visible:false},null],'synthetic user entry of the turn is not a boundary');
 assert.deepEqual(out.meta.entries.slice(0,full.length),entries);assert.ok(noUnderscore(out.messages));
 const stale=mergeModelMessages(full,{...meta,hash:'x'},turn,loop);assert.ok(stale.meta.entries.slice(0,full.length).every(e=>e===null),'invalid stored meta is not trusted');
 const tampered=[...full];tampered[0]={...tampered[0],content:'changed'};
 assert.throws(()=>mergeModelMessages(tampered,meta,turn,loop),e=>e.status===409&&e.code==='model_history_conflict');
 assert.throws(()=>mergeModelMessages([...full,{role:'assistant',content:'x'}],meta,turn,loop),e=>e.code==='model_history_conflict');
 assert.throws(()=>mergeModelMessages(full,meta,turn,p.window.slice(1)),e=>e.code==='model_history_conflict');
 assert.deepEqual(mergeModelMessages(full,meta,{model_history:[]},loop),{messages:loop,meta:undefined},'legacy turn keeps old behaviour');
});
test('GET projection drops model_messages, model_message_meta and the future summary/ledger, keeps the iOS-checked messages',()=>{
 const c={id:'c',messages:[{id:'1'}],model_messages:[1],model_message_meta:{},context_summary:'s',context_ledger:[],revision:3};
 assert.deepEqual(projectConversation(c),{id:'c',messages:[{id:'1'}],revision:3});
});

// ---------- integration through the HTTP runtime ----------
async function setup(){
 const probe={inputs:[]};
 const f=await fixture({stream:async function*(input){probe.inputs.push({messages:input.messages,system_prompt:input.system_prompt});yield {type:'text_delta',text:'好的'};yield {type:'done',finish_reason:'stop'};}});
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 return {f,probe,cid,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
}
const stored=s=>s.f.runtime.chat.readConversation('Bearer memory-fixture',s.f.scope.scope_id,s.cid);
async function post(s,text){const c=await stored(s),tid=randomUUID();const r=await s.f.req(s.path+'/turns',{turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text},context:[]});const body=await r.text();await s.f.runtime.chat.waitIdle();return {status:r.status,body,tid};}
test('multi-turn past the window: model_messages grows monotonically with markers, provider sees only the window without markers',async()=>{
 const s=await setup(),lengths=[];
 for(let i=0;i<6;i++){const r=await post(s,big(7000)+i);assert.equal(r.status,200);const c=await stored(s);lengths.push(c.model_messages.length);
  assert.ok(noUnderscore(c.model_messages),'v52 shape: no inline markers');assert.ok(metaValid(c.model_message_meta,c.model_messages));
  assert.equal(boundariesOf(c.model_message_meta.entries).length,i+1);}
 assert.deepEqual(lengths,[2,4,6,8,10,12],'full history kept, never truncated');
 const last=s.probe.inputs.at(-1);assert.equal(last.messages.filter(m=>m.role==='user').length,3,'80 kB consented window → last 3 turns');
 assert.ok(noUnderscore(last.messages),'adapters need no stripping: nothing server-only is in the messages');
 const cc=await stored(s);assert.deepEqual(last.messages,cc.model_messages.slice(-last.messages.length-1,-1),'provider got exactly the stored v52-shape window');
 assert.ok(last.system_prompt.includes(WINDOW_NOTE.trim()));assert.ok(!s.probe.inputs[0].system_prompt.includes(WINDOW_NOTE.trim()));
 const c=await stored(s);assert.equal(c.messages.length,12);
 const wire=(await s.f.json(await s.f.req(s.path))).conversation;assert.equal(wire.messages.length,12);assert.ok(!('model_messages' in wire)&&!('model_message_meta' in wire),'GET omits server-only fields');
});
test('more than 40 visible messages no longer returns 422 history_limit_reached; storage cap returns 413 conversation_too_long',async()=>{
 const s=await setup();
 for(let i=0;i<22;i++){const r=await post(s,'第'+i+'条');assert.equal(r.status,200,r.body);}
 assert.equal((await stored(s)).messages.length,44);assert.ok(s.probe.inputs.at(-1).messages.length<=40);
 let r;for(let i=0;i<20;i++){r=await post(s,big(7000)+i);if(r.status!==200)break;}
 assert.equal(r.status,413);assert.equal(JSON.parse(r.body).error.code,'conversation_too_long');
});

const rewrite=async(s,fn)=>{const {owner}=await s.f.runtime.chat.scoped('Bearer memory-fixture',s.f.scope.scope_id);await s.f.repository.transaction(async tx=>{const c=await tx.get(owner,'native-chat-conversations',s.cid);await tx.put(owner,'native-chat-conversations',fn(c));});};
test('v52-shape compatibility: stored model_messages are exactly what v52 stores ({role,content}), turn meta lives beside them',async()=>{
 const s=await setup();for(const t of ['一','二','三'])assert.equal((await post(s,t)).status,200);
 const c=await stored(s);
 assert.deepEqual(c.model_messages,[{role:'user',content:'一'},{role:'assistant',content:'好的'},{role:'user',content:'二'},{role:'assistant',content:'好的'},{role:'user',content:'三'},{role:'assistant',content:'好的'}]);
 assert.deepEqual(c.model_message_meta.entries.map(e=>e&&e.visible),[true,null,true,null,true,null]);assert.equal(c.model_message_meta.length,6);
 const turnIDs=c.model_message_meta.entries.filter(Boolean).map(e=>e.turn_id);assert.equal(new Set(turnIDs).size,3);
 assert.ok(s.probe.inputs.every(i=>noUnderscore(i.messages)));
});
test('rollback then roll-forward: v52 appended turns without meta → meta recomputed from visible messages, history intact',async()=>{
 const s=await setup();for(const t of ['一','二'])assert.equal((await post(s,t)).status,200);
 // what v52 would write for one more turn: messages + model_messages grow, model_message_meta untouched (v52 does not know it)
 await rewrite(s,c=>({...c,revision:c.revision+1,messages:[...c.messages,{id:randomUUID(),role:'user',content:'v52 问'},{id:randomUUID(),role:'assistant',content:'v52 答'}],model_messages:[...c.model_messages,{role:'user',content:'v52 问'},{role:'assistant',content:'v52 答'}]}));
 assert.equal((await post(s,'回来了')).status,200);
 const c=await stored(s);assert.equal(c.model_messages.length,8);assert.ok(metaValid(c.model_message_meta,c.model_messages));
 assert.deepEqual(boundariesOf(c.model_message_meta.entries),[0,2,4,6]);assert.equal(c.model_messages[4].content,'v52 问');
 assert.equal(s.probe.inputs.at(-1).messages.length,7,'all four turns fit the window');
});
test('meta missing (pre-change conversation) → recomputed; unreconcilable → one window, still answers',async()=>{
 const s=await setup();for(const t of ['一','二'])assert.equal((await post(s,t)).status,200);
 await rewrite(s,({model_message_meta,...c})=>c);
 assert.equal((await post(s,'三')).status,200);let c=await stored(s);assert.ok(metaValid(c.model_message_meta,c.model_messages));assert.deepEqual(boundariesOf(c.model_message_meta.entries),[0,2,4]);
 // an extra unexplained user entry in model_messages (counts no longer match the visible messages) and stale meta
 await rewrite(s,c=>({...c,model_messages:[...c.model_messages,{role:'user',content:'unexplained'}]}));
 assert.equal((await post(s,'四')).status,200);c=await stored(s);
 assert.deepEqual(boundariesOf(c.model_message_meta.entries),[c.model_messages.length-2],'only the new turn is a known boundary');
 assert.equal(s.probe.inputs.at(-1).messages.length,c.model_messages.length-1,'one window: the whole history was sent');
});

// ---------- B5: erasure clears derived notes/outcomes and v1.2 summary/ledger in the same write ----------
test('B5: source erasure clears turn_outcome_notes, device_undo_notes, interaction_outcomes, context_summary/ledger in one put',async()=>{
 const scope={scope_id:'s1',profile_id:'p',workspace_id:'w'},principal={subject_id:'u',scopes:[scope]},puts=[];
 const conv={id:'c1',subject_id:'u',scope_id:'s1',state:'active',revision:2,grant_epoch:1,messages:[{id:'m1',role:'user',content:'删掉我'},{id:'m2',role:'assistant',content:'好'}],
  model_messages:[{role:'user',content:'删掉我'},{role:'assistant',content:'好'}],model_message_meta:{schema:1},turn_outcome_notes:[{turn_id:'t0',text:'shown'}],device_undo_notes:[{x:1}],interaction_outcomes:[{turn_id:'t0'}],context_summary:'sum',context_ledger:[{a:1}]};
 const records={lock:async()=>{},get:async()=>conv,list:async kind=>kind==='native-chat-turns'?[]:[],put:async(o,kind,v)=>puts.push([kind,v]),withScope:async(_s,fn)=>fn({list:async()=>[],put:async()=>{}})};
 await eraseChatSource({records,principal,scope_id:'s1',source:{type:'chat_message',conversation_id:'c1',id:'m1',turn_id:'t1'}});
 const [kind,c]=puts.find(p=>p[0]==='native-chat-conversations');assert.equal(kind,'native-chat-conversations');
 assert.deepEqual([c.turn_outcome_notes,c.device_undo_notes,c.interaction_outcomes],[[],[],[]]);assert.ok(!('context_summary' in c)&&!('context_ledger' in c)&&!('model_message_meta' in c));
 assert.deepEqual(c.messages.map(m=>m.id),['m2']);assert.deepEqual(c.model_messages,[{role:'assistant',content:'好'}]);assert.equal(c.revision,3);
});

// ---------- Gemini: placeholder for current-turn calls without a cached signature; 400 classification ----------
const call=(id,name='reminder_create')=>({id,type:'function',function:{name,arguments:'{}'}});
test('toSteps: placeholder only for current-turn calls without a signature, on the first call of a parallel step; older turns untouched',()=>{
 _signatureCacheForTests.clear?.();
 const msgs=[{role:'user',content:'早'},{role:'assistant',content:'',tool_calls:[call('old1')]},{role:'tool',tool_call_id:'old1',content:'{}'},{role:'assistant',content:'好'},
  {role:'user',content:'再加两个'},{role:'assistant',content:'',tool_calls:[call('n1'),call('n2')]},{role:'tool',tool_call_id:'n1',content:'{}'},{role:'tool',tool_call_id:'n2',content:'{}'}];
 const steps=toSteps(msgs),ph=steps.filter(s=>s[GEMINI_SIGNATURE_FIELD]===GEMINI_SKIP_SIGNATURE);
 assert.equal(ph.length,1);const i=steps.indexOf(ph[0]);assert.equal(steps[i+1].id,'n1');assert.equal(steps[i+2].id,'n2');
 assert.equal(steps.findIndex(s=>s.id==='old1')>0&&steps[steps.findIndex(s=>s.id==='old1')-1].type,'user_input','previous turns are not validated → no placeholder');
 assert.equal(toSteps(msgs,{signaturePlaceholder:false}).filter(s=>s[GEMINI_SIGNATURE_FIELD]===GEMINI_SKIP_SIGNATURE).length,0);
});
test('geminiRejectReason: fixed vocabulary, signature errors recognised',()=>{
 assert.equal(geminiRejectReason({error:{message:'function call is missing a thought_signature'}}),'missing_thought_signature');
 assert.equal(geminiRejectReason({error:{message:'Function call is missing a thought signature in functionCall parts.'}}),'missing_thought_signature');
 assert.equal(geminiRejectReason({error:{message:'Invalid JSON payload: unknown field'}}),'invalid_argument');
 assert.equal(geminiRejectReason({}),'invalid_argument');
});
const KEY='gem-test-key-not-real';
const sseOk=text=>new Response(new ReadableStream({start(c){for(const f of [{choices:[{index:0,delta:{content:text}}]},{choices:[{index:0,delta:{},finish_reason:'stop'}]},'[DONE]'])c.enqueue(new TextEncoder().encode(`data: ${typeof f==='string'?f:JSON.stringify(f)}\n\n`));c.close();}}),{status:200,headers:{'content-type':'text/event-stream'}});
const toolHistory=[{role:'user',content:'加提醒'},{role:'assistant',content:'',tool_calls:[call('c1')]},{role:'tool',tool_call_id:'c1',content:'{"ok":true}'}];
async function run(geminiBody){
 const urls=[],c=readFreeRouteChain(k=>({CATPAW_PRIVATE_MODEL_KEY:'o',CATPAW_GEMINI_API_KEY:KEY,CATPAW_GEMINI_ROUTE:'primary'})[k]);
 const p=new FreeRouteChainProvider({...c,fetchImpl:async url=>{urls.push(url);return url.includes('googleapis')?new Response(geminiBody,{status:400}):sseOk('续写');}});
 const out=[];try{for await(const e of p.stream({messages:toolHistory,system_prompt:'猫爪',tools:[]}))out.push(e);}catch(e){out.push({type:'thrown',code:e.code});}
 return {urls,out};
}
test('400 classification: thought-signature 400 fails over; any other 400 with tool history stays provider_request_invalid (no failover)',async()=>{
 const sig=await run('{"error":{"code":400,"message":"function call is missing a thought_signature"}}');
 assert.ok(sig.urls.some(u=>!u.includes('googleapis')),'failed over to the next route');assert.ok(sig.out.some(e=>e.type==='text_delta'&&e.text==='续写'));
 health.clear();
 const other=await run('{"error":{"code":400,"message":"Invalid value at generation_config"}}');
 assert.ok(other.urls.every(u=>u.includes('googleapis')),'no failover on a real request error');
 assert.ok(other.out.some(e=>(e.type==='thrown'||e.type==='error')&&JSON.stringify(e).includes('provider_request_invalid')),JSON.stringify(other.out));
});
