import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {memoryHTTPFixture} from './fixtures/memory-http-fixture.mjs';
import {ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {PARENTING_INTAKE_CONTRACT as CONTRACT,PARENTING_INTAKE_PREFIX as PREFIX} from '../supabase/functions/_shared/core/src/parenting-intake-contract.mjs';

globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const draft=id=>({schema_version:1,contract:CONTRACT,request_id:id,title:'合成绘本安排',due_at:null,time_evidence:null,clarification:'请补充日期和钟点'});
const requestID=input=>JSON.parse(input.messages.at(-1).content).request_id;
const output=async function*(input){yield {type:'text_delta',text:JSON.stringify(draft(requestID(input)))};yield {type:'done',finish_reason:'stop'};};
async function fixture(options={}){
 const f=await memoryHTTPFixture({stream:options.stream??output,...options});
 f.baseIntake=`${PREFIX}/scopes/${f.scope.scope_id}/conversations`;
 f.prepare=async({consent=true}={})=>{
  const cid=randomUUID(),created=await f.req(f.baseIntake,{conversation_id:cid});assert.equal(created.status,201,await created.clone().text());assert.equal((await created.json()).conversation.intake_contract,CONTRACT);
  if(consent)await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
  const tid=randomUUID(),path=f.baseIntake+'/'+cid,body={turn_id:tid,expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:JSON.stringify({request_id:tid,source_text:'合成读绘本，时间还没定'})},context:[]};
  return {cid,tid,path,body};
 };
 f.sendIntake=async(p,headers={})=>{const response=await f.req(p.path+'/turns',p.body,'Bearer memory-fixture',headers);assert.equal(response.status,200,await response.clone().text());const wire=await response.text();await f.runtime.chat.waitIdle();const turn=(await f.json(await f.req(p.path+'/turns/'+p.tid))).turn;return {wire,turn};};
 f.records=async kind=>{const {owner}=await f.runtime.chat.scoped('Bearer memory-fixture',f.scope.scope_id);return f.repository.transaction(tx=>tx.list(owner,kind));};
 return f;
}
function deferred(){let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};}
const purge=(f,p,auth='Bearer memory-fixture')=>f.runtime.api(new Request('https://memory-test.example.invalid'+p.path,{method:'DELETE',headers:{Authorization:auth}}));

test('dedicated production handler freezes mode, uses selected provider port, strict JSON and no memory/tools/capability input',async()=>{
 const f=await fixture(),p=await f.prepare();let forbidden=0;
 const fail=()=>{forbidden++;throw Error('intake touched memory or capability service');};
 f.runtime.chat.facade.agentMemory={recallForTurn:fail,userTurnedOff:fail};f.runtime.chat.facade.agentMemoryPrivacy={userTurnedOff:fail};f.runtime.chat.facade.proactiveSuggestions={claimForTurn:fail};
 for(const name of ['memoryUserDisabled','memoryUsage','capture','stageMemoryExtraction','proposeMemory'])f.runtime.chat.integration[name]=fail;
 const {turn,wire}=await f.sendIntake(p,{'X-Catpaw-Use-Memory':'1','X-Catpaw-Live-Text':'1'});
 assert.equal(turn.state,'completed');assert.equal(turn.intake_contract,CONTRACT);assert.equal(forbidden,0);assert.equal(f.calls.length,1);
 assert.deepEqual(f.calls[0].tools,[]);assert.deepEqual(f.calls[0].messages,[{role:'user',content:p.body.message.text}]);
 assert.equal(f.calls[0].provider_context.memory_usage,undefined);assert.equal(f.calls[0].provider_context.memory_context,undefined);assert.match(f.calls[0].system_prompt,/No tools, memory/);
 assert.deepEqual(f.calls[0].provider_context.input_context,[{text:p.body.message.text}]); // The existing pre-provider sensitive-content gate sees transient source, despite empty persisted c.messages.
 const events=wire.split('\n\n').filter(s=>s.startsWith('data: ')).map(s=>JSON.parse(s.slice(6)));assert.ok(events.length>=3);assert.ok(events.every(e=>e.intake_contract===CONTRACT));assert.equal(events.at(-1).type,'turn_completed');
 assert.deepEqual(turn.task_bindings,[]);assert.deepEqual(await f.records('tasks'),[]);assert.deepEqual(await f.records('catpaw-delegations'),[]);assert.equal(f.repository.snapshot().rows.length,0);
});

