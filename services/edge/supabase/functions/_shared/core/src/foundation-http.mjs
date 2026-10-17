import {ApiError,check,shape,UUID} from '../facade-r2/src/common.mjs';
import {createChatFetchHandler} from './http.mjs';
import {MEMORY_CONTRACT,MEMORY_LIMITS,parseMemoryCommand,memoryUUID} from './memory-contract.mjs';
import {readMemoryState,readMemorySource,readMemoryOperation,applyMemoryCommand} from './memory-service.mjs';
// Additive typed user memory commands; source purge and existing plans keep their contracts.
export function createFoundationFetchHandler(runtime){
 const chat=createChatFetchHandler(runtime);
 return async request=>{
  const parts=new URL(request.url).pathname.split('/').filter(Boolean);
  if(!(parts[0]==='catpaw'&&['memory','plans'].includes(parts[1])))return chat(request);
  try{
   if(parts[1]==='plans'){
    check(parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='runs'&&parts[7]==='plan'&&UUID.test(parts[4]??'')&&UUID.test(parts[6]??''),404,'route_not_supported');
    check(new URL(request.url).search==='',422,'schema_invalid');
    const auth=request.headers.get('authorization'),scope=parts[4],run=parts[6];let value;
    if(request.method==='GET'&&parts.length===8)value=await runtime.facade.readPlan(auth,scope,run);
    else if(request.method==='GET'&&parts.length===10&&parts[8]==='amendments'){check(UUID.test(parts[9]),422,'schema_invalid');value=await runtime.facade.readPlanAmendment(auth,scope,run,parts[9]);}
    else {
     check(request.method==='POST'&&parts.length===9&&parts[8]==='amendments',404,'route_not_supported');
     check(Number(request.headers.get('content-length')??0)<=48000,413,'request_too_large');
     const text=await request.text();check(new TextEncoder().encode(text).length<=48000,413,'request_too_large');let input;try{input=JSON.parse(text);}catch{throw new ApiError(422,'schema_invalid');}
     value=await runtime.facade.amendPlan(auth,scope,run,input);
    }
    return Response.json(value,{headers:{'Cache-Control':'no-store'}});
   }
   if(parts[2]==='v1'&&parts[3]==='scopes'&&['state','commands'].includes(parts[5]) || parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='sources'&&parts.length===7){
    check(!new URL(request.url).search,422,'memory_schema_invalid');const scope=memoryUUID(parts[4]),auth=request.headers.get('authorization'),options={signal:request.signal};let value;
    if(request.method==='GET'&&parts.length===6&&parts[5]==='state')value=await readMemoryState(runtime,auth,scope,options);
    else if(request.method==='GET'&&parts.length===7&&parts[5]==='sources')value=await readMemorySource(runtime,auth,scope,memoryUUID(parts[6]),options);
    else if(request.method==='GET'&&parts.length===7&&parts[5]==='commands')value=await readMemoryOperation(runtime,auth,scope,memoryUUID(parts[6]),options);
    else {check(request.method==='POST'&&parts.length===6&&parts[5]==='commands',404,'route_not_supported');check(Number(request.headers.get('content-length')??0)<=MEMORY_LIMITS.payload_bytes,413,'memory_request_too_large');value=await applyMemoryCommand(runtime,auth,scope,parseMemoryCommand(await request.text()),options);}
    return Response.json(value,{headers:{'Cache-Control':'no-store'}});
   }
   if(request.method==='GET'&&parts.length===8&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='sources'&&parts[7]==='purge-plan'){check(UUID.test(parts[4])&&UUID.test(parts[6]),422,'schema_invalid');const plan=await runtime.previewSourcePurge(request.headers.get('authorization'),parts[4],parts[6]);return Response.json({schema_version:1,plan},{headers:{'Cache-Control':'no-store'}});}
   check(request.method==='POST'&&parts.length===8&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='sources'&&parts[7]==='delete',404,'route_not_supported');
   check(UUID.test(parts[4])&&UUID.test(parts[6]),422,'schema_invalid');
   const text=await request.text();check(new TextEncoder().encode(text).length<=256,413,'request_too_large');let body;try{body=JSON.parse(text);}catch{throw new ApiError(422,'schema_invalid');}shape(body,[]);
   const result=await runtime.deleteChatSource(request.headers.get('authorization'),parts[4],parts[6]);
   return Response.json({schema_version:1,result},{headers:{'Cache-Control':'no-store'}});
  }catch(e){return Response.json({schema_version:1,...parts[1]==='memory'?{contract:MEMORY_CONTRACT}:{},error:{code:e instanceof ApiError?e.code:'internal_error',retryable:e instanceof ApiError&&e.retryable===true,reconciliation_required:e instanceof ApiError?e.reconciliation:false}},{status:e instanceof ApiError?e.status:500,headers:{'Cache-Control':'no-store',...e instanceof ApiError&&e.retryAfterSec?{'Retry-After':String(e.retryAfterSec)}:{}}});}
 };
}
