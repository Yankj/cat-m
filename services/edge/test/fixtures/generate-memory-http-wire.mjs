// Named synthetic fixture from actual HTTP handlers, never hand-authored success.
import {memoryHTTPFixture} from './memory-http-fixture.mjs';
import {hash} from '../../supabase/functions/_shared/core/facade-r2/src/common.mjs';
globalThis.fetch=()=>{throw Error('external_network_forbidden');};
const f=await memoryHTTPFixture(),cid=await f.newConversation();
await f.json((await f.post({type:'set_enabled',enabled:true})).response);
const text='Fictional preference: I prefer tea';
const request=await f.command({type:'remember',conversation_id:cid.toUpperCase(),source_text:text,claim:{kind:'preference',predicate:'drink.preference',value:'tea',conditions:{},assertion:'explicit',evidence:{span_start:0,span_end:text.length}},allow_relearn:false,sensitive_consent:false});
request.operation_id=request.operation_id.toUpperCase();
const receipt=await f.json(await f.req(f.base+'/commands',request)),state=await f.state(),source=await f.json(await f.req(f.base+'/sources/'+state.claims[0].source_id));
const result={schema_version:1,fixture_kind:'actual_maintenance_memory_http_v1',reality:{auth:'synthetic',model:'injected_not_invoked',repository:'serialized_TestRepository',real_auth:false,real_model:false,real_sql:false},request,request_hash:hash(request),receipt,state,source};
const path=Deno.args[0];if(!path)throw Error('explicit_output_path_required');
await Deno.writeTextFile(path,JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({path,request_hash:result.request_hash}));
