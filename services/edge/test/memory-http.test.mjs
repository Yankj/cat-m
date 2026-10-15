import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {ApiError,hash,clone} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {MEMORY_CONTRACT} from '../supabase/functions/_shared/core/src/memory-contract.mjs';
import {kickTurnTasks} from '../supabase/functions/_shared/worker-kick.mjs';
import {resolveMemoryProviderInput} from '../supabase/functions/_shared/core/src/memory-service.mjs';
import {memoryHTTPFixture as fixture} from './fixtures/memory-http-fixture.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const claim=(value,source,conditions={})=>({kind:'preference',predicate:'drink.preference',value,conditions,assertion:'explicit',evidence:{span_start:0,span_end:source.length}});
const remember=(cid,value,source='Fictional user preference source')=>({type:'remember',conversation_id:cid,source_text:source,claim:claim(value,source),allow_relearn:false,sensitive_consent:false});
test('actual maintenance memory: default disabled, explicit opt-in, remember, new conversation model input, correct, forget and original GET',async()=>{
 const f=await fixture(),cid=await f.newConversation(),initial=await f.state();assert.equal(initial.enabled,false);
 const denied=await f.post(remember(cid,'coffee'));assert.equal(denied.response.status,409);assert.equal((await denied.response.json()).error.code,'memory_disabled');
 await f.json((await f.post({type:'set_enabled',enabled:true})).response);
 const saved=await f.post(remember(cid,'coffee','Private original evidence text; do not forward this entire source'));
 const receipt=await f.json(saved.response);assert.equal(receipt.operation.request_hash,hash(saved.input));assert.equal(receipt.operation.command_type,'remember');
 assert.deepEqual(await f.json(await f.req(f.base+'/commands',saved.input)),receipt);assert.deepEqual(await f.json(await f.req(f.base+'/commands/'+saved.input.operation_id)),receipt);
 let state=await f.state();assert.equal(state.claims.length,1);assert.equal(state.sources[0].type,'user_memory_command');assert.equal(state.sources[0].command_id,saved.input.operation_id);
 assert.equal(Object.hasOwn(state.claims[0],'confidence'),false);const original=await f.json(await f.req(f.base+'/sources/'+state.claims[0].source_id));assert.match(original.source.text,/Private original/);
 const turn=await f.send(await f.newConversation(),'What coffee drink do I prefer?');assert.equal(turn.state,'completed');assert.equal(f.calls.length,1);assert.equal(f.calls[0].provider_context.memory_context.claims[0].value,'coffee');assert.equal(f.calls[0].system_prompt.includes(original.source.text),false);assert.equal(turn.memory_usage.claims[0].id,state.claims[0].id);assert.equal(JSON.stringify(turn.memory_usage).includes('coffee'),false);
 const old=state.claims[0],correction=remember(cid,'tea','New explicitly entered correction evidence');correction.type='correct';correction.target_id=old.id;correction.expected_version=old.version;
 const changed=await f.json((await f.post(correction)).response);assert.equal(changed.operation.result.version,2);state=await f.state();assert.deepEqual(state.claims[0].previous_source_ref,{id:old.source_id,content_hash:old.source_hash});assert.equal((await f.json(await f.req(f.base+'/sources/'+old.source_id))).source.text,original.source.text);
 await f.send(await f.newConversation(),'Does my drink preference include tea?');assert.equal(f.calls[1].provider_context.memory_context.claims[0].value,'tea');
 const forgotten=await f.post({type:'forget',target_id:old.id,expected_version:2,no_relearn:true});await f.json(forgotten.response);assert.equal((await f.state()).claims.length,0);
 await f.send(await f.newConversation(),'What coffee or tea drink do I prefer?');assert.deepEqual(f.calls[2].provider_context.memory_context.claims,[]);assert.deepEqual(f.calls[2].provider_context.memory_context.conflicts,[]);
 assert.deepEqual(await f.json(await f.req(f.base+'/commands/'+saved.input.operation_id)),receipt);
 const commands=await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,s=>s.list('commands')));assert.equal(JSON.stringify(commands).includes(original.source.text),false);
});
test('strict schema, changed replay, generation/version CAS and account-scope checks preserve authority',async()=>{
 const f=await fixture(),cid=await f.newConversation();await f.json((await f.post({type:'set_enabled',enabled:true})).response);
 const saved=await f.post(remember(cid,'coffee')),receipt=await f.json(saved.response),state=await f.state(),fact=state.claims[0];
 const changed={...saved.input,command:{...saved.input.command,source_text:'Changed source'}};assert.equal((await f.req(f.base+'/commands',changed)).status,409);
 assert.equal((await f.req(f.base+'/commands',{...saved.input,operation_id:randomUUID()})).status,409);
 const conflict=await f.post({type:'forget',target_id:fact.id,expected_version:99,no_relearn:true});assert.equal(conflict.response.status,409);assert.equal((await f.state()).claims.length,1);
 assert.equal((await f.req(f.base+'/state?override=true')).status,422);assert.equal((await f.req(f.base+'/commands','{"schema_version":1,"schema_version":1}')).status,422);
 assert.equal((await f.req(f.base+'/commands',{...saved.input,extra:1})).status,422);assert.equal((await f.req(f.base+'/commands',' '.repeat(16001))).status,413);
 assert.equal((await f.req(f.base+'/state',undefined,'Bearer no-session')).status,401);assert.equal((await f.req(f.base.replace(f.scope.scope_id,randomUUID())+'/state')).status,403);
 assert.equal((await f.req(f.base+'/sources/'+fact.source_id,undefined,'Bearer foreign-fixture')).status,403);assert.equal((await f.req(f.base+'/commands/'+receipt.operation.operation_id,undefined,'Bearer foreign-fixture')).status,403);
 assert.equal((await f.req(f.base+'/commands/'+randomUUID())).status,404);
});
test('confirmed candidate only, late extraction, no-relearn and explicit workspace versus conversation conditions',async()=>{
 const f=await fixture(),cid=await f.newConversation();await f.json((await f.post({type:'set_enabled',enabled:true})).response);await f.send(cid,'I prefer coffee');
 const lease=randomUUID(),job=await f.runtime.foundation.claimExtraction(f.principal,f.scope.scope_id,{lease_id:lease});assert.ok(job);
 const result=await f.runtime.foundation.submitCandidates(f.principal,f.scope.scope_id,{job_id:job.job.id,lease_id:lease,memory_generation:job.job.memory_generation,candidates:[claim('coffee',job.source.text)]});const candidate=result.candidates[0];assert.ok(candidate);
 await f.send(await f.newConversation(),'coffee preference');assert.deepEqual(f.calls.at(-1).provider_context.memory_context.claims,[]);
 await f.json((await f.post({type:'confirm',candidate_id:candidate.id,expected_version:1,allow_relearn:false,sensitive_consent:false})).response);
 await f.send(await f.newConversation(),'coffee preference');assert.equal(f.calls.at(-1).provider_context.memory_context.claims[0].value,'coffee');
 const lateLease=randomUUID(),late=await f.runtime.foundation.claimExtraction(f.principal,f.scope.scope_id,{lease_id:lateLease});assert.ok(late);
 const fact=(await f.state()).claims[0];await f.json((await f.post({type:'forget',target_id:fact.id,expected_version:1,no_relearn:true})).response);
 await assert.rejects(f.runtime.foundation.submitCandidates(f.principal,f.scope.scope_id,{job_id:late.job.id,lease_id:lateLease,memory_generation:late.job.memory_generation,candidates:[claim('coffee',late.source.text)]}),e=>e.code==='memory_fenced');
 const relearn=await f.post(remember(cid,'coffee'));assert.equal(relearn.response.status,409);assert.equal((await relearn.response.json()).error.code,'no_relearn_guard');
 const explicit=remember(cid,'coffee');explicit.allow_relearn=true;explicit.claim.conditions={conversation_id:cid};await f.json((await f.post(explicit)).response);
 await f.send(await f.newConversation(),'coffee preference');assert.deepEqual(f.calls.at(-1).provider_context.memory_context.claims,[]);
 await f.send(cid,'coffee preference');assert.equal(f.calls.at(-1).provider_context.memory_context.claims[0].value,'coffee');
});
test('forget or disable while admitted context waits blocks later provider dispatch, never silently refreshes generation',async()=>{
 for(const action of ['forget','disable']){
  const f=await fixture(),cid=await f.newConversation();await f.json((await f.post({type:'set_enabled',enabled:true})).response);await f.json((await f.post(remember(cid,'coffee'))).response);const fact=(await f.state()).claims[0];
  let release,entered;const gate=new Promise(r=>{release=r;}),atGate=new Promise(r=>{entered=r;}),old=f.runtime.chat.integration.renew;
  f.runtime.chat.integration.renew=async(...args)=>{entered();await gate;return old(...args);};
  const pending=f.send(await f.newConversation(),'coffee preference');await atGate;
  await f.json((await f.post(action==='forget'?{type:'forget',target_id:fact.id,expected_version:1,no_relearn:true}:{type:'set_enabled',enabled:false})).response);release();
  const turn=await pending;assert.equal(turn.state,'failed');assert.equal(f.calls.length,0);assert.ok(turn.memory_usage.memory_generation<(await f.state()).memory_generation);
 }
});
test('sensitive confirmed values require separate model consent, source deletion does not rewrite real conversation history',async()=>{
 const f=await fixture(),cid=await f.newConversation();await f.json((await f.post({type:'set_enabled',enabled:true})).response);
 const command=remember(cid,'preference','User entered medical record memory');command.sensitive_consent=true;await f.json((await f.post(command)).response);
 const turn=await f.send(await f.newConversation(),'preference');assert.equal(turn.state,'failed');assert.equal(f.calls.length,0);
 await f.send(await f.newConversation(),'preference',{sensitive:true});assert.equal(f.calls.length,1);
 const state=await f.state(),before=await f.json(await f.req('/catpaw/chat/v1/scopes/'+f.scope.scope_id+'/conversations/'+cid));
 await f.json(await f.req(f.base+'/sources/'+state.claims[0].source_id+'/delete',{}));const after=await f.json(await f.req('/catpaw/chat/v1/scopes/'+f.scope.scope_id+'/conversations/'+cid));assert.deepEqual(after,before);assert.equal((await f.state()).claims.length,0);
});

