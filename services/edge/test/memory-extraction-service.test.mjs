// Domain/service checks only: serialized TestRepository, no API/model/Auth/SQL network.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {Foundation} from '../supabase/functions/_shared/core/integration/server-foundation/src/foundation.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,hash,clone} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {MEMORY_PROPOSAL_CONTRACT,validateConversationMemoryProposalCall,stageConversationMemoryExtraction,commitConversationMemoryCandidates} from '../supabase/functions/_shared/core/src/memory-extraction-service.mjs';

const receiptKeys=['schema_version','contract','scope_id','conversation_id','turn_id','source_id','source_hash','memory_generation','job_id','candidates','status','confirmed'].sort();
async function fixture({enabled=true,negotiated=true,sensitive=false}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()},principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://memory-proposal.example.invalid/auth/v1',issued_at:1,scopes:[scope]};
 let now=Date.parse('2026-10-15T00:00:00Z'),active=true,authorityCalls=0,denyAt=Infinity;
 const foundation=new Foundation(repository,{guardKey:'synthetic-memory-proposal-guard',clock:()=>new Date(now)}),owner=foundation.identity(principal,scope.scope_id).owner;
 await foundation.bootstrapScope(principal,scope.scope_id);
 await repository.transaction(tx=>tx.withScope(scope.scope_id,async s=>s.saveScope({...await s.scope(),memory_user_enabled:enabled,memory_subject_id:principal.subject_id})));
 const runtime={repository,foundation,dataClass:'private',memoryContextEnabled:true,memoryAuthority:async(_tx,p,identity)=>{authorityCalls++;if(!active||authorityCalls>=denyAt||p.subject_id!==principal.subject_id||identity.scope_id!==scope.scope_id)throw new ApiError(409,'grant_conflict');}};
 const seed=async(text,{conversationID=randomUUID(),state='running',work=false,revision=false}={})=>repository.transaction(async records=>{
  const old=await records.get(owner,'native-chat-conversations',conversationID),message={id:randomUUID(),role:'user',content:text};now+=1000;
  const conversation={id:conversationID,scope_id:scope.scope_id,subject_id:principal.subject_id,state:'active',revision:(old?.revision??1)+1,grant_epoch:1,messages:[...(old?.messages??[]),message]};
  const turn={id:randomUUID(),scope_id:scope.scope_id,subject_id:principal.subject_id,conversation_id:conversationID,grant_epoch:1,conversation_revision:conversation.revision,state,created_at:foundation.now(),input:{message:{id:message.id,text}},events:[],source_auth:{subject_id:principal.subject_id,scope_id:scope.scope_id,session_id:principal.session_id,issuer:principal.issuer,issued_at:1,consent_revision:1},source_sensitivity:sensitive?'sensitive':'low',...negotiated?{memory_proposal_contract:MEMORY_PROPOSAL_CONTRACT}:{},...work?{work_intent:{}}:{},...revision?{revision_target:{}}:{}};
  await records.put(owner,'native-chat-conversations',conversation);await records.put(owner,'native-chat-turns',turn);
  await foundation.captureInTransaction(records,principal,scope.scope_id,{conversation_id:conversationID,turn_id:turn.id,data_class:'private',sensitivity:turn.source_sensitivity});
  return {principal,scope,conversation,turn};
 });
 const stage=async args=>{
  const ref=await repository.transaction(async records=>{const ref=await stageConversationMemoryExtraction(runtime,records,args);if(ref){const turn=await records.get(owner,'native-chat-turns',args.turn.id);await records.put(owner,'native-chat-turns',{...turn,memory_extraction:ref});}return ref;});
  if(ref)args.turn={...args.turn,memory_extraction:ref};return ref;
 };
 const commit=async(args,call,{failAfterReceipt=false}={})=>repository.transaction(async records=>{
  const receipt=await commitConversationMemoryCandidates(runtime,records,{...args,call}),turn=await records.get(owner,'native-chat-turns',args.turn.id);
  await records.put(owner,'native-chat-turns',{...turn,memory_proposal_receipt:receipt,memory_proposal_call:{id:call.id,hash:hash({id:call.id,name:call.name,arguments:call.arguments})}});
  if(failAfterReceipt)throw new Error('synthetic_owner_receipt_failure');return receipt;
 });
 const rows=kind=>repository.transaction(tx=>tx.withScope(scope.scope_id,s=>s.list(kind)));
 const patchSource=(id,patch)=>repository.transaction(tx=>tx.withScope(scope.scope_id,async s=>s.put('sources',{...await s.get('sources',id),...patch})));
 const patchTurn=(id,patch)=>repository.transaction(async tx=>tx.put(owner,'native-chat-turns',{...await tx.get(owner,'native-chat-turns',id),...patch}));
 return {repository,foundation,runtime,owner,principal,scope,seed,stage,commit,rows,patchSource,patchTurn,advance:ms=>{now+=ms;},setActive:value=>{active=value;},denyFinal:()=>{authorityCalls=0;denyAt=2;}};
}
const callFor=(args,{scope='conversation',value='tea',id=randomUUID()}={})=>({id,name:'propose_memory_v1',arguments:{candidates:[{kind:'preference',predicate:'drink.preference',value,scope,evidence:{span_start:0,span_end:args.turn.input.message.text.length}}]}});
const denies=async fn=>assert.rejects(fn,error=>error instanceof Error&&[403,409,422,503].includes(error.status));

