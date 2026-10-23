import {check,UUID} from '../facade-r2/src/common.mjs';
import {createChatFetchHandler} from './http.mjs';
import {PARENTING_INTAKE_CONTRACT,PARENTING_INTAKE_PREFIX} from './parenting-intake-contract.mjs';
import {parseStrictObjectJSON} from './strict-json.mjs';

/** Namespace adapter only: the original chat service owns admission, leases, provider policy, receipts and cancellation. */
export function createParentingIntakeFetchHandler(runtime,{retain=()=>{}}={}){
 const chat=runtime.chat;
 const overrides={
  createConversation:(auth,scope,input)=>chat.createConversation(auth,scope,input,{intakeContract:PARENTING_INTAKE_CONTRACT}),
  readConversation:(auth,scope,cid)=>chat.readConversation(auth,scope,cid,{intakeContract:PARENTING_INTAKE_CONTRACT}),
  async startTurn(auth,scope,cid,input,options){
   check(!options?.memoryProposalContract&&!options?.approvalContract&&!options?.uiContract&&!options?.deviceContract&&!options?.deviceTools&&!options?.uiKinds,422,'parenting_intake_capability_forbidden');
   return chat.startTurn(auth,scope,cid,input,{intakeContract:PARENTING_INTAKE_CONTRACT});
  },
  readTurn:(auth,scope,cid,tid,options)=>chat.readTurn(auth,scope,cid,tid,{...options,intakeContract:PARENTING_INTAKE_CONTRACT}),
  async cancel(auth,scope,cid,tid){return {...await chat.cancel(auth,scope,cid,tid,{intakeContract:PARENTING_INTAKE_CONTRACT}),intake_contract:PARENTING_INTAKE_CONTRACT};},
  restartRateLimited:(auth,scope,cid,tid)=>chat.restartRateLimited(auth,scope,cid,tid,{intakeContract:PARENTING_INTAKE_CONTRACT}),
  async *observe(auth,scope,cid,tid,options){yield*chat.observe(auth,scope,cid,tid,{...options,intakeContract:PARENTING_INTAKE_CONTRACT});}
 };
 const restricted=new Proxy(chat,{get(target,key){if(Object.hasOwn(overrides,key))return overrides[key];const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;}});
 const handler=createChatFetchHandler({...runtime,chat:restricted,onAccepted:({owner,turnId})=>{
  // Retain this model request for Edge lifetime; do not kick any task or proactive work.
  const pending=chat.active.get(`${owner}:${turnId}`)?.promise;if(pending)retain(Promise.allSettled([pending]));
 }});
 return async(request,{path=new URL(request.url).pathname}={})=>{
  const tail=path.slice(PARENTING_INTAKE_PREFIX.length),parts=tail.split('/').filter(Boolean);
  check(path.startsWith(PARENTING_INTAKE_PREFIX+'/')&&parts[0]==='scopes'&&UUID.test(parts[1]??'')&&parts[2]==='conversations',404,'not_found');
  const method=request.method,u=new URL(request.url);
  if(method==='DELETE'&&parts.length===4&&UUID.test(parts[3]??'')&&!u.search){
   const raw=await request.text();check(!raw.trim(),422,'parenting_intake_schema_invalid');
   return Response.json({schema_version:1,contract:'catpaw.native-chat.v1',purge:await chat.purgeParentingIntake(request.headers.get('authorization'),parts[1],parts[3])},{headers:{'Cache-Control':'no-store'}});
  }
  const allowed=method==='POST'&&parts.length===3||method==='GET'&&parts.length===4&&UUID.test(parts[3]??'')||
   UUID.test(parts[3]??'')&&parts[4]==='turns'&&(method==='POST'&&parts.length===5||UUID.test(parts[5]??'')&&(
    method==='GET'&&parts.length===6||method==='GET'&&parts.length===7&&parts[6]==='events'||
    method==='POST'&&parts.length===7&&['cancel','retry-busy'].includes(parts[6])));
  check(allowed,404,'not_found');
  check(!u.search||method==='GET'&&parts[4]==='turns'&&[6,7].includes(parts.length)&&[...u.searchParams.keys()].every(k=>k==='after_sequence'),422,'parenting_intake_schema_invalid');
  const headers=new Headers(request.headers);headers.delete('X-Catpaw-Live-Text');
  let body;if(method==='POST'){
   check(Number(request.headers.get('content-length')??0)<=42000,413,'request_too_large');body=await request.text();
   if(body.trim())parseStrictObjectJSON(body,{maxBytes:42000,maxDepth:8});else check(Buffer.byteLength(body)<=64,413,'request_too_large');
  }
  return handler(new Request(new URL('/catpaw/chat/v1'+tail+u.search,u.origin),{method,headers,signal:request.signal,...method==='POST'?{body}:{}}));
 };
}
