import http from 'node:http';
import {createHash,randomUUID} from 'node:crypto';
const hash=x=>createHash('sha256').update(x).digest('hex');
const conversations=new Map(),turns=new Map(),runs=new Map(),artifacts=new Map();
let turnPosts=0,turnReads=0,ready=true;
const server=http.createServer(async(req,res)=>{
 try{
  if(req.headers.authorization!=='Bearer explicit-wire-test-only'){res.writeHead(401);return res.end('{}');}
  const parts=new URL(req.url,'http://localhost').pathname.split('/').filter(Boolean);
  const emit=(value,status=200,chat=true)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify({schema_version:1,...(chat?{contract:'catpaw.native-chat.v1'}:{}),...value}));};
  if(parts.join('/')==='readyz')return emit({ready},ready?200:503,false);
  if(parts.join('/')==='wire-test-ready'){let raw='';for await(const part of req)raw+=part;ready=JSON.parse(raw).ready===true;return emit({ready},200,false);}
  if(parts.join('/')==='wire-test-offline'){server.close();return emit({offline:true},200,false);}
  if(parts.join('/')==='wire-test-stats')return emit({turnPosts,turnReads},200,false);
  if(parts.slice(0,3).join('/')==='catpaw/v1/scopes'){
   if(parts[4]==='runs')return emit(runs.get(parts[5]),200,false);
   if(parts[4]==='artifacts')return emit({artifact:artifacts.get(parts[5]+':'+parts[7])},200,false);
   throw Error('unexpected fixture facade route');
  }
  if(parts.slice(0,4).join('/')!=='catpaw/chat/v1/scopes')throw Error('unexpected fixture chat route');
  const scope=parts[4],cid=parts[6],tid=parts[8];let chunks=[];for await(const x of req)chunks.push(x);const raw=Buffer.concat(chunks).toString();const body=raw?JSON.parse(raw):null;
  if(req.method==='POST'&&parts.length===6){if(Object.keys(body).join()!=='conversation_id')throw Error('create body');let c=conversations.get(body.conversation_id)??{id:body.conversation_id,scope_id:scope,revision:1,grant_epoch:1,state:'active',policy:'conversation-local-output-v1',messages:[],last_turn_id:null};conversations.set(c.id,c);return emit({conversation:c},201);}
  if(req.method==='GET'&&parts.length===7){let c=conversations.get(cid);return c?emit({conversation:c}):emit({error:{code:'not_found'}},404);}
  if(req.method==='GET'&&parts.length===9){turnReads++;return emit({turn:turns.get(tid)});}
  if(req.method==='POST'&&parts.length===8&&parts[7]==='turns'){
   turnPosts++;
   if(Object.keys(body).sort().join()!=='context,expected_grant_epoch,expected_revision,message,turn_id'||Object.keys(body.message).sort().join()!=='id,text')throw Error('body must not replace history/owner/model/key/permission');
   const c=conversations.get(cid);if(body.expected_revision!==c.revision||body.expected_grant_epoch!==c.grant_epoch)throw Error('frozen revision');
   c.messages.push({id:body.message.id,role:'user',content:body.message.text});c.revision++;
   const mode=body.message.text,mid=randomUUID(),delegation=/^wire-delegation-(delegate_plan_v1|delegate_sources_v1)-(empty|bom|nel|prose)(?: https:\/\/docs\.example\.org\/docs\/one)?$/.exec(mode),unicodeLine=/^wire-sse-(lf|crlf|cr)-unicode$/.exec(mode);
   const text=delegation?{empty:'',bom:' \t\n\u00a0\ufeff',nel:'\u0085',prose:' 已受理 '}[delegation[2]]:unicodeLine?'Wire Unicode \u0085 \u2028 \u2029 😺.':'wire-test answer';let sequence=0;
   const reality=mode==='wire-unconfigured'?'not_configured':'injected_test_provider';
   const event=(type,data)=>({schema_version:1,contract:'catpaw.native-chat.v1',scope_id:scope,conversation_id:cid,turn_id:body.turn_id,sequence:++sequence,cursor:`${body.turn_id}:${sequence}`,grant_epoch:1,model_reality:reality,type,data});
   const requestHash=hash(raw),events=[event('turn_started',{request_hash:requestHash,conversation_revision:c.revision})],bindings=[];
   if(mode==='wire-unconfigured')events.push(event('turn_failed',{code:'not_configured',retryable:false,reconciliation_required:false}));
   else{
    if(delegation||['wire-task','wire-bad-artifact','wire-bad-terminal','wire-scheduled','wire-outcome-unknown','wire-future-state','wire-revoked-scheduled'].includes(mode)){
     const b={scope_id:scope,conversation_id:cid,turn_id:body.turn_id,call_id:'call-one',delegation_id:randomUUID(),operation_id:randomUUID(),run_id:randomUUID(),task_id:hash(body.turn_id),request_hash:hash('task:'+body.turn_id),delegation_revision:1,grant_epoch:1};b.projection_url=`/catpaw/v1/scopes/${scope}/runs/${b.run_id}`;bindings.push(b);
     const toolName=delegation?.[1]??'delegate_task',argumentsValue=delegation?{title:`Wire-only ${toolName} ${delegation[2]}`,goal:'Offline protocol-only delegation',requirements:'No model or real source requests',stop_conditions:['Only named loopback fixture'],steps:['compose','save','verify'].map(id=>({id,title:id,detail:''})),...toolName==='delegate_sources_v1'?{source_urls:['https://docs.example.org/docs/one']}:{} }:{title:'Wire-only committed report',description:'Test only local artifact'};
     events.push(event('tool_call',{call_id:b.call_id,name:toolName,arguments:argumentsValue}));
     const aid='wire-'+b.task_id,content=JSON.stringify({kind:'report',title:'Verified wire artifact',summary:'Test-only result',data:{content:'Original immutable wire content',source:'model_local_output',conversation_id:cid}}),digest=hash(content);
     artifacts.set(aid+':1',{artifact_id:aid,version:1,content_hash:digest,mime_type:'application/json',body:mode==='wire-bad-artifact'?content+' ':content,run_id:b.run_id,task_id:b.task_id});
     const state=delegation||mode==='wire-scheduled'||mode==='wire-revoked-scheduled'?'scheduled':mode==='wire-outcome-unknown'?'outcome_unknown':mode==='wire-future-state'?'future_unrecognized':'succeeded';
     runs.set(b.run_id,{run:{id:b.run_id,operation_id:b.operation_id,delegation_id:b.delegation_id,task_id:b.task_id,request_hash:b.request_hash,delegation_revision:1,grant_epoch:1,state,authorization_state:mode==='wire-revoked-scheduled'?'revoked':'current',artifact_references:delegation?[]:[{artifact_id:aid,version:1,content_hash:digest}]},task:{id:b.task_id,status:state}});
     events.push(event('tool_result',{call_id:b.call_id,name:toolName,result:b}));
    }
    if(text!=='')events.push(event('text_delta',{message_id:mid,text}));
    events.push(event('turn_completed',{message_id:mid,final_text_hash:hash(text),task_bindings:mode==='wire-bad-terminal'?bindings.map(b=>({...b,operation_id:randomUUID()})):bindings}));
    // Match the real server: a delegation receipt never commits ECMAScript-blank assistant prose.
    if(!delegation||text.trim())c.messages.push({id:mid,role:'assistant',content:text});
   }
   c.last_turn_id=body.turn_id;
   turns.set(body.turn_id,{id:body.turn_id,conversation_id:cid,scope_id:scope,grant_epoch:1,state:mode==='wire-unconfigured'?'failed':'completed',request_hash:requestHash,conversation_revision:c.revision,events,task_bindings:bindings});
   if(mode==='wire-http-500')return emit({error:{code:'synthetic_response_lost_after_commit'}},500);
   let outgoing=mode==='wire-interrupt'?events.slice(0,2):events;
   if(mode==='wire-bad-scope')outgoing=events.map(e=>e.type==='text_delta'?{...e,scope_id:randomUUID()}:e);
   res.writeHead(200,{'Content-Type':'text/event-stream'});
   const lineEnding=unicodeLine?{lf:'\n',crlf:'\r\n',cr:'\r'}[unicodeLine[1]]:'\n';
   if(unicodeLine)res.write(': explicit loopback Unicode comment 😺\u2028'+lineEnding);
   for(const [index,e] of outgoing.entries()){
    const unterminated=mode==='wire-sse-unterminated'&&index===outgoing.length-1;
    res.write('data: '+JSON.stringify(e)+(unterminated?'':lineEnding+lineEnding));
   }
   return res.end();
  }
  throw Error('unexpected fixture route');
 }catch(e){res.writeHead(422,{'Content-Type':'application/json'});res.end(JSON.stringify({error:{code:'wire_test_failure'}}));}
});
server.listen(0,'127.0.0.1',()=>process.stdout.write('ORIGIN=http://127.0.0.1:'+server.address().port+'\n'));
process.on('SIGTERM',()=>server.close());