test('scope, subject, purpose and single-intent boundaries apply to start, read, events, retry and cancellation',async()=>{
 const f=await fixture(),p=await f.prepare();await f.sendIntake(p);
 const ordinary=p.path.replace(PREFIX,'/catpaw/chat/v1');
 for(const suffix of ['',`/turns/${p.tid}`,`/turns/${p.tid}/events`])assert.equal((await f.req(ordinary+suffix)).status,404);
 for(const suffix of [`/turns/${p.tid}/cancel`,`/turns/${p.tid}/retry-busy`])assert.equal((await f.req(ordinary+suffix,{})).status,404);
 assert.equal((await f.req(ordinary+'/turns',p.body)).status,404);
 assert.equal((await f.req(p.path+'/turns/'+p.tid,undefined,'Bearer foreign-fixture')).status,404);
 assert.equal((await f.req(p.path.replace(f.scope.scope_id,randomUUID())+'/turns/'+p.tid)).status,403);
 assert.equal((await f.req(p.path+'/turns/'+randomUUID()+'/cancel',{})).status,404);
 const second={...p.body,turn_id:randomUUID(),message:{id:randomUUID(),text:'replaced'}};second.message.text=JSON.stringify({request_id:second.turn_id,source_text:'second'});
 const rejected=await f.req(p.path+'/turns',second);assert.equal(rejected.status,409);assert.equal((await rejected.json()).error.code,'parenting_intake_single_request');
 const cid=await f.newConversation(),normal=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
 assert.equal((await f.req(normal.replace('/catpaw/chat/v1',PREFIX))).status,404);
 assert.equal((await f.req(p.path+'/control',{type:'revoke'})).status,404);assert.equal(f.calls.length,1);
});

test('duplicate POST replays original receipt; changed input with same identity is rejected without another provider call',async()=>{
 const f=await fixture(),p=await f.prepare(),first=await f.sendIntake(p);
 const replay=await f.req(p.path+'/turns',p.body);assert.equal(replay.status,200);const result=await replay.json();assert.equal(result.replayed,true);assert.deepEqual(result.turn.events,first.turn.events);assert.equal(result.turn.intake_contract,CONTRACT);
 const changed={...p.body,message:{...p.body.message,text:p.body.message.text+' changed'}};assert.equal((await f.req(p.path+'/turns',changed)).status,409);assert.equal(f.calls.length,1);
});

test('consent, source authority and existing daily quota remain required before provider dispatch',async()=>{
 const noConsent=await fixture(),p=await noConsent.prepare({consent:false}),refused=await noConsent.req(p.path+'/turns',p.body);assert.equal(refused.status,403);assert.equal(noConsent.calls.length,0);
 const revoked=await fixture(),q=await revoked.prepare();revoked.setSourceActive(false);assert.equal((await revoked.req(q.path+'/turns',q.body)).status,409);assert.equal(revoked.calls.length,0);
 const sensitive=await fixture(),privateInput=await sensitive.prepare();privateInput.body.message.text=JSON.stringify({request_id:privateInput.tid,source_text:'medical record: fictional protected health detail'});
 const sensitiveRefusal=await sensitive.req(privateInput.path+'/turns',privateInput.body);assert.equal(sensitiveRefusal.status,403);assert.equal(sensitive.calls.length,0);assert.equal(JSON.stringify(sensitive.repository.snapshot()).includes('fictional protected health detail'),false);
 const limited=await fixture({env:{CATPAW_DAILY_CALL_LIMIT:'1'}}),one=await limited.prepare();assert.equal((await limited.sendIntake(one)).turn.state,'completed');
 const two=await limited.prepare(),blocked=await limited.req(two.path+'/turns',two.body);assert.equal(blocked.status,200);await blocked.text();await limited.runtime.chat.waitIdle();assert.equal(limited.calls.length,1);const state=(await limited.json(await limited.req(two.path+'/turns/'+two.tid))).turn;assert.equal(state.state,'failed');assert.equal(state.error.code,'model_daily_limit');
});

