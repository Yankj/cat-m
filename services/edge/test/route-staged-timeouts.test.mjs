import test from 'node:test';import assert from 'node:assert/strict';
import {FreeRouteChainProvider,readFreeRouteChain,routeTimeouts,REASONING_ROUTE_TIMEOUTS,withRoutePreference} from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const env=o=>k=>o[k];
const chunk=delta=>JSON.stringify({choices:[{index:0,delta}]});
// Upstream stream: [delayMs, frame] pairs, honoring fetch abort.
const timed=(plan,signal)=>new Response(new ReadableStream({async start(c){for(const [ms,f] of plan){await sleep(ms);if(signal.aborted){c.error(new DOMException('aborted','AbortError'));return;}c.enqueue(new TextEncoder().encode(`data: ${f}\n\n`));}c.close();}}),{status:200,headers:{'content-type':'text/event-stream'}});
const chain=(timeouts,order='agnes,openrouter')=>{const c=readFreeRouteChain(env({CATPAW_PRIVATE_MODEL_KEY:'o',CATPAW_AGNES_API_KEY:'a',CATPAW_MODEL_ROUTE_ORDER:order}));c.routes=c.routes.map(r=>r.id==='agnes'?{...r,timeouts}:r);return c;};
const run=async(p)=>{const out=[];await withRoutePreference('agnes',async()=>{for await(const e of p.stream({messages:[],system_prompt:'s',tools:[]}))if(e.type!=='route_info')out.push(e);},{reasoningSummary:true});return out;};
const done=[[0,chunk({}).replace('{}','{}')],[0,JSON.stringify({choices:[{index:0,delta:{},finish_reason:'stop'}]})],[0,'[DONE]']];

test('agnes defaults to staged timeouts; other routes keep the single historical budget; env overrides are bounded',()=>{
 assert.deepEqual(routeTimeouts({id:'agnes'},20000),REASONING_ROUTE_TIMEOUTS);
 assert.deepEqual(REASONING_ROUTE_TIMEOUTS,{firstEventMs:75000,idleMs:20000,totalMs:100000});
 assert.deepEqual(routeTimeouts({id:'gemini'},20000),{firstEventMs:20000,idleMs:20000,totalMs:20000});
 const c=readFreeRouteChain(env({CATPAW_AGNES_API_KEY:'a',CATPAW_AGNES_FIRST_EVENT_TIMEOUT_MS:'60000',CATPAW_AGNES_IDLE_TIMEOUT_MS:'15000'}));
 assert.deepEqual(routeTimeouts(c.routes[0],20000),{firstEventMs:60000,idleMs:15000,totalMs:100000});
 assert.throws(()=>readFreeRouteChain(env({CATPAW_AGNES_API_KEY:'a',CATPAW_AGNES_IDLE_TIMEOUT_MS:'abc'})));
 assert.throws(()=>routeTimeouts({id:'agnes',timeouts:{totalMs:500000}},20000));
});
test('a long think before the first event succeeds within the first-event timeout (old single budget would expire)',async()=>{
 const p=new FreeRouteChainProvider({...chain({firstEventMs:2500,idleMs:1000,totalMs:6000}),timeoutMs:1000,fetchImpl:async(u,i)=>timed([[1600,chunk({reasoning_content:'思考'})],[100,chunk({content:'答案'})],...done],i.signal)});
 const out=await run(p);assert.deepEqual(out.map(e=>e.type),['thinking_delta','text_delta','done']);
});
test('reasoning chunks count as activity and reset the idle timeout',async()=>{
 const plan=[[0,chunk({reasoning_content:'a'})],...Array.from({length:5},()=>[600,chunk({reasoning_content:'b'})]),[600,chunk({content:'ok'})],...done];
 const p=new FreeRouteChainProvider({...chain({firstEventMs:2000,idleMs:1000,totalMs:8000}),fetchImpl:async(u,i)=>timed(plan,i.signal)});
 const out=await run(p);assert.equal(out.at(-1).type,'done');assert.equal(out.filter(e=>e.type==='thinking_delta').length,6);
});
test('idle stall after output is provider_timeout with reconciliation and never fails over',async()=>{
 let calls=0;const p=new FreeRouteChainProvider({...chain({firstEventMs:2000,idleMs:1000,totalMs:8000}),fetchImpl:async(u,i)=>{calls++;return timed([[0,chunk({reasoning_content:'a'})],[2500,chunk({content:'late'})],...done],i.signal);}});
 await assert.rejects(run(p),e=>e.code==='provider_timeout'&&e.reconciliation===true);assert.equal(calls,1);
});
test('no event before the first-event timeout fails over to the next chain route (existing chain rule)',async()=>{
 const urls=[];const p=new FreeRouteChainProvider({...chain({firstEventMs:1000,idleMs:1000,totalMs:3000}),fetchImpl:async(u,i)=>{urls.push(u);return urls.length===1?timed([[2000,chunk({content:'late'})],...done],i.signal):timed([[0,chunk({content:'fallback'})],...done],i.signal);}});
 const out=await run(p);assert.equal(urls.length,2);assert.match(urls[0],/agnes/);assert.equal(out.find(e=>e.type==='text_delta').text,'fallback');
 assert.equal(p.observations[0].error,'provider_timeout_before_output');assert.equal(p.observations[0].timeout_phase,'first_event');
});
test('long reasoning streams: >256kB of chunk framing and >16kB of reasoning do not fail the answer',async()=>{
 const plan=[...Array.from({length:1500},(_,i)=>[0,chunk({reasoning_content:'思考'.repeat(10)+i})]),...Array.from({length:800},()=>[0,chunk({content:'字'})]),...done];
 const p=new FreeRouteChainProvider({...chain({firstEventMs:5000,idleMs:5000,totalMs:20000}),fetchImpl:async(u,i)=>timed(plan,i.signal)});
 const out=await run(p);const thought=out.filter(e=>e.type==='thinking_delta').map(e=>e.text).join('');
 assert.equal(out.at(-1).type,'done');assert.equal(out.filter(e=>e.type==='text_delta').map(e=>e.text).join(''),'字'.repeat(800));
 assert.ok(Buffer.byteLength(thought)<=16000+200&&thought.length>0);
});
