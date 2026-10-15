import './node-buffer-runtime.mjs';
import postgres from 'npm:postgres@3.4.7';
import {readConfig} from './config.mjs';
import {pgCompatiblePool,boundedPool,verifyDedicatedPool} from './postgres-pool.mjs';
import {PostgresRepository} from './core/integration/server-foundation/src/postgres-repository.mjs';
import {createSupabaseSessionVerifier,createSupabaseTokenVerifier} from './core/src/supabase-auth.mjs';
import {AppScopeAuthority,officialUserVerifier} from './authority.mjs';
import {createCloudRuntime} from './api.mjs';
import {createPgStore} from './proactive/pg-store.mjs';
import {createPgAgentMemoryStore} from './agent-memory/pg-store.mjs';
import {selectGemmaReviewRequest,createGemmaShortTextProbeRuntime} from './model-route-review-probe.mjs';
import {selectGemmaNextReviewRequest,createGemmaNextShortTextProbeRuntime} from './model-route-review-probe-next.mjs';
export function edgeHandler(kind:'api'|'tick',get:(name:string)=>string|undefined,retain:(promise:Promise<unknown>)=>void){
 let runtime:Promise<any>|undefined,reviewRuntime:Promise<any>|undefined,nextReviewRuntime:Promise<any>|undefined;
 return async(request:Request)=>{
  try{
   const next=selectGemmaNextReviewRequest(request,get,kind);
   const selected=next.review?next:selectGemmaReviewRequest(request,get,kind);
   const config=readConfig(get);
   if(!config.ready)return Response.json({ready:false,error:{code:config.configurationIssues.length?'configuration_invalid':'configuration_missing',missing:config.missing,...config.configurationIssues.length?{issues:config.configurationIssues}:{}}},{status:503});
   let selectedRuntime=next.review?nextReviewRuntime:selected.review?reviewRuntime:runtime;
   if(!selectedRuntime){const sql=postgres(config.databaseUrl,{prepare:false,max:4,ssl:'require',connect_timeout:5,idle_timeout:10,max_lifetime:60});const pool=boundedPool(pgCompatiblePool(sql));const repository=new PostgresRepository(pool);
    const authenticate=createSupabaseSessionVerifier({projectUrl:config.projectUrl,scopeAuthority:new AppScopeAuthority(pool),remoteUserVerifier:officialUserVerifier({projectUrl:config.projectUrl,publishableKey:config.publishableKey})});
    const verifyToken=createSupabaseTokenVerifier({projectUrl:config.projectUrl});
    selectedRuntime=verifyDedicatedPool(pool).then(async()=>next.review?await createGemmaNextShortTextProbeRuntime({repository,authenticate,config,retain,verifyToken,subjectID:selected.subjectID,scopeID:selected.scopeID,fetchImpl:globalThis.fetch,liveNetworkEnabled:true}):selected.review?await createGemmaShortTextProbeRuntime({repository,authenticate,config,retain,verifyToken,subjectID:selected.subjectID,scopeID:selected.scopeID,fetchImpl:globalThis.fetch,liveNetworkEnabled:true}):await createCloudRuntime({repository,authenticate,config,retain,verifyToken,proactiveStore:get('CATPAW_PROACTIVE_TOOLS_ENABLED')==='true'?createPgStore(sql):null,agentMemoryStore:['true','1','allowlist'].includes(String(get('CATPAW_AGENT_MEMORY_ENABLED')??'').trim().toLowerCase())?createPgAgentMemoryStore(sql):null}));
    if(next.review)nextReviewRuntime=selectedRuntime;else if(selected.review)reviewRuntime=selectedRuntime;else runtime=selectedRuntime;
   }
   const r=await selectedRuntime;return kind==='api'?r.api(selected.request):r.tick(selected.request);
  }catch{return Response.json({schema_version:1,error:{code:'server_configuration_or_database_unavailable',retryable:false}},{status:503});}
 };
}
