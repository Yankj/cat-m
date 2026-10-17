// image-upload-bug (2026-10-17): the single OpenRouter Gemma vision route was 429 all day on the key it shares with text,
// so image turns failed with rate_limited. Free vision chain Gemini 3.5 Flash-Lite → Gemma 4, per-model Gemini cooldown,
// and an advisory Retry-After on every rate_limited (HTTP header + body, SSE turn_failed).
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {deflateSync} from 'node:zlib';
import {readConfig,readVisionRouteMode} from '../supabase/functions/_shared/config.mjs';
import {readFreeRouteChain} from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
import {LIVE_VISION_ROUTE_HASH,VISION_CHAIN_ROUTE,VISION_CHAIN_ROUTE_HASH,VISION_CHAIN_CONSENT_UI,VISION_CONSENT_UI,VISION_GEMINI_MODEL} from '../supabase/functions/_shared/core/src/live-vision-route.mjs';
import {VisionChainProvider} from '../supabase/functions/_shared/core/src/vision-route-chain.mjs';
import {crc32,validateVisionTurn,createVisionContract} from '../supabase/functions/_shared/core/src/vision-contract.mjs';
import {GeminiRateGuard} from '../supabase/functions/_shared/core/src/gemini-interactions-route.mjs';
import {OpenRouterProvider,retryAfterFromFailure,collectRound} from '../supabase/functions/_shared/core/src/openrouter-provider.mjs';
import {retryAfterOf,retryAfterParts} from '../supabase/functions/_shared/core/src/retry-after.mjs';
import {ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};

const GKEY='gem-vision-test-key-not-real',OKEY='or-vision-test-key-not-real';
const env=o=>k=>o[k];
const BASE={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:OKEY,CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'k'};
const sha=b=>createHash('sha256').update(b).digest('hex');
function png(w=2,h=2){const chunk=(type,data)=>{const len=Buffer.alloc(4);len.writeUInt32BE(data.length);const td=Buffer.concat([Buffer.from(type),data]);const crc=Buffer.alloc(4);crc.writeUInt32BE(crc32(td));return Buffer.concat([len,td,crc]);};
 const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(w,0);ihdr.writeUInt32BE(h,4);ihdr[8]=8;ihdr[9]=2;return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',ihdr),chunk('IDAT',deflateSync(Buffer.alloc((1+w*3)*h))),chunk('IEND',Buffer.alloc(0))]);}
const sse=frames=>new Response(new ReadableStream({start(c){for(const f of frames)c.enqueue(new TextEncoder().encode(`data: ${typeof f==='string'?f:JSON.stringify(f)}\n\n`));c.close();}}),{status:200,headers:{'content-type':'text/event-stream'}});
const gText=t=>sse([{event_type:'interaction.created',interaction:{id:'i1',model:VISION_GEMINI_MODEL}},{event_type:'step.start',index:0,step:{type:'model_output'}},{event_type:'step.delta',index:0,delta:{type:'text',text:t}},{event_type:'interaction.completed',interaction:{id:'i1',status:'completed'}},'[DONE]']);
const g429=(body='{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"retryDelay":"20s"}]}}')=>new Response(body,{status:429});
const orText=t=>sse([{id:'gen-1',model:'google/gemma-4-31b-it',provider:'Google AI Studio',choices:[{index:0,delta:{content:t}}]},{id:'gen-1',choices:[{index:0,delta:{},finish_reason:'stop'}],usage:{prompt_tokens:3,completion_tokens:2,total_tokens:5,cost:0}},'[DONE]']);
const catalog=()=>Response.json({data:{id:'google/gemma-4-31b-it:free',architecture:{input_modalities:['text','image'],output_modalities:['text']},endpoints:[{tag:'google-ai-studio',provider_name:'Google AI Studio',model_id:'google/gemma-4-31b-it:free',status:0,pricing:{prompt:'0',completion:'0'}}]}});
const or429=(headers={})=>new Response('{"error":{"code":429,"message":"Rate limit exceeded: free-models-per-day"}}',{status:429,headers});
function imageInput(){const bytes=png(),v=validateVisionTurn({schema_version:2,turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'这张图里有什么？',attachments:[{id:randomUUID(),mime_type:'image/png',sha256:sha(bytes),base64:bytes.toString('base64')}]},context:[]},{enabled:true});
 return {messages:[{role:'user',content:'这张图里有什么？'}],system_prompt:'你是猫爪',tools:[],image_attachments:v.attachments,vision_user_index:0,provider_context:{image_route_hash:VISION_CHAIN_ROUTE_HASH}};}
