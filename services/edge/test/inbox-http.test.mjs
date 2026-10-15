import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {revisionWorkHTTPFixture} from './fixtures/revision-work-http-fixture.mjs';
import {hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
const endpoint=f=>`/catpaw/inbox/v1/scopes/${f.scope.scope_id}/items`;
const artifactPath=(f,ref)=>`/catpaw/artifacts/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/artifacts/${ref.artifact_id}/versions/${ref.version}`;
const get=async(f,path,auth)=>f.json(await f.req(path,undefined,auth));
test('actual composed inbox finds A from B with canonical binding and same artifact, with no GET effects',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const conversationB=randomUUID(),base=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations`;
  await f.json(await f.req(base,{conversation_id:conversationB}),201);
  const before=f.repository.snapshot(),calls=f.calls.length,ticks=f.ticks(),reads=f.reads();
  const page=await get(f,endpoint(f));assert.equal(page.contract,'catpaw.inbox.v1');assert.equal(page.items.length,1);
  const item=page.items[0];assert.deepEqual(item.binding,f.binding);assert.deepEqual(item.artifacts,f.run.artifact_references);assert.equal(item.task_status,'succeeded');assert.equal(item.authorization_state,'current');
  assert.deepEqual(Object.keys(page).sort(),['schema_version','contract','scope_id','subject_id','items','next_cursor'].sort());
  assert.deepEqual(Object.keys(item).sort(),['binding','title','created_at','updated_at','task_status','authorization_state','artifacts','plan_reference','pending_action_count'].sort());
  const responses={};responses[endpoint(f)]=page;
  for(const path of [f.binding.projection_url,`${base}/${f.cid}`,`${base}/${conversationB}`,`${base}/${f.cid}/turns/${f.binding.turn_id}`,artifactPath(f,item.artifacts[0]),`/catpaw/v1/scopes/${f.scope.scope_id}/artifacts/${item.artifacts[0].artifact_id}/versions/${item.artifacts[0].version}`,'/readyz','/catpaw/privacy/v1/model-route'])responses[path]=await get(f,path);
  assert.deepEqual(responses[f.binding.projection_url].run.artifact_references,item.artifacts);
  assert.deepEqual(responses[f.binding.projection_url].plan.applied_revision,item.plan_reference.revision);
  assert.equal(responses[artifactPath(f,item.artifacts[0])].artifact.content_hash,item.artifacts[0].content_hash);
  const legacy=responses[`/catpaw/v1/scopes/${f.scope.scope_id}/artifacts/${item.artifacts[0].artifact_id}/versions/${item.artifacts[0].version}`];assert.equal(legacy.artifact.content_hash,item.artifacts[0].content_hash);assert.equal(hash(legacy.artifact.body),item.artifacts[0].content_hash);
  assert.deepEqual(f.repository.snapshot(),before);assert.equal(f.calls.length,calls);assert.equal(f.ticks(),ticks);assert.equal(f.reads(),reads);
  const output=globalThis.Deno?.args.find(v=>v.startsWith('--fixture-output='))?.slice('--fixture-output='.length);
  if(output)await writeFile(output,JSON.stringify({synthetic_only:true,scope_id:f.scope.scope_id,subject_id:f.principal.subject_id,conversation_a:f.cid,conversation_b:conversationB,page,responses},null,2)+'\n');
 }finally{f.stop();}
});
async function addTask(f,{auth='Bearer original',text='A second fictional report'}={}){
 const cid=randomUUID(),base=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations`;
 await f.json(await f.req(base,{conversation_id:cid},auth),201);
 await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash},auth));
 const turn={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text},context:[]};
 const response=await f.req(`${base}/${cid}/turns`,turn,auth);assert.equal(response.status,200);await response.body.getReader().cancel();await f.runtime.chat.waitIdle();
 const stored=await get(f,`${base}/${cid}/turns/${turn.turn_id}`,auth);assert.equal(stored.turn.state,'completed');return stored.turn.task_bindings[0];
}
async function denied(f,path,status,code,auth){const response=await f.req(path,undefined,auth),body=await response.json();assert.equal(response.status,status,JSON.stringify(body));assert.equal(body.error.code,code);assert.equal(body.error.retryable,false);}
test('same owner other actor and unauthorized scope cannot discover A',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  assert.deepEqual((await get(f,endpoint(f),'Bearer foreign')).items,[]);
  await denied(f,endpoint(f).replace(f.scope.scope_id,randomUUID()),403,'scope_forbidden');
  const b=await addTask(f,{auth:'Bearer foreign'}),mine=await get(f,endpoint(f)),theirs=await get(f,endpoint(f),'Bearer foreign');
  assert.deepEqual(mine.items.map(x=>x.binding.run_id),[f.run.id]);assert.deepEqual(theirs.items.map(x=>x.binding.run_id),[b.run_id]);
 }finally{f.stop();}
});
test('strict query, canonical scope, methods and malformed cursors fail closed',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  for(const suffix of ['?limit=0','?limit=51','?limit=01','?limit=1&limit=2','?cursor=','?cursor=!!!!','?cursor=a','?cursor=a&cursor=b','?other=1'])await denied(f,endpoint(f)+suffix,422,suffix.startsWith('?cursor=')&&!suffix.includes('&')?'inbox_cursor_invalid':'inbox_query_invalid');
  await denied(f,endpoint(f).replace(f.scope.scope_id,f.scope.scope_id.toUpperCase()),422,'inbox_query_invalid');
  const post=await f.req(endpoint(f),{});assert.equal(post.status,405);assert.equal((await post.json()).error.code,'method_not_allowed');
  assert.equal((await f.req(endpoint(f).replace('/v1/','/v2/'))).status,404);
 }finally{f.stop();}
});
test('stable keyset cursor binds actor and scope, excludes newer runs and survives task updates',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const second=await addTask(f),third=await addTask(f),path=endpoint(f)+'?limit=1',first=await get(f,path);assert.equal(first.items.length,1);assert.ok(first.next_cursor);
  await denied(f,path+'&cursor='+first.next_cursor,409,'inbox_cursor_partition_conflict','Bearer foreign');
  const outsidePath=path.replace(f.scope.scope_id,f.outside.scopes[0].scope_id)+'&cursor='+first.next_cursor;
  await denied(f,outsidePath,409,'inbox_cursor_partition_conflict','Bearer outside');
  await f.repository.transaction(async tx=>{const task=await tx.get(f.owner,'tasks',f.task.id);await tx.put(f.owner,'tasks',{...task,updatedAt:new Date(Date.now()+5000).toISOString()});});
  const fourth=await addTask(f);const ids=[first.items[0].binding.run_id];let cursor=first.next_cursor;
  while(cursor){const page=await get(f,path+'&cursor='+cursor);ids.push(...page.items.map(x=>x.binding.run_id));cursor=page.next_cursor;}
  assert.equal(new Set(ids).size,3);assert.deepEqual(new Set(ids),new Set([f.run.id,second.run_id,third.run_id]));assert.ok(!ids.includes(fourth.run_id));
 }finally{f.stop();}
});
test('original source revocation retains historical summary but no artifact or pending authority; viewer remains mandatory',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  await f.mutateSession(f.principal,{state:'revoked'});
  const page=await get(f,endpoint(f),'Bearer fresh'),item=page.items[0];assert.equal(item.authorization_state,'superseded');assert.deepEqual(item.artifacts,[]);assert.equal(item.pending_action_count,0);assert.deepEqual(item.binding,f.binding);
  await denied(f,endpoint(f),409,'grant_conflict');await f.mutateSession(f.fresh,{state:'revoked'});await denied(f,endpoint(f),409,'grant_conflict','Bearer fresh');
 }finally{f.stop();}
});
test('conversation/delegation and memory generation changes make historical rows read-only',async()=>{
 for(const reason of ['conversation','delegation','generation']){const f=await revisionWorkHTTPFixture();try{await f.invalidate(reason);const page=await get(f,endpoint(f));assert.equal(page.items.length,1);assert.equal(page.items[0].authorization_state,'superseded',reason);assert.deepEqual(page.items[0].artifacts,[]);assert.equal(page.items[0].pending_action_count,0);}finally{f.stop();}}
});
test('erased original conversation or turn never returns title or references, including cursor continuations',async()=>{
 for(const kind of ['native-chat-turns','native-chat-conversations']){const f=await revisionWorkHTTPFixture();try{
  await f.repository.transaction(async tx=>{const id=kind==='native-chat-turns'?f.binding.turn_id:f.cid,row=await tx.get(f.owner,kind,id);await tx.put(f.owner,kind,{...row,...kind==='native-chat-turns'?{content_redacted:true}:{source_purged_at:new Date().toISOString()}});});
  const page=await get(f,endpoint(f));assert.deepEqual(page.items,[]);assert.equal(page.next_cursor,null);assert.ok(!JSON.stringify(page).includes('Offline report'));
 }finally{f.stop();}}
});
test('a forged original task binding or canonical artifact hash is not returned as a valid item',async()=>{
 for(const kind of ['binding','artifact']){const f=await revisionWorkHTTPFixture();try{
  await f.repository.transaction(async tx=>{if(kind==='binding'){const t=await tx.get(f.owner,'native-chat-turns',f.binding.turn_id);await tx.put(f.owner,'native-chat-turns',{...t,task_bindings:[{...f.binding,conversation_id:randomUUID()}]});}else{const ref=f.run.artifact_references[0],v=await tx.get(f.owner,'catpaw-artifact-versions',`${ref.artifact_id}:${ref.version}`);await tx.put(f.owner,'catpaw-artifact-versions',{...v,body:v.body+' '});}});
  const response=await f.req(endpoint(f));assert.equal(response.status,409);assert.equal((await response.json()).error.code,kind==='binding'?'inbox_binding_conflict':'artifact_corrupt');
 }finally{f.stop();}}
});
test('title text is safe and bounded to 512 UTF8 bytes without splitting scalar values',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  await f.repository.transaction(async tx=>{const task=await tx.get(f.owner,'tasks',f.task.id);await tx.put(f.owner,'tasks',{...task,title:'\u0000\u202e'+ '🐾'.repeat(160)});});
  const item=(await get(f,endpoint(f))).items[0];assert.equal(item.title,'🐾'.repeat(128));assert.equal(new TextEncoder().encode(item.title).length,512);
 }finally{f.stop();}
});
test('pending actions are counted only from the existing current action projection',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const original=f.runtime.facade.beforeActionRead;f.runtime.facade.beforeActionWrite=(tx,ctx)=>original(tx,ctx); // Explicit offline target authority injection; no device executor.
  const plan=(await get(f,f.binding.projection_url)).plan;
  const input={operation_id:randomUUID(),kind:'calendar.create.v1',expected_plan_revision:plan.applied_revision,expected_plan_hash:plan.applied_plan_hash,expected_grant_epoch:f.binding.grant_epoch,target:{device_id:randomUUID(),environment_id:randomUUID(),calendar_id:'offline-test-calendar',calendar_display_name:'Offline test calendar',calendar_snapshot_hash:hash('named offline target descriptor')},parameters:{title:'Offline review meeting',start_at:'2026-10-15T01:00:00.000Z',end_at:'2026-10-15T01:20:00.000Z',time_zone:'Asia/Shanghai',reminder_offset_seconds:-300},artifact_reference:null,replaces_action_id:null};
  await f.json(await f.req(`/catpaw/actions/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/actions`,input),201);
  assert.equal((await get(f,endpoint(f))).items[0].pending_action_count,1);
  await f.invalidate('delegation');assert.equal((await get(f,endpoint(f))).items[0].pending_action_count,0);
 }finally{f.stop();}
});
test('provider tool call IDs retain their existing bounded-string contract rather than requiring a UUID',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const provider=f.runtime.chat.provider,original=provider.stream.bind(provider);provider.stream=async function*(input){for await(const event of original(input))yield event.type==='tool_call'?{...event,id:'call_offline_provider_ABC123'}:event;};
  const binding=await addTask(f);assert.equal(binding.call_id,'call_offline_provider_ABC123');
  const page=await get(f,endpoint(f));assert.equal(page.items.find(x=>x.binding.run_id===binding.run_id).binding.call_id,binding.call_id);
 }finally{f.stop();}
});
test('a redacted fresh revision source excludes the same task without falling back to its old artifact',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const request=await f.makeRequest();await f.accept(request);await f.settle();
  const page=await get(f,endpoint(f),'Bearer fresh');assert.equal(page.items.length,1);assert.equal(page.items[0].binding.run_id,f.run.id);assert.equal(page.items[0].artifacts[0].version,2);
  await f.invalidate('revision-source',request);assert.deepEqual((await get(f,endpoint(f),'Bearer fresh')).items,[]);
 }finally{f.stop();}
});
test('late current-viewer revocation is rechecked after awaited projections, and an aborted GET cannot return a page',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const original=f.runtime.facade.beforeArtifactRead;let calls=0;
  f.runtime.facade.beforeArtifactRead=async(tx,ctx)=>{const result=await original(tx,ctx);if(++calls===4){const key='system:supabase:'+hash(f.principal.issuer),row=await tx.get(key,'app-sessions',f.principal.session_id);await tx.put(key,'app-sessions',{...row,state:'revoked'});}return result;};
  await denied(f,endpoint(f),409,'grant_conflict');
  const controller=new AbortController();controller.abort();const response=await f.runtime.api(new Request('https://offline.example.invalid'+endpoint(f),{headers:{Authorization:'Bearer original'},signal:controller.signal}));assert.equal(response.status,409);assert.equal((await response.json()).error.code,'inbox_read_cancelled');
 }finally{f.stop();}
});
test('cursor continuation rechecks erasure rather than returning a retained prior-page snapshot',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  await addTask(f);const page=await get(f,endpoint(f)+'?limit=1');assert.ok(page.next_cursor);assert.notEqual(page.items[0].binding.run_id,f.run.id);
  await f.repository.transaction(async tx=>{const row=await tx.get(f.owner,'native-chat-turns',f.binding.turn_id);await tx.put(f.owner,'native-chat-turns',{...row,content_redacted:true});});
  const continuation=await get(f,endpoint(f)+'?limit=1&cursor='+page.next_cursor);assert.deepEqual(continuation.items,[]);assert.equal(continuation.next_cursor,null);
 }finally{f.stop();}
});
test('an accepted but unapplied plan is never advertised as the currently applied inbox plan',async()=>{
 const f=await revisionWorkHTTPFixture();try{
  const old=f.task.state.plan_binding;
  // Explicit stored checkpoint fixture: accepted plan 2 waits behind applied plan 1.
  await f.repository.transaction(async tx=>{
   const head=await tx.get(f.owner,'catpaw-task-plan-heads',f.run.id),version=await tx.get(f.owner,'catpaw-task-plan-versions',`${f.run.id}:1`),content={...version.content,requirements:'New requirements pending checkpoint'},plan_hash=hash(content);
   await tx.put(f.owner,'catpaw-task-plan-versions',{...version,id:`${f.run.id}:2`,revision:2,content,plan_hash});
   await tx.put(f.owner,'catpaw-task-plan-heads',{...head,accepted_revision:2,accepted_plan_hash:plan_hash,application_state:'pending'});
  });
  const projected=await get(f,f.binding.projection_url);assert.equal(projected.plan.accepted_revision,2);assert.equal(projected.plan.applied_revision,1);
  const before=f.repository.snapshot(),item=(await get(f,endpoint(f))).items[0];assert.deepEqual(item.plan_reference,old);assert.deepEqual(f.repository.snapshot(),before);
 }finally{f.stop();}
});
