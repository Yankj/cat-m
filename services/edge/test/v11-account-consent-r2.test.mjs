// v1.1 Round 2 (NoBug REVIEW B1, P1-1, P1-2, P2): account consent revoke is immediate everywhere; CAS on account writes;
// sensitive_confirmed follows the account's current value (stricter wins); consent writes need a live session.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {assertConsent,consentId,effectiveConsent} from '../supabase/functions/_shared/consent.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
function gated(){let release,reached;const g={gate:new Promise(r=>release=r),reached:new Promise(r=>reached=r)};g.release=release;
 g.stream=async function*(input){reached();yield {type:'text_delta',text:'第一段'};await Promise.race([g.gate,new Promise(r=>input.signal?.addEventListener?.('abort',r))]);yield {type:'text_delta',text:'第二段'};yield {type:'done',finish_reason:'stop'};};return g;}
async function setup(stream){const f=await fixture({stream:stream??(async function*(){yield {type:'text_delta',text:'好'};yield {type:'done',finish_reason:'stop'};})});
 const acct=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/model-consent`,conv=cid=>`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
 const start=async cid=>{const c=(await f.json(await f.req(conv(cid)))).conversation,tid=randomUUID();const r=await f.req(conv(cid)+'/turns',{turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'你好'},context:[]});return {r,tid};};
 const turn=async cid=>{const {r,tid}=await start(cid);const body=await r.text();await f.runtime.chat.waitIdle();return {status:r.status,body,tid};};
 const account=async(decision,extra={})=>{const cur=await f.json(await f.req(acct));return f.req(acct,{decision,expected_revision:cur.consent?.revision??0,route_hash:f.config.routeHash,...extra});};
 const owner=f.runtime.facade.owner(f.scope),row=cid=>f.runtime.repository.transaction(tx=>tx.get(owner,'provider-consents',consentId(f.principal.subject_id,cid)));
 return {f,acct,conv,start,turn,account,owner,row};}