const chainProvider=(fetchImpl,extra={})=>new VisionChainProvider({geminiSecret:GKEY,openRouterSecret:OKEY,fetchImpl,geminiGuard:new GeminiRateGuard({rpm:100}),beforeStream:async()=>{},...extra});
const route=url=>url.includes('googleapis')?'gemini':url.includes('/endpoints')?'catalog':'openrouter';

test('route hashes: legacy image hash is byte-identical, text route_hash does not depend on the vision route',()=>{
 assert.equal(LIVE_VISION_ROUTE_HASH,'3665b04ec3ef81e4860e99db87ce2a229c26ed23d17576bd08b5f7a2c5a6ae9e','legacy route unchanged (old consents stay valid on rollback)');
 assert.notEqual(VISION_CHAIN_ROUTE_HASH,LIVE_VISION_ROUTE_HASH);
 const withGemini={...BASE,CATPAW_GEMINI_API_KEY:GKEY};
 const chainCfg=readConfig(env(withGemini)),legacyCfg=readConfig(env({...withGemini,CATPAW_VISION_ROUTE:'legacy'}));
 assert.equal(chainCfg.visionRoute,'chain');assert.equal(legacyCfg.visionRoute,'legacy');
 assert.equal(chainCfg.routeHash,legacyCfg.routeHash,'text/account consent route_hash unchanged by the vision route');
 assert.deepEqual(VISION_CHAIN_ROUTE.routing_policy.chain.map(h=>[h.id,h.model]),[['gemini','gemini-3.5-flash-lite'],['openrouter','google/gemma-4-31b-it:free']]);
 assert.ok(!JSON.stringify(VISION_CHAIN_ROUTE).includes(GKEY)&&!JSON.stringify(VISION_CHAIN_ROUTE).includes(OKEY),'no key in the consented route');
 assert.match(VISION_CHAIN_CONSENT_UI.body,/Gemini API 免费层/);assert.match(VISION_CHAIN_CONSENT_UI.body,/训练/);assert.notEqual(VISION_CHAIN_CONSENT_UI.body,VISION_CONSENT_UI.body);
});

test('readVisionRouteMode: chain only with a usable Gemini interactions key; legacy/unknown/openai_compat/off keep the single route',()=>{
 const mode=o=>readVisionRouteMode(env(o),readFreeRouteChain(env(o)));
 assert.equal(mode({CATPAW_PRIVATE_MODEL_KEY:OKEY}),'legacy','no Gemini key');
 assert.equal(mode({CATPAW_PRIVATE_MODEL_KEY:OKEY,CATPAW_GEMINI_API_KEY:GKEY}),'chain');
 assert.equal(mode({CATPAW_PRIVATE_MODEL_KEY:OKEY,CATPAW_GEMINI_API_KEY:GKEY,CATPAW_VISION_ROUTE:'legacy'}),'legacy');
 assert.equal(mode({CATPAW_PRIVATE_MODEL_KEY:OKEY,CATPAW_GEMINI_API_KEY:GKEY,CATPAW_VISION_ROUTE:'bogus'}),'legacy','unknown value never breaks boot');
 assert.equal(mode({CATPAW_PRIVATE_MODEL_KEY:OKEY,CATPAW_GEMINI_API_KEY:GKEY,CATPAW_GEMINI_PROTOCOL:'openai_compat'}),'legacy');
 assert.equal(mode({CATPAW_PRIVATE_MODEL_KEY:OKEY,CATPAW_GEMINI_API_KEY:GKEY,CATPAW_GEMINI_ROUTE:'off'}),'legacy');
 const live=createVisionContract({visionLiveEnabled:true},chainProvider(async()=>{throw Error('no');}));
 assert.equal(live.isLive,true);assert.equal(live.routeHash,VISION_CHAIN_ROUTE_HASH);
});

