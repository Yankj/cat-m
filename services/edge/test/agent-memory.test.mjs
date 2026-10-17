import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {APPROVAL_CONTRACT} from '../supabase/functions/_shared/core/src/approval.mjs';
import {createAgentMemoryService} from '../supabase/functions/_shared/agent-memory/service.mjs';
import {createAgentMemoryStore} from '../supabase/functions/_shared/agent-memory/memory-store.mjs';
import {createAgentMemoryChatTools} from '../supabase/functions/_shared/agent-memory/chat-tools.mjs';
import {MEMORY_TOOLS,validateToolArgs,estimateTokens} from '../supabase/functions/_shared/agent-memory/contract.mjs';
import {toolApprovalPolicy} from '../supabase/functions/_shared/core/src/tools.mjs';
import {readConfig,readFeatureGate} from '../supabase/functions/_shared/config.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const H='https://memory-test.example.invalid';
const U1=randomUUID(),U2=randomUUID();
function svc({allow=()=>true,t0=Date.parse('2026-10-16T02:00:00Z')}={}){
 const clock={t:t0},store=createAgentMemoryStore();
 const service=createAgentMemoryService({store,allow,now:()=>clock.t,schedulerSecret:'tick-secret',verifyUser:async h=>h==='Bearer u1'?{sub:U1}:h==='Bearer u2'?{sub:U2}:null});
 const call=async(method,path,body,auth='Bearer u1',headers={})=>{const r=await service.handle(new Request(H+'/catpaw/agent-memory/v1'+path,{method,headers:{authorization:auth,'content-type':'application/json',...headers},body:body===undefined?undefined:JSON.stringify(body)}));return {status:r.status,body:await r.json()};};
 return {clock,store,service,call};
}
const consent=async(s,auth='Bearer u1')=>assert.equal((await s.call('PATCH','/settings',{consent:true,use_memory:true,auto_save:true},auth)).status,200);

test('contract: tool schemas, argument validation, approval policy (forget always asks)',()=>{
 assert.deepEqual(MEMORY_TOOLS.map(t=>t.function.name),['memory_save','memory_search','memory_update','memory_forget']);
 assert.throws(()=>validateToolArgs('memory_save',{kind:'journal',content:'x'}));assert.throws(()=>validateToolArgs('memory_save',{kind:'fact',content:''}));
 assert.throws(()=>validateToolArgs('memory_forget',{}));assert.throws(()=>validateToolArgs('memory_forget',{ids:[randomUUID()],query:'x'}));assert.throws(()=>validateToolArgs('memory_forget',{ids:['nope']}));
 validateToolArgs('memory_forget',{query:'咖啡'});validateToolArgs('memory_save',{kind:'preference',content:'喜欢靠窗座位',expires_at:'2027-01-01T00:00:00Z'});
 assert.equal(toolApprovalPolicy('memory_forget').approval,'always');for(const n of ['memory_save','memory_search','memory_update'])assert.equal(toolApprovalPolicy(n).approval,'never');
 assert.equal(estimateTokens('你好abcd'),3);
});

test('gate: default off, allowlist, and off means nothing is read or written',async()=>{
 assert.equal(readConfig(()=>undefined).agentMemory,'on');assert.equal(readConfig(n=>n==='CATPAW_AGENT_MEMORY_ENABLED'?'false':undefined).agentMemory,'off');assert.equal(readFeatureGate('allowlist'),'allowlist');
 const s=svc({allow:uid=>uid===U1});
 assert.equal((await s.call('GET','/settings',undefined,'Bearer u2')).status,404);
 assert.equal(await s.service.recallForTurn({subjectID:U2,query:'hi',turnID:randomUUID()}),null);
 assert.equal((await s.call('GET','/settings')).status,200);
});

test('consent: defaults false; enabling without consent is refused; revoking consent turns everything off',async()=>{
 const s=svc();
 assert.deepEqual((await s.call('GET','/settings')).body.settings,{use_memory:false,auto_save:false,consented_at:null});
 assert.equal((await s.call('PATCH','/settings',{use_memory:true})).body.error,'memory_consent_required');
 assert.equal((await s.call('POST','/items',{kind:'fact',content:'x'})).body.error,'memory_consent_required');
 await assert.rejects(s.service.executeTool(U1,'memory_save',{kind:'fact',content:'x'}),e=>e.code==='memory_consent_required');
 await consent(s);const r=await s.call('PATCH','/settings',{consent:false});assert.deepEqual(r.body.settings,{use_memory:false,auto_save:false,consented_at:null});
});

