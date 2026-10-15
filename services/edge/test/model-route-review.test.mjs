import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readConfig} from '../supabase/functions/_shared/config.mjs';
import {readConfig as readAPI19Config} from '../deployed-baselines/2026-10-13/catpaw-api-v19/_shared/config.mjs';
import {createCloudRuntime} from '../supabase/functions/_shared/api.mjs';
import {prepareGemmaRouteReview,createGemmaReviewProvider,gemmaRouteReviewManifest,GEMMA_PRIVATE_REVIEW_ID} from '../supabase/functions/_shared/model-route-review.mjs';
import {OpenRouterProvider} from '../supabase/functions/_shared/core/src/openrouter-provider.mjs';
import {chatTools,validateProvidedToolCall} from '../supabase/functions/_shared/core/src/tools.mjs';
import {hash,clone,ApiError} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {membershipOwner} from '../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
globalThis.fetch=()=>{throw Error('model_route_review_external_network_forbidden');};
const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-unused-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'offline-unused-guard'};
const baseline=()=>readConfig(k=>values[k]);
const plan={title:'Fictional report',goal:'Use only the supplied fictional facts',requirements:'No external data',stop_conditions:['Save a local report'],steps:[{id:'compose',title:'Compose',detail:''},{id:'save',title:'Save',detail:''},{id:'verify',title:'Verify',detail:''}]};
function body({model='google/gemma-4-31b-it:free',provider='Google AI Studio',cost=0,done=true,finish='stop',tool=null,argumentsText=JSON.stringify(plan),earlyMetadata=null}={}){
 const chunks=tool?[{choices:[{index:0,delta:{tool_calls:[{index:0,id:'synthetic-review-call',type:'function',function:{name:tool,arguments:argumentsText}}]}}]}]:[{choices:[{index:0,delta:{content:'received.'}}]}];
 if(earlyMetadata)Object.assign(chunks[0],earlyMetadata);
 chunks.push({id:'synthetic-review-response',...model===null?{}:{model},...provider===null?{}:{provider},...cost===null?{}:{usage:{cost}},choices:[{index:0,delta:{},finish_reason:finish}]});
 return chunks.map(c=>'data: '+JSON.stringify(c)+'\n\n').join('')+(done?'data: [DONE]\n\n':'');
}
function transport(options={}){
 const manifest=gemmaRouteReviewManifest(),calls=[];
 const provider=createGemmaReviewProvider({reviewID:GEMMA_PRIVATE_REVIEW_ID,manifest,secret:'synthetic-review-only',liveNetworkEnabled:true,beforeStream:async()=>{},fetchImpl:async(url,init)=>{calls.push({url,payload:JSON.parse(init.body),redirect:init.redirect});return new Response(body(options),{headers:{'Content-Type':'text/event-stream'}});}});
 return {provider,calls,manifest};
}
const collect=async provider=>{const out=[];for await(const e of provider.stream({messages:[{role:'user',content:'Reply only: received.'}],system_prompt:'Synthetic offline test',tools:chatTools}))out.push(e);return out;};

test('inactive named review freezes full route/hash while defaults and data scope remain unchanged',()=>{
 const base=baseline(),before=clone(base),m=gemmaRouteReviewManifest(),p=prepareGemmaRouteReview(base,{reviewID:GEMMA_PRIVATE_REVIEW_ID});
 assert.deepEqual(base,before);assert.equal(baseline().route.model,'apodex/apodex-1.1-mini:free');assert.equal(m.activation,'inactive_explicit_injection_only');assert.equal(m.requires_new_conversation_consent,true);assert.equal(m.route_hash,hash(m.route));assert.notEqual(m.route_hash,base.routeHash);
 for(const key of ['data_fields','purposes','excluded_fields','history_limit','sensitive_requires_separate_confirmation','policy_url','endpoint'])assert.deepEqual(p.config.route[key],base.route[key]);
 assert.equal(p.config.route.downstream_provider,'Google AI Studio');assert.deepEqual(p.config.route.routing_policy,{only:['google-ai-studio'],allow_fallbacks:false,require_parameters:true,data_collection:'deny',max_price:{prompt:0,completion:0,request:0,image:0}});
 assert.throws(()=>prepareGemmaRouteReview(base),e=>e.code==='private_route_review_input_invalid');const modified=clone(base);modified.route.data_fields.push('automatic_email_access');assert.throws(()=>prepareGemmaRouteReview(modified,{reviewID:GEMMA_PRIVATE_REVIEW_ID}));
});

