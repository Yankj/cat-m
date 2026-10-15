import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
import {hash,ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
const NAME='propose_memory_v1',CONTRACT='catpaw.memory-proposal.v1';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const args=(text,scope='workspace')=>({candidates:[{kind:'preference',predicate:'drink.preference',value:'coffee',scope,evidence:{span_start:0,span_end:text.length}}]});
const proposal=(input,scope='workspace')=>({type:'tool_call',id:'memory-call-1',name:NAME,arguments:args(input.messages.at(-1).content,scope)});
const stream=async function*(input){if(input.tools.some(t=>t.function.name===NAME)){yield proposal(input);yield {type:'done',finish_reason:'tool_calls'};}else {yield {type:'text_delta',text:'Named synthetic answer'};yield {type:'done',finish_reason:'stop'};}};
const enabled=async f=>f.json((await f.post({type:'set_enabled',enabled:true})).response);
const rows=(f,kind)=>f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,s=>s.list(kind)));
const storedTurn=(f,id)=>f.repository.transaction(tx=>tx.get(f.runtime.facade.owner(f.scope),'native-chat-turns',id));
const confirm=async(f,c)=>f.json((await f.post({type:'confirm',candidate_id:c.id,expected_version:c.version,allow_relearn:false,sensitive_consent:false})).response);
test('natural conversation proposal is current-source-only, reviewable, confirmed separately, then used by a new conversation',async()=>{
 const f=await fixture({memoryProposals:true,stream});await enabled(f);const cid=await f.newConversation(),text='I prefer coffee; remember this for future conversations.';
 const turn=await f.send(cid,text);assert.equal(turn.state,'completed');assert.equal(f.calls.length,1,'candidate receipt needs no second model call');
 const event=turn.events.find(e=>e.type==='tool_result'&&e.data.name===NAME);assert.ok(event);const receipt=event.data.result;
 assert.equal(receipt.contract,CONTRACT);assert.equal(receipt.confirmed,false);assert.equal(receipt.status,'proposed');assert.equal(receipt.turn_id,turn.id);assert.equal(receipt.conversation_id,cid);assert.equal(receipt.scope_id,f.scope.scope_id);
 const state=await f.state();assert.equal(state.claims.length,0);assert.equal(state.candidates.length,1);const c=state.candidates[0];assert.equal(c.assertion,'inferred');assert.deepEqual(c.conditions,{});assert.equal(c.source_hash,hash(text));assert.equal(c.source_id,receipt.source_id);assert.deepEqual(receipt.candidates,[{id:c.id,version:1}]);assert.equal(JSON.stringify(receipt).includes('coffee'),false);
 const source=(await f.json(await f.req(f.base+'/sources/'+c.source_id))).source;assert.equal(source.text,text);assert.equal(source.type,'user_message');assert.equal(turn.memory_extraction,undefined);assert.equal(turn.memory_proposal_call,undefined);assert.equal(turn.source_sensitivity,undefined);
 const raw=await storedTurn(f,turn.id);assert.equal(raw.memory_extraction.source_id,c.source_id);assert.ok(raw.memory_extraction.lease_id);
 await confirm(f,c);assert.equal((await f.state()).claims.length,1);
 // This next provider call deliberately answers without proposing another memory.
 const next=await f.send(await f.newConversation(),'What coffee drink do I prefer?');assert.equal(next.state,'completed');assert.equal(f.calls[1].provider_context.memory_context.claims[0].value,'coffee');
 assert.ok(turn.events.some(e=>e.type==='text_delta'&&e.data.text.includes('待确认')));
});
test('default opt-out and disabled model memory route do not offer extraction tools or stage a claim',async()=>{
 for(const routeDisabled of [false,true]){
  const f=await fixture({memoryProposals:true,stream});if(routeDisabled){await enabled(f);f.runtime.memoryContextEnabled=false;}
  const turn=await f.send(await f.newConversation(),'Remember coffee please');assert.equal(turn.state,'completed');assert.equal(f.calls[0].tools.some(t=>t.function.name===NAME),false);assert.deepEqual((await f.state()).candidates,[]);assert.equal((await storedTurn(f,turn.id)).memory_extraction,undefined);
 }
});
test('conversation-only proposal cannot affect a different conversation',async()=>{
 let count=0;const f=await fixture({memoryProposals:true,stream:async function*(input){if(++count===1){yield proposal(input,'conversation');yield {type:'done',finish_reason:'tool_calls'};}else{yield {type:'text_delta',text:'Named synthetic answer'};yield {type:'done',finish_reason:'stop'};}}});await enabled(f);const cid=await f.newConversation();await f.send(cid,'I prefer coffee here');const c=(await f.state()).candidates[0];assert.deepEqual(c.conditions,{conversation_id:cid});await confirm(f,c);
 await f.send(await f.newConversation(),'coffee preference');assert.deepEqual(f.calls[1].provider_context.memory_context.claims,[]);
});
test('incomplete terminal and mixed tool rounds create no candidates and no delegated tasks',async()=>{
 for(const mode of ['incomplete','mixed','duplicate','invalid_scope']){
  const f=await fixture({memoryProposals:true,stream:async function*(input){const p=proposal(input);if(mode==='invalid_scope')p.arguments.candidates[0].scope=randomUUID();yield p;if(mode==='mixed')yield {type:'tool_call',id:'status-2',name:'agent_status',arguments:{}};if(mode==='duplicate')yield {...p,id:'memory-call-2'};if(mode!=='incomplete')yield {type:'done',finish_reason:'tool_calls'};}});await enabled(f);
  const turn=await f.send(await f.newConversation(),'I prefer coffee');assert.notEqual(turn.state,'completed',mode);assert.deepEqual((await f.state()).candidates,[],mode);assert.deepEqual(turn.task_bindings,[],mode);assert.equal((await rows(f,'facts')).length,0,mode);
 }
});
test('generation change or original source revocation while the provider is pending fences all candidate writes',async()=>{
 for(const mode of ['generation','source']){
  let mutate;const f=await fixture({memoryProposals:true,stream:async function*(input){await mutate();yield proposal(input);yield {type:'done',finish_reason:'tool_calls'};}});await enabled(f);
  mutate=async()=>{if(mode==='generation')await f.json((await f.post({type:'set_enabled',enabled:false})).response);else f.setSourceActive(false);};
  const cid=await f.newConversation();let tid;try{const turn=await f.send(cid,'I prefer coffee');tid=turn.id;assert.notEqual(turn.state,'completed');}catch(error){assert.equal(mode,'source');}
  assert.equal((await rows(f,'candidates')).length,0);assert.equal((await rows(f,'facts')).length,0);
 }
});
test('cold original turn GET recovers the exact proposal receipt without extraction or provider replay',async()=>{
 const f=await fixture({memoryProposals:true,stream});await enabled(f);const cid=await f.newConversation(),turn=await f.send(cid,'I prefer coffee'),before=f.repository.snapshot(),cold=await f.restore();
 assert.ok(turn.memory_proposal_receipt);
 const path='/catpaw/chat/v1/scopes/'+f.scope.scope_id+'/conversations/'+cid+'/turns/'+turn.id;
 const recovered=(await cold.json(await cold.req(path))).turn;assert.deepEqual(recovered.memory_proposal_receipt,turn.memory_proposal_receipt);assert.deepEqual(recovered.events,turn.events);assert.equal(recovered.memory_extraction,undefined);assert.equal(cold.calls.length,0);assert.deepEqual(cold.repository.snapshot(),before);
});
test('sensitive conversation source keeps its classification; confirmation requires a new explicit sensitive decision',async()=>{
 const f=await fixture({memoryProposals:true,stream});await enabled(f);await f.send(await f.newConversation(),'medical record: fictional coffee preference',{sensitive:true});const c=(await f.state()).candidates[0];assert.ok(c);const source=(await rows(f,'sources')).find(s=>s.id===c.source_id);assert.equal(source.sensitivity,'sensitive');
 const rejected=await f.post({type:'confirm',candidate_id:c.id,expected_version:1,allow_relearn:false,sensitive_consent:false});assert.equal(rejected.response.status,409);assert.equal((await f.state()).claims.length,0);
 await f.json((await f.post({type:'confirm',candidate_id:c.id,expected_version:1,allow_relearn:false,sensitive_consent:true})).response);assert.equal((await f.state()).claims.length,1);
});