test('tool calls cannot reach tool execution, and malformed or identity-mismatched model JSON never completes',async()=>{
 const cases=[
  async function*(){yield {type:'tool_call',id:'forbidden',name:'memory_save',arguments:{content:'must never persist'}};yield {type:'done',finish_reason:'tool_calls'};},
  async function*(){yield {type:'text_delta',text:'{"schema_version":1,"schema_version":1}'};yield {type:'done',finish_reason:'stop'};},
  async function*(input){yield {type:'text_delta',text:JSON.stringify({...draft(requestID(input)),request_id:randomUUID()})};yield {type:'done',finish_reason:'stop'};},
  async function*(input){yield {type:'text_delta',text:JSON.stringify({...draft(requestID(input)),child_id:randomUUID()})};yield {type:'done',finish_reason:'stop'};}
 ];
 for(const stream of cases){const f=await fixture({stream}),p=await f.prepare();let executions=0;f.runtime.chat.executeTool=async()=>{executions++;throw Error('forbidden');};const {turn}=await f.sendIntake(p);assert.equal(turn.state,'failed');assert.equal(turn.events.some(e=>e.type==='turn_completed'||e.type==='tool_call'||e.type==='tool_result'),false);assert.equal(executions,0);assert.deepEqual(await f.records('tasks'),[]);assert.equal(f.repository.snapshot().rows.length,0);}
});

test('capability/context/attachment injection and malformed duplicate request fields are refused before any model call',async()=>{
 for(const headers of [{'X-Catpaw-Memory-Proposal-Contract':'catpaw.memory-proposal.v1'},{'X-Catpaw-Approval-Contract':'catpaw.approval.v1'},{'X-Catpaw-UI-Kinds':'text'},{'X-Catpaw-Device-Tools':'calendar_list'}]){
  const f=await fixture(),p=await f.prepare(),response=await f.req(p.path+'/turns',p.body,'Bearer memory-fixture',headers);assert.equal(response.status,422);assert.equal(f.calls.length,0);
 }
 const f=await fixture(),p=await f.prepare();assert.equal((await f.req(p.path+'/turns',{...p.body,context:[{id:'injected',text:'secret context'}]})).status,422);
 const bad={...p.body,message:{...p.body.message,attachment_ids:[randomUUID()]}};assert.notEqual((await f.req(p.path+'/turns',bad)).status,200);
 const raw=JSON.stringify(p.body).replace('"context":[]','"context":[],"context":[]');assert.equal((await f.req(p.path+'/turns',raw)).status,422);assert.equal(f.calls.length,0);
});

test('cancel wins before model completion, late output cannot complete, and completion-first cancellation reports the durable outcome',async()=>{
 const entered=deferred(),release=deferred();
 const f=await fixture({stream:async function*(input){entered.resolve();await release.promise;yield*output(input);}}),p=await f.prepare();
 const response=await f.req(p.path+'/turns',p.body);await entered.promise;
 const cancelled=await f.json(await f.req(p.path+'/turns/'+p.tid+'/cancel',{}));assert.equal(cancelled.cancel.cancelled,true);assert.equal(cancelled.cancel.intake_contract,CONTRACT);release.resolve();await response.text();await f.runtime.chat.waitIdle();
 const turn=(await f.json(await f.req(p.path+'/turns/'+p.tid))).turn;assert.equal(turn.state,'failed');assert.equal(turn.error.code,'cancelled');assert.equal(turn.events.some(e=>e.type==='turn_completed'),false);
 const done=await fixture(),q=await done.prepare();await done.sendIntake(q);const late=await done.json(await done.req(q.path+'/turns/'+q.tid+'/cancel',{}));assert.equal(late.cancel.cancelled,false);assert.equal(late.cancel.already_terminal,true);assert.equal(late.cancel.state,'completed');
});

