import { ApiError,check } from '../facade-r2/src/common.mjs';
import { createFetchHandler } from '../facade-r2/src/http.mjs';
export function createChatFetchHandler(runtime){
  const {chat,facade}=runtime,taskHandler=createFetchHandler(facade);
  return async request=>{
    try{
      const u=new URL(request.url),parts=u.pathname.split('/').filter(Boolean),auth=request.headers.get('authorization');
      if(parts[0]==='catpaw'&&parts[1]==='v1'){
        check(request.method==='GET'||(request.method==='POST'&&parts.at(-1)==='control'),404,'route_not_supported');
        return taskHandler(request);
      }
      check(parts[0]==='catpaw'&&parts[1]==='chat'&&parts[2]==='v1'&&parts[3]==='scopes'&&parts[4],404,'not_found');
      const scope=parts[4],tail=parts.slice(5),method=request.method;
      const body=async()=>{check(Number(request.headers.get('content-length')??0)<=42000,413,'request_too_large');const text=await request.text();check(Buffer.byteLength(text)<=42000,413,'request_too_large');try{return JSON.parse(text);}catch{throw new ApiError(422,'schema_invalid');}};
      const json=(v,status=200)=>Response.json({schema_version:1,contract:'catpaw.native-chat.v1',...v},{status,headers:{'Cache-Control':'no-store'}});
      if(method==='POST'&&tail.length===1&&tail[0]==='conversations')return json({conversation:await chat.createConversation(auth,scope,await body())},201);
      if(method==='GET'&&tail.length===2&&tail[0]==='conversations')return json({conversation:await chat.readConversation(auth,scope,tail[1])});
      if(method==='GET'&&tail.length===4&&tail[0]==='conversations'&&tail[2]==='turns')return json({turn:await chat.readTurn(auth,scope,tail[1],tail[3],{afterSequence:Number(u.searchParams.get('after_sequence')??0)})});
      if(method==='POST'&&tail.length===3&&tail[0]==='conversations'&&tail[2]==='control')return json({conversation:await chat.control(auth,scope,tail[1],await body())});
      if(method==='POST'&&tail.length===3&&tail[0]==='conversations'&&tail[2]==='turns'){
        const input=await body(),started=await chat.startTurn(auth,scope,tail[1],input);
        if(started.replayed)return json({turn:await chat.readTurn(auth,scope,tail[1],input.turn_id),replayed:true});
        const detach=new AbortController();request.signal?.addEventListener('abort',()=>detach.abort(),{once:true});if(request.signal?.aborted)detach.abort();
        const stream=new ReadableStream({
          async start(controller){try{for await(const e of chat.observe(auth,scope,tail[1],input.turn_id,{signal:detach.signal})){if(detach.signal.aborted)break;controller.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(e)}\n\n`));}if(!detach.signal.aborted)controller.close();}catch{if(!detach.signal.aborted)controller.error(new Error('Observation interrupted; read original turn snapshot'));}},
          cancel(){detach.abort();} // never cancel a durable task or active model turn
        });
        return new Response(stream,{headers:{'Content-Type':'text/event-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
      }
      throw new ApiError(404,'not_found');
    }catch(e){const known=e instanceof ApiError;return Response.json({schema_version:1,error:{code:known?e.code:'internal_error',retryable:false,reconciliation_required:known?e.reconciliation:false}},{status:known?e.status:500,headers:{'Cache-Control':'no-store'}});}
  };
}