test('proposal validator is strict, bounded data-only and never accepts model authority fields',()=>{
 const args={turn:{input:{message:{text:'I prefer tea'}}}},valid=callFor(args);assert.deepEqual(validateConversationMemoryProposalCall(valid),valid);
 const variants=[];
 for(const extra of [{assertion:'explicit'},{conditions:{}},{source_id:randomUUID()},{sensitivity:'low'},{confirmed:true}]){const v=clone(valid);Object.assign(v.arguments.candidates[0],extra);variants.push(v);}
 for(const patch of [{kind:'instruction'},{predicate:'Bad predicate'},{scope:'another-account'},{evidence:{span_start:-1,span_end:2}},{evidence:{span_start:false,span_end:2}},{evidence:{span_start:2,span_end:2}},{value:'界'.repeat(400)},{value:Infinity},{value:NaN},{value:undefined},{value:()=>{}}]){const v=clone(valid);Object.assign(v.arguments.candidates[0],patch);variants.push(v);}
 variants.push({...clone(valid),extra:true},{...clone(valid),name:'remember'}, {...clone(valid),id:''},{...clone(valid),arguments:{candidates:[]}},{...clone(valid),arguments:{candidates:Array.from({length:7},()=>clone(valid.arguments.candidates[0]))}});
 for(const value of variants)assert.throws(()=>validateConversationMemoryProposalCall(value),error=>error.status===422);
});

test('explicit enabled state and negotiated client are necessary; normal answers hold no extraction lease',async()=>{
 for(const options of [{enabled:false},{negotiated:false}]){
  const f=await fixture(options),args=await f.seed('I prefer tea');assert.equal(await f.stage(args),null);assert.equal((await f.rows('jobs'))[0].status,'ready');assert.equal((await f.rows('candidates')).length,0);
 }
 for(const contract of [null,'unknown.contract']){const f=await fixture(),args=await f.seed('I prefer tea');args.turn.memory_proposal_contract=contract;await f.patchTurn(args.turn.id,{memory_proposal_contract:contract});assert.equal(await f.stage(args),null);}
 for(const key of ['work','revision']){const f=await fixture(),args=await f.seed('I prefer tea',{[key]:true});assert.equal(await f.stage(args),null);assert.equal((await f.rows('jobs'))[0].status,'ready');}
 const f=await fixture(),args=await f.seed('A normal question');await f.stage(args);assert.equal((await f.rows('jobs'))[0].status,'ready');assert.equal((await f.rows('jobs'))[0].attempts,0);
 const leased=await f.foundation.claimExtraction(f.principal,f.scope.scope_id,{lease_id:randomUUID()});assert.equal(leased.source.id,args.turn.input.message.id);
});

