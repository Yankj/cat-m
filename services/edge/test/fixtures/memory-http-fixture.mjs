// Actual maintained Cloud API with serialized TestRepository and named synthetic provider only.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createCloudRuntime} from '../../supabase/functions/_shared/api.mjs';
import {readConfig} from '../../supabase/functions/_shared/config.mjs';
import {membershipOwner} from '../../supabase/functions/_shared/authority.mjs';
import {TestRepository} from '../../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {ApiError,clone} from '../../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {MEMORY_CONTRACT} from '../../supabase/functions/_shared/core/src/memory-contract.mjs';
export async function memoryHTTPFixture({snapshot=null,identity=null,delegate=false,stream=null,memoryProposals=false,vision=false,attachmentStorage=null}={}){
 const repository=new TestRepository(snapshot??undefined),scope=identity?.scope??{scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID(),local_output:true},principal=identity?.principal??{subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://memory-test.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}},foreign=identity?.foreign??{subject_id:randomUUID(),session_id:randomUUID(),issuer:'https://memory-test.example.invalid/auth/v1',issued_at:1,scopes:[scope],permissions:{local_output:true}},calls=[];let sourceActive=true;
 const values={CATPAW_DATABASE_URL:'offline-unused',CATPAW_PRIVATE_MODEL_KEY:'offline-unused',CATPAW_TICK_HMAC_KEY:'offline-only-at-least-thirty-two-chars',CATPAW_MEMORY_GUARD_KEY:'memory-offline-test-guard',...vision?{CATPAW_VISION_CONTRACT_ENABLED:'true',CATPAW_VISION_LIVE_ENABLED:'false'}:{}},config=readConfig(k=>values[k]);
 const provider={identity:{provider:'memory-test',model:'injected-only',adapter_version:1},reality:'injected_test_provider',assertReady(){},async *stream(input){calls.push(clone({...input,signal:null,assertDispatchReady:null}));if(stream){yield*stream(input);return;}if(delegate){if(input.tools.some(t=>t.function.name==='delegate_plan_v1'))yield{type:'tool_call',id:randomUUID(),name:'delegate_plan_v1',arguments:{title:'Fictional coffee report',goal:'Use confirmed coffee preference',requirements:'Only fictional local output',stop_conditions:['Local report saved'],steps:['compose','save','verify'].map(id=>({id,title:id,detail:''}))}};else{yield{type:'tool_call',id:randomUUID(),name:'save_artifact',arguments:{title:'Fictional coffee report',summary:'Named synthetic result',content:'Coffee preference used in a named synthetic worker'}};yield{type:'tool_call',id:randomUUID(),name:'finish_task',arguments:{summary:'Saved fictional report'}};}yield{type:'done',finish_reason:'tool_calls'};}else{yield {type:'text_delta',text:'Named synthetic answer'};yield {type:'done',finish_reason:'stop'};}}};
 if(vision){provider.liveNetworkEnabled=false;provider.visionContract={execution_layer:'synthetic_mock',route:{id:'synthetic-vision-mock',provider:'offline',downstream_provider:'offline',model:'offline/vision-mock:free',free:true,data_fields:['user_selected_image_bytes'],purposes:['chat_reply'],retention:'none',zero_retention_claim:false}};}
 const sourceChecker=async(tx,source,identity)=>{const row=await tx.get(membershipOwner(source.issuer),'app-sessions',source.session_id);if(!sourceActive||source.scope_id!==identity.scope_id||row?.subject_id!==source.subject_id||row.state!=='active')throw new ApiError(409,'grant_conflict');};
 const authenticate=auth=>{if(auth==='Bearer memory-fixture')return principal;if(auth==='Bearer foreign-fixture')return foreign;throw new ApiError(401,'unauthorized');};
 const runtime=await createCloudRuntime({repository,config,provider,sourceChecker,authenticate,autoKick:false,diagnostic:()=>{},attachmentStorage});
 await runtime.foundation.bootstrapScope(principal,scope.scope_id);
 if(!snapshot)await repository.transaction(async tx=>{for(const p of [principal,foreign])await tx.put(membershipOwner(p.issuer),'app-sessions',{id:p.session_id,subject_id:p.subject_id,state:'active',expires_at:9999999999});});
 const base='/catpaw/memory/v1/scopes/'+scope.scope_id;
 const req=(path,body,auth='Bearer memory-fixture')=>runtime.api(new Request('https://memory-test.example.invalid'+path,{method:body===undefined?'GET':'POST',headers:{Authorization:auth,'Content-Type':'application/json',...memoryProposals&&body!==undefined&&/\/catpaw\/chat\/v1\/.*\/turns$/.test(path)?{'X-Catpaw-Memory-Proposal-Contract':'catpaw.memory-proposal.v1'}:{}},...body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)}}));
 const json=async response=>{const value=await response.json();assert.equal(response.status,200,JSON.stringify(value));return value;};
 const state=()=>req(base+'/state').then(json);
 const command=async(command,extra={})=>({schema_version:1,contract:MEMORY_CONTRACT,operation_id:randomUUID(),expected_memory_generation:(await state()).memory_generation,command,...extra});
 const post=async(command,extra={})=>{const input=await f.command(command,extra);return {input,response:await req(base+'/commands',input)};};
 const newConversation=async()=>{const cid=randomUUID(),response=await req('/catpaw/chat/v1/scopes/'+scope.scope_id+'/conversations',{conversation_id:cid});assert.equal(response.status,201);return cid;};
 const send=async(cid,text,{sensitive=false}={})=>{
  const privacy='/catpaw/privacy/v1/scopes/'+scope.scope_id+'/conversations/'+cid+'/model-consent';const prior=(await json(await req(privacy))).consent;
  await json(await req(privacy,{decision:'allow',expected_revision:prior?.revision??0,route_hash:config.routeHash,sensitive_confirmed:sensitive}));
  const path='/catpaw/chat/v1/scopes/'+scope.scope_id+'/conversations/'+cid,conversation=(await json(await req(path))).conversation,tid=randomUUID();
  const response=await req(path+'/turns',{turn_id:tid,expected_revision:conversation.revision,expected_grant_epoch:conversation.grant_epoch,message:{id:randomUUID(),text},context:[]});assert.equal(response.status,200);await response.text();await runtime.chat.waitIdle();return (await json(await req(path+'/turns/'+tid))).turn;
 };
 const f={repository,runtime,scope,principal,foreign,calls,config,base,req,json,state,command,post,newConversation,send,setSourceActive:value=>{sourceActive=value;},restore:()=>memoryHTTPFixture({snapshot:repository.snapshot(),identity:{scope,principal,foreign},delegate,stream,memoryProposals})};return f;
}
