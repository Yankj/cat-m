import test from 'node:test';
import assert from 'node:assert/strict';
import {ModelRegistry, freezeRequest, hash, CredentialProvider} from '../src/models.mjs';
import {ModelGateway, HTTPSTransport} from '../src/transport.mjs';
const r = new ModelRegistry();
const request = (input = {messages:[{role:'user', content:'synthetic'}]}) => freezeRequest(r.select('dots-free'), input);
const frame = c => `data: ${JSON.stringify(c)}\r\n\r\n`;
const chunk = (delta, finish_reason = null) => ({id:'synthetic-generation',choices:[{index:0,delta,finish_reason}]});
function transport(text, status = 200, headers = {}, width = 1) {
  return {async open(_r, _c, signal) {return {status,headers,body:(async function*(){
    const bytes = Buffer.from(text); for(let i=0;i<bytes.length;i+=width) {if(signal.aborted) throw new Error('aborted'); yield bytes.subarray(i,i+width);}
  })()};}};
}
const collect = async (t, req = request(), options = {}) => {
  const events = []; for await(const e of new ModelGateway({transport:t,credentials:new CredentialProvider()}).stream(req, {operationID:'synthetic-operation',...options})) events.push(e);
  return events;
};
test('UTF8 and CRLF split at every byte preserve deltas and require explicit terminal', async () => {
  const events = await collect(transport(': heartbeat\r\n\r\n'+frame(chunk({content:'猫'}))+frame(chunk({content:'爪'}))+frame(chunk({},'stop'))+'data: [DONE]\r\n\r\n'));
  assert.deepEqual(events.map(e=>e.type),['accepted','text_delta','text_delta','message_completed','task_completed']);
  assert.equal(events[3].final_text_hash, hash('猫爪'));
  assert.deepEqual(events.map(e=>e.sequence),[1,2,3,4,5]);
  assert.ok(events.every(e=>e.reality==='simulated'));
  for(const tail of ['',frame(chunk({},'stop')), 'data: [DONE]\r\n\r\n']) {
    const failed = await collect(transport(frame(chunk({content:'partial'}))+tail));
    assert.equal(failed.at(-1).code,'missing_terminal');
    assert.equal(failed.filter(e=>e.type==='task_completed').length,0);
  }
});
test('indexed tool argument fragments are assembled without granting execution', async () => {
  const input = {messages:[{role:'user',content:'synthetic'}],tools:[{type:'function',function:{name:'lookup',parameters:{type:'object'}}}]};
  const events = await collect(transport(frame(chunk({tool_calls:[{index:0,id:'call-1',function:{name:'look',arguments:'{"q":'}}]}))+
    frame(chunk({tool_calls:[{index:0,function:{name:'up',arguments:'"猫"}'}}]}))+frame(chunk({},'tool_calls'))+'data: [DONE]\n\n'),request(input));
  assert.equal(events.find(e=>e.type==='tool_call_complete').arguments,'{"q":"猫"}');
  assert.equal(events.at(-1).code,'tool_requires_policy');
  assert.equal(events.filter(e=>e.type==='task_completed').length,0);
});
test('quota denial, 429 and errors in a 200 stream never complete a task', async () => {
  const quota = await collect(transport('{"code":"AllocationQuota.FreeTierOnly"}',403));
  assert.equal(quota.at(-1).code,'quota_denied'); assert.equal(quota.at(-1).retryable,false);
  const limit = await collect(transport('{"error":{"code":429}}',429,{'retry-after':'7'}));
  assert.equal(limit.at(-1).retry_after_seconds,7);
  const mid = await collect(transport(frame(chunk({content:'partial'}))+frame({error:{code:402,message:'synthetic'}})));
  assert.equal(mid.at(-1).code,'quota_denied'); assert.equal(mid.filter(e=>e.type==='task_completed').length,0);
});
test('timeout and cancellation have explicit terminal events even if injected transport hangs', async () => {
  const hanging = {async open(){return await new Promise(()=>{});}};
  const timed = await collect(hanging, request(), {timeoutMs:10});
  assert.equal(timed.at(-1).code,'timeout');
  const controller = new AbortController(); controller.abort();
  const cancelled = await collect(hanging,request(),{signal:controller.signal});
  assert.equal(cancelled.at(-1).type,'cancelled');
});
test('malformed arguments, length finish and unterminated frames retain partial text and fail', async () => {
  for(const [body,code] of [
    [frame(chunk({content:'partial'}))+frame(chunk({},'length'))+'data: [DONE]\n\n','output_truncated'],
    [frame(chunk({content:'partial'}))+'data: {oops}\n\n','malformed_sse_json'],
    [frame(chunk({content:'partial'}))+'data: [DONE]','incomplete_sse']
  ]) {const events=await collect(transport(body)); assert.equal(events.at(-1).code,code); assert.equal(events[1].text,'partial');}
});
test('the real transport refuses mock requests; the gateway refuses real calls by default', async () => {
  await assert.rejects(new HTTPSTransport().open(request(), {secret:'MOCK_ONLY'},new AbortController().signal), {code:'transport_not_authorized'});
  const req = {...request(),real:true};
  const events = await collect({open(){throw new Error('must not be reached');}},req);
  assert.equal(events.at(-1).code,'real_calls_disabled');
});

test('real admission rechecks protection immediately before credentials and binds the credential account', async () => {
  const model=r.select('qwen-beijing'), now=Date.parse('2026-10-11T00:00:00Z');
  const evidence={provider:model.provider,model:model.model,region:model.region,account_reference:'synthetic-account',
    eligibility:'verified',verified_at:'2026-10-10T00:00:00Z',valid_until:'2026-10-11T00:01:00Z',quota_expires_at:'2026-11-01T00:00:00Z',
    key_kind:'general_api_key',stop_when_free_exhausted:'effective',platform_evidence_reference:'synthetic-check'};
  const req=freezeRequest(model,{messages:[{role:'user',content:'synthetic'}]},{real:true,evidence,now});
  const gateway=new ModelGateway({realEnabled:true,clock:()=>now+61000,
    credentials:{credentialFor(){throw new Error('must not request credentials after expiry');}},
    transport:{open(){throw new Error('must not dispatch');}}});
  const expired=[];for await(const e of gateway.stream(req))expired.push(e);
  assert.equal(expired.at(-1).code,'free_protection_unverified');
  const mismatch=new ModelGateway({realEnabled:true,clock:()=>now,
    credentials:{async credentialFor(){return {secret:'SYNTHETIC_ONLY',accountReference:'other-account'};}},
    transport:{open(){throw new Error('must not dispatch with mismatched account');}}});
  const events=[];for await(const e of mismatch.stream(req))events.push(e);
  assert.equal(events.at(-1).code,'credential_account_mismatch');
});

test('cancelling a partially streamed response keeps the partial text and never resends', async () => {
  let invocations=0; const controller=new AbortController();
  const t={async open(){invocations++;return {status:200,headers:{},body:(async function*(){
    yield Buffer.from(frame(chunk({content:'partial'})));await new Promise(()=>{});
  })()};}};
  const events=[];
  const gateway=new ModelGateway({transport:t,credentials:new CredentialProvider()});
  for await(const e of gateway.stream(request(),{signal:controller.signal})) {
    events.push(e);if(e.type==='text_delta')controller.abort();
  }
  assert.equal(events.at(-1).type,'cancelled');assert.equal(events[1].text,'partial');assert.equal(invocations,1);
});