test('stage freezes the exact current user source, not the queue head, and accepts prior admission conversation snapshot',async()=>{
 const f=await fixture(),old=await f.seed('Old preference',{state:'completed'}),args=await f.seed('我喜欢茶🫖',{conversationID:old.conversation.id});
 const freshMessages=clone(args.conversation.messages);args.conversation={...old.conversation};const reference=await f.stage(args);
 assert.equal(reference.source_id,args.turn.input.message.id);assert.equal(reference.source_hash,createHash('sha256').update('我喜欢茶🫖','utf8').digest('hex'));
 const jobs=await f.rows('jobs');assert.equal(jobs.find(j=>j.id===reference.job_id).source_id,args.turn.input.message.id);assert.equal(jobs.find(j=>j.source_id===old.turn.input.message.id).status,'ready');assert.equal(jobs.find(j=>j.id===reference.job_id).status,'ready');
 assert.equal(freshMessages.length,2);assert.equal(args.conversation.messages.length,1);
});

test('commit produces only inferred proposed candidates with authenticated source, bounded scope and refs-only receipt',async()=>{
 const f=await fixture({sensitive:true}),args=await f.seed('我喜欢茶🫖');await f.stage(args);const call=callFor(args);call.arguments.candidates.push({...clone(call.arguments.candidates[0]),predicate:'drink.workspace',scope:'workspace'});
 const receipt=await f.commit(args,call),candidates=await f.rows('candidates'),jobs=await f.rows('jobs');assert.deepEqual(Object.keys(receipt).sort(),receiptKeys);assert.equal(receipt.confirmed,false);assert.equal(receipt.status,'proposed');assert.equal(receipt.candidates.length,2);
 assert.equal((await f.rows('facts')).length,0);assert.equal(jobs[0].status,'done');assert.equal(jobs[0].attempts,1);assert.equal(jobs[0].lease_id,null);
 for(const candidate of candidates){assert.equal(candidate.assertion,'inferred');assert.equal(candidate.status,'proposed');assert.equal(candidate.sensitivity,'sensitive');assert.equal(candidate.source_id,args.turn.input.message.id);assert.equal(candidate.source_hash,receipt.source_hash);}
 assert.deepEqual(candidates.find(c=>c.predicate==='drink.preference').conditions,{conversation_id:args.conversation.id});assert.deepEqual(candidates.find(c=>c.predicate==='drink.workspace').conditions,{});
 assert.equal(JSON.stringify(receipt).includes('茶'),false);assert.equal(JSON.stringify(receipt).includes('tea'),false);assert.equal(JSON.stringify(receipt).includes('lease_id'),false);
 const candidate=candidates.find(c=>c.predicate==='drink.workspace');await assert.rejects(f.foundation.applyUserMemoryCommand(f.principal,f.scope.scope_id,{request_id:randomUUID(),type:'confirm',candidate_id:candidate.id,expected_version:1}),e=>e.code==='sensitive_confirmation_required');
 await f.foundation.applyUserMemoryCommand(f.principal,f.scope.scope_id,{request_id:randomUUID(),type:'confirm',candidate_id:candidate.id,expected_version:1,sensitive_consent:true});assert.equal((await f.rows('facts'))[0].assertion,'explicit');
});

test('same original call and body reuse the receipt; changed body or another call cannot produce a second effect',async()=>{
 const f=await fixture(),args=await f.seed('I prefer tea');await f.stage(args);const call=callFor(args),receipt=await f.commit(args,call),before=f.repository.snapshot();assert.deepEqual(await f.commit(args,clone(call)),receipt);assert.deepEqual(f.repository.snapshot(),before);
 const changed=clone(call);changed.arguments.candidates[0].value='coffee';await assert.rejects(f.commit(args,changed),e=>e.code==='memory_proposal_operation_conflict');await assert.rejects(f.commit(args,{...clone(call),id:randomUUID()}),e=>e.code==='memory_proposal_operation_conflict');assert.deepEqual(f.repository.snapshot(),before);
});

