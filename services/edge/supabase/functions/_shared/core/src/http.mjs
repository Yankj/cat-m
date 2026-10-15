import { ApiError,check,UUID } from '../facade-r2/src/common.mjs';
import {TASK_REVISION_CONTRACT,TASK_REVISION_LIMITS} from './task-revision-contract.mjs';
import {ACCEPTED_WORK_INTENT_CONTRACT,ACCEPTED_WORK_INTENT_BYTES,parseAcceptedWorkJSON} from './accepted-work-intent-contract.mjs';
import { createFetchHandler } from '../facade-r2/src/http.mjs';
export function createChatFetchHandler(runtime){
  const {chat,facade}=runtime,taskHandler=createFetchHandler(facade);
  return async request=>{
    try{
      const u=new URL(request.url),parts=u.pathname.split('/').filter(Boolean),auth=request.headers.get('authorization');
      if(parts[0]==='catpaw'&&parts[1]==='accepted-work'){
        check(parts[2]==='v1'&&parts[3]==='scopes'&&UUID.test(parts[4]??'')&&!u.search,422,'work_intent_schema_invalid');
        check(parts[5]==='conversations'&&UUID.test(parts[6]??'')&&parts[7]==='turns',404,'not_found');
        const scope=parts[4],reply=v=>Response.json({schema_version:1,contract:ACCEPTED_WORK_INTENT_CONTRACT,...v},{headers:{'Cache-Control':'no-store'}});
        if(request.method==='GET'&&parts.length===9){check(UUID.test(parts[8]),422,'work_intent_schema_invalid');return reply({turn:await chat.readTurn(auth,scope,parts[6],parts[8])});}
        check(request.method==='POST'&&parts.length===8,404,'not_found');
        check(Number(request.headers.get('content-length')??0)<=ACCEPTED_WORK_INTENT_BYTES,413,'work_intent_request_too_large');
        const input=parseAcceptedWorkJSON(await request.text()),started=await chat.startAcceptedWorkTurn(auth,scope,parts[6],input);
        if(started.replayed)return reply({turn:await chat.readTurn(auth,scope,parts[6],input.turn.turn_id,{trusted:started.trusted}),replayed:true});
        runtime.onAccepted?.({owner:started.trusted.owner,principal:started.trusted.principal,turnId:input.turn.turn_id});
        return streamTurn(request,auth,scope,parts[6],input.turn.turn_id,{trusted:started.trusted,initial:started.turn.events[0],afterSequence:1});
      }
      if(parts[0]==='catpaw'&&parts[1]==='revisions'){
        check(parts[2]==='v1'&&parts[3]==='scopes'&&UUID.test(parts[4]??'')&&!u.search,422,'revision_schema_invalid');const scope=parts[4],reply=v=>Response.json({schema_version:1,contract:TASK_REVISION_CONTRACT,...v},{headers:{'Cache-Control':'no-store'}});
        if(request.method==='GET'&&parts.length===9&&parts[5]==='runs'&&parts[7]==='operations'){check(UUID.test(parts[6]??'')&&UUID.test(parts[8]??''),422,'revision_schema_invalid');return reply(await chat.readRevision(auth,scope,parts[6],parts[8]));}
        check(parts[5]==='conversations'&&UUID.test(parts[6]??'')&&parts[7]==='turns',404,'not_found');
        if(request.method==='GET'&&parts.length===9){check(UUID.test(parts[8]),422,'revision_schema_invalid');return reply({turn:await chat.readTurn(auth,scope,parts[6],parts[8])});}
        check(request.method==='POST'&&parts.length===8,404,'not_found');check(Number(request.headers.get('content-length')??0)<=TASK_REVISION_LIMITS.payload_bytes,413,'revision_request_too_large');const text=await request.text();check(Buffer.byteLength(text)<=TASK_REVISION_LIMITS.payload_bytes,413,'revision_request_too_large');let input;try{input=JSON.parse(text);}catch{throw new ApiError(422,'revision_schema_invalid');}
        const started=await chat.startRevisionTurn(auth,scope,parts[6],input);if(started.replayed)return reply({turn:await chat.readTurn(auth,scope,parts[6],input.turn.turn_id,{trusted:started.trusted}),replayed:true});
        runtime.onAccepted?.({owner:started.trusted.owner,principal:started.trusted.principal,turnId:input.turn.turn_id});return streamTurn(request,auth,scope,parts[6],input.turn.turn_id,{trusted:started.trusted,initial:started.turn.events[0],afterSequence:1});
      }
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