test('legacy client keeps its exact admission hash and tools; new client capability is frozen for original POST replay',async()=>{
 for(const modern of [false,true]){
  const f=await fixture({memoryProposals:modern,stream});await enabled(f);const cid=await f.newConversation(),turn=await f.send(cid,'I prefer coffee'),raw=await storedTurn(f,turn.id),path='/catpaw/chat/v1/scopes/'+f.scope.scope_id+'/conversations/'+cid+'/turns';
  assert.equal(f.calls[0].tools.some(t=>t.function.name===NAME),modern);
  const same=await f.req(path,raw.input);assert.equal(same.status,200);const replay=await same.json();assert.equal(replay.replayed,true);assert.equal(f.calls.length,1);
  const direct=contract=>f.runtime.api(new Request('https://memory-test.example.invalid'+path,{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json',...contract?{'X-Catpaw-Memory-Proposal-Contract':contract}:{}},body:JSON.stringify(raw.input)}));
  const changed=await direct(modern?null:CONTRACT);assert.equal(changed.status,409);assert.equal((await changed.json()).error.code,'turn_conflict');
  const unsupported=await direct('catpaw.memory-proposal.v999');assert.equal(unsupported.status,422);assert.equal(f.calls.length,1);
  if(!modern){const trusted=await f.runtime.chat.scoped('Bearer memory-fixture',f.scope.scope_id);assert.equal(raw.admission_hash,hash({input:raw.input,conversation_id:cid,scope:trusted.scope,subject:f.principal.subject_id,model:f.runtime.chat.provider.identity}));assert.deepEqual((await f.state()).candidates,[]);}
 }
});
test('candidate, job completion, and public receipt roll back as one transaction on late storage or source denial',async()=>{
 for(const mode of ['storage','authority']){
  const f=await fixture({memoryProposals:true,stream});await enabled(f);const original=f.runtime.chat.integration.proposeMemory;
  f.runtime.chat.integration.proposeMemory=async(...input)=>{const result=await original(...input);if(mode==='storage')throw new ApiError(503,'named_memory_receipt_storage_failure');f.setSourceActive(false);return result;};
  const cid=await f.newConversation();try{const turn=await f.send(cid,'I prefer coffee');assert.notEqual(turn.state,'completed');assert.equal(turn.memory_proposal_receipt,undefined);assert.equal(turn.events.some(e=>e.type==='tool_result'&&e.data.name===NAME),false);}catch(error){assert.equal(mode,'authority');}
  assert.deepEqual(await rows(f,'candidates'),[]);assert.deepEqual(await rows(f,'facts'),[]);assert.equal((await rows(f,'jobs')).some(j=>j.status==='done'||j.status==='leased'),false);assert.equal(f.calls.length,1);
 }
});

test('duplicate model candidates yield one reviewable reference, not a permanently undecodable receipt',async()=>{
 const f=await fixture({memoryProposals:true,stream:async function*(input){const call=proposal(input);call.arguments.candidates.push(structuredClone(call.arguments.candidates[0]));yield call;yield {type:'done',finish_reason:'tool_calls'};}});await enabled(f);const turn=await f.send(await f.newConversation(),'I prefer coffee');assert.equal(turn.state,'completed');assert.equal((await f.state()).candidates.length,1);assert.equal(turn.memory_proposal_receipt.candidates.length,1);assert.equal(new Set(turn.memory_proposal_receipt.candidates.map(c=>c.id)).size,1);
 await confirm(f,(await f.state()).candidates[0]);assert.equal((await f.state()).claims.length,1);
});