test('another public extractor consumer keeps its lease, even expired; proposal never steals it or claims a different job',async()=>{
 for(const expired of [false,true]){
  const f=await fixture(),args=await f.seed('I prefer tea');await f.stage(args);await f.foundation.claimExtraction(f.principal,f.scope.scope_id,{lease_id:randomUUID(),lease_ms:1000});if(expired)f.advance(1001);const before=f.repository.snapshot();
  await assert.rejects(f.commit(args,callFor(args)),e=>e.code==='lease_lost');assert.deepEqual(f.repository.snapshot(),before);
 }
});

test('assistant, external, wrong actor, changed source bytes/hash and wrong turn cannot become user evidence',async()=>{
 for(const patch of [{type:'assistant_message',trust:'model_generated',authenticated_actor_id:null},{type:'external_document',trust:'external_untrusted'},{authenticated_actor_id:randomUUID()},{text:'fabricated bytes'},{text:'fabricated bytes',content_hash:hash('fabricated bytes')},{turn_id:randomUUID()},{conversation_id:randomUUID()}]){
  const f=await fixture(),args=await f.seed('I prefer tea');await f.stage(args);await f.patchSource(args.turn.input.message.id,patch);const before=f.repository.snapshot();await denies(()=>f.commit(args,callFor(args)));assert.deepEqual(f.repository.snapshot(),before);
 }
});

test('source scope, frozen job and foreign subject are checked before any candidate write',async()=>{
 const f=await fixture(),old=await f.seed('Old text',{state:'completed'}),args=await f.seed('I prefer tea');await f.stage(args);const otherJob=(await f.rows('jobs')).find(j=>j.source_id===old.turn.input.message.id);
 await f.patchTurn(args.turn.id,{memory_extraction:{...args.turn.memory_extraction,job_id:otherJob.id}});let before=f.repository.snapshot();await denies(()=>f.commit(args,callFor(args)));assert.deepEqual(f.repository.snapshot(),before);
 await f.patchTurn(args.turn.id,{memory_extraction:args.turn.memory_extraction});const foreign={...args,principal:{...args.principal,subject_id:randomUUID()}};before=f.repository.snapshot();await denies(()=>f.commit(foreign,callFor(args)));assert.deepEqual(f.repository.snapshot(),before);
 await assert.rejects(f.patchSource(args.turn.input.message.id,{scope_id:randomUUID()}),e=>e.code==='scope_forbidden'); // Repository also enforces scope.
});

test('forget, disabled memory, source deletion and newer generation fence late proposal without resurrection',async()=>{
 for(const action of ['forget','disable','delete-source','correct-generation']){
  const f=await fixture(),args=await f.seed('I prefer tea');
  let fact;if(action==='forget')fact=await f.foundation.applyUserMemoryCommand(f.principal,f.scope.scope_id,{request_id:randomUUID(),type:'remember',source_message_id:args.turn.input.message.id,claim:{kind:'preference',predicate:'drink.preference',value:'tea',conditions:{},assertion:'explicit',evidence:{span_start:0,span_end:12}}});
  await f.stage(args);
  if(action==='forget')await f.foundation.applyUserMemoryCommand(f.principal,f.scope.scope_id,{request_id:randomUUID(),type:'forget',target_id:fact.claim_id,expected_version:1,no_relearn:true});
  if(action==='disable')await f.foundation.setMemoryEnabled(f.principal,f.scope.scope_id,false);
  if(action==='delete-source')await f.patchSource(args.turn.input.message.id,{text:'',deleted_at:f.foundation.now(),suppressed_for_memory:true});
  if(action==='correct-generation')await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,s=>f.foundation.invalidate(s,[],[],'correct',false)));
  const before=f.repository.snapshot();await denies(()=>f.commit(args,callFor(args)));assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.rows('candidates')).length,0);
 }
});

