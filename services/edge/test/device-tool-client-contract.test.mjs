// NoBug P0-4: server ↔ iOS client device-tool contract. Reads the Swift source of truth (DeviceToolContract.swift).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {DEVICE_TOOLS,DEVICE_TOOL_NAMES,DEVICE_RESULT_STATUSES,createDeviceTools,parseDeviceTools,deviceResult} from '../supabase/functions/_shared/core/src/device-call.mjs';
const root=new URL('../../../apps/ios-conversation/Sources/',import.meta.url);
const contract=readFileSync(new URL('Features/DeviceCalls/DeviceToolContract.swift',root),'utf8');
const swiftList=name=>JSON.parse(contract.match(new RegExp(`static let ${name}: \\[String\\] = (\\[[^\\]]*\\])`))[1]);
const clientTools=swiftList('clientTools');
test('client advertises exactly the server device tools',()=>{assert.deepEqual([...clientTools].sort(),[...DEVICE_TOOL_NAMES].sort());});
test('every server enum value is handled by the client',()=>{
  for(const tool of DEVICE_TOOLS){for(const [k,p] of Object.entries(tool.definition.function.parameters.properties)){if(!p.enum)continue;
    for(const v of p.enum){
      if(k==='platform')assert.match(contract,new RegExp(`case [^\\n]*"${v}"`),`shop_open platform ${v} has its own client case`);
      else if(k==='mode'){const router=readFileSync(new URL('Features/DeviceCalls/DeviceToolRouter.swift',root),'utf8');assert.ok(router.includes(`"${v}":`),`maps_open mode ${v} mapped`);}
      else assert.fail(`unhandled enum ${tool.definition.function.name}.${k}`);}}}
  assert.match(contract,/imeituan:\/\//);});
test('client status enum matches server',()=>{const sw=readFileSync(new URL('Features/DeviceCalls/DeviceCall.swift',root),'utf8');const m=sw.match(/enum DeviceCallStatus[^{]*\{ case ([^}]*) \}/)[1].split(',').map(s=>s.trim());assert.deepEqual(m.sort(),[...DEVICE_RESULT_STATUSES].sort());});
test('server offers only tools the client advertised',()=>{
  const tools=createDeviceTools(),base={device_contract:'catpaw.device.v1',approval_contract:'catpaw.approval.v1'};
  const listed=parseDeviceTools('calendar_create, sms_compose,bogus');assert.deepEqual(listed,['calendar_create','sms_compose']);
  assert.equal(tools.get('calendar_create').offer({...base,device_tools:listed}),true);
  assert.equal(tools.get('calendar_list').offer({...base,device_tools:listed}),false);
  assert.equal(tools.get('calendar_list').offer(base),true,'legacy client without header keeps old behaviour');
  assert.equal(parseDeviceTools(null),null);});
test('pending_timeout tells the model status is unknown, verify before retry',()=>{const r=deviceResult({status:'expired'});assert.equal(r.status,'pending_timeout');assert.match(r.message,/status is unknown/);assert.match(r.message,/verify/);assert.doesNotMatch(r.message,/nothing is known/);});
