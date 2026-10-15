// Loopback replay of the actual maintenance handler's injected-provider fixture.
// No Auth, model, source transport or production endpoint is contacted here.
import http from 'node:http';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const fixture=JSON.parse(readFileSync(process.env.CATPAW_REVISION_WIRE_FIXTURE,'utf8'));
const scope=fixture.scope.scope_id,cid=fixture.conversation_id,tid=fixture.request.turn.turn_id;
const run=fixture.projection.run.id,op=fixture.operation.revision.operation_id;
const workPath=`/catpaw/revision-work/v1/scopes/${scope}/conversations/${cid}/turns`;
const chatPath=`/catpaw/chat/v1/scopes/${scope}/conversations/${cid}`;
let mode='valid',posted=false,turnPosts=0,turnReads=0,operationReads=0;
const corrupt=value=>{const v=structuredClone(value);if(mode!=='badouter')return v;
 const change=r=>{if(r?.contract==='catpaw.task-revision-work.v1'&&r.grant_reference)r.grant_receipt_hash='0'.repeat(64);};
 change(v);for(const r of v.turn?.revision_work_receipts??[])change(r);
 for(const e of v.turn?.events??[])if(e.type==='tool_result')change(e.data?.result);else if(e.type==='turn_completed')for(const r of e.data?.revision_work_receipts??[])change(r);
 return v;
};
const server=http.createServer(async(req,res)=>{
 const send=(value,status=200)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
 try{
  assert.equal(req.headers.authorization,'Bearer explicit-wire-test-only');
  const path=new URL(req.url,'http://127.0.0.1').pathname;
  if(path==='/wire-test-mode'&&req.method==='POST'){let raw='';for await(const c of req)raw+=c;const next=JSON.parse(raw).mode;assert.ok(['valid','drop','badouter'].includes(next));mode=next;posted=false;return send({mode});}
  if(path==='/wire-test-stats')return send({turnPosts,turnReads,operationReads});
  assert.ok(['GET','POST'].includes(req.method));
  if(path==='/readyz')return send(fixture.readiness);
  if(path==='/catpaw/privacy/v1/model-route')return send(fixture.route);
  if(path===chatPath&&req.method==='GET')return send(posted?fixture.conversation_after:fixture.conversation_before);
  if(path===chatPath+'/turns/'+fixture.original_turn.turn.id&&req.method==='GET')return send(fixture.original_turn);
  if(path===workPath+'/'+tid&&req.method==='GET'){turnReads++;return send(corrupt(fixture.turn));}
  if(path===`/catpaw/revision-work/v1/scopes/${scope}/runs/${run}/operations/${op}`&&req.method==='GET'){operationReads++;return send(corrupt(fixture.operation));}
  if(path===`/catpaw/v1/scopes/${scope}/runs/${run}`&&req.method==='GET')return send(posted?fixture.projection:fixture.projection_before);
  const base=fixture.base_artifact.artifact;
  if(path===`/catpaw/artifacts/v1/scopes/${scope}/runs/${run}/artifacts/${base.artifact_id}/versions/${base.version}`&&req.method==='GET')return send(fixture.base_artifact);
  for(const entry of fixture.artifacts??[]){const a=entry.artifact;if(path===`/catpaw/v1/scopes/${scope}/artifacts/${a.artifact_id}/versions/${a.version}`&&req.method==='GET')return send(entry);}
  if(path===workPath&&req.method==='POST'){
   let raw='';for await(const c of req){raw+=c;assert.ok(Buffer.byteLength(raw)<=48000);}
   assert.deepEqual(JSON.parse(raw),fixture.request);turnPosts++;posted=true;
   res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});
   const packets=fixture.raw_sse.split('\n\n').filter(Boolean);
   for(const packet of mode==='drop'?packets.slice(0,1):packets){assert.ok(packet.startsWith('data: '));const value=JSON.parse(packet.slice(6));const wrapper=corrupt({turn:{events:[value]}});res.write('data: '+JSON.stringify(wrapper.turn.events[0])+'\n\n');}
   return res.end();
  }
  throw Error('unexpected_fixture_route');
 }catch(error){process.stderr.write(JSON.stringify({event:'revision_wire_rejected',path:req.url,code:error.code??error.message})+'\n');return send({schema_version:1,error:{code:'revision_wire_fixture_rejected',retryable:false,reconciliation_required:false}},422);}
});
server.listen(0,'127.0.0.1',()=>process.stdout.write('ORIGIN=http://127.0.0.1:'+server.address().port+'\n'));
process.on('SIGTERM',()=>server.close());
