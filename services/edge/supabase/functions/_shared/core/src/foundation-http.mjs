import {ApiError,check,shape,UUID} from '../facade-r2/src/common.mjs';
import {createChatFetchHandler} from './http.mjs';
// Minimal owner deletion endpoint; no model memory command, source ingress or second scheduler.
export function createFoundationFetchHandler(runtime){
 const chat=createChatFetchHandler(runtime);
 return async request=>{
  const parts=new URL(request.url).pathname.split('/').filter(Boolean);
  if(!(parts[0]==='catpaw'&&parts[1]==='memory'))return chat(request);
  try{
   if(request.method==='GET'&&parts.length===8&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='sources'&&parts[7]==='purge-plan'){check(UUID.test(parts[4])&&UUID.test(parts[6]),422,'schema_invalid');const plan=await runtime.previewSourcePurge(request.headers.get('authorization'),parts[4],parts[6]);return Response.json({schema_version:1,plan},{headers:{'Cache-Control':'no-store'}});}
   check(request.method==='POST'&&parts.length===8&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[5]==='sources'&&parts[7]==='delete',404,'route_not_supported');
   check(UUID.test(parts[4])&&UUID.test(parts[6]),422,'schema_invalid');
   const text=await request.text();check(new TextEncoder().encode(text).length<=256,413,'request_too_large');let body;try{body=JSON.parse(text);}catch{throw new ApiError(422,'schema_invalid');}shape(body,[]);
   const result=await runtime.deleteChatSource(request.headers.get('authorization'),parts[4],parts[6]);
   return Response.json({schema_version:1,result},{headers:{'Cache-Control':'no-store'}});
  }catch(e){return Response.json({schema_version:1,error:{code:e instanceof ApiError?e.code:'internal_error',retryable:false,reconciliation_required:e instanceof ApiError?e.reconciliation:false}},{status:e instanceof ApiError?e.status:500,headers:{'Cache-Control':'no-store'}});}
 };
}
