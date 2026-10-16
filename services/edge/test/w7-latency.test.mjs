// w7 latency: short first-event timeout per hop, route circuit breaker, turn-budget-aware chain, per-attempt log line.
import test, {beforeEach} from 'node:test';import assert from 'node:assert/strict';
import {FreeRouteChainProvider,readFreeRouteChain,withRoutePreference,routeTimeouts,FAST_ROUTE_TIMEOUTS,REASONING_ROUTE_TIMEOUTS,MIN_ATTEMPT_MS,noteRouteResult,routeCircuitOpen,_routeHealthForTests} from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
import {GeminiRateGuard} from '../supabase/functions/_shared/core/src/gemini-interactions-route.mjs';
beforeEach(()=>_routeHealthForTests.clear());
const env=o=>k=>o[k];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const sse=frames=>new Response(frames.map(f=>`data: ${f}\n\n`).join(''),{status:200,headers:{'content-type':'text/event-stream'}});
const orOk=t=>sse([JSON.stringify({choices:[{index:0,delta:{content:t}}]}),JSON.stringify({choices:[{index:0,delta:{},finish_reason:'stop'}]}),'[DONE]']);
const hang=signal=>new Promise((_,rej)=>signal.addEventListener('abort',()=>rej(new DOMException('aborted','AbortError')),{once:true}));
const E={CATPAW_GEMINI_API_KEY:'g',CATPAW_PRIVATE_MODEL_KEY:'o',CATPAW_AGNES_API_KEY:'a',CATPAW_GEMINI_PROTOCOL:'openai_compat'};
const collect=async(p,input={},pref=null)=>{const out=[];await withRoutePreference(pref,async()=>{for await(const e of p.stream({messages:[{role:'user',content:'hi'}],system_prompt:'s',tools:[],...input}))out.push(e);},{routeEvents:true});return out;};
const routeOf=url=>url.includes('googleapis')?'gemini':url.includes('openrouter')?'openrouter':'agnes';

test('defaults: fast routes wait ≤12 s for the first upstream frame (was 20 s) and may stream up to 45 s; agnes first-event 30 s (was 75 s)',()=>{
 assert.deepEqual(routeTimeouts({id:'gemini'},20000),FAST_ROUTE_TIMEOUTS);
 assert.deepEqual(routeTimeouts({id:'openrouter'},20000),{firstEventMs:12000,idleMs:20000,totalMs:45000});
 assert.deepEqual(routeTimeouts({id:'agnes'},20000),REASONING_ROUTE_TIMEOUTS);
 // worst-case auto chain before any text: 12 + 12 + 30 = 54 s, inside the 120 s turn budget (was 20 + 20 + 75 = 115 s)
 assert.ok(FAST_ROUTE_TIMEOUTS.firstEventMs*2+REASONING_ROUTE_TIMEOUTS.firstEventMs<=60000);
 // env override still wins and stays bounded
 const c=readFreeRouteChain(env({...E,CATPAW_GEMINI_FIRST_EVENT_TIMEOUT_MS:'5000'}));
 assert.equal(routeTimeouts(c.routes.find(r=>r.id==='gemini'),20000).firstEventMs,5000);
});

test('breaker: Gemini 503 overloaded → next auto turn starts on the next route without paying the Gemini hop again',async()=>{
 const urls=[];const fetchImpl=async url=>{urls.push(routeOf(url));return url.includes('googleapis')?new Response('{}',{status:503}):orOk('ok');};
 const p=new FreeRouteChainProvider({...readFreeRouteChain(env(E)),fetchImpl,geminiGuard:new GeminiRateGuard({rpm:100})});
 const first=await collect(p);assert.equal(first.find(e=>e.type==='route_info').failover,true);
 assert.ok(routeCircuitOpen('gemini'));
 urls.length=0;const second=await collect(p);
 assert.deepEqual(urls,['openrouter']);const ri=second.find(e=>e.type==='route_info');assert.equal(ri.route,'openrouter');assert.equal(ri.failover,false);
});

test('breaker: free_model_unavailable (404) cools the route for 10 min; success closes it; Retry-After wins',()=>{
 const t=1_000_000;noteRouteResult('openrouter','free_model_unavailable',t);
 assert.ok(routeCircuitOpen('openrouter',t+599_000));assert.ok(!routeCircuitOpen('openrouter',t+601_000));
 noteRouteResult('openrouter',null,t+1000);assert.ok(!routeCircuitOpen('openrouter',t+2000));
 noteRouteResult('gemini','rate_limited',t,{retryAfterSeconds:5});assert.ok(routeCircuitOpen('gemini',t+4000));assert.ok(!routeCircuitOpen('gemini',t+6000));
 noteRouteResult('agnes','invalid_tool_arguments',t);assert.ok(!routeCircuitOpen('agnes',t+1),'non-busy errors do not open the breaker');
});

