import http from 'node:http';
import { once } from 'node:events';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { DurableStore } from './store.mjs';
import { AssistantService, scopeKey } from './assistant.mjs';
import { LocalWorker } from './worker.mjs';
import { ModelRegistry, freezeRequest, hash, CredentialProvider, fail, canonicalJSON } from './models.mjs';
import { ModelGateway } from './transport.mjs';
import { SyntheticTransport } from './mock.mjs';

export const DEMO_SCOPE={profile_id:'22222222-1111-4111-8111-111111111111',workspace_id:'22222222-2222-4222-8222-111111111111'};
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
async function jsonBody(req) {
  let text='';for await(const chunk of req) {text+=chunk.toString('utf8');if(Buffer.byteLength(text)>1024*1024) throw fail('body_too_large');}
  try {return JSON.parse(text||'{}');} catch {throw fail('invalid_json');}
}
const json=(res,status,body)=> {res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});res.end(JSON.stringify(body));};
const errorStatus=code=>['conflict','idempotency_conflict','approval_stale','lease_lost'].includes(code)?409:
  ['scope_mismatch','synthetic_scope_required','origin_forbidden'].includes(code)?403:code==='missing'?404:code==='store_locked'?503:400;

// Explicit local synthetic server. Production auth/TLS/tenant resolution is a separate prerequisite.
// There is no command-line flag that enables paid or real inference, and no secret lookup.
export function createLocalServer({statePath,scope=DEMO_SCOPE,service=new AssistantService(new DurableStore(statePath)),gateway=new ModelGateway({transport:new SyntheticTransport(),credentials:new CredentialProvider()})}) {
  const worker=new LocalWorker(service,{gateway,id:`local-${randomUUID()}`});const active=new Map();const registry=new ModelRegistry();
  const server=http.createServer(async(req,res)=>{
    try {
      if(req.headers.origin) throw fail('origin_forbidden');
      const url=new URL(req.url,'http://127.0.0.1');const path=url.pathname;const method=req.method;
      if(path==='/v1/capabilities'&&method==='GET') return json(res,200,{schema_version:1,mode:'local_synthetic',cloud_worker:'unverified',push_registration:'unverified',real_model_calls:'disabled',external_dispatch:'unavailable',models:registry.list()});
      if(req.headers['x-catpaw-demo']!=='synthetic-only') throw fail('synthetic_scope_required');
      const input=['POST','PATCH','DELETE'].includes(method)?await jsonBody(req):{};
      if(input.scope&&scopeKey(input.scope)!==scopeKey(scope)) throw fail('scope_mismatch');
      const key=req.headers['idempotency-key'];const expected=Number(req.headers['if-match']);
      let match;
      if(path==='/v1/sync'&&method==='GET') return json(res,200,service.projection(scope,Number(url.searchParams.get('cursor')??0)));
      if(path==='/v1/delegations'&&method==='POST') return json(res,201,service.createDelegation(scope,input,key));
      if((match=/^\/v1\/delegations\/([^/]+)$/.exec(path))) {
        if(method==='GET') return json(res,200,service.getDelegation(scope,match[1]));
        if(method==='PATCH') return json(res,200,service.editDelegation(scope,match[1],input,expected,key));
      }
      if((match=/^\/v1\/delegations\/([^/]+)\/(pause|resume|cancel|complete)$/.exec(path))&&method==='POST') return json(res,200,service.control(scope,match[1],{pause:'paused',resume:'active',cancel:'cancelled',complete:'completed'}[match[2]],expected,key));
      if((match=/^\/v1\/delegations\/([^/]+)\/runs$/.exec(path))&&method==='POST') return json(res,201,service.enqueue(scope,match[1],key));
      if((match=/^\/v1\/delegations\/([^/]+)\/sources$/.exec(path))&&method==='POST') return json(res,201,service.addSource(scope,match[1],input.url,key));
      if((match=/^\/v1\/sources\/([^/]+)\/permission$/.exec(path))&&method==='POST') return json(res,200,service.sourcePermission(scope,match[1],input.allowed,expected,key));
      if((match=/^\/v1\/delegations\/([^/]+)\/memories$/.exec(path))&&method==='POST') return json(res,201,service.addMemory(scope,match[1],input.content,input.source_message_id,key));
      if((match=/^\/v1\/memories\/([^/]+)$/.exec(path))&&method==='DELETE') return json(res,202,service.forgetMemory(scope,match[1],expected,key));
      if((match=/^\/v1\/runs\/([^/]+)$/.exec(path))&&method==='GET') return json(res,200,service.getRun(scope,match[1]));
      if((match=/^\/v1\/artifacts\/([^/]+)$/.exec(path))) {
        if(method==='GET') return json(res,200,service.getArtifact(scope,match[1]));
        if(method==='PATCH') return json(res,200,service.editArtifact(scope,match[1],input.base_version,input.body,key));
      }
      if((match=/^\/v1\/artifacts\/([^/]+)\/versions\/(\d+)$/.exec(path))&&method==='GET') {
        const artifact=service.getArtifact(scope,match[1]);const version=artifact.versions.find(v=>v.version===Number(match[2]));
        if(!version) throw fail('missing');return json(res,200,{...version,artifact_id:artifact.id,document_id:artifact.document_id});
      }
      if(path==='/v1/actions/prepare'&&method==='POST') return json(res,201,service.prepareApproval(scope,input.artifact_id,input.reference,input.target,key));
      if((match=/^\/v1\/approvals\/([^/]+)\/decisions$/.exec(path))&&method==='POST') return json(res,200,service.decideApproval(scope,match[1],expected,input.action_digest,input.decision,key));
      if(path==='/v1/local-worker/tick'&&method==='POST') return json(res,200,await worker.tick());
      if(path==='/v1/chat'&&method==='POST') {
        if(!UUID.test(input.operation_id??'')||!Number.isSafeInteger(input.runtime_epoch)||input.runtime_epoch<1||
          typeof input.text!=='string'||hash(input.text)!==input.frozen_text_hash) throw fail('invalid_chat_request');
        const index=`${scopeKey(scope)}:${input.operation_id.toLowerCase()}:${input.runtime_epoch}`;
        const digest=hash(canonicalJSON({...input,operation_id:input.operation_id.toLowerCase(),scope}));let saved=service.store.read().chats?.[index];
        if(saved&&saved.digest!==digest) throw fail('idempotency_conflict');
        if(saved?.state==='finished') {
          res.writeHead(200,{'content-type':'text/event-stream','cache-control':'no-store'});
          for(const e of saved.events) res.write(`data: ${JSON.stringify(e)}\n\n`);res.end();return;
        }
        if(saved) throw fail('chat_already_admitted'); // reconnect/unknown never silently invokes again
        const frozen=freezeRequest(registry.select(input.model_id),{messages:[{role:'user',content:input.text}]});
        service.store.transact(s=>{s.chats??={};s.chats[index]={scope,digest,state:'admitted',frozen_request:frozen,events:[]};});
        const controller=new AbortController();active.set(index,controller);
        res.on('close',()=>controller.abort());
        res.writeHead(200,{'content-type':'text/event-stream','cache-control':'no-store','x-catpaw-mode':'local_synthetic'});
        try {
          for await(const event of gateway.stream(frozen,{operationID:input.operation_id,runtimeEpoch:input.runtime_epoch,signal:controller.signal})) {
            service.store.transact(s=>{s.chats[index].events.push(event);});
            if(!res.destroyed&&!res.write(`data: ${JSON.stringify(event)}\n\n`)) await Promise.race([once(res,'drain'),once(res,'close')]);
          }
          service.store.transact(s=>{s.chats[index].state='finished';});
        } finally {active.delete(index);res.end();}
        return;
      }
      if((match=/^\/v1\/chat\/([^/]+)\/(observe|cancel)$/.exec(path))) {
        const epoch=Number(input.runtime_epoch??url.searchParams.get('epoch'));
        const index=`${scopeKey(scope)}:${match[1].toLowerCase()}:${epoch}`;
        const saved=service.store.read().chats?.[index];if(!saved) throw fail('missing');
        if(match[2]==='cancel'&&method==='POST') {active.get(index)?.abort();return json(res,200,{status:active.has(index)?'cancel_requested':'not_running',events:saved.events});}
        if(match[2]==='observe'&&method==='GET') return json(res,200,{status:saved.state==='admitted'&&!active.has(index)?'outcome_unknown':saved.state,events:saved.events});
      }
      json(res,404,{code:'route_unavailable'});
    } catch(error) {if(res.headersSent) res.destroy();else json(res,errorStatus(error.code),{code:error.code??'request_failed'});}
  });
  return {server,service,worker};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
  const app=createLocalServer({statePath:resolve('local-data/state.json')});
  app.server.listen(8787,'127.0.0.1',()=>process.stdout.write('Catpaw local synthetic gateway http://127.0.0.1:8787 — real calls disabled, no cloud deployment\n'));
}
