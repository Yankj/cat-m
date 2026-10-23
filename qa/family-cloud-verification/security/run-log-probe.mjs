import assert from 'node:assert/strict';
import {assertPinnedSources} from './source-pin.mjs';
import {createProactiveService} from '../../../services/edge/supabase/functions/_shared/proactive/service.mjs';
import {backgroundFailure,providerFailure} from '../../../services/edge/supabase/functions/_shared/core/integration/edge-adapter/vendor/openmuse/runtime/log.mjs';
import {createChatMetrics} from '../../../services/edge/supabase/functions/_shared/core/src/chat-metrics.mjs';
const sourcePin=assertPinnedSources(['services/edge/supabase/functions/_shared/proactive/service.mjs','services/edge/supabase/functions/_shared/core/integration/edge-adapter/vendor/openmuse/runtime/log.mjs','services/edge/supabase/functions/_shared/core/src/chat-metrics.mjs']);
let networkAttempts=0;globalThis.fetch=async()=>{networkAttempts++;throw Error('offline probe network prohibited');};
const canary='SYNTHETIC_PRIVATE_CANARY_NO_REAL_DATA',captured=[];
const service=createProactiveService({store:{listTasks:async()=>{throw Error(canary);}},verifyUser:async()=>({sub:'00000000-0000-4000-8000-000000000001'}),log:(...args)=>captured.push(args)});
const response=await service.handle(new Request('https://offline.invalid/catpaw-proactive/tasks'));
const responseBody=await response.json(),safe=[],original=console.error;
console.error=(...args)=>safe.push(args);
try{backgroundFailure('synthetic-audit',Error(canary));providerFailure('synthetic-audit',Error(canary));}finally{console.error=original;}
const metrics=[];createChatMetrics({sink:e=>metrics.push(e),now:()=>2}).record('request_auth',0,{count:1,bytes:4,message:canary});
const actual={status:response.status,response_body:responseBody,proactive_logger_contains_canary:JSON.stringify(captured).includes(canary),sanitized_vendor_logger_contains_canary:JSON.stringify(safe).includes(canary),chat_metrics_contains_canary:JSON.stringify(metrics).includes(canary)};
assert.deepEqual(actual,{status:500,response_body:{error:'internal_error'},proactive_logger_contains_canary:true,sanitized_vendor_logger_contains_canary:false,chat_metrics_contains_canary:false});assert.equal(networkAttempts,0);
console.log(JSON.stringify({id:'LP-01',...sourcePin,layer:'offline-injected-error-only',classification:'GAP_REPRODUCED',acceptance_status:'FAIL',scope:'Captured logger arguments contain a synthetic marker; no real logs, OS logs, database, Auth, model or APNs verified.',network_attempts:networkAttempts,actual},null,2));