test('breaker: every route open → all are still tried (demoted, never dropped)',async()=>{
 const t=Date.now();for(const id of ['gemini','openrouter','agnes'])noteRouteResult(id,'provider_overloaded',t);
 const urls=[];const p=new FreeRouteChainProvider({...readFreeRouteChain(env(E)),fetchImpl:async url=>{urls.push(routeOf(url));return orOk('ok');},geminiGuard:new GeminiRateGuard({rpm:100})});
 const out=await collect(p);assert.equal(out.find(e=>e.type==='text_delta').text,'ok');assert.equal(urls.length,1);
});

test('breaker: an explicitly selected route stays first even while its breaker is open',async()=>{
 noteRouteResult('gemini','provider_overloaded');
 const urls=[];const p=new FreeRouteChainProvider({...readFreeRouteChain(env(E)),fetchImpl:async url=>{urls.push(routeOf(url));return orOk('ok');},geminiGuard:new GeminiRateGuard({rpm:100})});
 await collect(p,{},'gemini');assert.deepEqual(urls,['gemini']);
});

test('silent route fails over after its first-event timeout, not the old 20 s budget',async()=>{
 const c=readFreeRouteChain(env({...E,CATPAW_GEMINI_FIRST_EVENT_TIMEOUT_MS:'1000'}));
 const p=new FreeRouteChainProvider({...c,fetchImpl:async(url,i)=>url.includes('googleapis')?hang(i.signal):orOk('快'),geminiGuard:new GeminiRateGuard({rpm:100})});
 const t0=Date.now();const out=await collect(p);const ms=Date.now()-t0;
 assert.equal(out.find(e=>e.type==='text_delta').text,'快');assert.ok(ms<3000,`took ${ms}ms`);
 assert.equal(p.observations[0].error,'provider_timeout_before_output');assert.equal(p.observations[0].timeout_phase,'first_event');
});

test('turn budget: hop timers are clamped to the remaining turn budget; no hop starts below MIN_ATTEMPT_MS',async()=>{
 
 const urls=[];const p=new FreeRouteChainProvider({...readFreeRouteChain(env(E)),fetchImpl:async(url,i)=>{urls.push(routeOf(url));return hang(i.signal);},geminiGuard:new GeminiRateGuard({rpm:100})});
 const t0=Date.now();await assert.rejects(collect(p,{turn_deadline_at:Date.now()+MIN_ATTEMPT_MS+1200}),e=>['provider_timeout_before_output','chat_dispatch_budget_exhausted'].includes(e.code));
 const ms=Date.now()-t0;assert.ok(ms<MIN_ATTEMPT_MS+2500,`took ${ms}ms`);assert.equal(urls.length,1,'second hop not started without budget');
 urls.length=0;_routeHealthForTests.clear();
 await assert.rejects(collect(p,{turn_deadline_at:Date.now()+1000}),e=>e.code==='chat_dispatch_budget_exhausted');assert.equal(urls.length,0);
});

test('no in-place 12 s re-run of the whole chain after every failover route was already tried',async()=>{
 let n=0;const p=new FreeRouteChainProvider({...readFreeRouteChain(env({CATPAW_PRIVATE_MODEL_KEY:'o',CATPAW_AGNES_API_KEY:'a'})),fetchImpl:async()=>{n++;return new Response('{}',{status:429,headers:{'retry-after':'1'}});}});
 const t0=Date.now();await assert.rejects(collect(p),e=>e.code==='rate_limited');assert.equal(n,2);assert.ok(Date.now()-t0<900);
});

const GKEY='CATPAW_GEMINI_'+'API_KEY',MARK='zz-marker-'+'7f3';
test('each route attempt logs one structured line with first_event_ms and outcome, without secrets or bodies',async()=>{
 const lines=[];const orig=console.info;console.info=l=>lines.push(l);
 try{const p=new FreeRouteChainProvider({...readFreeRouteChain(env(Object.assign({},E,{[GKEY]:MARK}))),fetchImpl:async url=>url.includes('googleapis')?new Response(JSON.stringify({error:MARK+' body'}),{status:503}):orOk('ok'),geminiGuard:new GeminiRateGuard({rpm:100})});await collect(p);}
 finally{console.info=orig;}
 const a=lines.map(l=>JSON.parse(l)).filter(x=>x.event==='catpaw_route_attempt');
 assert.deepEqual(a.map(x=>[x.route,x.outcome]),[['gemini','provider_overloaded'],['openrouter','ok']]);
 assert.equal(typeof a[1].first_event_ms,'number');assert.equal(a[0].first_event_ms,null);
 assert.ok(!lines.join('').includes(MARK));
});