test('save emits memory_saved with an undo token; undo hard-deletes; replay of the same operation does not duplicate',async()=>{
 const s=svc();await consent(s);
 const op=randomUUID(),a=await s.service.executeTool(U1,'memory_save',{kind:'preference',content:'喜欢靠窗座位'},{operation_id:op,conversation_id:randomUUID(),turn_id:randomUUID()});
 assert.equal(a.result.status,'saved');assert.equal(a.events[0].type,'memory_saved');const {memory,undo_token}=a.events[0].data;
 assert.deepEqual(Object.keys(memory),['id','kind','content']);assert.equal(memory.content,'喜欢靠窗座位');assert.match(undo_token,/^[A-Za-z0-9_-]{32}$/);
 const b=await s.service.executeTool(U1,'memory_save',{kind:'preference',content:'喜欢靠窗座位'},{operation_id:op});assert.equal(b.result.id,memory.id);assert.deepEqual(b.events,[]);
 assert.equal(s.store._dump().rows.length,1);assert.equal(s.store._dump().rows[0].undo_token_hash.includes(undo_token),false,'only the hash is stored');
 assert.equal((await s.call('POST','/undo',{undo_token},'Bearer u2')).status,410,'other user cannot undo');
 assert.equal((await s.call('POST','/undo',{undo_token})).status,200);assert.equal(s.store._dump().rows.length,0);
 assert.equal((await s.call('POST','/undo',{undo_token})).status,410);
 await s.call('PATCH','/settings',{auto_save:false});assert.equal((await s.service.executeTool(U1,'memory_save',{kind:'fact',content:'y'})).result.status,'not_saved');
});

test('isolation (RLS equivalent): another user cannot list, search, read, edit, delete or forget',async()=>{
 const s=svc();await consent(s);await consent(s,'Bearer u2');
 const id=(await s.call('POST','/items',{kind:'fact',content:'我的护照号在抽屉里'})).body.memory.id;
 assert.deepEqual((await s.call('GET','/items',undefined,'Bearer u2')).body.memories,[]);
 assert.deepEqual((await s.call('GET','/items?q=护照',undefined,'Bearer u2')).body.memories,[]);
 assert.equal((await s.call('PATCH','/items/'+id,{content:'x'},'Bearer u2')).status,404);
 assert.equal((await s.call('DELETE','/items/'+id,undefined,'Bearer u2')).status,404);
 assert.equal((await s.service.executeTool(U2,'memory_forget',{ids:[id]})).result.count,0);
 assert.deepEqual((await s.service.executeTool(U2,'memory_search',{query:'护照'})).result.memories,[]);
 await assert.rejects(s.service.executeTool(U2,'memory_update',{id,content:'x'}),e=>e.code==='memory_not_found');
 assert.equal((await s.service.recallForTurn({subjectID:U2,query:'护照',turnID:randomUUID()})).ids.length,0);
 assert.equal((await s.call('GET','/items')).body.memories.length,1);assert.equal((await s.call('GET','/items',undefined,'')).status,401);
});

