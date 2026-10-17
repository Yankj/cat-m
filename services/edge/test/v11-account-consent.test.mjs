// v1.1 (b): account-level model-route consent keyed by (subject_id, route_hash); per-conversation consent stays a fallback.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {accountConsentId,consentId} from '../supabase/functions/_shared/consent.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const stream=async function*(){yield {type:'text_delta',text:'好'};yield {type:'done',finish_reason:'stop'};};
async function setup(){const f=await fixture({stream});const acct=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/model-consent`;
 const conv=cid=>`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
 const turn=async(cid,auth)=>{const c=(await f.json(await f.req(conv(cid)))).conversation;const r=await f.req(conv(cid)+'/turns',{turn_id:randomUUID(),expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'你好'},context:[]},auth);const body=await r.text();await f.runtime.chat.waitIdle();return {status:r.status,body};};
 const grant=async(decision='allow')=>{const cur=await f.json(await f.req(acct));return f.json(await f.req(acct,{decision,expected_revision:cur.consent?.revision??0,route_hash:f.config.routeHash}));};
 return {f,acct,conv,turn,grant};}
const code=r=>JSON.parse(r.body).error?.code;
test('no consent anywhere: new conversation 403 provider_consent_required; GET reports granted:false',async()=>{
 const {f,acct,turn}=await setup();const g=await f.json(await f.req(acct));assert.deepEqual([g.granted,g.consent,g.route_hash],[false,null,f.config.routeHash]);
 const r=await turn(await f.newConversation());assert.equal(r.status,403);assert.equal(code(r),'provider_consent_required');
});
test('account consent: a NEW conversation on the same account + route needs no re-consent (no 403)',async()=>{
 const {f,acct,turn,grant}=await setup();const g=await grant();assert.equal(g.granted,true);assert.equal(g.consent.route_hash,f.config.routeHash);
 for(let i=0;i<2;i++){const cid=await f.newConversation();const r=await turn(cid);assert.equal(r.status,200,r.body);assert.match(r.body,/turn_completed/);
  const row=await f.runtime.repository.transaction(tx=>tx.get(f.runtime.facade.owner(f.scope),'provider-consents',consentId(f.principal.subject_id,cid)));assert.equal(row.source,'account');assert.equal(row.decision,'allow');}
 assert.equal((await f.json(await f.req(acct))).granted,true);
});
test('changed route_hash ⇒ account consent no longer applies ⇒ 403 (re-consent required)',async()=>{
 const {f,acct,turn,grant}=await setup();await grant();const cid=await f.newConversation();assert.equal((await turn(cid)).status,200);
 f.config.routeHash='0'.repeat(64);
 const r1=await turn(await f.newConversation());assert.equal(r1.status,403);assert.equal(code(r1),'provider_consent_required');
 const r2=await turn(cid);assert.equal(r2.status,403,'already-materialized conversation also needs re-consent for the new route');
 assert.equal((await f.json(await f.req(acct))).granted,false);
 await grant();assert.equal((await turn(await f.newConversation())).status,200);
});
test('a different account gets nothing from another account\'s consent (403), and cannot see ours',async()=>{
 const {f,turn}=await setup();
 const other=randomUUID();await f.runtime.repository.transaction(tx=>tx.put(f.runtime.facade.owner(f.scope),'provider-consents',{id:accountConsentId(other,f.config.routeHash),consent_scope:'account',scope_id:f.scope.scope_id,subject_id:other,route_hash:f.config.routeHash,revision:1,decision:'allow',sensitive_confirmed:false,updated_at:new Date().toISOString()}));
 const r=await turn(await f.newConversation());assert.equal(r.status,403);assert.equal(code(r),'provider_consent_required');
 // Our own grant is invisible to (and does not cover) another subject sharing the scope: GET is keyed by the caller's subject.
 const acct=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/model-consent`;await f.json(await f.req(acct,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const foreign=await f.json(await f.req(acct,undefined,'Bearer foreign-fixture'));assert.deepEqual([foreign.granted,foreign.consent],[false,null]);
});
test('per-conversation consent still works without account consent (fallback); per-conversation deny beats account allow',async()=>{
 const {f,turn,grant}=await setup();const cid=await f.newConversation();
 await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 assert.equal((await turn(cid)).status,200);assert.equal((await turn(await f.newConversation())).status,403,'per-conversation consent does not leak to other conversations');
 const denied=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${denied}/model-consent`,{decision:'deny',expected_revision:0,route_hash:f.config.routeHash}));
 await grant();assert.equal((await turn(await f.newConversation())).status,200);
 const c=await f.req(`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${denied}`);const r=await turn(denied).catch(e=>({status:409}));assert.notEqual(r.status,200,'explicit conversation deny wins');void c;
});
test('account revoke (deny) ⇒ conversations that relied on it need re-consent; own per-conversation consent survives',async()=>{
 const {f,turn,grant}=await setup();await grant();const viaAccount=await f.newConversation();assert.equal((await turn(viaAccount)).status,200);
 const own=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${own}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const d=await grant('deny');assert.equal(d.granted,false);
 const r=await turn(viaAccount);assert.equal(r.status,403);assert.equal(code(r),'provider_consent_required');
 assert.equal((await turn(await f.newConversation())).status,403);assert.equal((await turn(own)).status,200);
});
test('per-conversation POST with apply_to:"account" grants the account too; invalid apply_to rejected',async()=>{
 const {f,acct,turn}=await setup();const cid=await f.newConversation(),p=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`;
 const bad=await f.req(p,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash,apply_to:'everything'});assert.equal(bad.status,422);
 await f.json(await f.req(p,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash,apply_to:'account'}));
 assert.equal((await f.json(await f.req(acct))).granted,true);assert.equal((await turn(await f.newConversation())).status,200);
});
test('account POST validation: wrong route_hash 422 invalid_consent, stale expected_revision 409',async()=>{
 const {f,acct,grant}=await setup();const w=await f.req(acct,{decision:'allow',expected_revision:0,route_hash:'f'.repeat(64)});assert.equal(w.status,422);assert.equal((await w.json()).error.code,'invalid_consent');
 await grant();const s=await f.req(acct,{decision:'deny',expected_revision:0,route_hash:f.config.routeHash});assert.equal(s.status,409);
});
