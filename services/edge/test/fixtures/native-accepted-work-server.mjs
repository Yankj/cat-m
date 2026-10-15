// Explicit local-only synthetic App integration server. It never verifies an
// external token, proxies a request, invokes a real provider, or uses real SQL.
import {createServer} from 'node:http';
import {Buffer} from 'node:buffer';
import {readFile,mkdir,writeFile,rename} from 'node:fs/promises';
import {dirname,resolve,sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createNativeAcceptedWorkWireFixture} from './generate-native-accepted-work-wire.mjs';

const repoRoot=fileURLToPath(new URL('../../../../',import.meta.url));
const evidenceRoot=resolve(repoRoot,'services/edge/build/native-accepted-work-20261015');
const modes=new Set(['normal','lose-first-accepted-response']);
export function nativeLoopbackRouteNotice(actual){
 const notice=structuredClone(actual);notice.ui={...notice.ui,title:'允许合成离线测试处理此对话？',body:'这是本机 loopback 合成测试。消息和选中的文字上下文仅进入维护 API、序列化测试仓库与注入脚本模型；不会发送给 OpenRouter、Google 或真实 Supabase Auth/数据库。新的对话仍须明确许可；有限工作仍遵守原先确认的期限、次数与撤权约束。'};return notice;
}
export function parseNativeAcceptedWorkServerOptions(args){
 const values={port:8767,mode:'normal',state:resolve(evidenceRoot,'server-state.json')};
 for(const arg of args){const match=/^--(port|mode|state)=(.*)$/.exec(arg);if(!match)throw Error('synthetic_server_argument_invalid');values[match[1]]=match[2];}
 const port=Number(values.port),state=resolve(values.state);
 if(!Number.isInteger(port)||port<1024||port>65535||!modes.has(values.mode)||!state.startsWith(evidenceRoot+sep))throw Error('synthetic_server_options_invalid');
 return {port,hostname:'127.0.0.1',mode:values.mode,state};
}

