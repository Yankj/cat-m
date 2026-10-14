import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {PublicWebReader,parsePublicHTTPResponse,extractPublicSourceText,sourceBodyHash} from '../supabase/functions/_shared/public-web-reader.mjs';
import {canonicalPublicURL,canonicalUserSourceURLs,freezePublicSourceCatalog,isPublicIPv4,validatePublicSourcePolicy,policyTargetForURL,sourceReadIdentity} from '../supabase/functions/_shared/core/src/public-source-contract.mjs';
import {TaskSourceService,hasUnresolvedSourceReads,SOURCE_READS,SOURCE_RECEIPTS} from '../supabase/functions/_shared/core/src/task-source-service.mjs';
import {TestRepository} from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
import {LocalOutputFacade} from '../supabase/functions/_shared/core/src/local-output-facade.mjs';
import {ApiError,hash} from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';

globalThis.fetch=()=>{throw Error('fetch_dns_fallback_forbidden');};
const URL1='https://docs.example.org/docs/one',URL2='https://docs.example.org/docs/two';
const POLICY={schema_version:1,contract:'catpaw.public-web-policy.v1',origins:[{origin:'https://docs.example.org',connect_ipv4:'93.184.216.34',path_prefixes:['/docs/']}]};
const encode=text=>new TextEncoder().encode(text),TEXT='A public fictional document. This exact supported sentence is useful evidence.';
const http=(body=TEXT,headers='Content-Type: text/plain; charset=utf-8\r\n')=>encode(`HTTP/1.1 200 OK\r\n${headers}Content-Length: ${encode(body).length}\r\n\r\n${body}`);
function fakeNet(responses=[http()],{peer='93.184.216.34',onWrite=null}={}){
 const calls=[],connections=[];
 const net={calls,connections,async connect(options){calls.push({connect:options});const conn={remoteAddr:{hostname:peer,port:443},closed:false,close(){this.closed=true;}};connections.push(conn);return conn;},async startTls(tcp,options){calls.push({tls:options});const response=responses.shift();assert.ok(response,'unexpected extra network request');let offset=0;const conn={remoteAddr:tcp.remoteAddr,closed:false,async handshake(){return {alpnProtocol:'http/1.1'};},async write(bytes){assert.equal(this.closed,false);calls.push({request:new TextDecoder().decode(bytes)});if(onWrite)await onWrite();return bytes.length;},async read(buffer){assert.equal(this.closed,false);if(offset===response.length)return null;const n=Math.min(buffer.length,response.length-offset,13);buffer.set(response.subarray(offset,offset+n));offset+=n;return n;},close(){this.closed=true;tcp.close();}};connections.push(conn);return conn;}};
 return net;
}
const read=(reader,url=URL1,options={})=>reader.read(url,{signal:new AbortController().signal,assertLive(){},...options});
async function fixture({responses=[http()],urls=[URL1],onWrite=null,policy=POLICY}={}){
 const repository=new TestRepository(),scope={scope_id:randomUUID(),profile_id:randomUUID(),workspace_id:randomUUID()},principal={subject_id:randomUUID(),session_id:randomUUID(),scopes:[scope]},facade=new LocalOutputFacade({repository,authenticate:()=>principal});
 const planContent={title:'Public sources',goal:'Read given documents',requirements:'Fixture only',stop_conditions:['Require bound receipts'],steps:['compose','save','verify'].map(id=>({id,title:id,detail:''}))};
 const owner=facade.owner(scope),runID=randomUUID(),taskID=hash(runID),cid=randomUUID(),delegation=randomUUID(),operation=randomUUID(),lease=randomUUID(),planReference={revision:1,plan_hash:hash(planContent)},net=fakeNet(responses,{onWrite}),reader=new PublicWebReader({policy,net});
 await repository.bootstrapScope({...scope,owner});facade.memoryGenerationEnabled=true;
 const catalog=freezePublicSourceCatalog({runID,selectedURLs:urls,userTexts:urls,policyHash:reader.policyHash??hash(POLICY)}),frozen={scope,subject_id:principal.subject_id,conversation_id:cid,turn_id:randomUUID(),source_auth:{subject_id:principal.subject_id,session_id:principal.session_id,scope_id:scope.scope_id},memory_generation:1,public_sources:catalog,policy:'conversation-local-output-v1'},requestHash=hash(frozen),tag={run_id:runID,delegation_id:delegation,operation_id:operation,grant_epoch:1,delegation_revision:1,request_hash:requestHash};
 const task={id:taskID,status:'running',leaseId:lease,leaseUntil:new Date(Date.now()+60000).toISOString(),state:{catpaw:tag,plan_binding:planReference,local_model:{round:{state:'received',calls:[{id:'read',name:'read_public_sources_v1',arguments:{}}],next:0,results:[]}}},artifactIds:[]};
 const run={id:runID,...tag,task_id:taskID,frozen_request:frozen,approval_ids:[],artifact_references:[]};
 await repository.transaction(async tx=>{await tx.put(owner,'native-chat-conversations',{id:cid,subject_id:principal.subject_id,scope_id:scope.scope_id});await tx.put(owner,'catpaw-delegations',{id:delegation,state:'active',revision:1,grant_epoch:1,subject_id:principal.subject_id,conversation_id:cid});await tx.put(owner,'catpaw-runs',run);await tx.put(owner,'tasks',task);await tx.put(owner,'catpaw-task-plan-heads',{id:runID,run_id:runID,task_id:taskID,scope_id:scope.scope_id,subject_id:principal.subject_id,conversation_id:cid,accepted_revision:1,applied_revision:1,applied_plan_hash:planReference.plan_hash});await tx.put(owner,'catpaw-task-plan-versions',{id:`${runID}:1`,run_id:runID,revision:1,plan_hash:planReference.plan_hash,content:planContent});});
 let permitted=true;const original=facade.admittedTask.bind(facade);facade.admittedTask=async(...args)=>{const value=await original(...args);checkPermitted();return value;};const checkPermitted=()=>{if(!permitted)throw new ApiError(409,'grant_conflict');};facade.beforeSourceRead=async()=>checkPermitted();
 const service=new TaskSourceService({facade,reader}),controller=new AbortController(),options={signal:controller.signal,assertLive(){if(controller.signal.aborted)throw new ApiError(409,'source_read_cancelled');}};
 return {repository,facade,service,reader,net,owner,runID,taskID,lease,scope,principal,planReference,catalog,controller,options,revoke:()=>{permitted=false;},read:(source='source-1',extra={})=>service.readSource(owner,taskID,lease,source,{...options,...extra}),rows:kind=>repository.transaction(tx=>tx.list(owner,kind))};
}