test('a freshly hashed memory data-range expansion cannot reuse this fixed review candidate',()=>{
 const expanded=baseline();expanded.route.data_fields.push('confirmed_memory_context');expanded.route.purposes.push('memory_personalization');expanded.routeHash=hash(expanded.route);assert.notEqual(expanded.routeHash,'eef4100e83db1b2ab5ea9a7efd4818e97dcd90c819f056b54082fbdf5cd5e305');assert.equal(gemmaRouteReviewManifest().supersedes_route_hash,'eef4100e83db1b2ab5ea9a7efd4818e97dcd90c819f056b54082fbdf5cd5e305');assert.throws(()=>prepareGemmaRouteReview(expanded,{reviewID:GEMMA_PRIVATE_REVIEW_ID}),e=>e.code==='private_route_review_input_invalid');
});

test('inactive preparation accepts the same frozen API19 text data contract without replacing its public-key or vision settings',()=>{
 const old=readAPI19Config(k=>values[k]),before=clone(old),prepared=prepareGemmaRouteReview(old,{reviewID:GEMMA_PRIVATE_REVIEW_ID});assert.deepEqual(old,before);assert.equal(old.routeHash,gemmaRouteReviewManifest().supersedes_route_hash);for(const field of ['visionContractEnabled','visionLiveEnabled','configurationIssues','projectUrl','publishableKey'])assert.deepEqual(prepared.config[field],old[field]);assert.equal(prepared.config.routeHash,gemmaRouteReviewManifest().route_hash);
});

test('private review requires the exact explicit identity, model, supplier, complete policy and transport',()=>{
 const m=gemmaRouteReviewManifest(),base={model:m.route.model,secret:'synthetic-review-only',liveNetworkEnabled:true,privateRoutingPolicy:m.route.routing_policy,beforeStream:async()=>{},expectedProviderDisplay:m.route.downstream_provider,privateRouteReviewID:GEMMA_PRIVATE_REVIEW_ID};
 new OpenRouterProvider(base).assertReady();
 const changes=[x=>{delete x.privateRouteReviewID;},x=>{x.privateRouteReviewID='other';},x=>{x.model='openrouter/free';},x=>{x.model='paid/model';},x=>{x.expectedProviderDisplay='Novita';},x=>{x.privateRoutingPolicy.only=['google-ai-studio','novita/bf16'];},x=>{x.privateRoutingPolicy.allow_fallbacks=true;},x=>{x.privateRoutingPolicy.require_parameters=false;},x=>{x.privateRoutingPolicy.data_collection='allow';},x=>{delete x.privateRoutingPolicy.max_price.request;},x=>{x.privateRoutingPolicy.max_price.prompt=0.01;},x=>{x.beforeStream=null;}];
 for(const change of changes){const x={...base,privateRoutingPolicy:clone(base.privateRoutingPolicy)};change(x);assert.throws(()=>new OpenRouterProvider(x).assertReady(),e=>e.code==='private_route_not_configured');}
 const original=baseline();new OpenRouterProvider({model:original.route.model,secret:'synthetic-review-only',liveNetworkEnabled:true,privateRoutingPolicy:original.route.routing_policy,beforeStream:async()=>{},expectedProviderDisplay:'Novita'}).assertReady();
 assert.throws(()=>createGemmaReviewProvider({reviewID:GEMMA_PRIVATE_REVIEW_ID,manifest:m,secret:'synthetic-review-only',beforeStream:async()=>{}}),e=>e.code==='private_route_review_input_invalid');
 const disabled=createGemmaReviewProvider({reviewID:GEMMA_PRIVATE_REVIEW_ID,manifest:m,secret:'synthetic-review-only',beforeStream:async()=>{},fetchImpl:()=>{throw Error('must_not_dispatch');}});assert.throws(()=>disabled.assertReady(),e=>e.code==='live_calls_not_authorized');
});

test('candidate SSE passes only with original policy, exact model/provider, cost0 and validated terminal',async()=>{
 const f=transport(),events=await collect(f.provider);assert.equal(events.filter(e=>e.type==='text_delta').map(e=>e.text).join(''),'received.');assert.equal(events.at(-1).type,'done');assert.equal(f.calls.length,1);assert.deepEqual(f.calls[0].payload.provider,f.manifest.route.routing_policy);assert.equal(f.calls[0].redirect,'error');assert.equal(f.provider.observations[0].terminal_validated,true);
});

