import {TASK_REVISION_WORK_CONTRACT,TASK_REVISION_WORK_BYTES,parseTaskRevisionWorkJSON} from './task-revision-work-contract.mjs';
import {MEMORY_PROPOSAL_CONTRACT} from './memory-extraction-service.mjs';
import { ApiError,check,UUID } from '../facade-r2/src/common.mjs';
import {TASK_REVISION_CONTRACT,TASK_REVISION_LIMITS} from './task-revision-contract.mjs';
import {ACCEPTED_WORK_INTENT_CONTRACT,ACCEPTED_WORK_INTENT_BYTES,parseAcceptedWorkJSON} from './accepted-work-intent-contract.mjs';
import { createFetchHandler } from '../facade-r2/src/http.mjs';
import {boundedJsonBody,VISION_LIMITS} from './vision-contract.mjs';
import {APPROVAL_HEADER} from './approval.mjs';
import {UI_HEADER} from './generative-ui.mjs';
import {DEVICE_HEADER,DEVICE_RESULT_MAX_BYTES} from './device-call.mjs';
export function createChatFetchHandler(runtime){
  const {chat,facade}=runtime,taskHandler=createFetchHandler(facade);
  return async request=>{
    try{
      const u=new URL(request.url),parts=u.pathname.split('/').filter(Boolean),auth=request.headers.get('authorization');
      if(parts[0]==='catpaw'&&parts[1]==='revision-work'){
        check(parts[2]==='v1'&&parts[3]==='scopes'&&UUID.test(parts[4]??'')&&!u.search,422,'revision_work_schema_invalid');
        const scope=parts[4],reply=value=>Response.json({schema_version:1,contract:TASK_REVISION_WORK_CONTRACT,...value},{headers:{'Cache-Control':'no-store'}});
        if(request.method==='GET'&&parts.length===9&&parts[5]==='runs'&&parts[7]==='operations'){return Response.json(await chat.readRevisionWork(auth,scope,parts[6],parts[8]),{headers:{'Cache-Control':'no-store'}});}
        check(parts[5]==='conversations'&&UUID.test(parts[6]??'')&&parts[7]==='turns',404,'not_found');
        if(request.method==='GET'&&parts.length===9){check(UUID.test(parts[8]),422,'revision_work_schema_invalid');return reply({turn:await chat.readTurn(auth,scope,parts[6],parts[8])});}
        check(request.method==='POST'&&parts.length===8,404,'not_found');check(Number(request.headers.get('content-length')??0)<=TASK_REVISION_WORK_BYTES,413,'revision_work_request_too_large');
        const input=parseTaskRevisionWorkJSON(await request.text()),started=await chat.startRevisionWorkTurn(auth,scope,parts[6],input);
        if(started.replayed)return reply({turn:await chat.readTurn(auth,scope,parts[6],input.turn.turn_id,{trusted:started.trusted}),replayed:true});
        runtime.onAccepted?.({owner:started.trusted.owner,principal:started.trusted.principal,turnId:input.turn.turn_id});
        return streamTurn(request,auth,scope,parts[6],input.turn.turn_id,{trusted:started.trusted,initial:started.turn.events[0],afterSequence:1});
      }
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
      if(method==='POST'&&tail.length===5&&tail[0]==='conversations'&&tail[2]==='turns'&&tail[4]==='cancel'){
        const raw=await request.text();check(raw.length<=64&&['','{}'].includes(raw.trim()),422,'schema_invalid');
        return json({cancel:await chat.cancel(auth,scope,tail[1],tail[3])});
      }
      if(method==='POST'&&tail.length===7&&tail[0]==='conversations'&&tail[2]==='turns'&&tail[4]==='interrupts'&&tail[6]==='decision'){
        // catpaw.approval.v1: decide one interrupt; streams the SAME turn from the approval_resolved event on.
        const decided=await chat.decideInterrupt(auth,scope,tail[1],tail[3],tail[5],await boundedJsonBody(request,2048));
        if(decided.resumed)runtime.onAccepted?.({owner:decided.trusted.owner,principal:decided.trusted.principal,turnId:tail[3]});
        const requested=u.searchParams.get('after_sequence');const afterSequence=requested===null?decided.afterSequence:Number(requested);
        check(Number.isSafeInteger(afterSequence)&&afterSequence>=0&&afterSequence<=decided.turn.events.length,422,'invalid_cursor');
        return streamTurn(request,auth,scope,tail[1],tail[3],{trusted:decided.trusted,afterSequence});
      }
      if(method==='POST'&&tail.length===5&&tail[0]==='conversations'&&tail[2]==='turns'&&tail[4]==='device-result'){
        // catpaw.device.v1: the phone reports one device_call; streams the SAME turn from approval_resolved on.
        const decided=await chat.submitDeviceResult(auth,scope,tail[1],tail[3],await boundedJsonBody(request,DEVICE_RESULT_MAX_BYTES));
        if(decided.resumed)runtime.onAccepted?.({owner:decided.trusted.owner,principal:decided.trusted.principal,turnId:tail[3]});
        return streamTurn(request,auth,scope,tail[1],tail[3],{trusted:decided.trusted,afterSequence:decided.afterSequence});
      }
      if(method==='POST'&&tail.length===5&&tail[0]==='conversations'&&tail[2]==='turns'&&tail[4]==='retry-busy'){
        const restarted=await chat.restartRateLimited(auth,scope,tail[1],tail[3]);
        runtime.onAccepted?.({owner:restarted.trusted.owner,principal:restarted.trusted.principal,turnId:tail[3]});
        return streamTurn(request,auth,scope,tail[1],tail[3],{trusted:restarted.trusted,afterSequence:restarted.afterSequence});
      }
      if(method==='POST'&&tail.length===3&&tail[0]==='conversations'&&tail[2]==='control')return json({conversation:await chat.control(auth,scope,tail[1],await body())});
      if(tail[0]==='attachments'){
        check(chat.attachments,503,'attachments_unavailable');
        if(method==='POST'&&tail.length===1)return json({contract:'catpaw.chat-attachments.v1',...await chat.attachments.create(auth,scope,await boundedJsonBody(request,2048))},201);
        if(method==='GET'&&tail.length===2)return json({contract:'catpaw.chat-attachments.v1',...await chat.attachments.read(auth,scope,tail[1])});
        if(method==='POST'&&tail.length===3&&tail[2]==='complete'){const raw=await request.text();check(raw.length<=64&&['','{}'].includes(raw.trim()),422,'schema_invalid');return json({contract:'catpaw.chat-attachments.v1',...await chat.attachments.complete(auth,scope,tail[1])});}
        throw new ApiError(404,'not_found');
      }
      if(method==='POST'&&tail.length===3&&tail[0]==='conversations'&&tail[2]==='turns'){
        const raw=await body();check(raw?.message?.attachment_ids===undefined||chat.attachments,503,'attachments_unavailable');
        const resolved=raw?.message?.attachment_ids===undefined?{input:raw,consume:async()=>{}}:await chat.attachments.resolveTurnInput(auth,scope,raw);
        if(resolved.replay)return json({turn:await chat.readTurn(auth,scope,tail[1],raw.turn_id),replayed:true});
        const input=resolved.input,capability=request.headers.get('X-Catpaw-Memory-Proposal-Contract'),approvalContract=request.headers.get(APPROVAL_HEADER),timeZone=request.headers.get('X-Catpaw-Time-Zone'),uiContract=request.headers.get(UI_HEADER),memoryMode=request.headers.get('X-Catpaw-Memory-Mode'),deviceContract=request.headers.get(DEVICE_HEADER);
        check(capability===null||capability===MEMORY_PROPOSAL_CONTRACT,422,'memory_proposal_contract_invalid');
        const started=await chat.startTurn(auth,scope,tail[1],input,{memoryProposalContract:capability,approvalContract,timeZone,uiContract,memoryMode,deviceContract});
        if(!started.replayed)await resolved.consume();
        if(started.replayed)return json({turn:await chat.readTurn(auth,scope,tail[1],input.turn_id,{trusted:started.trusted}),replayed:true});
        runtime.onAccepted?.({owner:started.trusted.owner,principal:started.trusted.principal,turnId:input.turn_id});
        return streamTurn(request,auth,scope,tail[1],input.turn_id,{trusted:started.trusted,initial:started.turn.events[0],afterSequence:1});
      }
      function streamTurn(request,auth,scope,cid,tid,{initial,...options}){
        const detach=new AbortController();request.signal?.addEventListener('abort',()=>detach.abort(),{once:true});if(request.signal?.aborted)detach.abort();
        const stream=new ReadableStream({
          async start(controller){try{
            const enqueue=e=>{const started=chat.metrics.now(),bytes=new TextEncoder().encode(`data: ${JSON.stringify(e)}\n\n`);controller.enqueue(bytes);chat.metrics.record('sse_enqueue',started,{bytes:bytes.length});};
            // R7 §5.3 heartbeat: comment frame every 10s; clients treat 15s of silence as a drop.
            const keepalive=setInterval(()=>{try{if(!detach.signal.aborted)controller.enqueue(new TextEncoder().encode(': keepalive\n\n'));}catch{}},10000);detach.signal.addEventListener('abort',()=>clearInterval(keepalive),{once:true});
            try{
            if(initial&&!detach.signal.aborted)enqueue(initial);
            for await(const e of chat.observe(auth,scope,cid,tid,{...options,signal:detach.signal})){if(detach.signal.aborted)break;enqueue(e);}if(!detach.signal.aborted)controller.close();
            }finally{clearInterval(keepalive);}
          }catch(error){console.info(JSON.stringify({event:'catpaw_sse_observe_interrupted',name:error?.name??'unknown',code:error instanceof ApiError?error.code:typeof error?.code==='string'&&/^[A-Za-z0-9_]{1,40}$/.test(error.code)?error.code:null,status:error instanceof ApiError?error.status:null,frames:String(error?.stack??'').split('\n').slice(1,5).map(l=>l.trim().replace(/\(.*?:(\d+):\d+\)/,'@$1').replace(/^at /,'').slice(0,80)),aborted:detach.signal.aborted}));if(!detach.signal.aborted)controller.error(new Error('Observation interrupted; read original turn snapshot'));}},
          cancel(){detach.abort();} // never cancel a durable task or active model turn
        });
        return new Response(stream,{headers:{'Content-Type':'text/event-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
      }
      throw new ApiError(404,'not_found');
    }catch(e){const known=e instanceof ApiError;return Response.json({schema_version:1,error:{code:known?e.code:'internal_error',retryable:false,reconciliation_required:known?e.reconciliation:false}},{status:known?e.status:500,headers:{'Cache-Control':'no-store'}});}
  };
}