test('Gemini first: image sent inline to Flash-Lite without tools, OpenRouter not called, receipt names the hop',async()=>{
 const seen=[];const p=chainProvider(async(url,init)=>{seen.push({route:route(url),init});return gText('一个红色小方块');});
 const round=await collectRound(p,imageInput());
 assert.equal(round.text,'一个红色小方块');assert.deepEqual(seen.map(s=>s.route),['gemini']);
 const body=JSON.parse(seen[0].init.body);assert.equal(body.model,'gemini-3.5-flash-lite');assert.equal(body.store,false);assert.equal(body.tools,undefined);
 assert.equal(seen[0].init.headers['x-goog-api-key'],GKEY);assert.ok(body.input[0].content.some(c=>c.type==='image'&&c.mime_type==='image/png'));
 assert.equal(round.provider_receipt.route,'gemini');assert.equal(round.provider_receipt.route_hash,VISION_CHAIN_ROUTE_HASH);assert.equal(round.provider_receipt.cost,0);assert.equal(round.provider_receipt.image_count,1);
});

test('Gemini 429 → OpenRouter Gemma fallback before any output (the prod bug: a second image now succeeds)',async()=>{
 const seen=[];const guard=new GeminiRateGuard({rpm:100});const p=chainProvider(async url=>{seen.push(route(url));return route(url)==='gemini'?g429():route(url)==='catalog'?catalog():orText('红色方块');},{geminiGuard:guard});
 const round=await collectRound(p,imageInput());
 assert.equal(round.text,'红色方块');assert.deepEqual(seen,['gemini','catalog','openrouter']);
 assert.equal(round.provider_receipt.route,'openrouter');assert.equal(round.provider_receipt.route_hash,VISION_CHAIN_ROUTE_HASH);
 assert.deepEqual(p.observations.map(o=>[o.route,o.error??'ok']),[['gemini','rate_limited'],['openrouter','ok']]);
 assert.ok(guard.coolUntilFor(VISION_GEMINI_MODEL)>Date.now());
 // Next image while Gemini cools down: Google is not called again, Gemma answers.
 seen.length=0;await collectRound(p,imageInput());assert.deepEqual(seen,['openrouter'],'cooling Gemini skipped without a request; catalog cached');
});

test('both free vision routes busy → rate_limited with the earliest advisory Retry-After',async()=>{
 const p=chainProvider(async url=>route(url)==='gemini'?g429():route(url)==='catalog'?catalog():or429({'retry-after':'45'}));
 await assert.rejects(collectRound(p,imageInput()),e=>e.code==='rate_limited'&&e.status===429&&e.retryAfterSeconds===20);
 const q=chainProvider(async url=>route(url)==='gemini'?g429('{"error":{"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded for metric generate_requests_per_model_per_day"}}'):route(url)==='catalog'?catalog():or429({'retry-after':'45'}));
 await assert.rejects(collectRound(q,imageInput()),e=>e.code==='rate_limited'&&e.retryAfterSeconds===45,'Gemini daily quota (1 h) → Gemma Retry-After is the earliest');
});

test('no failover after output or on an uncertain dispatch; wrong consented hash refused before any request',async()=>{
 let calls=0;const p=chainProvider(async()=>{calls++;throw new TypeError('network down');});
 await assert.rejects(collectRound(p,imageInput()),e=>e.code==='provider_transport_failed');assert.equal(calls,1,'reconciliation-flagged transport failure is not resent to Gemma');
 const q=chainProvider(async()=>{calls++;return gText('x');});
 await assert.rejects(collectRound(q,{...imageInput(),provider_context:{image_route_hash:LIVE_VISION_ROUTE_HASH}}),e=>e.code==='provider_image_context_required');assert.equal(calls,1);
});

test('Gemini cooldown is per model: one model at its daily quota does not pause the others',()=>{
 let t=1000;const g=new GeminiRateGuard({rpm:2,now:()=>t});
 g.backoff({daily:true,model:'gemini-3.8-flash'});
 assert.throws(()=>g.admit('gemini-3.8-flash'),e=>e.code==='rate_limited'&&e.localGuard==='cooldown'&&e.retryAfterSeconds===3600);
 g.admit('gemini-3.5-flash-lite');g.admit('gemini-3.5-flash-lite');assert.throws(()=>g.admit('gemini-3.5-flash-lite'),e=>e.localGuard==='rpm','RPM window is per model too');
 assert.equal(g.coolUntilFor('gemini-3.5-flash-lite'),0);assert.equal(g.coolUntil,1000+3600000,'status view: latest cooldown of any model');
});