test('candidate SSE mismatched or missing receipts and incomplete terminal fail once without retry',async()=>{
 const cases=[[{model:'apodex/apodex-1.1-mini:free'},'response_model_mismatch'],[{model:null},'private_provider_receipt_mismatch'],[{model:'google/gemma-4-31b-it'},'private_provider_receipt_mismatch'],[{provider:'Novita'},'private_provider_receipt_mismatch'],[{provider:null},'private_provider_receipt_mismatch'],[{cost:0.01},'private_provider_receipt_mismatch'],[{cost:null},'private_provider_receipt_mismatch'],[{done:false},'incomplete_provider_terminal'],[{finish:'length'},'incomplete_provider_terminal']];
 for(const [options,code] of cases){const f=transport(options);await assert.rejects(collect(f.provider),e=>e.code===code);assert.equal(f.calls.length,1);assert.equal(f.provider.observations[0].terminal_validated,false);}
});

for(const [label,earlyMetadata,code] of [
 ['provider',{provider:'Other Provider'},'private_provider_receipt_mismatch'],
 ['model',{model:'google/gemma-4-31b-it'},'private_provider_receipt_mismatch'],
 ['response id',{id:'conflicting-early-response'},'private_review_metadata_changed']
])test('review rejects early conflicting '+label+' even when the final receipt is correct',async()=>{const f=transport({earlyMetadata});await assert.rejects(collect(f.provider),e=>e.code===code);assert.equal(f.calls.length,1);assert.equal(f.provider.observations[0].terminal_validated,false);});

test('review accepts matching repeated identity and rejects conflicting stable metadata',async()=>{const good=transport({earlyMetadata:{model:'google/gemma-4-31b-it:free',provider:'Google AI Studio',id:'synthetic-review-response'}});await collect(good.provider);assert.equal(good.provider.observations[0].review_frame_validation.passed,true);assert.equal(good.provider.observations[0].review_frame_validation.frames,2);for(const key of ['object','created','system_fingerprint']){const first={id:'same',model:'google/gemma-4-31b-it:free',provider:'Google AI Studio',[key]:key==='created'?1:'one',choices:[{index:0,delta:{content:'received.'}}]},last={...first,[key]:key==='created'?2:'two',usage:{cost:0},choices:[{index:0,delta:{},finish_reason:'stop'}]};const f=transport();f.provider.fetchImpl=async()=>new Response([first,last].map(c=>'data: '+JSON.stringify(c)+'\n\n').join('')+'data: [DONE]\n\n',{headers:{'Content-Type':'text/event-stream'}});await assert.rejects(collect(f.provider),e=>e.code==='private_review_metadata_changed');assert.equal(f.provider.observations[0].terminal_validated,false);}});
test('original private route preserves its pre-review frame behavior',async()=>{const base=baseline(),p=new OpenRouterProvider({model:base.route.model,secret:'synthetic-review-only',liveNetworkEnabled:true,privateRoutingPolicy:base.route.routing_policy,beforeStream:async()=>{},expectedProviderDisplay:'Novita',fetchImpl:async()=>new Response(body({model:base.route.model,provider:'Novita',earlyMetadata:{provider:'Other Provider',id:'legacy-first'}}),{headers:{'Content-Type':'text/event-stream'}})});await collect(p);assert.equal(p.observations[0].terminal_validated,true);assert.equal(p.observations[0].review_frame_validation,undefined);});

test('candidate tool stream retains strict local argument checks before any domain work',async()=>{
 const f=transport({tool:'delegate_plan_v1',finish:'tool_calls'}),events=await collect(f.provider),call=events.find(e=>e.type==='tool_call');validateProvidedToolCall(call,'chat',chatTools);assert.deepEqual(call.arguments,plan);assert.equal(f.calls.length,1);
 const extra=transport({tool:'delegate_plan_v1',finish:'tool_calls',argumentsText:JSON.stringify({...plan,permission:'write-calendar'})}),bad=(await collect(extra.provider)).find(e=>e.type==='tool_call');assert.throws(()=>validateProvidedToolCall(bad,'chat',chatTools));
 const unknown=transport({tool:'write_calendar',finish:'tool_calls'});await assert.rejects(collect(unknown.provider),e=>e.code==='tool_not_allowed');
});

