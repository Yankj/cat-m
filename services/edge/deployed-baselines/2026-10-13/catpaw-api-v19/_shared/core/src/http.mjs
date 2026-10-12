import { ApiError,check } from '../facade-r2/src/common.mjs';
import { createFetchHandler } from '../facade-r2/src/http.mjs';
import {boundedJsonBody,VISION_LIMITS} from './vision-contract.mjs';
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
      const body=()=>boundedJsonBody(request,chat.vision?.enabled&&method==='POST'&&tail.length===3&&tail[2]==='turns'?VISION_LIMITS.max_request_bytes:42000);
      const json=(v,status=200)=>Response.json({schema_version:1,contract:'catpaw.native-chat.v1',...v},{status,headers:{'Cache-Control':'no-store'}});
      if(method==='POST'&&tail.length===1&&tail[0]==='conversations')return json({conversation:await chat.createConversation(auth,scope,await body())},201);
      if(method==='GET'&&tail.length===2&&tail[0]==='conversations')return json({conversation:await chat.readConversation(auth,scope,tail[1])});
      if(method==='GET'&&tail.length===4&&tail[0]==='conversations'&&tail[2]==='turns')return json({turn:await chat.readTurn(auth,scope,tail[1],tail[3],{afterSequence:Number(u.searchParams.get('after_sequence')??0)})});
      if(method==='GET'&&tail.length===5&&tail[0]==='conversations'&&tail[2]==='turns'&&tail[4]==='events'){
        const afterSequence=Number(u.searchParams.get('after_sequence')??0);
        // Authenticate and validate cursor/scope before returning an SSE response.
        const trusted=await chat.scoped(auth,scope);
        await chat.readTurn(auth,scope,tail[1],tail[3],{afterSequence,trusted});
        return streamTurn(request,auth,scope,tail[1],tail[3],{afterSequence,trusted});
      }
      if(method==='POST'&&tail.length===3&&tail[0]==='conversations'&&tail[2]==='control')return json({conversation:await chat.control(auth,scope,tail[1],await body())});
      if(method==='POST'&&tail.length===3&&tail[0]==='conversations'&&tail[2]==='turns'){
        const input=await body(),started=await chat.startTurn(auth,scope,tail[1],input);
        if(started.replayed)return json({turn:await chat.readTurn(auth,scope,tail[1],input.turn_id,{trusted:started.trusted}),replayed:true});
        runtime.onAccepted?.({owner:started.trusted.owner,principal:started.trusted.principal,turnId:input.turn_id});
        return streamTurn(request,auth,scope,tail[1],input.turn_id,{trusted:started.trusted,initial:started.turn.events[0],afterSequence:1});
      }
      function streamTurn(request,auth,scope,cid,tid,{initial,...options}){
        const detach=new AbortController();request.signal?.addEventListener('abort',()=>detach.abort(),{once:true});if(request.signal?.aborted)detach.abort();
        const stream=new ReadableStream({
          async start(controller){try{
            const enqueue=e=>{const started=chat.metrics.now(),bytes=new TextEncoder().encode(`data: ${JSON.stringify(e)}\n\n`);controller.enqueue(bytes);chat.metrics.record('sse_enqueue',started,{bytes:bytes.length});};
            if(initial&&!detach.signal.aborted)enqueue(initial);
            for await(const e of chat.observe(auth,scope,cid,tid,{...options,signal:detach.signal})){if(detach.signal.aborted)break;enqueue(e);}if(!detach.signal.aborted)controller.close();
          }catch{if(!detach.signal.aborted)controller.error(new Error('Observation interrupted; read original turn snapshot'));}},
          cancel(){detach.abort();} // never cancel a durable task or active model turn
        });
        return new Response(stream,{headers:{'Content-Type':'text/event-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
      }
      throw new ApiError(404,'not_found');
    }catch(e){const known=e instanceof ApiError;return Response.json({schema_version:1,error:{code:known?e.code:'internal_error',retryable:false,reconciliation_required:known?e.reconciliation:false}},{status:known?e.status:500,headers:{'Cache-Control':'no-store'}});}
  };
}
