import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {revisionWorkHTTPFixture} from './fixtures/revision-work-http-fixture.mjs';
import {V22_ROUTES} from './fixtures/v22-routes.mjs';

// Every route the live v22 bundle answered must still reach a handler in the
// maintained runtime: a router miss is a bare 404 not_found / route_not_supported.
const ROUTER_MISS=new Set(['not_found','route_not_supported']);
test('every v22 route is handled by the maintained runtime',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const ids={scope:f.scope.scope_id,cid:f.cid,turn:f.binding.turn_id,run:f.run.id,any:randomUUID()};
  const call=async(route,auth)=>{
   const path=route.path.replace(/\{(\w+)\}/g,(_,k)=>ids[k]??ids.any);
   const response=await f.runtime.api(new Request('https://offline.example.invalid'+path,{method:route.method,headers:{Authorization:auth,'Content-Type':'application/json'},...route.method==='POST'?{body:JSON.stringify(route.body??{})}:{}}));
   const text=await response.text();let code=null;try{const v=JSON.parse(text);code=v.error?.code??v.code??null;}catch{}
   return response.status===404&&ROUTER_MISS.has(code);
  };
  // Random resource ids can 404 inside a handler; a principal outside the scope
  // is refused by the handler (403) but would still be a 404 on a router miss.
  const missed=async route=>await call(route,'Bearer original')&&await call(route,'Bearer outside');
  const misses=[];for(const route of V22_ROUTES)if(await missed(route))misses.push(`${route.method} ${route.path}`);
  assert.equal(await missed({method:'GET',path:'/catpaw/v1/scopes/{scope}/no-such-route/{any}'}),true,'negative control must be detected');
  assert.equal(await missed({method:'GET',path:'/catpaw/chat/v1/scopes/{scope}/no-such-route'}),true,'negative control must be detected');
  assert.deepEqual(misses,[]);
 }finally{f.stop();}
});
test('readyz and image-model-route expose v22 vision fields',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const ready=await f.json(await f.req('/readyz'));
  assert.equal(typeof ready.chat_capabilities.image_input,'boolean');assert.ok(ready.chat_capabilities.vision_contract);
  assert.ok(ready.chat_capabilities.memory&&ready.chat_capabilities.followups,'maintained capabilities retained');
  const route=await f.json(await f.req('/catpaw/privacy/v1/image-model-route'));
  assert.equal(route.consent_default,'deny');assert.equal(route.non_sensitive_confirmation_required,true);assert.ok(route.capability&&'route_hash' in route);
 }finally{f.stop();}
});