test('source catalog freezes only bounded exact USER URLs, stable run ordinals and read identity',()=>{
 assert.deepEqual(canonicalUserSourceURLs([`User says [first](${URL1}#part), then <${URL2}>.`]),[URL1,URL2]);
 const runID=randomUUID(),catalog=freezePublicSourceCatalog({runID,selectedURLs:[URL2,URL1],userTexts:[URL1+' '+URL2],policyHash:hash(POLICY)});assert.deepEqual(catalog.sources.map(s=>s.source_id),['source-1','source-2']);assert.equal(catalog.sources[0].requested_url,URL2);
 assert.throws(()=>freezePublicSourceCatalog({runID,selectedURLs:['https://invented.example.org/docs/a'],userTexts:[URL1],policyHash:hash(POLICY)}),e=>e.code==='source_not_user_provided');
 const binding={revision:1,plan_hash:hash('p')};assert.equal(sourceReadIdentity(runID,binding,'source-1'),sourceReadIdentity(runID,binding,'source-1'));assert.notEqual(sourceReadIdentity(runID,binding,'source-1'),sourceReadIdentity(runID,{...binding,revision:2},'source-1'));
});
test('origin lexical checks and public IPv4 pins reject metadata/private/link-local/rebinding representations',()=>{
 for(const url of ['http://docs.example.org/','https://127.0.0.1/','https://2130706433/','https://0x7f000001/','https://[::1]/','https://[::ffff:127.0.0.1]/','https://metadata.google.internal/','https://localhost/','https://a.local/','https://user:pass@docs.example.org/docs/a','https://docs.example.org:8443/docs/a','https://docs.example.org/docs/%0d%0aX:evil','https://docs.example.org/docs/%hello','https://docs.example.org\\@localhost/'])assert.throws(()=>canonicalPublicURL(url));
 for(const ip of ['0.0.0.0','10.1.1.1','100.64.1.1','127.0.0.1','168.63.129.16','169.254.169.254','172.16.0.1','192.168.1.1','192.0.0.1','192.0.2.2','192.88.99.1','198.18.0.1','198.51.100.3','203.0.113.4','224.0.0.1','255.255.255.255','::1','::ffff:8.8.8.8','008.8.8.8'])assert.equal(isPublicIPv4(ip),false,ip);
 assert.equal(isPublicIPv4('93.184.216.34'),true);assert.throws(()=>validatePublicSourcePolicy({...POLICY,origins:[{...POLICY.origins[0],connect_ipv4:'127.0.0.1'}]}));
 for(const url of ['https://other.example.org/docs/a','https://docs.example.org/private','https://docs.example.org/docs/%2e%2e/private','https://docs.example.org/docs/%252e%252e/private','https://docs.example.org/docs/%2fprivate'])assert.throws(()=>policyTargetForURL(POLICY,url));
});
test('anonymous public URLs reject common signed/auth query keys while retaining ordinary public filters',()=>{
 for(const query of ['access_token=fake','Access_Token=fake','api_key=fake','APIKEY=fake','authorization=fake','password=fake','token=fake','X-Amz-Signature=fake','x-amz-credential=fake','X-Goog-Signature=fake','oauth_token=fake','sig=fake','%61ccess_token=fake','%2561ccess_token=fake'])assert.throws(()=>canonicalPublicURL(URL1+'?'+query),e=>e.code==='source_url_credential_not_allowed',query);
 assert.equal(canonicalPublicURL(URL1+'?hl=zh&page=2&q=token'),URL1+'?hl=zh&page=2&q=token');assert.deepEqual(canonicalUserSourceURLs([URL1+'?token=fake '+URL2]),[URL2]);
 const net=fakeNet();assert.throws(()=>canonicalPublicURL(URL1+'?access_token=fake'));assert.equal(net.calls.length,0);
});
test('reader dials only pinned literal public IPv4, verifies original TLS hostname, and emits actual byte/text hashes',async()=>{
 const net=fakeNet(),reader=new PublicWebReader({policy:POLICY,net}),receipt=await read(reader);assert.equal(receipt.content_hash,sourceBodyHash(encode(TEXT)));assert.equal(receipt.text_hash,hash(TEXT));assert.equal(receipt.requested_url,URL1);assert.equal(receipt.final_url,URL1);assert.match(receipt.read_at,/\.\d{3}Z$/);
 assert.deepEqual(net.calls[0].connect,{hostname:'93.184.216.34',port:443,transport:'tcp'});assert.deepEqual(net.calls[1].tls,{hostname:'docs.example.org',alpnProtocols:['http/1.1']});const request=net.calls.find(c=>c.request).request;assert.match(request,/Host: docs.example.org\r\n/);assert.match(request,/Accept-Encoding: identity/);assert.doesNotMatch(request,/Authorization|Cookie|Proxy-Authorization/i);assert.ok(net.connections.every(c=>c.closed));
 await assert.rejects(read(new PublicWebReader({net})),e=>e.code==='public_source_policy_not_configured');await assert.rejects(read(new PublicWebReader({policy:POLICY,net:{}})),e=>e.code==='public_source_transport_not_supported');
 const wrong=fakeNet([http()],{peer:'169.254.169.254'});await assert.rejects(read(new PublicWebReader({policy:POLICY,net:wrong})),e=>e.code==='source_peer_binding_invalid');assert.equal(wrong.calls.length,1);assert.ok(wrong.connections.every(c=>c.closed));
});
test('redirects are manual, re-authorized per hop and cannot reach a new origin, private target, path or loop',async()=>{
 const redirect=location=>encode(`HTTP/1.1 302 Found\r\nLocation: ${location}\r\nContent-Length: 0\r\n\r\n`);
 const net=fakeNet([redirect('/docs/two'),http()]),reader=new PublicWebReader({policy:POLICY,net});let guards=0;const receipt=await read(reader,URL1,{beforeSend:async()=>{guards++;}});assert.equal(receipt.final_url,URL2);assert.deepEqual(receipt.redirect_chain,[URL1,URL2]);assert.equal(guards,4);assert.equal(net.calls.filter(c=>c.connect).length,2);
 for(const target of ['https://127.0.0.1/','https://metadata.google.internal/','https://attacker.example.org/docs/a','/private',URL1]){const denied=fakeNet([redirect(target)]);await assert.rejects(read(new PublicWebReader({policy:POLICY,net:denied})));assert.equal(denied.calls.filter(c=>c.connect).length,1);assert.ok(denied.connections.every(c=>c.closed));}
});
test('HTTP framing rejects smuggling, compressed/binary/invalid UTF8, truncation, trailers and text/body overflow',()=>{
 assert.equal(new TextDecoder().decode(parsePublicHTTPResponse(encode('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n')).bytes),'abc');
 assert.equal(new TextDecoder().decode(parsePublicHTTPResponse(encode('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nclose framed')).bytes),'close framed');
 for(const raw of ['HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc','HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\nabc','HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nab','HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nabcd','HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n folded: evil\r\n\r\nabc','HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-Secret: value\r\n\r\n'])assert.throws(()=>parsePublicHTTPResponse(encode(raw)));
 assert.throws(()=>parsePublicHTTPResponse(http(TEXT,'Content-Type: text/plain\r\nContent-Encoding: gzip\r\n')));assert.throws(()=>parsePublicHTTPResponse(http(TEXT,'Content-Type: application/octet-stream\r\n')));assert.throws(()=>parsePublicHTTPResponse(http('x'.repeat(256001))));assert.throws(()=>extractPublicSourceText(new Uint8Array([255]),'text/plain'));assert.throws(()=>extractPublicSourceText(encode('x'.repeat(12001)),'text/plain'));
 assert.equal(extractPublicSourceText(encode('<html><script>unsafe()</script><style>hidden</style><p>Hello &amp; public &#x4e16;&#30028;</p></html>'),'text/html'),'Hello & public 世界');
});
test('HTML extraction scans malformed tags/comments/hidden regions once and handles quoted attributes and Unicode offsets',()=>{
 const text=extractPublicSourceText(encode('<p title="a>b">İ real text &amp; evidence</p><!-- hidden --><ScRiPt data-x=">">secret words</sCrIpT><style>style hidden</style><noscript>scriptless hidden</noscript><template>template hidden</template><p data-x=\'quoted > tag\'>Visible &#x4e16;&#30028; &quot;quote&quot;</p>'),'text/html');assert.equal(text,'İ real text & evidence Visible 世界 "quote"');
 assert.equal(extractPublicSourceText(encode('Visible evidence<script>hidden without closing '+ '<script>'.repeat(1000)),'text/html'),'Visible evidence');
 assert.equal(extractPublicSourceText(encode('Visible evidence<!-- unclosed '+ '<!--'.repeat(1000)),'text/html'),'Visible evidence');
 assert.equal(extractPublicSourceText(encode('Visible evidence<tag attribute="unclosed '+ '<'.repeat(1000)),'text/html'),'Visible evidence');
 assert.throws(()=>extractPublicSourceText(encode('<p>bad &#1; control</p>'),'text/html'),e=>e.code==='source_text_invalid');
 for(const unit of ['<script>','<!--','<'])for(const bytes of [128000,256000]){
  const input=encode(unit.repeat(Math.floor(bytes/unit.length))),start=performance.now();assert.throws(()=>extractPublicSourceText(input,'text/html'),e=>e.code==='source_text_limit');const elapsed=performance.now()-start;
  // A generous offline regression budget. This is not a device or hosted CPU SLO.
  assert.ok(elapsed<1000,`adversarial ${unit} ${bytes} took ${elapsed}ms`);
 }
});
test('pre-dispatch cancellation and delayed TCP/TLS completion after timeout close late sockets with no GET',async()=>{
 const cancelled=fakeNet(),controller=new AbortController();controller.abort();await assert.rejects(read(new PublicWebReader({policy:POLICY,net:cancelled}),URL1,{signal:controller.signal}));assert.equal(cancelled.calls.length,0);
 let releaseTCP;const lateTCP={remoteAddr:{hostname:'93.184.216.34',port:443},closed:false,close(){this.closed=true;}},tcpNet={connect:()=>new Promise(resolve=>{releaseTCP=resolve;}),startTls(){throw Error('TLS must not start');}};
 await assert.rejects(read(new PublicWebReader({policy:POLICY,net:tcpNet,timeoutMs:100})),e=>e.code==='source_read_timeout');releaseTCP(lateTCP);await Promise.resolve();await Promise.resolve();assert.equal(lateTCP.closed,true);
 let releaseTLS;const tcp={...lateTCP,closed:false},lateTLS={...lateTCP,closed:false},tlsNet={connect:async()=>tcp,startTls:()=>new Promise(resolve=>{releaseTLS=resolve;})};
 await assert.rejects(read(new PublicWebReader({policy:POLICY,net:tlsNet,timeoutMs:100})),e=>e.code==='source_read_timeout');releaseTLS(lateTLS);await Promise.resolve();await Promise.resolve();assert.equal(tcp.closed,true);assert.equal(lateTLS.closed,true);
});
test('same scoped Store persists original read receipt and tool checkpoint atomically; cached received read never refetches',async()=>{
 const f=await fixture();let callbacks=0;const commitCallback=async(tx,{task,receipt,toolResult})=>{callbacks++;assert.equal(toolResult.content_hash,receipt.content_hash);await tx.put(f.owner,'tasks',{...task,state:{...task.state,source_checkpoint:{read_id:receipt.id,receipt_hash:receipt.receipt_hash}}});};
 const result=await f.read('source-1',{commitCallback});assert.equal(result.state,'received');assert.equal(callbacks,1);assert.equal(result.receipt.content_hash,sourceBodyHash(encode(TEXT)));assert.equal(result.receipt.text_hash,hash(TEXT));assert.equal(result.receipt.plan_reference.plan_hash,f.planReference.plan_hash);assert.match(result.read_id,/^[a-f0-9-]{36}$/);assert.equal((await f.rows(SOURCE_READS))[0].state,'received');assert.equal((await f.rows(SOURCE_RECEIPTS)).length,1);
 const before=f.net.calls.length;assert.equal((await f.read('source-1',{commitCallback})).state,'received');assert.equal(f.net.calls.length,before);assert.equal(callbacks,2);assert.equal((await f.rows(SOURCE_RECEIPTS)).length,1);assert.equal(await f.repository.transaction(tx=>hasUnresolvedSourceReads(tx,f.owner,f.runID)),false);
 const wire=await f.service.readCatalog('Bearer fixture',f.scope.scope_id,f.runID);assert.equal(wire.reads[0].state,'received');assert.equal(wire.reads[0].source.content_hash,result.receipt.content_hash);assert.ok(!('body_base64' in wire.reads[0].source));
});
test('network-received but receipt callback/deadline/lease/revocation denial preserves dispatched unknown without refetch',async()=>{
 for(const reason of ['callback','deadline','lease','grant']){
  const f=await fixture();let denied=false;const options={assertLive(){if(denied)throw new ApiError(409,'step_deadline');},commitCallback:async(tx,{task})=>{
   if(reason==='callback')throw Error('commit denied');if(reason==='deadline')denied=true;
   if(reason==='lease')await tx.put(f.owner,'tasks',{...task,leaseUntil:new Date(0).toISOString()});if(reason==='grant')f.revoke();
  }};
  assert.equal((await f.read('source-1',options)).state,'unknown',reason);assert.equal((await f.rows(SOURCE_RECEIPTS)).length,0);assert.equal((await f.rows(SOURCE_READS))[0].state,'dispatched');const before=f.net.calls.length;
  if(reason==='grant')await assert.rejects(f.read());else{assert.equal((await f.read()).state,'unknown');assert.equal(f.net.calls.length,before);}assert.equal(await f.repository.transaction(tx=>hasUnresolvedSourceReads(tx,f.owner,f.runID)),true);
 }
});
test('absent policy, pre-dispatch cancellation, expired lease and non-admitted source cannot send or manufacture receipts',async()=>{
 const f=await fixture({policy:null});await assert.rejects(f.read(),e=>e.code==='public_source_policy_not_configured');assert.equal(f.net.calls.length,0);assert.equal((await f.rows(SOURCE_READS)).length,0);
 const cancelled=await fixture();cancelled.controller.abort();await assert.rejects(cancelled.read());assert.equal(cancelled.net.calls.length,0);assert.equal((await cancelled.rows(SOURCE_READS)).length,0);
 const expired=await fixture();await expired.repository.transaction(async tx=>{const task=await tx.get(expired.owner,'tasks',expired.taskID);await tx.put(expired.owner,'tasks',{...task,leaseUntil:new Date(0).toISOString()});});await assert.rejects(expired.read(),e=>e.code==='lease_lost');assert.equal(expired.net.calls.length,0);
 const wrong=await fixture();await assert.rejects(wrong.read('source-2'),e=>e.code==='source_not_admitted');assert.equal(wrong.net.calls.length,0);
});
test('public catalog/citations require every current-plan successful source, real supported quotes and fresh viewer',async()=>{
 const f=await fixture({responses:[http(),http('A second exact sentence for comparison of public evidence.')],urls:[URL1,URL2]});
 const validate=citations=>f.repository.transaction(async tx=>f.service.validateCitationsInTransaction(tx,f.owner,await tx.get(f.owner,'catpaw-runs',f.runID),await tx.get(f.owner,'tasks',f.taskID),citations));
 await f.read();await assert.rejects(validate([{source_id:'source-1',quote:TEXT}]),e=>e.code==='required_source_receipt_missing');await f.read('source-2');
 await assert.rejects(validate([{source_id:'source-1',quote:'Invented unsupported quotation'}]),e=>e.code==='source_quote_not_supported');await assert.rejects(validate([{source_id:'source-1',quote:TEXT}]),e=>e.code==='source_citations_incomplete');
 const cited=await validate([{source_id:'source-1',quote:'This exact supported sentence is useful evidence.'},{source_id:'source-2',quote:'A second exact sentence for comparison of public evidence.'}]);assert.equal(cited.sources.length,2);assert.equal(cited.receipt_references.length,2);assert.equal(cited.sources[0].requested_url,URL1);
 f.facade.beforeSourceRead=null;await assert.rejects(f.service.readCatalog('Bearer fixture',f.scope.scope_id,f.runID),e=>e.code==='source_viewer_authority_not_configured');f.facade.beforeSourceRead=async()=>{throw new ApiError(409,'grant_conflict');};await assert.rejects(f.service.readCatalog('Bearer fixture',f.scope.scope_id,f.runID),e=>e.code==='grant_conflict');
 await f.repository.transaction(async tx=>{const task=await tx.get(f.owner,'tasks',f.taskID);await tx.put(f.owner,'tasks',{...task,state:{...task.state,plan_binding:{revision:2,plan_hash:hash('v2')}}});});await assert.rejects(validate([{source_id:'source-1',quote:TEXT}]),e=>e.code==='source_plan_binding_conflict');
});
test('authority revoked after TLS and TLS certificate failure cannot send GET or fall back to fetch/DNS',async()=>{
 const net=fakeNet();let guards=0;await assert.rejects(read(new PublicWebReader({policy:POLICY,net}),URL1,{beforeSend:async()=>{if(++guards===2)throw new ApiError(409,'grant_conflict');}}),e=>e.code==='grant_conflict');assert.equal(net.calls.filter(c=>c.request).length,0);assert.ok(net.connections.every(c=>c.closed));
 const failed=fakeNet(),upgrade=failed.startTls;failed.startTls=async(...args)=>{const conn=await upgrade(...args);conn.handshake=async()=>{throw Error('offline certificate denial');};return conn;};await assert.rejects(read(new PublicWebReader({policy:POLICY,net:failed})),e=>e.code==='source_transport_failed');assert.equal(failed.calls.filter(c=>c.request).length,0);assert.ok(failed.connections.every(c=>c.closed));
});
test('known HTTP failure persists one failed identity, read-only cause and zero retry receipts',async()=>{
 const f=await fixture({responses:[encode('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')]});assert.equal((await f.read()).state,'failed');const count=f.net.calls.length;assert.equal((await f.read()).state,'failed');assert.equal(f.net.calls.length,count);assert.equal((await f.rows(SOURCE_RECEIPTS)).length,0);assert.equal((await f.rows(SOURCE_READS))[0].error_code,'source_http_status');
 const wire=await f.service.readCatalog('Bearer fixture',f.scope.scope_id,f.runID);assert.equal(wire.reads[0].state,'failed');assert.equal(wire.reads[0].error_code,'source_http_status');assert.equal(await f.repository.transaction(tx=>hasUnresolvedSourceReads(tx,f.owner,f.runID)),false);
});
test('read-only catalog rejects mismatched task authority, applied head and immutable plan content',async()=>{
 for(const corrupt of ['tag','head','version']){
  const f=await fixture();await f.read();await f.repository.transaction(async tx=>{
   if(corrupt==='tag'){const task=await tx.get(f.owner,'tasks',f.taskID);await tx.put(f.owner,'tasks',{...task,state:{...task.state,catpaw:{...task.state.catpaw,operation_id:randomUUID()}}});}
   if(corrupt==='head'){const head=await tx.get(f.owner,'catpaw-task-plan-heads',f.runID);await tx.put(f.owner,'catpaw-task-plan-heads',{...head,applied_plan_hash:hash('mismatch')});}
   if(corrupt==='version'){const version=await tx.get(f.owner,'catpaw-task-plan-versions',`${f.runID}:1`);await tx.put(f.owner,'catpaw-task-plan-versions',{...version,content:{...version.content,goal:'tampered'}});}
  });await assert.rejects(f.service.readCatalog('Bearer fixture',f.scope.scope_id,f.runID),e=>e.code===(corrupt==='tag'?'source_binding_conflict':'source_plan_binding_conflict'));
 }
});
