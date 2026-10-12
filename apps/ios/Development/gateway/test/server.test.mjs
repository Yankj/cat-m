import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createLocalServer} from '../src/server.mjs';
import {hash} from '../src/models.mjs';
const request=(port,path,method='GET',body,headers={})=>new Promise((resolve,reject)=>{
  const req=http.request({hostname:'127.0.0.1',port,path,method,headers:{'x-catpaw-demo':'synthetic-only','content-type':'application/json',...headers}},res=>{
    let text='';res.setEncoding('utf8');res.on('data',x=>text+=x);res.on('end',()=>resolve({status:res.statusCode,text,json:res.headers['content-type'].startsWith('application/json')?JSON.parse(text):null}));
  });req.on('error',reject);req.end(body?JSON.stringify(body):undefined);
});
test('HTTP local protocol closes delegation -> worker -> versioned artifact -> projection and denies dispatch', async () => {
  const app=createLocalServer({statePath:join(mkdtempSync(join(tmpdir(),'catpaw-http-')),'state.json')});
  await new Promise(r=>app.server.listen(0,'127.0.0.1',r));const port=app.server.address().port;
  try {
    const cap=await request(port,'/v1/capabilities'); assert.equal(cap.json.real_model_calls,'disabled');
    const created=await request(port,'/v1/delegations','POST',{title:'Synthetic',goal:'Synthetic draft',stop_conditions:['user stops'],model_id:'qwen-beijing'},{'idempotency-key':'d'});
    assert.equal(created.status,201);
    const d=created.json;
    const run=await request(port,`/v1/delegations/${d.id}/runs`,'POST',{}, {'idempotency-key':'run'}); assert.equal(run.status,201);
    const tick=await request(port,'/v1/local-worker/tick','POST',{});assert.equal(tick.json.status,'published');assert.equal(tick.json.reality,'simulated');
    const sync=await request(port,'/v1/sync');assert.equal(sync.json.delegations[0].state,'active');assert.equal(sync.json.runs[0].state,'succeeded');
    const a=sync.json.artifacts[0];assert.equal(a.current_reference.content_hash,hash(a.versions[0].body));
    const v=await request(port,`/v1/artifacts/${a.id}/versions/1`);assert.equal(v.json.content_hash,a.current_reference.content_hash);
    const send=await request(port,'/v1/actions/dispatch','POST',{});assert.equal(send.status,404);
    const blocked=await request(port,'/v1/sync','GET',undefined,{'origin':'https://example.com'});assert.equal(blocked.status,403);
  } finally {await new Promise(r=>app.server.close(r));}
});
test('chat HTTP replay returns the same frozen events and never silently resumes an unknown admission', async () => {
  const app=createLocalServer({statePath:join(mkdtempSync(join(tmpdir(),'catpaw-chat-')),'state.json')});
  await new Promise(r=>app.server.listen(0,'127.0.0.1',r));const port=app.server.address().port;
  try {
    const body={operation_id:'11111111-2222-4222-8222-111111111111',runtime_epoch:1,model_id:'dots-free',text:'synthetic',frozen_text_hash:hash('synthetic')};
    const a=await request(port,'/v1/chat','POST',body);
    const b=await request(port,'/v1/chat','POST',body);
    assert.equal(a.status,200);assert.equal(b.text,a.text);
    const reordered=await request(port,'/v1/chat','POST',Object.fromEntries(Object.entries(body).reverse()));
    assert.equal(reordered.text,a.text);
    assert.ok(a.text.includes('message_completed'));assert.ok(a.text.includes('task_completed'));
    const changed=await request(port,'/v1/chat','POST',{...body,text:'edit',frozen_text_hash:hash('edit')});assert.equal(changed.status,409);
    const observed=await request(port,`/v1/chat/${body.operation_id}/observe?epoch=1`);assert.equal(observed.json.status,'finished');
  } finally {await new Promise(r=>app.server.close(r));}
});
