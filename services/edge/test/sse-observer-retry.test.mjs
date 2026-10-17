import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {transientObserverError} from '../supabase/functions/_shared/core/src/chat-service.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
// Live v26/v28: the observer's read transaction hit Postgres 55P03 (lock_timeout)
// while the turn held the scope lock, and the SSE stream ended after turn_started.
const lockError=()=>Object.assign(new Error('canceling statement due to lock timeout'),{name:'PostgresError',code:'55P03'});
const stream=async function*(){await new Promise(r=>setTimeout(r,50));yield {type:'thinking_delta',text:'thinking'};yield {type:'text_delta',text:'hello'};yield {type:'done',finish_reason:'stop'};};
async function sse(f,{failGate=0,failRead=0,otherError=null}={}){
 const {scope,config,req,json}=f,chat=f.runtime.chat;chat.observeRetryBaseMs=1;
 const gate=chat.observationGate.bind(chat),read=chat.readTurn.bind(chat);let observing=false;
 chat.observationGate=async(...a)=>{if(failGate-->0)throw otherError??lockError();return gate(...a);};
 chat.readTurn=async(...a)=>{if(observing&&failRead-->0)throw lockError();return read(...a);};
 const cid=await f.newConversation(),privacy=`/catpaw/privacy/v1/scopes/${scope.scope_id}/conversations/${cid}/model-consent`;
 await json(await req(privacy,{decision:'allow',expected_revision:0,route_hash:config.routeHash}));
 const path=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations/${cid}`,c=(await json(await req(path))).conversation;
 const response=await f.runtime.api(new Request('https://memory-test.example.invalid'+path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Reasoning-Summary':'1'},body:JSON.stringify({turn_id:randomUUID(),expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'hi'},context:[]})}));
 assert.equal(response.status,200);observing=true;
 try{return (await response.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)).type);}catch{return 'stream_error';}
}
test('transient observer lock failures are retried and the SSE stream still reaches turn_completed',async()=>{
 const types=await sse(await fixture({stream}),{failGate:3,failRead:2});
 assert.deepEqual(types,['turn_started','reasoning_summary','text_delta','turn_completed']);
});
test('non-transient observer failures still interrupt the stream',async()=>{
 assert.equal(await sse(await fixture({stream}),{failGate:1,otherError:new Error('boom')}),'stream_error');
});
test('transient classification is limited to lock/serialization/timeout sqlstates',()=>{
 assert.equal(transientObserverError(lockError()),true);
 assert.equal(transientObserverError({name:'PostgresError',code:'23505'}),false);
 assert.equal(transientObserverError({name:'Error',code:'55P03'}),false);
});
