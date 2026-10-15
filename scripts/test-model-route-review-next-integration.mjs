import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash,randomUUID} from 'node:crypto';
import {Buffer} from 'node:buffer';
import {ModelRouteReviewNextClient,newNextProbeJournal,nextReviewProbePlan} from './model-route-review-next-client.mjs';
import {TestRepository} from '../services/edge/supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {clone,hash} from '../services/edge/supabase/functions/_shared/core/facade-r2/src/common.mjs';

globalThis.Buffer??=Buffer;
globalThis.fetch=()=>{throw Error('r8_integration_external_network_forbidden');};
const packageRoot=new URL('../services/edge/build/model-route-review-20261015/packages-r8/',import.meta.url);
const sourceRoot=new URL('catpaw-api-v21/_shared/',packageRoot);
const manifest=JSON.parse(await readFile(new URL('PACKAGE-MANIFEST.json',packageRoot),'utf8'));
assert.equal(manifest.candidate_file_count,55);
for(const [path,expected] of Object.entries(manifest.files))assert.equal(createHash('sha256').update(await readFile(new URL('catpaw-api-v21/'+path,packageRoot))).digest('hex'),expected,'Frozen r8 source mismatch: '+path);
const packaged=await import(new URL('model-route-review-probe-next.mjs',sourceRoot));
const {readConfig}=await import(new URL('config.mjs',sourceRoot));
const {membershipOwner}=await import(new URL('authority.mjs',sourceRoot));
const plan=nextReviewProbePlan();
assert.equal(packaged.GEMMA_NEXT_REVIEW_ID,plan.review_id);
assert.equal(packaged.GEMMA_NEXT_REVIEW_ROUTE_HASH,plan.route_hash);
const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-unused-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};

