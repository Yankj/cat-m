import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {CATPAW_CAPABILITIES,CAPABILITY_PROMPT,CAPABILITY_LINK_TARGETS,renderCapabilityPrompt,isAllowedCapabilityLink,sanitizeCapabilityLinks,capabilityPromptFor} from '../supabase/functions/_shared/capabilities.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
const manifest=JSON.parse(readFileSync(new URL('../../../docs/product/capabilities/catpaw-capabilities.json',import.meta.url),'utf8'));

test('generated module mirrors the canonical manifest (run scripts/check-capabilities.py --write after editing it)',()=>{
 assert.deepEqual(JSON.parse(JSON.stringify(CATPAW_CAPABILITIES)),manifest);
});
test('manifest shape: unique ids, shipped/planned only, planned entries have no UI entry',()=>{
 const ids=manifest.capabilities.map(c=>c.id);assert.equal(new Set(ids).size,ids.length);
 for(const c of manifest.capabilities){assert.ok(['shipped','planned'].includes(c.status),c.id);assert.ok(c.name&&c.purpose,c.id);if(c.status==='planned'){assert.equal(c.ui_entry,null);assert.ok(c.planned_for);}else assert.ok(c.ui_entry?.anchor,c.id);}
 assert.deepEqual([...CAPABILITY_LINK_TARGETS].sort(),['memory','proactive','results','settings','tasks']);
});
test('prompt: identity, every shipped capability, planned features stated honestly, only manifest links',()=>{
 assert.match(CAPABILITY_PROMPT,/你是 Catpaw/);assert.match(CAPABILITY_PROMPT,/不要编造/);
 for(const c of manifest.capabilities)assert.ok(CAPABILITY_PROMPT.includes(c.name),c.id);
 assert.match(CAPABILITY_PROMPT,/计划中[^\n]*\n[\s\S]*读取 Gmail：还没上线/);
 const links=[...CAPABILITY_PROMPT.matchAll(/\]\((catpawm:\/\/[^)]+)\)/g)].map(m=>m[1]);
 assert.equal(links.length,5);for(const l of links)assert.ok(isAllowedCapabilityLink(l),l);
 assert.ok(CAPABILITY_PROMPT.length<2500,String(CAPABILITY_PROMPT.length));
 assert.equal(renderCapabilityPrompt(manifest),CAPABILITY_PROMPT);
});
test('link allowlist and sanitizer',()=>{
 assert.ok(isAllowedCapabilityLink('catpawm://memory'));
 for(const bad of ['catpawm://debug','catpawm://proactive/debug','catpawm://conversation/x','https://memory','catpawm://memory?x=1','',null])assert.equal(isAllowedCapabilityLink(bad),false,String(bad));
 assert.equal(sanitizeCapabilityLinks('看 [打开记忆](catpawm://memory) 和 [调试](catpawm://proactive/debug) [官网](https://x.example)'),'看 [打开记忆](catpawm://memory) 和 调试 [官网](https://x.example)');
});
test('turn selection: revision/explain and image turns keep their own contracts',()=>{
 assert.equal(capabilityPromptFor({}),CAPABILITY_PROMPT);assert.equal(capabilityPromptFor(null),CAPABILITY_PROMPT);
 assert.equal(capabilityPromptFor({revision_target:{}}),'');assert.equal(capabilityPromptFor({},{imageTurn:true}),'');
});
test('chat turn system prompt carries the Catpaw identity block',async()=>{
 const prompts=[];
 const f=await fixture({stream:async function*(input){prompts.push(input.system_prompt);yield {type:'text_delta',text:'我是 Catpaw'};yield {type:'done',finish_reason:'stop'};}});
 const cid=await f.newConversation();
 await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const path=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
 const c=(await f.json(await f.req(path))).conversation;
 const r=await f.runtime.api(new Request(H+path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify({turn_id:randomUUID(),expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'你能做什么？'},context:[]})}));
 assert.equal(r.status,200,await r.clone().text());await r.text();await f.runtime.chat.waitIdle();
 assert.ok(prompts.length>=1);assert.ok(prompts[0].includes(CAPABILITY_PROMPT));
});