async function cloudFixture(options={}){
 const base=baseline(),prepared=prepareGemmaRouteReview(base,{reviewID:GEMMA_PRIVATE_REVIEW_ID}),repository=new TestRepository(),f=transport(options),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true};
 const principal={subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://route-review.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}},retained=[];
 const sourceChecker=async(tx,source)=>{const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);if(row?.subject_id!==source.subject_id||row.state!=='active'||row.expires_at<=Math.floor(Date.now()/1000))throw new ApiError(409,'grant_conflict');};
 const runtime=await createCloudRuntime({repository,config:prepared.config,provider:f.provider,autoKick:false,sourceChecker,authenticate:()=>principal,retain:p=>retained.push(p),diagnostic:()=>{}});
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);await repository.transaction(async tx=>{await tx.put(membershipOwner(principal.issuer),'scope-memberships',{id:principal.subject_id,scopes:[scope]});await tx.put(membershipOwner(principal.issuer),'app-sessions',{id:principal.session_id,subject_id:principal.subject_id,state:'active',expires_at:Math.floor(Date.now()/1000)+600});});
 const cid=randomUUID(),path=`/catpaw/chat/v1/scopes/${scope.scope_id}/conversations`,req=(url,input)=>runtime.api(new Request('https://route-review.example.invalid'+url,{method:input===undefined?'GET':'POST',headers:{Authorization:'Bearer synthetic-route-review','Content-Type':'application/json'},...input===undefined?{}:{body:JSON.stringify(input)}}));
 assert.equal((await req(path,{conversation_id:cid})).status,201);return {...f,runtime,repository,prepared,base,cid,scope,req,path,retained,principal,sourceChecker};
}

test('actual maintenance Cloud path requires new candidate consent then persists and cold-reads one original reply',async()=>{
 const f=await cloudFixture();try{
  const route=await (await f.req('/catpaw/privacy/v1/model-route')).json();assert.equal(route.route_hash,f.manifest.route_hash);assert.equal(route.consent_default,'deny');assert.ok(route.ui.body.includes('Google AI Studio'));
  const consent=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${f.cid}/model-consent`;
  assert.equal((await f.req(consent,{decision:'allow',expected_revision:0,route_hash:f.base.routeHash})).status,422);assert.equal(f.calls.length,0);
  assert.equal((await f.req(consent,{decision:'allow',expected_revision:0,route_hash:f.manifest.route_hash})).status,200);
  const input={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'Reply only: received.'},context:[]},turnPath=`${f.path}/${f.cid}/turns`;
  const response=await f.req(turnPath,input);assert.equal(response.status,200);await response.text();await Promise.all(f.retained);const full=await (await f.req(`${turnPath}/${input.turn_id}`)).json();assert.equal(full.turn.state,'completed');assert.equal(full.turn.events.filter(e=>e.type==='text_delta').map(e=>e.data.text).join(''),'received.');assert.equal(f.calls.length,1);
  assert.equal((await (await f.req(turnPath,input)).json()).replayed,true);const cold=new TestRepository(f.repository.snapshot());const saved=await cold.transaction(tx=>tx.get(f.runtime.facade.owner(f.scope),'native-chat-turns',input.turn_id));assert.equal(saved.id,full.turn.id);assert.equal(saved.request_hash,full.turn.request_hash);assert.deepEqual(saved.events,full.turn.events);const restored=await createCloudRuntime({repository:cold,config:f.prepared.config,provider:f.provider,autoKick:false,sourceChecker:f.sourceChecker,authenticate:()=>f.principal,diagnostic:()=>{}});try{const recovered=await (await restored.api(new Request('https://route-review.example.invalid'+turnPath+'/'+input.turn_id,{headers:{Authorization:'Bearer synthetic-route-review'}}))).json();assert.deepEqual(recovered,full);assert.equal(f.calls.length,1);}finally{await restored.worker.stop();}
 }finally{await f.runtime.worker.stop();}
});

test('actual maintenance Cloud path stores wrong-provider terminal as failure and never creates tasks',async()=>{
 const f=await cloudFixture({provider:'Novita'});try{
  const consent=`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${f.cid}/model-consent`;assert.equal((await f.req(consent,{decision:'allow',expected_revision:0,route_hash:f.manifest.route_hash})).status,200);
  const input={turn_id:randomUUID(),expected_revision:1,expected_grant_epoch:1,message:{id:randomUUID(),text:'Reply only: received.'},context:[]},turnPath=`${f.path}/${f.cid}/turns`;await (await f.req(turnPath,input)).text();await Promise.all(f.retained);const full=await (await f.req(`${turnPath}/${input.turn_id}`)).json();assert.equal(full.turn.state,'outcome_unknown');assert.equal(full.turn.error.code,'private_provider_receipt_mismatch');assert.equal(full.turn.task_bindings.length,0);assert.equal(f.calls.length,1);await f.req(`${turnPath}/${input.turn_id}`);assert.equal(f.calls.length,1);
 }finally{await f.runtime.worker.stop();}
});