class OperationJournal {
 constructor(){this.data=null;this.serial=Promise.resolve();}
 async load(){return clone(this.data);}
 update(fn){const value=this.serial.then(()=>{this.data=clone(fn(clone(this.data??newNextProbeJournal())));return clone(this.data);});this.serial=value.catch(()=>{});return value;}
}
function repositoryWithSQL(snapshot){
 const repository=new TestRepository(snapshot),transaction=repository.transaction.bind(repository);
 // Read-only authority SQL stand-in only; this is not real Auth, TLS or PostgreSQL verification.
 repository.transaction=fn=>transaction(tx=>{tx.connection={query:async(sql,args)=>{
  if(sql.startsWith('SELECT pg_advisory_xact_lock'))return {rows:[]};
  const kind=/kind='([^']+)'/.exec(sql)?.[1];assert.ok(['app-sessions','scope-memberships'].includes(kind));
  const row=await tx.get(args[0],kind,args[1]);return {rows:row?[{data:row}]:[]};
 }};return fn(tx);});return repository;
}
async function fixture(outcome){
 const scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const actor={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://dbyklgxdvjbutxzsjeth.supabase.co/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}};
 const vault={attempt_id:randomUUID(),subject_id:actor.subject_id,is_anonymous:true,issuer:actor.issuer,expires_at:Date.now()+600000,access_token:'synthetic-probe',refresh_token:'synthetic-unused',publishable_key:'sb_publishable_synthetic01'};
 const original={review_id:plan.route_review_id,route_hash:plan.route_hash,auth:{known:true,attempt_id:vault.attempt_id,subject_id:actor.subject_id},scope:{scope_id:scope.scope_id}},existingBefore=JSON.stringify({original,vault});
 const existingSessionStore={load:async()=>clone(original),vault:async()=>clone(vault)},journal=new OperationJournal(),calls={model:0,turnPOST:0,http:[]},retained=[];
 let repository=repositoryWithSQL(),server;
 const make=async()=>{
  server=await packaged.createGemmaNextShortTextProbeRuntime({repository,authenticate:authorization=>{assert.ok(authorization==='Bearer '+vault.access_token,'Only injected synthetic session');return actor;},config:readConfig(name=>values[name]),retain:p=>retained.push(p),subjectID:actor.subject_id,scopeID:scope.scope_id,liveNetworkEnabled:true,fetchImpl:async(url,init)=>{
   calls.model++;assert.equal(calls.model,1,'No replacement inference is permitted');assert.equal(url,'https://openrouter.ai/api/v1/chat/completions');assert.equal(init.redirect,'error');
   const body=JSON.parse(init.body);assert.equal(body.max_tokens,512);assert.equal(body.model,plan.model);assert.deepEqual(body.tools??[],[]);assert.deepEqual(body.provider,plan.routing_policy);
   if(outcome==='429')return Response.json({error:{code:429,message:'Synthetic provider rate limit'}},{status:429});
   const chunks=[{id:'synthetic-r8-response',model:plan.model,provider:plan.provider,choices:[{index:0,delta:{content:'received.'}}]},{id:'synthetic-r8-response',model:plan.model,provider:plan.provider,usage:{cost:0},choices:[{index:0,delta:{},finish_reason:'stop'}]}];
   return new Response(chunks.map(value=>'data: '+JSON.stringify(value)+'\n\n').join('')+'data: [DONE]\n\n',{headers:{'Content-Type':'text/event-stream'}});
  }});
 };
 await make();await server.runtime.foundation.bootstrapScope(actor,scope.scope_id);
 await repository.transaction(async tx=>{await tx.put(membershipOwner(actor.issuer),'app-sessions',{id:actor.session_id,subject_id:actor.subject_id,state:'active',expires_at:Math.floor(Date.now()/1000)+600});await tx.put(membershipOwner(actor.issuer),'scope-memberships',{id:actor.subject_id,state:'active',tokens_valid_after:1,revoked_session_ids:[],scopes:[scope]});});
 const env={CATPAW_REVIEW_PROBE_ID:plan.route_review_id,CATPAW_REVIEW_PROBE_SUBJECT_ID:actor.subject_id,CATPAW_REVIEW_PROBE_SCOPE_ID:scope.scope_id};
 const fetchImpl=async(url,init)=>{
  assert.ok(url.startsWith(plan.api+plan.prefix+'/'));assert.equal(init.redirect,'error');assert.ok(!new URL(url).pathname.includes('/auth/'));
  calls.http.push({path:new URL(url).pathname,method:init.method});
  if(init.method==='POST'&&url.endsWith('/turns')){calls.turnPOST++;assert.equal(calls.turnPOST,1);const saved=await journal.load();assert.equal(saved.turn.attempted,true);assert.equal(saved.input_hash,hash(JSON.parse(init.body)));}
  const selected=packaged.selectGemmaNextReviewRequest(new Request(url,init),name=>env[name],'api');
  const response=await server.api(selected.request);Object.defineProperty(response,'url',{value:url});return response;
 };
 const client=()=>new ModelRouteReviewNextClient({existingSessionStore,operationJournal:journal,fetchImpl,execute:true,approval:plan.review_id});
 return {client,calls,journal,get repository(){return repository;},get server(){return server;},scope,actor,async restart(){await server.runtime.worker.stop();repository=repositoryWithSQL(repository.snapshot());await make();},async stop(){await Promise.all(retained);await server.runtime.worker.stop();},checkExisting(){assert.equal(JSON.stringify({original,vault}),existingBefore);for(const value of [vault.access_token,vault.refresh_token,vault.publishable_key])assert.ok(!JSON.stringify(journal.data).includes(value),'No credential copied to operation journal');}};
}
for(const outcome of ['success','429'])test('frozen 55-file wrapper → actual chat/provider/SSE/receipt → next client '+outcome,async()=>{
 const f=await fixture(outcome);
 try{
  const c=f.client();await c.prepareConversation();await c.consent({allowRouteHash:plan.route_hash});const result=await c.send();
  assert.equal(result.state,outcome==='success'?'bounded_text_route_probe_pass':'probe_FAIL_or_unknown_stop');
  assert.equal(result.turn_state,outcome==='success'?'completed':'failed');assert.equal(result.product_acceptance,false);
  assert.equal(result.first_delta_seen,outcome==='success');assert.equal(result.cost,outcome==='success'?0:null);assert.equal(result.terminal_validated,outcome==='success');
  assert.equal(f.calls.model,1);assert.equal(f.calls.turnPOST,1);f.checkExisting();
  const posts=f.calls.http.filter(value=>value.method==='POST').length;assert.equal(posts,3);
  await f.restart();const before=f.repository.snapshot(),cold=f.client(),recovered=await cold.observe();
  assert.deepEqual(recovered,result);assert.deepEqual(f.repository.snapshot(),before,'Cold original GET has no task/model/authority writes');assert.equal(f.calls.http.filter(value=>value.method==='POST').length,posts);
  await assert.rejects(()=>cold.send(),error=>error.code==='probe_original_GET_only');assert.equal(f.calls.model,1);assert.equal(f.calls.turnPOST,1);
  assert.equal(f.server.transport.observations.length,0,'Cold runtime does not invoke a replacement provider');f.checkExisting();
  const owner=f.server.runtime.facade.owner(f.scope);for(const kind of ['tasks','catpaw-runs','catpaw-delegations'])assert.deepEqual(await f.repository.transaction(tx=>tx.list(owner,kind)),[]);
 }finally{await f.stop();}
});