test('recall: pinned/profile within 1.5k tokens + lexical top-k with time decay; edits and deletes apply to the next recall',async()=>{
 const s=svc();await consent(s);
 const profile=(await s.call('POST','/items',{kind:'profile',content:'名字叫小林，住在上海'})).body.memory;
 for(let i=0;i<4;i++)await s.call('POST','/items',{kind:'profile',content:'很长的档案'.repeat(90)+i});
 const old=(await s.call('POST','/items',{kind:'preference',content:'咖啡只喝美式'})).body.memory;s.clock.t+=90*86400000;
 const fresh=(await s.call('POST','/items',{kind:'preference',content:'咖啡最近改喝拿铁'})).body.memory;
 const r=await s.service.recallForTurn({subjectID:U1,query:'帮我点一杯咖啡',turnID:randomUUID()});
 assert.ok(r.ids.includes(profile.id));assert.ok(r.ids.indexOf(fresh.id)<r.ids.indexOf(old.id),'fresh outranks old after decay');
 const headTokens=(await s.store.list(U1)).filter(x=>r.ids.includes(x.id)&&x.kind==='profile').reduce((n,x)=>n+estimateTokens(x.content)+6,0);assert.ok(headTokens<=1500);
 assert.ok(r.prompt.includes('咖啡最近改喝拿铁'));
 await s.call('PATCH','/items/'+fresh.id,{content:'不喝咖啡了，改喝茶'});await s.call('DELETE','/items/'+old.id);
 const n=await s.service.recallForTurn({subjectID:U1,query:'帮我点一杯咖啡 茶',turnID:randomUUID()});
 assert.equal(n.prompt.includes('拿铁'),false);assert.equal(n.prompt.includes('美式'),false);assert.equal(n.ids.includes(old.id),false);
 const e=(await s.call('POST','/items',{kind:'fact',content:'临时：本周在北京出差',expires_at:new Date(s.clock.t+1000).toISOString()})).body.memory;s.clock.t+=2000;
 assert.equal((await s.service.recallForTurn({subjectID:U1,query:'北京出差',turnID:randomUUID()})).ids.includes(e.id),false,'expired is not recalled');
});

test('temporary (ephemeral) turn: no recall, no journal fragment; journal compresses the day; clear-all needs confirmation',async()=>{
 const s=svc();await consent(s);
 await s.call('POST','/items',{kind:'profile',content:'名字叫小林'});
 const eph=await s.service.recallForTurn({subjectID:U1,query:'秘密话题',mode:'ephemeral',turnID:randomUUID()});
 assert.deepEqual([eph.enabled,eph.ids,eph.prompt],[false,[],'']);assert.equal(s.store._dump().fragments.length,0);
 await s.service.recallForTurn({subjectID:U1,query:'周末去杭州玩',turnID:randomUUID()});await s.service.recallForTurn({subjectID:U1,query:'订西湖边酒店',turnID:randomUUID()});
 assert.equal((await s.call('POST','/journal/tick',{day:'2026-10-16'},'',{'x-catpaw-scheduler-secret':'wrong'})).status,401);
 const t=await s.call('POST','/journal/tick',{day:'2026-10-16'},'',{'x-catpaw-scheduler-secret':'tick-secret'});assert.deepEqual(t.body,{day:'2026-10-16',written:1});
 const j=(await s.call('GET','/items?kind=journal')).body.memories;assert.equal(j.length,1);assert.match(j[0].content,/杭州.*西湖/);assert.equal(JSON.stringify(j).includes('秘密'),false);
 assert.equal((await s.call('POST','/clear',{})).body.error,'confirmation_required');
 assert.equal((await s.call('POST','/clear',{confirm:'delete_all'})).body.deleted,2);assert.equal(s.store._dump().rows.length,0);
});