test('unknown outcomes can only be read; explicit busy retry keeps original identity and the read-only mode',async()=>{
 const unknown=await fixture({stream:async function*(){throw new ApiError(503,'named_uncertain_provider',{reconciliation:true});}}),p=await unknown.prepare(),first=await unknown.sendIntake(p);assert.equal(first.turn.state,'outcome_unknown');
 assert.equal((await unknown.req(p.path+'/turns/'+p.tid+'/retry-busy',{})).status,409);const replay=await unknown.req(p.path+'/turns',p.body);assert.equal((await replay.json()).replayed,true);assert.equal(unknown.calls.length,1);
 let attempts=0;const busy=await fixture({stream:async function*(input){if(attempts++===0)throw new ApiError(429,'rate_limited');yield*output(input);}}),q=await busy.prepare(),failed=await busy.sendIntake(q);assert.equal(failed.turn.state,'failed');assert.equal(failed.turn.error.code,'rate_limited');
 const retried=await busy.req(q.path+'/turns/'+q.tid+'/retry-busy',{});assert.equal(retried.status,200);await retried.text();await busy.runtime.chat.waitIdle();const final=(await busy.json(await busy.req(q.path+'/turns/'+q.tid))).turn;assert.equal(final.state,'completed');assert.equal(final.id,q.tid);assert.equal(final.intake_contract,CONTRACT);assert.equal(busy.calls.length,2);assert.ok(busy.calls.every(c=>c.tools.length===0&&c.provider_context.memory_usage===undefined));
});

test('normal namespace cannot bypass purpose fences using repeated path separators; foreign operations never mutate the intake',async()=>{
 const f=await fixture(),p=await f.prepare();await f.sendIntake(p);
 for(const normal of [p.path.replace(PREFIX,'/catpaw/chat/v1'),p.path.replace(PREFIX,'/catpaw/chat/v1/'),p.path.replace(PREFIX,'/catpaw//chat/v1')]){
  for(const [suffix,body] of [['',undefined],['/turns/'+p.tid,undefined],['/turns/'+p.tid+'/events',undefined],['/turns/'+p.tid+'/cancel',{}],['/turns/'+p.tid+'/retry-busy',{}],['/control',{type:'revoke'}]])assert.equal((await f.req(normal+suffix,body)).status,404);
 }
 for(const [suffix,body] of [['/turns',p.body],['/turns/'+p.tid,undefined],['/turns/'+p.tid+'/events',undefined],['/turns/'+p.tid+'/cancel',{}],['/turns/'+p.tid+'/retry-busy',{}]])assert.equal((await f.req(p.path+suffix,body,'Bearer foreign-fixture')).status,404);
 assert.equal((await purge(f,p,'Bearer foreign-fixture')).status,404);assert.equal((await f.json(await f.req(p.path+'/turns/'+p.tid))).turn.state,'completed');assert.equal(f.calls.length,1);
 const normalCID=await f.newConversation(),ordinary={...p,path:f.baseIntake+'/'+normalCID};
 assert.equal((await f.req(ordinary.path+'/turns',p.body)).status,404);assert.equal((await f.req(ordinary.path+'/turns/'+p.tid+'/cancel',{})).status,404);assert.equal((await purge(f,ordinary)).status,404);
});

test('source, answer and reasoning canaries are live only, never in durable snapshots or logs; cold read never invokes a provider',async()=>{
 const sourceCanary='SOURCE_ONLY_'+randomUUID(),answerCanary='ANSWER_ONLY_'+randomUUID(),reasonCanary='REASON_ONLY_'+randomUUID(),logs=[],oldLog=console.info;
 console.info=(...parts)=>logs.push(parts.join(' '));
 try {
  const entered=deferred(),release=deferred(),f=await fixture({stream:async function*(input){entered.resolve();await release.promise;yield {type:'thinking_delta',text:reasonCanary};yield {type:'text_delta',text:JSON.stringify({...draft(requestID(input)),title:answerCanary})};yield {type:'done',finish_reason:'stop'};}}),p=await f.prepare();
  p.body.message.text=JSON.stringify({request_id:p.tid,source_text:sourceCanary});const response=await f.req(p.path+'/turns',p.body);await entered.promise;
  assert.equal(JSON.stringify(f.repository.snapshot()).includes(sourceCanary),false);release.resolve();const wire=await response.text();await f.runtime.chat.waitIdle();
  assert.ok(wire.includes(answerCanary));assert.ok(wire.includes(reasonCanary));
  const snapshot=f.repository.snapshot(),stored=JSON.stringify(snapshot);for(const canary of [sourceCanary,answerCanary,reasonCanary]){assert.equal(stored.includes(canary),false);assert.equal(logs.join('\n').includes(canary),false);}
  const cold=await fixture({snapshot,identity:{scope:f.scope,principal:f.principal,foreign:f.foreign}}),read=await cold.req(p.path+'/turns/'+p.tid);assert.equal(read.status,409);assert.equal((await read.json()).error.code,'parenting_intake_content_unavailable');
  const replay=await cold.req(p.path+'/turns',p.body);assert.equal(replay.status,409);assert.equal(cold.calls.length,0);assert.equal(f.calls.length,1);
 }finally{console.info=oldLog;}
});

