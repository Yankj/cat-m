// Bounded offline probes against the pinned maintenance service plus its in-memory store.
// These assertions reproduce current behavior; observations marked GAP are not acceptance passes.
import assert from 'node:assert/strict';
import {assertPinnedSources} from './source-pin.mjs';
import {createAgentMemoryService} from '../../../services/edge/supabase/functions/_shared/agent-memory/service.mjs';
import {createAgentMemoryStore} from '../../../services/edge/supabase/functions/_shared/agent-memory/memory-store.mjs';
const sourcePin=assertPinnedSources(['services/edge/supabase/functions/_shared/agent-memory/service.mjs','services/edge/supabase/functions/_shared/agent-memory/memory-store.mjs']);
let networkAttempts=0;
globalThis.fetch=async()=>{networkAttempts++;throw Error('offline probe network prohibited');};
const uid='00000000-0000-4000-8000-000000000001',other='00000000-0000-4000-8000-000000000002';
const start=Date.parse('2026-10-22T17:00:00Z');
const fresh=async()=>{const store=createAgentMemoryStore();await store.putSettings(uid,{use_memory:true,auto_save:true,consented_at:new Date(start).toISOString()});let tick=0;const service=createAgentMemoryService({store,allow:()=>true,verifyUser:async()=>({sub:uid}),now:()=>start+tick++});return {store,service};};
const req=(method,path,body)=>new Request(`https://offline.example.invalid/catpaw/agent-memory/v1/${path}`,{method,headers:{'content-type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});
const results=[];
const record=(id,name,classification,actual)=>results.push({id,name,layer:'offline-service-with-memory-store',classification,acceptance_status:'NOT_RUN',actual});
{
 const {store,service}=await fresh();const saved=await service.save(uid,{kind:'fact',content:'虚构记录甲'},{created_by:'user'});
 assert.equal(await store.get(other,saved.row.id),null);assert.equal(await store.update(other,saved.row.id,{content:'虚构篡改'}),null);assert.equal(await store.remove(other,[saved.row.id]),0);
 record('SP-01','内存store按用户隔离读取修改删除','SUPPORTED_OFFLINE',{foreign_get:null,foreign_update:null,foreign_deleted:0});
}
{
 const {store,service}=await fresh();const saved=await service.save(uid,{kind:'fact',content:'虚构旧偏好'},{created_by:'user'});
 const corrected=await service.handle(req('PATCH',`items/${saved.row.id}`,{content:'虚构新偏好'}));const delayed=await service.handle(req('PATCH',`items/${saved.row.id}`,{content:'虚构旧偏好'}));
 assert.equal(corrected.status,200);assert.equal(delayed.status,200);assert.equal((await store.get(uid,saved.row.id)).content,'虚构旧偏好');
 record('SP-02','迟到正文PATCH覆盖较新纠正','GAP_REPRODUCED',{corrected_status:200,delayed_status:200,stale_content_won:true,expected_revision_supported:false});
}
{
 const {store,service}=await fresh();const args={kind:'fact',content:'虚构稳定偏好'};const ctx={operation_id:'synthetic-original-operation',turn_id:'synthetic-original-turn'};
 const first=await service.executeTool(uid,'memory_save',args,ctx),replay=await service.executeTool(uid,'memory_save',args,ctx);
 assert.equal(first.result.id,replay.result.id);assert.equal(replay.events.length,0);assert.equal(await store.count(uid),1);
 record('SP-03','相同operation重放返回原memory','SUPPORTED_OFFLINE',{same_id:true,rows:1,replay_events:0});
 const mismatch=await service.executeTool(uid,'memory_save',{...args,content:'虚构另一偏好'},ctx);assert.equal(first.result.id,mismatch.result.id);assert.equal(mismatch.result.status,'saved');
 record('SP-04','相同operation异payload未返回冲突','GAP_REPRODUCED',{returned_original_id:true,status:'saved',http_409_observed:false});
 await store.remove(uid,[first.result.id]);const resurrect=await service.executeTool(uid,'memory_save',args,ctx);assert.notEqual(resurrect.result.id,first.result.id);assert.equal(await store.count(uid),1);
 record('SP-05','删除后迟到同operation重放重建新memory','GAP_REPRODUCED',{new_id:true,rows_after_replay:1,original_operation_same:true});
}
{
 const {store,service}=await fresh();const body={kind:'fact',content:'虚构重复点击记录'};
 const one=await service.handle(req('POST','items',body)),two=await service.handle(req('POST','items',body));const a=await one.json(),b=await two.json();
 assert.equal(one.status,201);assert.equal(two.status,201);assert.notEqual(a.memory.id,b.memory.id);assert.equal(await store.count(uid),2);
 record('SP-06','HTTP手工创建重复请求无command回执幂等','GAP_REPRODUCED',{statuses:[201,201],different_ids:true,rows:2,request_has_command_id:false});
}
{
 const {store,service}=await fresh();const saved=await service.executeTool(uid,'memory_save',{kind:'fact',content:'虚构原始记录'},{conversation_id:'synthetic-conversation',turn_id:'synthetic-turn-1',operation_id:'synthetic-op-1'});
 await service.executeTool(uid,'memory_update',{id:saved.result.id,content:'虚构更正记录'},{turn_id:'synthetic-turn-2',operation_id:'synthetic-op-2'});const row=await store.get(uid,saved.result.id);
 assert.equal(row.content,'虚构更正记录');assert.equal(row.source_turn_id,'synthetic-turn-1');assert.equal(row.operation_id,'synthetic-op-1');assert.equal(Object.hasOwn(row,'previous_source_ref'),false);
 record('SP-07','agent-memory纠正未更新来源链','GAP_REPRODUCED',{content_corrected:true,source_turn_still_original:true,operation_still_original:true,has_previous_source_ref:false,has_revision_version:Object.hasOwn(row,'version')});
}
{
 const {store,service}=await fresh();const day='2026-10-21';await store.appendFragment(uid,{day,turn_id:'synthetic-journal-turn',conversation_id:'synthetic-journal-conversation',text:'虚构片段',at:new Date(start).toISOString()});
 store.insert=async()=>{throw Error('synthetic insert failure');};await assert.rejects(service.journalTick(day),/synthetic insert failure/);assert.equal(store._dump().fragments.length,0);assert.equal(await store.count(uid),0);
 record('SP-08','journal写入失败后唯一fragment已被删除','GAP_REPRODUCED',{fragments_after_failure:0,journals_after_failure:0});
}
{
 const {store}=await fresh();const service=createAgentMemoryService({store,allow:()=>true,verifyUser:async()=>{throw Object.assign(Error('synthetic auth unavailable'),{status:503,code:'auth_service_unavailable'});}});
 const response=await service.handle(req('GET','settings'));assert.equal(response.status,401);assert.deepEqual(await response.json(),{error:'unauthorized'});
 record('SP-09','memory路由把身份服务不可用转成401','GAP_REPRODUCED',{injected_auth_status:503,response_status:401,error:'unauthorized'});
}
assert.equal(networkAttempts,0);
console.log(JSON.stringify({...sourcePin,contract_sha:'2419db9b98e2e3bc0e8c850da62418d216fd3bb8',node:process.version,synthetic:true,real_auth:false,postgres_rls:false,production_requests:false,network_attempts:networkAttempts,meaning:'Assertions reproduce current offline behavior, including gaps. No household acceptance criterion is closed.',total:results.length,results},null,2));
