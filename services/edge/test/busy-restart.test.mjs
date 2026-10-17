import test from 'node:test';import assert from 'node:assert/strict';
import {assertBusyRestartable,restartedTurn,BUSY_RESTART_LIMIT} from '../supabase/functions/_shared/core/src/busy-restart.mjs';
const ev=(type,sequence)=>({type,sequence,data:{}});
const base=()=>({id:'turn-1',conversation_id:'c1',subject_id:'s1',grant_epoch:1,conversation_revision:2,state:'failed',error:{code:'rate_limited',retryable:false,reconciliation_required:false,retry_after_seconds:20},finished_at:'x',events:[ev('turn_started',1),ev('turn_failed',2)]});
const conv={id:'c1',state:'active',last_turn_id:'turn-1',grant_epoch:1,revision:2};const who={subject_id:'s1'};
const code=c=>e=>e.code===c;
test('same turn id restarts after rate_limited with no output; sequence continues',()=>{
 const t=base();assert.doesNotThrow(()=>assertBusyRestartable(t,conv,who));
 const next=restartedTurn(t);assert.equal(next.id,'turn-1');assert.equal(next.state,'running');assert.equal(next.error,null);assert.equal(next.finished_at,undefined);assert.equal(next.busy_restarts,1);
 assert.equal(next.events.length+1,3,'next event is sequence 3, after the original failure');assert.deepEqual(next.events,t.events);});
test('turn that already streamed output is not restartable',()=>{for(const type of ['text_delta','tool_call','tool_result','reasoning_summary']){const t=base();t.events.splice(1,0,ev(type,2));assert.throws(()=>assertBusyRestartable(t,conv,who),code('turn_output_started'));}});
test('non rate_limited failures and unknown outcomes are not restartable',()=>{
 for(const patch of [{error:{code:'provider_failed'}},{state:'outcome_unknown'},{state:'completed',error:null},{work_intent:{}},{revision_target:{}}])assert.throws(()=>assertBusyRestartable({...base(),...patch},conv,who),code('turn_not_restartable'));});
test('only the conversation head of the same subject, bounded restarts',()=>{
 assert.throws(()=>assertBusyRestartable(base(),{...conv,last_turn_id:'turn-2'},who),code('turn_not_restartable'));
 assert.throws(()=>assertBusyRestartable(base(),conv,{subject_id:'other'}),code('turn_not_found'));
 assert.throws(()=>assertBusyRestartable({...base(),busy_restarts:BUSY_RESTART_LIMIT},conv,who),code('busy_restart_limit'));});