test('B1: account deny aborts the running turn of a conversation relying on account consent (provider_consent_revoked)',async()=>{
 const g=gated(),{f,conv,start,account}=await setup(g.stream);assert.equal((await account('allow')).status,200);
 const cid=await f.newConversation(),{r,tid}=await start(cid);assert.equal(r.status,200);const body=r.text();await g.reached;
 assert.equal((await account('deny')).status,200);g.release();await body.catch(()=>{});await f.runtime.chat.waitIdle();void conv;
 const stored=await f.runtime.repository.transaction(tx=>tx.get(f.runtime.facade.owner(f.scope),'native-chat-turns',tid));
 assert.equal(stored.state,'failed');assert.equal(stored.error.code,'provider_consent_revoked');
 assert.ok(!stored.events.some(e=>e.type==='text_delta'&&e.data?.text==='第二段'),'no model output after revoke');
});
test('B1: after account deny every assertConsent caller (task tick / revision / work grant), plan read and observation reject; new turns 403',async()=>{
 const {f,conv,turn,account,owner,row}=await setup();await account('allow');const cid=await f.newConversation();const t=await turn(cid);assert.equal(t.status,200);
 const before=await row(cid);const source={subject_id:f.principal.subject_id,scope_id:f.scope.scope_id,consent_revision:before.revision};
 await f.runtime.repository.transaction(tx=>assertConsent(tx,owner,source,cid,f.config.routeHash));
 // an active delegation + task bound to this conversation
 const did=randomUUID(),taskId=randomUUID();await f.runtime.repository.transaction(async tx=>{await tx.put(owner,'catpaw-delegations',{id:did,conversation_id:cid,state:'active',revision:1,grant_epoch:1});await tx.put(owner,'tasks',{id:taskId,status:'queued',state:{catpaw:{delegation_id:did}},updatedAt:new Date().toISOString()});});
 await account('deny');
 await assert.rejects(f.runtime.repository.transaction(tx=>assertConsent(tx,owner,source,cid,f.config.routeHash)),e=>e.status===403&&e.code==='provider_consent_required');
 const eff=await f.runtime.repository.transaction(tx=>effectiveConsent(tx,owner,f.principal.subject_id,cid,f.config.routeHash));assert.notEqual(eff.decision,'allow');
 const [d,task]=await f.runtime.repository.transaction(async tx=>[await tx.get(owner,'catpaw-delegations',did),await tx.get(owner,'tasks',taskId)]);
 assert.equal(d.state,'revoked');assert.equal(task.status,'cancelled');
 assert.ok((await row(cid)).revision>before.revision,'frozen consent_revision invalidated');
 const r=await turn(cid);assert.equal(r.status,403);assert.equal(JSON.parse(r.body).error.code,'provider_consent_required');
 assert.equal((await turn(await f.newConversation())).status,403);
 // re-grant: old frozen revision stays dead, new turns work again
 await account('allow');await assert.rejects(f.runtime.repository.transaction(tx=>assertConsent(tx,owner,source,cid,f.config.routeHash)));
 assert.equal((await turn(cid)).status,200);void conv;
});
test('P1-1: concurrent account POSTs with the same expected_revision — exactly one wins, the other 409',async()=>{
 const {f,acct}=await setup();const body=d=>({decision:d,expected_revision:0,route_hash:f.config.routeHash});
 const rs=await Promise.all([f.req(acct,body('allow')),f.req(acct,body('deny'))]);assert.deepEqual(rs.map(r=>r.status).sort(),[200,409]);
 const g=await f.json(await f.req(acct));assert.equal(g.consent.revision,1);
});
test('P1-1: apply_to:"account" is CAS-checked with expected_account_revision',async()=>{
 const {f,account}=await setup();await account('allow');const cid=await f.newConversation(),p=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`;
 const stale=await f.req(p,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash,apply_to:'account',expected_account_revision:0});assert.equal(stale.status,409);
 assert.equal((await f.req(p,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash,apply_to:'account',expected_account_revision:1})).status,200);
 assert.equal((await f.req(p,{decision:'deny',expected_revision:1,route_hash:f.config.routeHash,expected_account_revision:2})).status,422,'expected_account_revision only with apply_to');
});
test('P1-2: sensitive_confirmed follows the account\'s current value (narrowing applies immediately, widening at next admission); apply_to never widens it',async()=>{
 const {f,turn,account,owner,row}=await setup();await account('allow',{sensitive_confirmed:true});const cid=await f.newConversation();assert.equal((await turn(cid)).status,200);
 const eff=()=>f.runtime.repository.transaction(tx=>effectiveConsent(tx,owner,f.principal.subject_id,cid,f.config.routeHash));
 assert.equal((await eff()).sensitive_confirmed,true);
 await account('allow',{sensitive_confirmed:false});assert.equal((await eff()).sensitive_confirmed,false,'narrowed before any new admission');
 assert.equal((await turn(cid)).status,200);assert.equal((await row(cid)).sensitive_confirmed,false);
 await account('allow',{sensitive_confirmed:true});assert.equal((await turn(cid)).status,200);assert.equal((await row(cid)).sensitive_confirmed,true);
 // apply_to from a conversation with sensitive_confirmed:true does not widen the account
 const g=await setup();const c2=await g.f.newConversation();await g.f.json(await g.f.req(`/catpaw/privacy/v1/scopes/${g.f.scope.scope_id}/conversations/${c2}/model-consent`,{decision:'allow',expected_revision:0,route_hash:g.f.config.routeHash,sensitive_confirmed:true,apply_to:'account',expected_account_revision:0}));
 const a=await g.f.json(await g.f.req(g.acct));assert.equal(a.granted,true);assert.equal(a.consent.sensitive_confirmed,false);assert.equal(a.applies_to,'all_conversations');
 assert.equal((await g.row(c2)).sensitive_confirmed,true,'kept for that conversation only');
});
test('P2: consent writes are rejected for a signed-out / revoked session',async()=>{
 const {f,acct}=await setup();const cid=await f.newConversation();f.setSourceActive(false);
 const a=await f.req(acct,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash});assert.ok(a.status>=400,String(a.status));// fixture source checker answers 409 grant_conflict; prod assertSourceAuthority answers 401 session_revoked
 const c=await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash});assert.ok(c.status>=400,String(c.status));
 f.setSourceActive(true);assert.equal((await f.json(await f.req(acct))).consent,null,'nothing was written');
});
