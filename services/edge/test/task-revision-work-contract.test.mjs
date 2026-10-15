import test from 'node:test';
import assert from 'node:assert/strict';
import {hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {taskRevisionReceiptHash} from '../supabase/functions/_shared/core/src/task-revision-contract.mjs';
import {TASK_REVISION_WORK_CONTRACT as CONTRACT,TASK_REVISION_WORK_BYTES,parseTaskRevisionWorkJSON,validateTaskRevisionWorkRequest,freezeRevisionWorkIntent,validateFrozenRevisionWorkIntent,assertRevisionWorkNewExecutionWindow,revisionWorkIntentHash,revisionWorkReceiptHash,validatePublicRevisionWorkReceipt} from '../supabase/functions/_shared/core/src/task-revision-work-contract.mjs';

const ids={subject:'11111111-1111-4111-8111-111111111111',scope:'22222222-2222-4222-8222-222222222222',conversation:'33333333-3333-4333-8333-333333333333',turn:'44444444-4444-4444-8444-444444444444',message:'55555555-5555-4555-8555-555555555555',run:'66666666-6666-4666-8666-666666666666',decision:'77777777-7777-4777-8777-777777777777'};
const NOW=Date.parse('2026-10-15T03:00:00.000Z'),ROUTE=hash('frozen route');
const fixture=()=>{
 const turn={turn_id:ids.turn,expected_revision:7,expected_grant_epoch:3,message:{id:ids.message,text:'第二条补充风险。\n保留原文 / \ufeff \u0085'},context:[]};
 const target={intent:'revise_report',run_id:ids.run,task_id:hash('original task'),artifact_reference:{artifact_id:hash('original artifact'),version:2,content_hash:hash('original body')},expected_grant_epoch:4,expected_plan_revision:3,expected_plan_hash:hash('original plan')};
 const work={decision_id:ids.decision,input_hash:hash({turn,target}),route_hash:ROUTE,tool_policy:'public_sources_v1',not_after:new Date(NOW+3600000).toISOString(),execution_budget_ms:120000,limits:{due:1,model:4,source:3}};
 const body={schema_version:1,contract:CONTRACT,turn,target,work};
 const context={turn:{id:ids.turn,input:turn},target,scope:{scope_id:ids.scope},principal:{subject_id:ids.subject},conversation:{id:ids.conversation,scope_id:ids.scope,subject_id:ids.subject,grant_epoch:3},routeHash:ROUTE,now:NOW};
 return {body,context};
};
const reject=(fn,status,code)=>assert.throws(fn,error=>error?.status===status&&error?.code===code);
const frozen=()=>{const f=fixture();return {...f,intent:freezeRevisionWorkIntent(f.body.work,f.context)};};

test('revision-work request preserves exact raw instruction and target in its canonical hash',()=>{
 const {body}=fixture(),value=validateTaskRevisionWorkRequest(parseTaskRevisionWorkJSON(JSON.stringify(body)));
 assert.deepEqual(value,body);assert.equal(value.work.input_hash,hash({turn:value.turn,target:value.target}));
 assert.equal(TASK_REVISION_WORK_BYTES,48000);assert.equal(CONTRACT,'catpaw.task-revision-work.v1');
 value.turn.message.text='changed';assert.notEqual(value.turn.message.text,body.turn.message.text);
});
test('raw instruction, turn/context, target version/hash and target identity cannot change under an old decision',()=>{
 for(const mutate of [
 b=>b.turn.message.text+=' ',b=>b.turn.context.push({type:'note',text:'new'}),b=>b.turn.message.id=ids.run,
 b=>b.target.artifact_reference.version++,b=>b.target.artifact_reference.content_hash=hash('changed'),b=>b.target.run_id=ids.message,
 b=>b.target.expected_plan_hash=hash('new plan')
 ]){const {body}=fixture();mutate(body);reject(()=>validateTaskRevisionWorkRequest(body),409,'revision_work_input_conflict');}
});
test('revision-work accepts only the exact additive wrapper and revise_report target',()=>{
 for(const mutate of [b=>b.schema_version=2,b=>b.contract='catpaw.accepted-work-intent.v1',b=>b.extra=true,b=>delete b.work,b=>b.target.intent='explain_report',b=>b.target.extra=true]){
  const {body}=fixture();mutate(body);assert.throws(()=>validateTaskRevisionWorkRequest(body));
 }
});
test('target normalization cannot silently alter authorization hash input',()=>{
 const {body}=fixture();body.target.run_id='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';body.work.input_hash=hash({turn:body.turn,target:body.target});
 reject(()=>validateTaskRevisionWorkRequest(body),422,'revision_work_target_not_canonical');
});
test('strict parser rejects duplicate and escaped duplicate keys at every nested authority boundary',()=>{
 const {body}=fixture(),raw=JSON.stringify(body);
 for(const changed of [
 raw.replace('"schema_version":1','"schema_version":1,"schema_version":1'),
 raw.replace('"decision_id":','"decision_id":"'+ids.decision+'","decision_id":'),
 raw.replace('"version":2','"version":2,"\\u0076ersion":2'),
 raw.replace('"text":','"text":"first","text":')
 ])reject(()=>parseTaskRevisionWorkJSON(changed),422,'revision_work_duplicate_key');
});
test('parser and typed request enforce the 48000 UTF-8 byte bound',()=>{
 const {body}=fixture();body.turn.message.text='猫'.repeat(17000);body.work.input_hash=hash({turn:body.turn,target:body.target});
 reject(()=>parseTaskRevisionWorkJSON(JSON.stringify(body)),413,'revision_work_request_too_large');
 reject(()=>validateTaskRevisionWorkRequest(body),413,'revision_work_request_too_large');
});
test('parser rejects malformed/non-object/deep and non-JSON numeric input without authority defaults',()=>{
 for(const raw of ['{','[]','null','{"a":NaN}','{"a":'+ '['.repeat(10)+'0'+']'.repeat(10)+'}'])assert.throws(()=>parseTaskRevisionWorkJSON(raw));
 const {body}=fixture();body.turn.context=[{number:Infinity}];assert.throws(()=>validateTaskRevisionWorkRequest(body));
});
test('fresh decision freezes exact target/input, subject/scope/conversation epoch, turn and message',()=>{
 const {body,context,intent}=frozen();
 assert.deepEqual(intent,{schema_version:1,contract:CONTRACT,...body.work,subject_id:ids.subject,scope_id:ids.scope,conversation_id:ids.conversation,conversation_epoch:3,turn_id:ids.turn,message_id:ids.message,target_hash:hash(body.target),admitted_at:new Date(NOW).toISOString()});
 assert.deepEqual(validateFrozenRevisionWorkIntent(intent,{...context,callName:'revise_current_report_work_v1'}),intent);
 intent.limits.model=0;assert.equal(body.work.limits.model,4);
});
test('freeze refuses a different current user, scope, conversation epoch, turn or message binding',()=>{
 for(const mutate of [
 c=>c.conversation.subject_id=ids.run,c=>c.conversation.scope_id=ids.run,c=>c.principal.subject_id='not-a-subject',
 c=>c.conversation.grant_epoch=4,c=>c.turn.id=ids.run,c=>c.turn.input.expected_grant_epoch=4,
 c=>c.turn.input.message.id=c.turn.id
 ]){const {body,context}=fixture();mutate(context);assert.throws(()=>freezeRevisionWorkIntent(body.work,context));}
});
test('freeze rejects changed route/input and expired, oversized or insufficient execution windows',()=>{
 for(const mutate of [
 f=>f.context.routeHash=hash('other route'),f=>f.context.turn.input.message.text+=' changed',
 f=>f.body.work.not_after=new Date(NOW).toISOString(),
 f=>f.body.work.not_after=new Date(NOW+86400001).toISOString(),
 f=>f.body.work.not_after=new Date(NOW+1000).toISOString(),
 f=>f.context.now=NaN
 ]){const f=fixture();mutate(f);assert.throws(()=>freezeRevisionWorkIntent(f.body.work,f.context));}
});
test('new revision never inherits a missing decision, deadline, limit or tool policy from an old grant',()=>{
 for(const field of ['decision_id','not_after','execution_budget_ms','tool_policy','limits']){
  const {body,context}=fixture();delete body.work[field];assert.throws(()=>freezeRevisionWorkIntent(body.work,context));
 }
 for(const mutate of [w=>w.limits.model=21,w=>w.limits.source=13,w=>w.limits.due=2,w=>w.tool_policy='all_tools',w=>w.tool_policy='local_output_v1']){
  const {body,context}=fixture();mutate(body.work);assert.throws(()=>freezeRevisionWorkIntent(body.work,context));
 }
});
test('frozen intent rejects tampered identities, target/raw input, route, extra fields and non-revision tools',()=>{
 for(const mutate of [
 f=>f.intent.subject_id=ids.run,f=>f.intent.scope_id=ids.run,f=>f.intent.conversation_id=ids.run,
 f=>f.intent.conversation_epoch++,f=>f.intent.turn_id=ids.run,f=>f.intent.message_id=ids.run,f=>f.intent.target_hash=hash('other target'),
 f=>f.context.target.artifact_reference.version++,f=>f.context.turn.input.message.text+=' ',f=>f.context.routeHash=hash('other'),
 f=>f.intent.extra=true,f=>f.intent.admitted_at='invalid'
 ]){const f=frozen();mutate(f);assert.throws(()=>validateFrozenRevisionWorkIntent(f.intent,{...f.context,callName:'revise_current_report_work_v1'}));}
 for(const callName of ['delegate_task','delegate_sources_v1','save_artifact','finish_task','explain_report']){const f=frozen();reject(()=>validateFrozenRevisionWorkIntent(f.intent,{...f.context,callName}),403,'revision_work_tool_policy_conflict');}
});
test('local-output work is allowed only with explicitly zero source budget',()=>{
 const {body,context}=fixture();body.work.tool_policy='local_output_v1';body.work.limits.source=0;
 assert.equal(freezeRevisionWorkIntent(body.work,context).tool_policy,'local_output_v1');
});
test('immutable validation cannot renew the absolute window; only a fresh execution within it is admissible',()=>{
 const {intent,context}=frozen();
 assert.deepEqual(validateFrozenRevisionWorkIntent(intent,{...context,callName:'revise_current_report_work_v1'}),intent);
 assertRevisionWorkNewExecutionWindow(intent,NOW);assertRevisionWorkNewExecutionWindow(intent,NOW+1000);
 for(const now of [NOW-1,Date.parse(intent.not_after),Date.parse(intent.not_after)-intent.execution_budget_ms+1,NaN])reject(()=>assertRevisionWorkNewExecutionWindow(intent,now),409,'revision_work_expired');
 assert.equal(intent.not_after,new Date(NOW+3600000).toISOString());
});

const receiptFixture=()=>{
 const f=frozen(),r={operation_id:'88888888-8888-4888-8888-888888888888',operation_hash:hash('revision operation'),scope_id:ids.scope,subject_id:ids.subject,conversation_id:ids.conversation,turn_id:ids.turn,call_id:'provider-call-1',run_id:ids.run,task_id:f.body.target.task_id,base_reference:f.body.target.artifact_reference,base_plan_reference:{revision:3,plan_hash:f.body.target.expected_plan_hash},accepted_plan_reference:{revision:4,plan_hash:hash('new accepted plan')},instruction_hash:hash(f.body.turn.message.text),source_auth_hash:hash('original source'),fresh_source_auth_hash:hash('fresh source'),grant_epoch:4,accepted_at:new Date(NOW).toISOString(),state:'accepted'};
 r.receipt_hash=taskRevisionReceiptHash(r);
 const envelope={schema_version:1,contract:CONTRACT,decision_id:ids.decision,input_hash:f.body.work.input_hash,target_hash:hash(f.body.target),work_intent_hash:revisionWorkIntentHash(f.intent),revision:r,grant_reference:{schema_version:2,contract:'catpaw.task-work-grant.v2',grant_id:ids.decision,terms_hash:hash('new revision terms')},grant_receipt_hash:hash('new grant receipt')};
 envelope.receipt_hash=revisionWorkReceiptHash(envelope);return {...f,envelope};
};
test('work intent hash covers exactly the seven submitted fields and excludes admission metadata',()=>{
 const {body,intent}=frozen();assert.equal(revisionWorkIntentHash(intent),hash(body.work));
 const later={...intent,admitted_at:new Date(NOW+1000).toISOString(),subject_id:ids.run};assert.equal(revisionWorkIntentHash(later),hash(body.work));
 later.limits={...later.limits,model:3};assert.notEqual(revisionWorkIntentHash(later),hash(body.work));
 delete later.decision_id;assert.throws(()=>revisionWorkIntentHash(later));
});
test('public receipt binds a strict v2 grant and validates the original immutable inner receipt',()=>{
 const {envelope}=receiptFixture();assert.deepEqual(validatePublicRevisionWorkReceipt(envelope),envelope);
 const copy=validatePublicRevisionWorkReceipt(envelope);copy.revision.base_reference.version++;assert.equal(envelope.revision.base_reference.version,2);
});
test('original GET completion and unknown state do not rotate the outer work receipt identity',()=>{
 const {envelope}=receiptFixture(),original=envelope.receipt_hash;
 envelope.revision.state='blocked_unknown';assert.equal(revisionWorkReceiptHash(envelope),original);validatePublicRevisionWorkReceipt(envelope);
 envelope.revision.state='completed';envelope.revision.result_reference={...envelope.revision.base_reference,version:3,content_hash:hash('revised body')};envelope.revision.result_receipt_hash=hash('result receipt');
 assert.equal(revisionWorkReceiptHash(envelope),original);validatePublicRevisionWorkReceipt(envelope);
 assert.equal(envelope.revision.receipt_hash,taskRevisionReceiptHash(envelope.revision));
});
test('public work receipt refuses extra fields, wrong grant and changed inner immutable identities',()=>{
 for(const mutate of [
 e=>e.extra=true,e=>e.grant_reference.contract='catpaw.task-work-grant.v1',e=>e.grant_reference.schema_version=1,e=>e.grant_reference.grant_id=ids.run,e=>e.grant_reference.extra=true,
 e=>e.revision.operation_id=ids.run,e=>e.revision.instruction_hash=hash('other instruction'),e=>e.revision.extra=true,
 e=>e.input_hash=hash('other input'),e=>e.target_hash=hash('other target'),e=>e.work_intent_hash=hash('other work'),e=>e.grant_receipt_hash=hash('other receipt')
 ]){const {envelope}=receiptFixture();mutate(envelope);assert.throws(()=>validatePublicRevisionWorkReceipt(envelope));}
});
test('completed receipt cannot omit or substitute its exact same-artifact result reference',()=>{
 for(const mutate of [
 r=>{},r=>{r.result_reference={artifact_id:hash('other artifact'),version:3,content_hash:hash('body')};r.result_receipt_hash=hash('result');},
 r=>{r.result_reference={...r.base_reference};r.result_receipt_hash=hash('result');},
 r=>{r.result_reference={...r.base_reference,version:3};r.result_receipt_hash='not-a-hash';}
 ]){const {envelope}=receiptFixture();envelope.revision.state='completed';mutate(envelope.revision);assert.throws(()=>validatePublicRevisionWorkReceipt(envelope));}
});
