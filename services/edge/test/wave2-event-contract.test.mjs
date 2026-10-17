// B5: Wave 2 event contract (docs/wave2-event-contract.md). Self-contained validators so the iOS side can mirror them;
// B1 (#41) and B3 (#49) emit these shapes (their own tests assert the emission order).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DEVICE_TOOLS={calendar_list:'none',contacts_search:'card',calendar_create:'card',reminder_create:'card',mail_compose:'card',sms_compose:'card',phone_call:'card',maps_open:'card',shop_open:'card',alarm_set:'card',shortcut_run:'card',places_search:'none'};
const obj=v=>v&&typeof v==='object'&&!Array.isArray(v);
export function validateWave2Event(e){
 const fail=m=>{throw new Error(m);};
 if(!obj(e)||!UUID.test(e.conversation_id??'')||!UUID.test(e.turn_id??'')||!obj(e.data))fail('envelope');
 const d=e.data;
 if(e.type==='memory_saved'){
  const m=d.memory;if(!obj(m)||!UUID.test(m.id??'')||!['profile','preference','person','fact'].includes(m.kind)||typeof m.content!=='string'||!m.content.trim()||m.content.length>500)fail('memory');
  if(typeof d.undo_token!=='string'||!/^[A-Za-z0-9_-]{16,100}$/.test(d.undo_token))fail('undo_token');return 'memory_saved';
 }
 if(e.type==='memory_recalled'){
  if(!Array.isArray(d.ids)||d.ids.length<1||d.ids.length>26||!d.ids.every(i=>UUID.test(i))||new Set(d.ids).size!==d.ids.length)fail('ids');return 'memory_recalled';
 }
 if(e.type==='device_call'){
  if(typeof d.call_id!=='string'||!d.call_id||d.call_id.length>160)fail('call_id');
  if(!Object.hasOwn(DEVICE_TOOLS,d.tool))fail('tool');if(!obj(d.args))fail('args');
  if(d.confirm!==DEVICE_TOOLS[d.tool])fail('confirm');if(!Number.isInteger(d.ttl_sec)||d.ttl_sec<1||d.ttl_sec>3600)fail('ttl_sec');
  if(!UUID.test(d.interrupt_id??'')||!/^[a-f0-9]{64}$/.test(d.args_hash??'')||!Number.isFinite(Date.parse(d.expires_at)))fail('binding');return 'device_call';
 }
 fail('type');
}
const rows=readFileSync(new URL('./fixtures/wave2-events.jsonl',import.meta.url),'utf8').trim().split('\n').map(l=>JSON.parse(l));
test('fixture covers all three events, valid and invalid',()=>{
 assert.deepEqual(new Set(rows.filter(r=>r.valid).map(r=>r.event.type)),new Set(['memory_saved','memory_recalled','device_call']));
 assert.ok(rows.filter(r=>!r.valid).length>=6);
});
for(const r of rows)test(`${r.valid?'accepts':'rejects'} ${r.why??r.event.type+' '+(r.event.data.tool??'')}`,()=>{
 if(r.valid)assert.equal(validateWave2Event(r.event),r.event.type);else assert.throws(()=>validateWave2Event(r.event));
});
test('plan §6 flat shape maps to envelope.data (memory_saved / device_call field names unchanged)',()=>{
 const saved=rows.find(r=>r.valid&&r.event.type==='memory_saved').event.data;assert.deepEqual(Object.keys(saved.memory),['id','kind','content']);assert.ok('undo_token' in saved);
 const call=rows.find(r=>r.valid&&r.event.type==='device_call').event.data;for(const k of ['call_id','tool','args','confirm','ttl_sec'])assert.ok(k in call);
});