test('no-relearn guards may filter all inputs, yielding an empty refs-only proposed receipt without bypass',async()=>{
 const f=await fixture(),args=await f.seed('I prefer tea'),call=callFor(args);await f.stage(args);
 await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,s=>s.put('guards',{id:randomUUID(),scope_id:f.scope.scope_id,subject_key_hmac:f.foundation.claimKey({predicate:'drink.preference',conditions:{conversation_id:args.conversation.id}}),no_relearn:true,generation:1,reason:'forget'},{insert:true})));
 const receipt=await f.commit(args,call);assert.deepEqual(receipt.candidates,[]);assert.equal((await f.rows('candidates')).length,0);assert.equal((await f.rows('facts')).length,0);assert.equal((await f.rows('jobs'))[0].status,'done');
});

test('late terminal, revoked grant, lost negotiated contract and malformed evidence cannot commit',async()=>{
 for(const patch of [{state:'completed'},{state:'failed'},{state:'outcome_unknown'},{content_redacted:true},{work_intent:{}},{revision_target:{}},{memory_proposal_contract:null}]){
  const f=await fixture(),args=await f.seed('I prefer tea');await f.stage(args);await f.patchTurn(args.turn.id,patch);const before=f.repository.snapshot();await denies(()=>f.commit(args,callFor(args)));assert.deepEqual(f.repository.snapshot(),before);
 }
 const f=await fixture(),args=await f.seed('I prefer tea');await f.stage(args);const call=callFor(args);call.arguments.candidates[0].evidence.span_end=999;const before=f.repository.snapshot();await assert.rejects(f.commit(args,call),e=>e.code==='evidence_invalid');assert.deepEqual(f.repository.snapshot(),before);
 await f.repository.transaction(async tx=>tx.put(f.owner,'native-chat-conversations',{...args.conversation,state:'revoked',grant_epoch:2}));const revoked=f.repository.snapshot();await denies(()=>f.commit(args,callFor(args)));assert.deepEqual(f.repository.snapshot(),revoked);
});

test('final authority denial and chat-owner receipt storage failure roll back lease, candidates, events and journal together',async()=>{
 for(const mode of ['final-authority','owner-receipt']){
  const f=await fixture(),args=await f.seed('I prefer tea');await f.stage(args);const before=f.repository.snapshot();if(mode==='final-authority')f.denyFinal();
  await assert.rejects(f.commit(args,callFor(args),{failAfterReceipt:mode==='owner-receipt'}));assert.deepEqual(f.repository.snapshot(),before);assert.equal((await f.rows('jobs'))[0].status,'ready');assert.equal((await f.rows('candidates')).length,0);
 }
});

test('already applied receipt is not replayed around current source/generation or fresh account authority',async()=>{
 for(const mode of ['source','generation','authority']){
  const f=await fixture(),args=await f.seed('I prefer tea');await f.stage(args);const call=callFor(args);await f.commit(args,call);
  if(mode==='source')await f.patchSource(args.turn.input.message.id,{suppressed_for_memory:true});
  if(mode==='generation')await f.repository.transaction(tx=>tx.withScope(f.scope.scope_id,s=>f.foundation.invalidate(s,[],[],'correct',false)));
  if(mode==='authority')f.setActive(false);const before=f.repository.snapshot();await denies(()=>f.commit(args,call));assert.deepEqual(f.repository.snapshot(),before);
 }
});

test('identical proposals produce one candidate reference from the shared Foundation set, and it remains confirmable',async()=>{
 const f=await fixture(),args=await f.seed('I prefer tea');await f.stage(args);const call=callFor(args,{scope:'workspace'});call.arguments.candidates.push(clone(call.arguments.candidates[0]));
 const receipt=await f.commit(args,call);assert.equal(receipt.candidates.length,1);assert.equal((await f.rows('candidates')).length,1);assert.equal(new Set(receipt.candidates.map(c=>c.id)).size,receipt.candidates.length);
 await f.foundation.applyUserMemoryCommand(f.principal,f.scope.scope_id,{request_id:randomUUID(),type:'confirm',candidate_id:receipt.candidates[0].id,expected_version:1});assert.equal((await f.rows('facts')).length,1);assert.equal((await f.rows('facts'))[0].value,'tea');
});