test('original command GET after a new runtime preserves immutable receipt and never recreates source or model work',async()=>{
 const f=await fixture(),cid=await f.newConversation();await f.json((await f.post({type:'set_enabled',enabled:true})).response);
 const accepted=await f.post(remember(cid,'coffee')),receipt=await f.json(accepted.response),before=f.repository.snapshot(),cold=await f.restore();
 assert.deepEqual(await cold.json(await cold.req(cold.base+'/commands/'+accepted.input.operation_id)),receipt);
 assert.deepEqual(await cold.json(await cold.req(cold.base+'/commands',accepted.input)),receipt);
 assert.deepEqual(cold.repository.snapshot(),before);assert.equal(cold.calls.length,0);
 await f.repository.transaction(async tx=>{const owner=membershipOwner(f.principal.issuer),row=await tx.get(owner,'app-sessions',f.principal.session_id);await tx.put(owner,'app-sessions',{...row,state:'revoked'});});
 const revoked=await f.restore();assert.equal((await revoked.req(revoked.base+'/commands/'+accepted.input.operation_id)).status,409);assert.equal(revoked.calls.length,0);
});
test('final authority await and receipt storage failure roll back source, claim and receipt together',async()=>{
 for(const failure of ['authority','storage']){
  const f=await fixture(),cid=await f.newConversation();await f.json((await f.post({type:'set_enabled',enabled:true})).response);
  const input=await f.command(remember(cid,'coffee')),before=f.repository.snapshot(),transaction=f.repository.transaction.bind(f.repository);
  f.repository.transaction=async(scope,fn)=>transaction(scope,async tx=>{const put=tx.put.bind(tx);tx.put=async(kind,...args)=>{const value=await put(kind,...args);if(kind==='commands'){if(failure==='storage')throw new ApiError(503,'named_receipt_storage_failure');f.setSourceActive(false);}return value;};return fn(tx);});
  const response=await f.req(f.base+'/commands',input);assert.equal(response.status,failure==='storage'?503:409);assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,0);
 }
});
test('legacy enabled rows never opt a user into model memory; stale resolved context cannot survive deletion',async()=>{
 const f=await fixture(),cid=await f.newConversation();await f.send(cid,'I prefer coffee');
 const sources=await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,s=>s.list('sources'))),source=sources.find(s=>s.type==='user_message');
 await f.runtime.foundation.applyUserMemoryCommand(f.principal,f.scope.scope_id,{request_id:randomUUID(),type:'remember',source_message_id:source.id,claim:claim('coffee',source.text)});
 const legacy=await f.send(await f.newConversation(),'coffee preference');assert.equal((await f.state()).enabled,false);assert.equal(legacy.memory_usage,undefined);assert.equal(f.calls.at(-1).provider_context.memory_context,undefined);
 await f.json((await f.post({type:'set_enabled',enabled:true})).response);await f.send(await f.newConversation(),'coffee preference');
 const stale=f.calls.at(-1),fact=(await f.state()).claims[0];await f.json((await f.post({type:'forget',target_id:fact.id,expected_version:1,no_relearn:true})).response);
 await assert.rejects(resolveMemoryProviderInput(f.runtime,stale),e=>e.code==='memory_generation_superseded');
});
test('original task worker receives the same frozen confirmed memory refs and deletion fences further worker calls',async()=>{
 const f=await fixture({delegate:true}),cid=await f.newConversation();await f.json((await f.post({type:'set_enabled',enabled:true})).response);await f.json((await f.post(remember(cid,'coffee'))).response);
 const turn=await f.send(await f.newConversation(),'coffee preference report'),binding=turn.task_bindings[0],owner=f.runtime.facade.owner(f.scope);assert.ok(binding);
 const run=await f.repository.transaction(tx=>tx.get(owner,'catpaw-runs',binding.run_id));assert.deepEqual(run.frozen_request.memory_usage,turn.memory_usage);assert.equal(JSON.stringify(run.frozen_request.memory_usage).includes('coffee'),false);
 let now=Date.now();await kickTurnTasks(f.runtime,{owner,principal:f.principal,turnId:turn.id},{now:()=>now,sleep:async ms=>{now+=ms;}});
 assert.ok(f.calls.length>=2);assert.equal(f.calls[1].provider_context.memory_context.claims[0].value,'coffee');assert.equal(f.calls[1].provider_context.source_auth.session_id,f.principal.session_id);
 const fact=(await f.state()).claims[0];await f.json((await f.post({type:'forget',target_id:fact.id,expected_version:1,no_relearn:true})).response);const calls=f.calls.length;
 await assert.rejects(f.runtime.facade.effectiveRequest(owner,binding.task_id),e=>e.code==='memory_generation_superseded');assert.equal(f.calls.length,calls);
});
test('contradictory confirmed values remain a visible conflict group; old active snapshot cannot silently win',async()=>{
 const f=await fixture(),cid=await f.newConversation();await f.json((await f.post({type:'set_enabled',enabled:true})).response);await f.json((await f.post(remember(cid,'coffee'))).response);
 await f.send(await f.newConversation(),'coffee preference');const stale=f.calls.at(-1);
 await f.json((await f.post(remember(cid,'tea','Another explicit user preference'))).response);
 await assert.rejects(resolveMemoryProviderInput(f.runtime,stale),e=>e.code==='memory_generation_superseded');
 const state=await f.state();assert.equal(state.claims.length,2);assert.ok(state.claims.every(c=>c.status==='disputed'));
 await f.send(await f.newConversation(),'coffee preference');const context=f.calls.at(-1).provider_context.memory_context;assert.deepEqual(context.claims,[]);assert.deepEqual(new Set(context.conflicts[0].claims.map(c=>c.value)),new Set(['coffee','tea']));
});