test('OpenRouter 429 always carries retryAfterSeconds: header, else account daily reset (≤1 h), else 30 s',async()=>{
 assert.equal(retryAfterFromFailure({headers:{retry_after_seconds:12.2}}),13);
 const now=Date.parse('2026-10-17T23:40:00Z');assert.equal(retryAfterFromFailure({headers:{retry_after_seconds:null},category:'account_daily_quota',account_daily_reset_utc:'2026-10-18T00:00:00.000Z'},now),1200);
 assert.equal(retryAfterFromFailure({headers:{retry_after_seconds:null},category:'account_daily_quota',account_daily_reset_utc:'2026-10-18T00:00:00.000Z'},Date.parse('2026-10-17T11:00:00Z')),3600);
 assert.equal(retryAfterFromFailure({headers:{retry_after_seconds:null},category:'unknown_429'}),30);
 const p=new OpenRouterProvider({model:'apodex/apodex-1.1-mini:free',secret:OKEY,liveNetworkEnabled:true,fetchImpl:async()=>or429({'retry-after':'9'})});
 await assert.rejects(collectRound(p,{messages:[{role:'user',content:'hi'}],system_prompt:'s',tools:[]}),e=>e.code==='rate_limited'&&e.status===429&&e.retryAfterSeconds===9);
});

test('retryAfterOf / retryAfterParts: ApiError.retryAfterSec or provider retryAfterSeconds, rounded up, 1..3600',()=>{
 assert.equal(retryAfterOf(new ApiError(503,'chat_runtime_busy',{retryAfterSec:4})),4);
 assert.equal(retryAfterOf(Object.assign(new ApiError(429,'rate_limited'),{retryAfterSeconds:7.2})),8);
 assert.equal(retryAfterOf(Object.assign(new ApiError(429,'rate_limited'),{retryAfterSeconds:99999})),3600);
 assert.equal(retryAfterOf(new ApiError(429,'rate_limited')),null);
 assert.deepEqual(retryAfterParts(Object.assign(new ApiError(429,'rate_limited'),{retryAfterSeconds:5})),{headers:{'Retry-After':'5'},body:{retry_after_seconds:5}});
});

test('SSE turn_failed rate_limited carries retry_after_seconds (rounded up)',async()=>{
 const f=await fixture({stream:async function*(){throw Object.assign(new ApiError(429,'rate_limited'),{retryAfterSeconds:7.4});}});
 const turn=await f.send(await f.newConversation(),'你好');
 const failed=turn.events.find(e=>e.type==='turn_failed');assert.equal(failed.data.code,'rate_limited');assert.equal(failed.data.retry_after_seconds,8);
});

test('end to end: image-model-route serves the chain + v2 consent text; Gemini busy → Gemma answers the image turn',async()=>{
 const seen=[];const imageProvider=chainProvider(async url=>{seen.push(route(url));return route(url)==='gemini'?g429():route(url)==='catalog'?catalog():orText('图里是一个红色小方块');});
 const f=await fixture({imageProvider,env:{CATPAW_GEMINI_API_KEY:GKEY}});
 const r=await f.json(await f.req('/catpaw/privacy/v1/image-model-route'));
 assert.equal(r.route_hash,VISION_CHAIN_ROUTE_HASH);assert.equal(r.ui.body,VISION_CHAIN_CONSENT_UI.body);assert.equal(r.live_transmission_available,true);
 assert.ok(!JSON.stringify(r).includes(GKEY)&&!JSON.stringify(r).includes(OKEY));
 const cid=await f.newConversation(),chat=`/catpaw/chat/v1/scopes/${f.scope.scope_id}`,p=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
 await f.json(await f.req(p+'/model-consent',{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const stale=await f.req(p+'/image-model-consent',{decision:'allow',expected_revision:0,route_hash:LIVE_VISION_ROUTE_HASH,non_sensitive_confirmed:true});
 assert.equal(stale.status,422,'a consent for the old single route cannot authorise the chain');
 await f.json(await f.req(p+'/image-model-consent',{decision:'allow',expected_revision:0,route_hash:r.route_hash,non_sensitive_confirmed:true}));
 const c=(await f.json(await f.req(`${chat}/conversations/${cid}`))).conversation,bytes=png();
 const res=await f.req(`${chat}/conversations/${cid}/turns`,{schema_version:2,turn_id:randomUUID(),expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'这张图里有什么？一句话',attachments:[{id:randomUUID(),mime_type:'image/png',sha256:sha(bytes),base64:bytes.toString('base64')}]},context:[]});
 assert.equal(res.status,200);const text=await res.text();assert.match(text,/turn_completed/);assert.match(text,/红色小方块/);
 await f.runtime.chat.waitIdle();assert.deepEqual(seen.filter(x=>x!=='catalog'),['gemini','openrouter']);
});