export async function createNativeAcceptedWorkLoopbackServer(options){
 options=parseNativeAcceptedWorkServerOptions([`--port=${options.port}`,`--mode=${options.mode??'normal'}`,`--state=${options.state}`]);
 let stored=null;try{stored=JSON.parse(await readFile(options.state,'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
 if(stored&&stored.fixture_kind!=='actual_cloud_native_loopback_v1')throw Error('synthetic_server_snapshot_invalid');
 const f=await createNativeAcceptedWorkWireFixture({autoKick:true,snapshot:stored?.repository??null,providerReality:'injected_test_provider',sessionLifetimeSeconds:21600}),priorProviderCalls=stored?.counters?.provider_calls??0;
 const counters={requests:stored?.counters?.requests??0,accepted_posts:stored?.counters?.accepted_posts??0,dropped_responses:stored?.counters?.dropped_responses??0};
 const requests=stored?.requests??[];let persistQueue=Promise.resolve();
 const stats=()=>({...counters,provider_calls:priorProviderCalls+f.calls.length,turns:[...f.repository.records].filter(([key])=>JSON.parse(key)[1]==='native-chat-turns').length});
 const persist=()=>{
  persistQueue=persistQueue.then(async()=>{const state={fixture_kind:'actual_cloud_native_loopback_v1',version:1,mode:options.mode,origin:`http://127.0.0.1:${options.port}`,updated_at:new Date().toISOString(),scope:f.scope,subject_id:f.subject_id,repository:f.repository.snapshot(),counters:stats(),requests};await mkdir(dirname(options.state),{recursive:true});const temp=options.state+'.writing';await writeFile(temp,JSON.stringify(state,null,2)+'\n');await rename(temp,options.state);});return persistQueue;
 };
 const metadata=()=>({fixture_kind:'actual_cloud_native_loopback_v1',origin:`http://127.0.0.1:${options.port}`,subject_id:f.subject_id,scope:{scope_id:f.scope.scope_id,profile_id:f.scope.profile_id,workspace_id:f.scope.workspace_id},seed_conversation_id:f.cid,mode:options.mode,route_hash:f.model_route.route_hash,authentication:'explicit_test_fixture_session',model_reality:'injected_synthetic_fixture',event_model_reality:'injected_test_provider',real_supabase_login_verified:false,synthetic_viewer_window:{new_snapshot_session_lifetime_seconds:21600,restored_snapshot:stored!==null,restore_preserves_original_expiry:true,extends_work_grant:false},execution:'actual_maintenance_bounded_single_step_v1',auto_kick:true,clock:'Date.now',provenance:{repository:'serialized TestRepository',provider:'injected_test_provider',real_auth:false,real_model:false,real_sql:false},counters:stats()});
 const server=createServer(async(incoming,outgoing)=>{
  const method=incoming.method??'GET',url=new URL(incoming.url??'/',`http://127.0.0.1:${options.port}`),entry={sequence:++counters.requests,method,path:url.pathname,received_at:new Date().toISOString(),status:null,transport:'pending'};requests.push(entry);
  try{
   if(!['127.0.0.1','::ffff:127.0.0.1'].includes(incoming.socket.remoteAddress??''))throw Error('synthetic_server_loopback_required');
   if(['/testing/v1/fixture','/testing/v1/stats','/catpaw/testing/v1/fixture','/catpaw/testing/v1/stats'].includes(url.pathname)){
    if(method!=='GET'){entry.status=405;outgoing.writeHead(405,{'Content-Type':'application/json'});outgoing.end('{"error":{"code":"method_not_allowed"}}');}
    else{entry.status=200;outgoing.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});outgoing.end(JSON.stringify(metadata()));}
    entry.transport='delivered';await persist();return;
   }
   const chunks=[];let size=0;for await(const chunk of incoming){size+=chunk.length;if(size>7100000)throw Error('synthetic_server_body_too_large');chunks.push(chunk);}
   const headers=new Headers();for(const [key,value] of Object.entries(incoming.headers))if(value!==undefined)headers.set(key,Array.isArray(value)?value.join(','):value);
   const request=new Request(url,{method,headers,...method==='GET'||method==='HEAD'?{}:{body:Buffer.concat(chunks)}});
   const acceptedPost=method==='POST'&&/^\/catpaw\/accepted-work\/v1\/scopes\/[a-f0-9-]+\/conversations\/[a-f0-9-]+\/turns$/.test(url.pathname);
   if(acceptedPost)counters.accepted_posts++;
   let response=await f.runtime().api(request);entry.status=response.status;
   if(method==='GET'&&url.pathname==='/catpaw/privacy/v1/model-route'&&response.status===200){
    // Only the local synthetic notice changes. Domain route, route hash,
    // consent default and actual consent decisions remain the maintained API's.
    const notice=nativeLoopbackRouteNotice(await response.json());
    response=Response.json(notice,{status:response.status,headers:response.headers});
   }
   if(acceptedPost&&response.status===200&&options.mode==='lose-first-accepted-response'&&counters.dropped_responses===0){
    // API has already committed the original turn. Cancelling its observer only
    // detaches this HTTP response, then the actual retained work may continue.
    await response.body?.cancel();await f.drain();counters.dropped_responses++;entry.transport='dropped_after_durable_acceptance';await persist();outgoing.destroy();return;
   }
   outgoing.writeHead(response.status,Object.fromEntries(response.headers));
   if(response.body){const reader=response.body.getReader();try{while(true){const {done,value}=await reader.read();if(done)break;if(outgoing.destroyed){await reader.cancel();break;}outgoing.write(Buffer.from(value));}}finally{reader.releaseLock();}}
   if(!outgoing.destroyed)outgoing.end();entry.transport=outgoing.destroyed?'client_disconnected':'delivered';
   if(method==='POST')await f.drain();await persist();
  }catch(error){entry.transport='server_error';entry.error=error.code??error.name??'Error';if(!outgoing.headersSent){entry.status=500;outgoing.writeHead(500,{'Content-Type':'application/json'});outgoing.end('{"error":{"code":"synthetic_server_error"}}');}else outgoing.destroy();await persist();}
 });
 const start=()=>new Promise((resolve,reject)=>{server.once('error',reject);server.listen(options.port,'127.0.0.1',()=>{server.off('error',reject);resolve();});});
 const stop=async()=>{await f.drain();await persist();await f.stop();await new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve()));};
 await persist();return {server,start,stop,persist,metadata,fixture:f};
}

if(import.meta.main){
 const options=parseNativeAcceptedWorkServerOptions(Deno.args),local=await createNativeAcceptedWorkLoopbackServer(options);await local.start();console.log(JSON.stringify({event:'synthetic_native_server_ready',...local.metadata(),state_file:options.state}));
 const stop=()=>{local.stop().then(()=>Deno.exit(0),()=>Deno.exit(1));};Deno.addSignalListener('SIGTERM',stop);Deno.addSignalListener('SIGINT',stop);
}