test('same-scope foreign subject cannot initialize, forget, replay a guard or disable another account memory',async()=>{
 const f=await fixture(),cid=await f.newConversation(),initial=await f.state();
 let input=await f.command({type:'set_enabled',enabled:true}),before=f.repository.snapshot();
 let response=await f.req(f.base+'/commands',input,'Bearer foreign-fixture');assert.equal(response.status,403);assert.equal((await response.json()).error.code,'memory_scope_subject_conflict');assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.state()).enabled,initial.enabled);
 await f.json((await f.post({type:'set_enabled',enabled:true})).response);await f.json((await f.post(remember(cid,'coffee'))).response);let state=await f.state(),target=state.claims[0];
 for(const command of [{type:'forget',target_id:target.id,expected_version:target.version,no_relearn:true},{type:'set_enabled',enabled:false}]){
  input=await f.command(command);before=f.repository.snapshot();response=await f.req(f.base+'/commands',input,'Bearer foreign-fixture');assert.equal(response.status,403);assert.deepEqual(f.repository.snapshot(),before);
 }
 await f.json((await f.post({type:'forget',target_id:target.id,expected_version:target.version,no_relearn:true})).response);
 input=await f.command({type:'forget',target_id:target.id,expected_version:target.version,no_relearn:true});before=f.repository.snapshot();response=await f.req(f.base+'/commands',input,'Bearer foreign-fixture');assert.equal(response.status,403);assert.deepEqual(f.repository.snapshot(),before);
 assert.equal((await f.req(f.base+'/state',undefined,'Bearer foreign-fixture')).status,403);assert.equal(f.calls.length,0);
});
