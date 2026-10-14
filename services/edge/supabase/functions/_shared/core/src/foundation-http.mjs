import {ApiError,check,shape,UUID} from '../facade-r2/src/common.mjs';
import {createChatFetchHandler} from './http.mjs';
// Minimal owner deletion endpoint; no model memory command, source ingress or second scheduler.
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
   if(request.method==='GET'&&parts.length===8&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='sources'&&parts[7]==='purge-plan'){check(UUID.test(parts[4])&&UUID.test(parts[6]),422,'schema_invalid');const plan=await runtime.previewSourcePurge(request.headers.get('authorization'),parts[4],parts[6]);return Response.json({schema_version:1,plan},{headers:{'Cache-Control':'no-store'}});}
   check(request.method==='POST'&&parts.length===8&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='sources'&&parts[7]==='delete',404,'route_not_supported');
   check(UUID.test(parts[4])&&UUID.test(parts[6]),422,'schema_invalid');
   const text=await request.text();check(new TextEncoder().encode(text).length<=256,413,'request_too_large');let body;try{body=JSON.parse(text);}catch{throw new ApiError(422,'schema_invalid');}shape(body,[]);
   const result=await runtime.deleteChatSource(request.headers.get('authorization'),parts[4],parts[6]);
   return Response.json({schema_version:1,result},{headers:{'Cache-Control':'no-store'}});
  }catch(e){return Response.json({schema_version:1,error:{code:e instanceof ApiError?e.code:'internal_error',retryable:false,reconciliation_required:e instanceof ApiError?e.reconciliation:false}},{status:e instanceof ApiError?e.status:500,headers:{'Cache-Control':'no-store'}});}
 };
}