// ---- chat integration (catpaw-api turn loop, in-memory repository + agent memory store) ----
function scripted(steps,probe){
 return async function*(input){probe.tools.push(input.tools.map(t=>t.function.name));probe.prompts.push(String(input.system_prompt??'')+JSON.stringify(input.messages.filter(m=>m.role==='system')));
  const last=input.messages.at(-1);if(last.role==='tool'){probe.results.push(JSON.parse(last.content));yield {type:'text_delta',text:'好'};yield {type:'done',finish_reason:'stop'};return;}
  const step=steps[0]&&input.tools.some(t=>t.function.name===steps[0].name)?steps.shift():null;if(!step){yield {type:'text_delta',text:'嗯'};yield {type:'done',finish_reason:'stop'};return;}
  yield {type:'tool_call',id:'call-'+randomUUID(),name:step.name,arguments:step.arguments};yield {type:'done',finish_reason:'tool_calls'};};
}
async function chatSetup(steps){
 const probe={tools:[],prompts:[],results:[]},f=await fixture({stream:scripted(steps,probe)}),store=createAgentMemoryStore();
 const service=createAgentMemoryService({store,allow:()=>true});
 f.runtime.chat.facade.agentMemory=service;f.runtime.chat.facade.gatedChatTools=new Map([...(f.runtime.chat.facade.gatedChatTools??[]),...createAgentMemoryChatTools({service})]);
 const cid=await f.newConversation();await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
 return {f,probe,store,service,path:`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`};
}
const sse=async r=>(await r.text()).split('\n\n').filter(b=>b.startsWith('data: ')).map(b=>JSON.parse(b.slice(6)));
async function send(s,text,headers={}){
 const c=(await s.f.json(await s.f.req(s.path))).conversation,tid=randomUUID();
 const r=await s.f.runtime.api(new Request(H+s.path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,...headers},body:JSON.stringify({turn_id:tid,expected_revision:c.revision,expected_grant_epoch:c.grant_epoch,message:{id:randomUUID(),text},context:[]})}));
 assert.equal(r.status,200);const events=await sse(r);await s.f.runtime.chat.waitIdle();return {tid,events};
}
test('chat: memory tools only after consent; memory_saved streams after tool_result; next turn recalls it (memory_recalled); edits apply next turn',async()=>{
 const s=await chatSetup([{name:'memory_save',arguments:{kind:'preference',content:'喜欢靠窗座位'}}]);
 await send(s,'你好');assert.equal(s.probe.tools[0].includes('memory_save'),false,'no consent → no memory tools');assert.equal(s.store._dump().rows.length,0);
 const owner=s.f.principal.subject_id;
 await s.service.patchSettings(owner,{consent:true,use_memory:true,auto_save:true});
 const a=await send(s,'记住我喜欢靠窗座位');const types=a.events.map(e=>e.type);
 assert.ok(types.indexOf('memory_saved')===types.indexOf('tool_result')+1,types.join(','));
 const saved=a.events.find(e=>e.type==='memory_saved');assert.equal(saved.data.memory.content,'喜欢靠窗座位');assert.ok(saved.data.undo_token);assert.equal(saved.conversation_id,a.events[0].conversation_id);assert.equal(saved.turn_id,a.tid);
 const b=await send(s,'帮我订靠窗座位');const rec=b.events.find(e=>e.type==='memory_recalled');assert.deepEqual(rec.data.ids,[saved.data.memory.id]);assert.ok(s.probe.prompts.at(-1).includes('喜欢靠窗座位'));
 const snap=(await s.f.json(await s.f.req(s.path+'/turns/'+b.tid))).turn;assert.equal(snap.agent_memory,undefined,'recall snapshot is not projected');
 await s.service.update(owner,saved.data.memory.id,{content:'喜欢过道座位'});await send(s,'帮我订座位');
 assert.equal(s.probe.prompts.at(-1).includes('靠窗'),false);assert.ok(s.probe.prompts.at(-1).includes('过道'));
});
test('chat: temporary conversation header → no recall, no tools, no rows; forget suspends with a card listing the hits',async()=>{
 const s=await chatSetup([{name:'memory_forget',arguments:{query:'座位'}}]);const owner=s.f.principal.subject_id;
 await s.service.patchSettings(owner,{consent:true,use_memory:true,auto_save:true});await s.service.save(owner,{kind:'preference',content:'喜欢靠窗座位'});
 const e=await send(s,'这次不要记住任何东西：座位',{'X-Catpaw-Memory-Mode':'ephemeral'});
 assert.equal(e.events.some(x=>x.type==='memory_recalled'),false);assert.equal(s.probe.tools.at(-1).some(n=>n.startsWith('memory_')),false);assert.equal(s.probe.prompts.at(-1).includes('靠窗'),false);
 assert.equal(s.store._dump().rows.length,1);assert.equal(s.store._dump().fragments.length,0);
 const f=await send(s,'忘掉我的座位偏好');const req=f.events.find(x=>x.type==='approval_requested');assert.equal(req.data.tool,'memory_forget');assert.match(req.data.summary,/靠窗座位/);
 assert.equal(s.store._dump().rows.length,1,'nothing deleted before the decision');
 const r=await s.f.runtime.api(new Request(H+s.path+'/turns/'+f.tid+'/interrupts/'+req.data.interrupt_id+'/decision',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json'},body:JSON.stringify({operation_id:randomUUID(),decision:'approve',args_hash:req.data.args_hash})}));
 assert.equal(r.status,200);await sse(r);await s.f.runtime.chat.waitIdle();assert.equal(s.store._dump().rows.length,0);assert.equal(s.probe.results.at(-1).count,1);
});
