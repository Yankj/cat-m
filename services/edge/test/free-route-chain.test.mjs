import test from 'node:test';import assert from 'node:assert/strict';
import {FreeRouteChainProvider,readFreeRouteChain,withRoutePreference} from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
const sse=frames=>new Response(new ReadableStream({start(c){for(const f of frames)c.enqueue(new TextEncoder().encode(`data: ${f}\n\n`));c.close();}}),{status:200,headers:{'content-type':'text/event-stream'}});
const ok=text=>sse([JSON.stringify({choices:[{index:0,delta:{content:text}}]}),JSON.stringify({choices:[{index:0,delta:{},finish_reason:'stop'}]}),'[DONE]']);
const busy=()=>new Response('{"error":{"message":"rate limit"}}',{status:429,headers:{'retry-after':'18'}});
const env=o=>k=>o[k];
const routes=readFreeRouteChain(env({CATPAW_GEMINI_API_KEY:'g',CATPAW_GROQ_API_KEY:'q',CATPAW_MODEL_ROUTE_ORDER:'gemini,groq,openrouter'}));
const collect=async p=>{const out=[];for await(const e of p.stream({messages:[],system_prompt:'s',tools:[]}))out.push(e);return out;};
test('no extra key keeps frozen route; default order openrouter first',()=>{assert.equal(readFreeRouteChain(env({CATPAW_PRIVATE_MODEL_KEY:'o'})),null);assert.equal(readFreeRouteChain(env({CATPAW_PRIVATE_MODEL_KEY:'o',CATPAW_GEMINI_API_KEY:'g'})).routes[0].id,'openrouter');assert.equal(readConfig(env({})).route.id,'catpaw-free-consented-v1');});
test('chain route changes consented hash',()=>{const c=readConfig(env({CATPAW_GEMINI_API_KEY:'g'}));assert.equal(c.route.id,'catpaw-free-chain-v1');assert.notEqual(c.routeHash,readConfig(env({})).routeHash);});
test('gemini first, fails over on 429 before output',async()=>{const calls=[];const p=new FreeRouteChainProvider({...routes,fetchImpl:async url=>{calls.push(url);return calls.length===1?busy():ok('hi');}});const out=await collect(p);assert.match(calls[0],/generativelanguage/);assert.match(calls[1],/groq/);assert.deepEqual(out.map(e=>e.type),['text_delta','done']);});
test('no failover when disabled; retry-after surfaced',async()=>{const p=new FreeRouteChainProvider({...routes,autoFailover:false,fetchImpl:async()=>busy()});await assert.rejects(collect(p),e=>e.code==='rate_limited'&&e.retryAfterSeconds===18);});
test('never fails over after output',async()=>{let n=0;const p=new FreeRouteChainProvider({...routes,fetchImpl:async()=>{n++;return sse([JSON.stringify({choices:[{index:0,delta:{content:'a'}}]}),JSON.stringify({error:{code:429}})]);}});await assert.rejects(collect(p));assert.equal(n,1);});
test('developer preference reorders',async()=>{const calls=[];const p=new FreeRouteChainProvider({...routes,fetchImpl:async url=>{calls.push(url);return ok('x');}});await withRoutePreference('groq',()=>collect(p));assert.match(calls[0],/groq/);});
test('thinking summary hidden unless enabled',async()=>{const p=new FreeRouteChainProvider({...routes,fetchImpl:async()=>sse([JSON.stringify({choices:[{index:0,delta:{content:'plan',extra_content:{google:{thought:true}}}}]}),JSON.stringify({choices:[{index:0,delta:{content:'ans'},finish_reason:'stop'}]}),'[DONE]'])});const out=await collect(p);assert.deepEqual(out.map(e=>e.type),['text_delta','done']);assert.equal(out[0].text,'ans');});
test('thinking summary forwarded to capable clients',async()=>{const p=new FreeRouteChainProvider({...routes,fetchImpl:async()=>sse([JSON.stringify({choices:[{index:0,delta:{content:'plan',extra_content:{google:{thought:true}}}}]}),JSON.stringify({choices:[{index:0,delta:{content:'ans'},finish_reason:'stop'}]}),'[DONE]'])});const out=await withRoutePreference(null,()=>collect(p),{reasoningSummary:true});assert.deepEqual(out.map(e=>e.type),['thinking_delta','text_delta','done']);});
test('busy: one in-place retry when retry-after fits budget, no resend after output',async()=>{let n=0;const p=new FreeRouteChainProvider({...routes,autoFailover:false,fetchImpl:async()=>{n++;return n===1?new Response('{}',{status:429,headers:{'retry-after':'0'}}):ok('later');}});const out=await collect(p);assert.equal(n,2);assert.equal(out[0].text,'later');});
const agnesOnly=readFreeRouteChain(env({CATPAW_PRIVATE_MODEL_KEY:'o',CATPAW_AGNES_API_KEY:'a'}));
test('agnes: enabled only with explicit key, after openrouter by default, model override + billing note',()=>{
  assert.equal(readFreeRouteChain(env({CATPAW_PRIVATE_MODEL_KEY:'o',CATPAW_AGNES_MODEL:'agnes-2.5-pro'})),null);
  assert.deepEqual(agnesOnly.routes.map(r=>r.id),['openrouter','agnes']);
  const a=agnesOnly.routes[1];assert.equal(a.model,'agnes-3.0-flash');assert.equal(a.endpoint,'https://apihub.agnes-ai.com/v1/chat/completions');assert.equal(a.billing,'promo_free_flash_paid_pro');
  assert.equal(readFreeRouteChain(env({CATPAW_AGNES_API_KEY:'a',CATPAW_AGNES_MODEL:'agnes-2.5-flash'})).routes[0].model,'agnes-2.5-flash');
  assert.throws(()=>readFreeRouteChain(env({CATPAW_AGNES_API_KEY:'a',CATPAW_AGNES_MODEL:'gpt-4o'})));
  assert.deepEqual(readFreeRouteChain(env({CATPAW_PRIVATE_MODEL_KEY:'o',CATPAW_AGNES_API_KEY:'a',CATPAW_MODEL_ROUTE_ORDER:'agnes,openrouter'})).routes.map(r=>r.id),['agnes','openrouter']);
  assert.equal(readConfig(env({CATPAW_AGNES_API_KEY:'a'})).route.id,'catpaw-free-chain-v1');
});
test('agnes: openrouter busy (429) fails over to agnes before output; bearer auth; thinking off by default',async()=>{
  const calls=[];const p=new FreeRouteChainProvider({...agnesOnly,fetchImpl:async(url,init)=>{calls.push({url,init});return calls.length===1?busy():ok('agnes says hi');}});
  const out=await collect(p);
  assert.match(calls[0].url,/openrouter/);assert.equal(calls[1].url,'https://apihub.agnes-ai.com/v1/chat/completions');
  assert.equal(calls[1].init.headers.Authorization,'Bearer a');
  const body=JSON.parse(calls[1].init.body);assert.equal(body.model,'agnes-3.0-flash');assert.equal(body.stream,true);assert.deepEqual(body.chat_template_kwargs,{enable_thinking:false});assert.equal(body.provider,undefined);
  assert.deepEqual(out.map(e=>e.type),['text_delta','done']);assert.equal(out[0].text,'agnes says hi');
});
test('agnes: reasoning_content maps to reasoning_summary (thinking_delta) for capable clients',async()=>{
  let body;const p=new FreeRouteChainProvider({...agnesOnly,fetchImpl:async(url,init)=>{if(/openrouter/.test(url))return busy();body=JSON.parse(init.body);return sse([JSON.stringify({choices:[{index:0,delta:{reasoning_content:'step 1'}}]}),JSON.stringify({choices:[{index:0,delta:{content:'ans'},finish_reason:'stop'}]}),'[DONE]']);}});
  const out=await withRoutePreference(null,()=>collect(p),{reasoningSummary:true});
  assert.deepEqual(body.chat_template_kwargs,{enable_thinking:true});
  assert.deepEqual(out.map(e=>e.type),['thinking_delta','text_delta','done']);assert.equal(out[0].text,'step 1');
});
test('agnes: 402 quota maps to quota_exhausted and fails over; developer preference puts agnes first',async()=>{
  const calls=[];const p=new FreeRouteChainProvider({...agnesOnly,fetchImpl:async url=>{calls.push(url);return /agnes/.test(url)?new Response('{"error":{"message":"balance"}}',{status:402}):ok('or');}});
  const out=await withRoutePreference('agnes',()=>collect(p));
  assert.match(calls[0],/agnes/);assert.match(calls[1],/openrouter/);assert.equal(out[0].text,'or');
  assert.equal(p.observations[0].error,'quota_exhausted');
});
test('agnes: live-captured SSE shape (role chunk, reasoning_content, \\n\\n, usage chunk, [DONE])',async()=>{
  const ch=d=>JSON.stringify({id:'x',object:'chat.completion.chunk',model:'agnes-3.0-flash',choices:[{index:0,delta:d}]});
  const p=new FreeRouteChainProvider({...agnesOnly,fetchImpl:async url=>/openrouter/.test(url)?busy():sse([ch({role:'assistant',content:''}),ch({reasoning_content:'用户问'}),ch({reasoning_content:'1+1'}),ch({content:'\n\n'}),ch({content:'2'}),ch({content:'。'}),JSON.stringify({id:'x',model:'agnes-3.0-flash',choices:[{index:0,delta:{},finish_reason:'stop'}]}),JSON.stringify({id:'x',choices:[{index:0,delta:{}}],usage:{completion_tokens:27,completion_tokens_details:{reasoning_tokens:19}}}),'[DONE]'])});
  const out=await withRoutePreference(null,()=>collect(p),{reasoningSummary:true});
  assert.equal(out.filter(e=>e.type==='thinking_delta').map(e=>e.text).join(''),'用户问1+1');
  assert.equal(out.filter(e=>e.type==='text_delta').map(e=>e.text).join(''),'2。');
  assert.equal(out.at(-1).type,'done');assert.equal(p.observations.at(-1).actual_model,'agnes-3.0-flash');
});