test('DELETE removes transient data and all durable content fields, fences late output, and cannot be revived by duplicate start',async()=>{
 const sourceCanary='DELETE_SOURCE_'+randomUUID(),answerCanary='DELETE_ANSWER_'+randomUUID(),entered=deferred(),release=deferred();
 const f=await fixture({stream:async function*(input){entered.resolve();await release.promise;yield {type:'text_delta',text:JSON.stringify({...draft(requestID(input)),title:answerCanary})};yield {type:'done',finish_reason:'stop'};}}),p=await f.prepare();p.body.message.text=JSON.stringify({request_id:p.tid,source_text:sourceCanary});
 const response=await f.req(p.path+'/turns',p.body);await entered.promise;const deleted=await f.json(await purge(f,p));assert.equal(deleted.purge.purged,true);assert.equal(deleted.purge.retained,'identity_hash_tombstone_only');
 const before=f.repository.snapshot();release.resolve();try{await response.text();}catch{}await f.runtime.chat.waitIdle();
 const content=snapshot=>({rows:snapshot.rows,records:snapshot.records.filter(([key])=>['native-chat-conversations','native-chat-turns'].includes(JSON.parse(key)[1]))});
 assert.deepEqual(content(f.repository.snapshot()),content(before)); // Runtime lease release may update lease metadata.
 assert.equal(f.runtime.chat.intakeRuntime.size,0);const stored=JSON.stringify(before);assert.equal(stored.includes(sourceCanary),false);assert.equal(stored.includes(answerCanary),false);
 const turns=await f.records('native-chat-turns'),t=turns.find(t=>t.id===p.tid);assert.equal(t.intake_purged,true);assert.deepEqual(t.events,[]);for(const key of ['input','history','model_history','dispatch_checkpoint','memory_extraction','source_auth'])assert.equal(Object.hasOwn(t,key),false);
 assert.equal((await f.req(p.path+'/turns',p.body)).status,410);assert.equal((await f.req(p.path+'/turns/'+p.tid+'/retry-busy',{})).status,409);assert.equal((await f.req(p.path+'/turns/'+p.tid)).status,409);assert.equal((await f.json(await purge(f,p))).purge.already_purged,true);assert.equal(f.calls.length,1);
});

test('completed result deletion and fifteen-minute buffer expiry retain only metadata and never trigger regeneration',async()=>{
 const f=await fixture(),p=await f.prepare();await f.sendIntake(p);const deleted=await f.json(await purge(f,p));assert.equal(deleted.purge.purged,true);assert.equal(f.runtime.chat.intakeRuntime.size,0);assert.equal((await f.req(p.path+'/turns',p.body)).status,410);assert.equal(f.calls.length,1);
 const expired=await fixture(),q=await expired.prepare();await expired.sendIntake(q);expired.runtime.chat.clockNow=()=>Date.now()+16*60*1000;
 const read=await expired.req(q.path+'/turns/'+q.tid);assert.equal(read.status,409);assert.equal((await read.json()).error.code,'parenting_intake_content_unavailable');assert.equal(expired.runtime.chat.intakeRuntime.size,0);assert.equal((await expired.req(q.path+'/turns',q.body)).status,409);assert.equal(expired.calls.length,1);
});

test('untrusted provider failure details cannot persist or log source material',async()=>{
 const canary='PROVIDER_ERROR_SOURCE_'+randomUUID(),logs=[],oldLog=console.info;console.info=(...parts)=>logs.push(parts.join(' '));
 try{const f=await fixture({stream:async function*(){throw new ApiError(503,canary,{reconciliation:true});}}),p=await f.prepare();const {turn}=await f.sendIntake(p);assert.equal(turn.state,'outcome_unknown');assert.equal(turn.error.code,'parenting_intake_failed');assert.equal(JSON.stringify(f.repository.snapshot()).includes(canary),false);assert.equal(logs.join('\n').includes(canary),false);}finally{console.info=oldLog;}
});
