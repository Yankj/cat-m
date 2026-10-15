import assert from 'node:assert/strict';
import {readFileSync,readdirSync,writeFileSync,mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {hash} from '../../supabase/functions/_shared/core/facade-r2/src/common.mjs';
import {validatePublicRevisionWorkReceipt} from '../../supabase/functions/_shared/core/src/task-revision-work-contract.mjs';
import {revisionWorkHTTPFixture} from './revision-work-http-fixture.mjs';

// Execute from repository root with the existing offline import map/cache and
// --deny-net --allow-read --allow-write=build/revision-work-20261015.
// Every payload below is emitted by the maintained handler, never handwritten.
const output='build/revision-work-20261015/native-wire.json';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
function snapshot(){
 const paths=[];
 const walk=directory=>{for(const entry of readdirSync(directory,{withFileTypes:true})){const path=directory+'/'+entry.name;if(entry.isDirectory())walk(path);else if(entry.isFile())paths.push(path);}};
 walk('services/edge/supabase/functions');
 paths.push('services/edge/test/fixtures/revision-work-http-fixture.mjs','services/edge/test/fixtures/generate-native-revision-work-wire.mjs','services/edge/test/revision-work-http.test.mjs','services/edge/test/revision-work-source-authority.test.mjs','services/edge/test/task-revision-work-contract.test.mjs');
 return paths.sort().map(path=>{const data=readFileSync(path);return {path,bytes:data.length,sha256:sha(data)};});
}
const before=snapshot(),f=await revisionWorkHTTPFixture({sourced:false,autoKick:false});
try{
 await f.mutateSession(f.principal,{expires_at:1});
 const chatBase=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${f.cid}`;
 const conversation_before=await f.json(await f.req(chatBase,undefined,'Bearer fresh'));
 const original_turn=await f.json(await f.req(chatBase+'/turns/'+f.binding.turn_id,undefined,'Bearer fresh'));
 const ref=f.run.artifact_references[0],basePath=`/catpaw/artifacts/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}/artifacts/${ref.artifact_id}/versions/1`;
 const base_artifact=await f.json(await f.req(basePath,undefined,'Bearer fresh'));
 assert.equal(base_artifact.contract,'catpaw.task-artifact.v1');assert.equal(base_artifact.artifact.is_current,true);assert.equal(base_artifact.artifact.editable,false);
 const projection_before=await f.json(await f.req(`/catpaw/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}`,undefined,'Bearer fresh'));
 const route=await f.json(await f.req('/catpaw/privacy/v1/model-route',undefined,'Bearer fresh')),readiness=await f.json(await f.req('/readyz',undefined,'Bearer fresh'));
 const request=await f.makeRequest(),response=await f.req(f.workPath,request,'Bearer fresh');assert.equal(response.status,200);
 const raw_sse=await response.text();await f.runtime.chat.waitIdle();
 const turn=await f.json(await f.req(f.workPath+'/'+request.turn.turn_id,undefined,'Bearer fresh'));
 assert.equal(turn.turn.state,'completed');assert.equal(turn.turn.revision_work_intent.input_hash,request.work.input_hash);
 const accepted=validatePublicRevisionWorkReceipt(turn.turn.revision_work_receipts[0]);assert.equal(accepted.revision.state,'accepted');
 const events=raw_sse.split('\n\n').flatMap(line=>line.startsWith('data: ')?[JSON.parse(line.slice(6))]:[]);
 assert.ok(events.length>0);assert.ok(events.every(event=>event.model_reality==='injected_offline_only'));
 assert.ok(events.some(event=>event.type==='tool_result'&&event.data?.result?.contract==='catpaw.task-revision-work.v1'));
 await f.settle();
 const operation=await f.readOperation(accepted.revision.operation_id);assert.equal(operation.revision.state,'completed');assert.equal(operation.revision.result_reference.version,2);assert.equal(operation.receipt_hash,accepted.receipt_hash);
 const conversation_after=await f.json(await f.req(chatBase,undefined,'Bearer fresh'));
 const projection=await f.json(await f.req(`/catpaw/v1/scopes/${f.scope.scope_id}/runs/${f.run.id}`,undefined,'Bearer fresh'));
 assert.equal(projection.run.state,'succeeded');assert.equal(projection.run.artifact_references[0].version,2);
 const artifacts=[];
 for(const version of [1,2])artifacts.push(await f.json(await f.req(`/catpaw/v1/scopes/${f.scope.scope_id}/artifacts/${ref.artifact_id}/versions/${version}`,undefined,'Bearer fresh')));
 assert.equal(artifacts[0].artifact.body,base_artifact.artifact.body);assert.equal(artifacts[1].artifact.content_hash,operation.revision.result_reference.content_hash);
 const after=snapshot();assert.equal(hash(after),hash(before),'source_changed_during_generation');
 const wire={scope:f.scope,principal:f.fresh,conversation_id:f.cid,route,readiness,request,conversation_before,conversation_after,original_turn,raw_sse,turn,operation,projection,projection_before,base_artifact,artifacts,provenance:{schema_version:1,contract:'catpaw.native-revision-work-wire-fixture.v1',created_at:new Date().toISOString(),fixture:'maintained_http_with_injected_offline_ports',source_files:before,source_fingerprint:hash(before),source_stable_during_generation:true,base_artifact_path:basePath,real_auth:false,real_model:false,real_sql:false,live_network:false,sql_boundary:'serialized_TestRepository_not_PostgreSQL',provider_reality:'injected_offline_only',transport:'injected_TLS_public_source_reader_unused_in_this_local_fixture',original_session_expired:true,body_identity:'unmodified_maintained_handler_envelopes'}};
 mkdirSync('build/revision-work-20261015',{recursive:true});writeFileSync(output,JSON.stringify(wire,null,2)+'\n');
 console.log(JSON.stringify({path:output,bytes:readFileSync(output).length,sha256:sha(readFileSync(output)),source_files:before.length,source_fingerprint:wire.provenance.source_fingerprint,base_artifact_path:basePath,artifact_versions:artifacts.map(item=>item.artifact.version),operation:operation.revision.state,real_auth:false,real_model:false,real_sql:false}));
}finally{await f.stop();}
