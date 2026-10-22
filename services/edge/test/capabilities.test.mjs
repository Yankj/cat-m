import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {catCapabilities,CAPABILITY_PROMPT,CAPABILITY_LINK_TARGETS,renderCapabilityPrompt,isAllowedCapabilityLink,sanitizeCapabilityLinks,capabilityPromptFor,unavailableCapabilities} from '../supabase/functions/_shared/capabilities.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
const manifest=JSON.parse(readFileSync(new URL('../../../docs/product/capabilities/cat-capabilities.json',import.meta.url),'utf8'));

test('generated module mirrors the canonical manifest (run scripts/check-capabilities.py --write after editing it)',()=>{
 assert.deepEqual(JSON.parse(JSON.stringify(catCapabilities)),manifest);
});
test('manifest shape: unique ids, shipped/planned only, planned entries have no UI entry',()=>{
 const ids=manifest.capabilities.map(c=>c.id);assert.equal(new Set(ids).size,ids.length);
 for(const c of manifest.capabilities){assert.ok(['shipped','planned'].includes(c.status),c.id);assert.ok(c.name&&c.purpose,c.id);if(c.status==='planned'){assert.equal(c.ui_entry,null);assert.ok(c.planned_for);}else assert.ok(c.ui_entry?.anchor,c.id);}
 assert.deepEqual([...CAPABILITY_LINK_TARGETS].sort(),['memory','proactive','results','settings','tasks']);
});
test('prompt: identity, every shipped capability, planned features stated honestly, only manifest links',()=>{
 assert.match(CAPABILITY_PROMPT,/你是 cat/);assert.match(CAPABILITY_PROMPT,/不要编造/);
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
 const all={tools:[{function:{name:'calendar_create'}}],publicSourcesEnabled:true};
 assert.equal(capabilityPromptFor({},all),CAPABILITY_PROMPT);assert.equal(capabilityPromptFor(null,all),CAPABILITY_PROMPT);
 assert.equal(capabilityPromptFor({revision_target:{}},all),'');assert.equal(capabilityPromptFor({},{...all,imageTurn:true}),'');
});
const shippedSection=p=>p.slice(p.indexOf('# 已上线能力'),p.search(/# (这一轮不可用|计划中)/));
const gatedSection=p=>{const i=p.indexOf('# 这一轮不可用');return i<0?'':p.slice(i,p.indexOf('# 计划中'));};
test('turn-gated capabilities: web links only with publicSourcesEnabled, calendar only when calendar_create is offered',()=>{
 // Defaults are conservative: nothing offered => both are unavailable, stated honestly.
 assert.deepEqual(unavailableCapabilities(),['web_reading','calendar']);
 const none=capabilityPromptFor({});
 assert.equal(shippedSection(none).includes('阅读网页链接'),false);assert.equal(shippedSection(none).includes('写入日历'),false);
 assert.match(gatedSection(none),/阅读网页链接：现在没有开启，不能打开或读取链接内容/);assert.match(gatedSection(none),/写入日历：这一轮不能直接写入 iPhone 日历；不要说已经加好了/);
 assert.equal(none.includes('帮我总结这篇'),false,'no usage hint for an unavailable feature');
 // Public sources on, no device tools.
 const web=capabilityPromptFor({},{publicSourcesEnabled:true,tools:[{function:{name:'delegate_task'}},{function:{name:'calendar_list'}}]});
 assert.ok(shippedSection(web).includes('阅读网页链接'));assert.equal(shippedSection(web).includes('写入日历'),false);assert.match(gatedSection(web),/写入日历/);
 // Calendar tool offered, public sources off.
 const cal=capabilityPromptFor({},{publicSourcesEnabled:false,tools:[{function:{name:'calendar_create'}}]});
 assert.ok(shippedSection(cal).includes('写入日历'));assert.equal(shippedSection(cal).includes('阅读网页链接'),false);assert.match(gatedSection(cal),/阅读网页链接/);
 assert.equal(capabilityPromptFor({},{publicSourcesEnabled:'true',tools:[]}).includes('读取你发来的公开网页链接'),false,'only boolean true enables web reading');
 // Both on: same as the full manifest rendering, no unavailable section.
 const all=capabilityPromptFor({},{publicSourcesEnabled:true,tools:[{function:{name:'calendar_create'}}]});assert.equal(all,CAPABILITY_PROMPT);assert.equal(gatedSection(all),'');
 for(const p of [none,web,cal,all]){assert.ok(p.length<2500,String(p.length));const links=[...p.matchAll(/\]\((catpawm:\/\/[^)]+)\)/g)].map(m=>m[1]);assert.equal(links.length,5);}
});
test('manifest wording: no hardcoded quiet hours; memory depends on the memory toggle and consent',()=>{
 const pro=manifest.capabilities.find(c=>c.id==='proactive'),mem=manifest.capabilities.find(c=>c.id==='memory');
 assert.equal(/\d{1,2}:\d{2}/.test(JSON.stringify(pro)),false,pro.limits);assert.match(pro.limits,/以设置为准/);
 assert.match(mem.limits,/使用记忆/);assert.match(mem.limits,/同意/);
 assert.equal(/\d{1,2}:\d{2}\s*[–-]\s*\d{1,2}:\d{2}/.test(CAPABILITY_PROMPT),false);
});
test('chat turn system prompt carries the cat identity block',async()=>{
 const prompts=[];
 const f=await fixture({stream:async function*(input){prompts.push(input.system_prompt);yield {type:'text_delta',text:'我是 cat'};yield {type:'done',finish_reason:'stop'};}});
 const cid=await f.newConversation();
 await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 const path=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
 const c=(await f.json(await f.req(path))).conversation;
 const r=await f.runtime.api(new Request(H+path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify({turn_id:randomUUID(),expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text:'你能做什么？'},context:[]})}));
 assert.equal(r.status,200,await r.clone().text());await r.text();await f.runtime.chat.waitIdle();
 assert.ok(prompts.length>=1);assert.ok(prompts[0].includes('# 你是谁\n你是 cat'));
 // Fixture runtime: public sources off and no device tools => both turn-gated entries are listed as unavailable.
 assert.ok(prompts[0].includes(capabilityPromptFor({},{publicSourcesEnabled:false,tools:[]})));assert.match(prompts[0],/# 这一轮不可用[\s\S]*阅读网页链接：现在没有开启/);
});
