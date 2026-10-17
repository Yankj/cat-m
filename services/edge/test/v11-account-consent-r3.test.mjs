// v1.1 Round 3 (NoBug REVIEW Round 2 P2-a/P2-c): two-conversation account deny; one lock order for all consent writes,
// independent of the work-grant feature; deny vs conversation consent concurrently never deadlocks.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {consentId} from '../supabase/functions/_shared/consent.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
function gated(){let release,reached;const g={gate:new Promise(r=>release=r),reached:new Promise(r=>reached=r),n:0};g.release=release;
 g.stream=async function*(input){g.n++;if(g.n===2){reached();yield {type:'text_delta',text:'第一段'};await Promise.race([g.gate,new Promise(r=>input.signal?.addEventListener?.('abort',r))]);yield {type:'text_delta',text:'第二段'};}else yield {type:'text_delta',text:'好'};yield {type:'done',finish_reason:'stop'};};return g;}
async function setup(stream){const f=await fixture({stream});const acct=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/model-consent`,conv=cid=>`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
 const start=async cid=>{const c=(await f.json(await f.req(conv(cid)))).conversation,tid=randomUUID();const r=await f.req(conv(cid)+'/turns',{turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'你好'},context:[]});return {r,tid};};
 const turn=async cid=>{const {r,tid}=await start(cid);const body=await r.text();await f.runtime.chat.waitIdle();return {status:r.status,body,tid};};
 const account=async(decision,extra={})=>{const cur=await f.json(await f.req(acct));return f.req(acct,{decision,expected_revision:cur.consent?.revision??0,route_hash:f.config.routeHash,...extra});};
 const owner=f.runtime.facade.owner(f.scope),get=(kind,id)=>f.runtime.repository.transaction(tx=>tx.get(owner,kind,id));
 return {f,acct,conv,start,turn,account,owner,get};}
function recordLocks(f){const seen=[],orig=f.runtime.repository.transaction.bind(f.runtime.repository);
 f.runtime.repository.transaction=fn=>orig(tx=>{const lock=tx.lock.bind(tx);tx.lock=async(o,k,id)=>{seen.push(k);return lock(o,k,id);};return fn(tx);});
 return {seen,restore:()=>{f.runtime.repository.transaction=orig;}};}
const order=seen=>seen.filter((k,i)=>k!==seen[i-1]);
test('account deny with two relying conversations: running turn ends provider_consent_revoked, both need re-consent',async()=>{
 const g=gated(),{f,start,turn,account,get}=await setup(g.stream);await account('allow');
 const a=await f.newConversation(),b=await f.newConversation();assert.equal((await turn(a)).status,200,'first turn in A (stream #1)');
 const {r,tid}=await start(b);assert.equal(r.status,200);const body=r.text();await g.reached;
 assert.equal((await account('deny')).status,200);g.release();await body.catch(()=>{});await f.runtime.chat.waitIdle();
 const t=await get('native-chat-turns',tid);assert.equal(t.state,'failed');assert.equal(t.error.code,'provider_consent_revoked');
 assert.ok(!t.events.some(e=>e.data?.text==='第二段'));
 for(const cid of [a,b]){const x=await turn(cid);assert.equal(x.status,403,cid);assert.equal(JSON.parse(x.body).error.code,'provider_consent_required');
  assert.ok((await get('provider-consents',consentId(f.principal.subject_id,cid))).account_revoked_at);}
 await account('allow');for(const cid of [a,b])assert.equal((await turn(cid)).status,200,'re-consent restores both');
});
test('one lock order for every consent write: source-subject → account record → conversation(s), even without work grants',async()=>{
 const {f,acct,turn,account}=await setup(async function*(){yield {type:'text_delta',text:'好'};yield {type:'done',finish_reason:'stop'};});
 const saved=f.runtime.facade.workGrantService;f.runtime.facade.workGrantService=null; // ordering must not depend on the feature
 try{
  const rec=recordLocks(f);await account('allow');const a=await f.newConversation(),b=await f.newConversation();rec.restore();
  assert.deepEqual(order(rec.seen),['source-subject','provider-consents'],'account allow');
  f.runtime.facade.workGrantService=saved;assert.equal((await turn(a)).status,200);assert.equal((await turn(b)).status,200);f.runtime.facade.workGrantService=null;
  const p=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/`;const c=await f.newConversation();
  const r1=recordLocks(f);await f.json(await f.req(p+c+'/model-consent',{decision:'allow',expected_revision:0,route_hash:f.config.routeHash,apply_to:'account',expected_account_revision:1}));r1.restore();
  assert.deepEqual(order(r1.seen).slice(0,3),['source-subject','provider-consents','native-chat-conversations'],'conversation POST + apply_to');
  const r2=recordLocks(f);const cur=await f.json(await f.req(acct));await f.json(await f.req(acct,{decision:'deny',expected_revision:cur.consent.revision,route_hash:f.config.routeHash}));r2.restore();
  const o=order(r2.seen);assert.deepEqual(o.slice(0,3),['source-subject','provider-consents','native-chat-conversations'],'account deny');
  assert.ok(o.slice(2).every(k=>k==='native-chat-conversations'),'no lock taken out of order after the conversations: '+JSON.stringify(o));
 }finally{f.runtime.facade.workGrantService=saved;}
});
test('account deny racing a conversation consent POST: both settle (no deadlock), outcome consistent',async()=>{
 const {f,acct,turn,account}=await setup(async function*(){yield {type:'text_delta',text:'好'};yield {type:'done',finish_reason:'stop'};});
 await account('allow');const a=await f.newConversation();assert.equal((await turn(a)).status,200);const b=await f.newConversation();
 const cur=await f.json(await f.req(acct));
 const race=Promise.all([f.req(acct,{decision:'deny',expected_revision:cur.consent.revision,route_hash:f.config.routeHash}),f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${b}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash})]);
 const rs=await Promise.race([race,new Promise((_,j)=>setTimeout(()=>j(Error('deadlock/timeout')),5000))]);assert.deepEqual(rs.map(r=>r.status),[200,200]);
 assert.equal((await f.json(await f.req(acct))).granted,false);
 assert.equal((await turn(a)).status,403,'relied on account → re-consent');assert.equal((await turn(b)).status,200,'own conversation consent survives');
});
