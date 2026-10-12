import './node-buffer-runtime.mjs';
import postgres from 'npm:postgres@3.4.7';
import {readConfig} from './config.mjs';
import {pgCompatiblePool,boundedPool,verifyDedicatedPool} from './postgres-pool.mjs';
import {PostgresRepository} from './core/integration/server-foundation/src/postgres-repository.mjs';
import {createSupabaseSessionVerifier,createSupabaseTokenVerifier} from './core/src/supabase-auth.mjs';
import {AppScopeAuthority,officialUserVerifier} from './authority.mjs';
import {createCloudRuntime} from './api.mjs';
export function edgeHandler(kind:'api'|'tick',get:(name:string)=>string|undefined,retain:(promise:Promise<unknown>)=>void){
 let runtime:Promise<any>|undefined;
 return async(request:Request)=>{
  try{
   const config=readConfig(get);
   if(!config.ready)return Response.json({ready:false,error:{code:config.configurationIssues.length?'configuration_invalid':'configuration_missing',missing:config.missing,...config.configurationIssues.length?{issues:config.configurationIssues}:{}}},{status:503});
   if(!runtime){const sql=postgres(config.databaseUrl,{prepare:false,max:4,ssl:'require',connect_timeout:5,idle_timeout:10,max_lifetime:60});const pool=boundedPool(pgCompatiblePool(sql));const repository=new PostgresRepository(pool);
    const authenticate=createSupabaseSessionVerifier({projectUrl:config.projectUrl,scopeAuthority:new AppScopeAuthority(pool),remoteUserVerifier:officialUserVerifier({projectUrl:config.projectUrl,publishableKey:config.publishableKey})});
    const verifyToken=createSupabaseTokenVerifier({projectUrl:config.projectUrl});
    runtime=verifyDedicatedPool(pool).then(()=>createCloudRuntime({repository,authenticate,config,retain,verifyToken}));
   }
   const r=await runtime;return kind==='api'?r.api(request):r.tick(request);
  }catch{return Response.json({schema_version:1,error:{code:'server_configuration_or_database_unavailable',retryable:false}},{status:503});}
 };
}
