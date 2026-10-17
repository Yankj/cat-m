// chat-ux #3 card-type eval (v2, NoBug re-check). Each case goes through the REAL chat service (in-memory Cloud runtime,
// the same createCloudRuntime as production) with every production gate on: task tools, render_ui, agent-memory tools
// and all 12 device tools, client contracts approval + device + ui and the iOS UI kinds header. The provider stub forwards
// the exact system prompt, messages and tool list the server built to the production Agnes route (free-route-chain.mjs;
// key from CATPAW_AGNES_API_KEY, never printed) and records the reply. The model's tool calls are recorded, never executed.
// Score = TYPE: a card case hits only if render_ui is called with the expected kind; a text case hits if render_ui is not called.
// Usage (from services/edge): node --no-warnings --import ./test/support/node-strip-loader.mjs ../../qa/chat-ux-ui-policy/run-eval.mjs --runs 3
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash,randomUUID} from 'node:crypto';
const realFetch=globalThis.fetch;
const E='../../services/edge/';
const {memoryHTTPFixture}=await import(E+'test/fixtures/memory-http-fixture.mjs');
const {APPROVAL_CONTRACT}=await import(E+'supabase/functions/_shared/core/src/approval.mjs');
const {createDeviceTools,DEVICE_CONTRACT}=await import(E+'supabase/functions/_shared/core/src/device-call.mjs');
const {UI_CONTRACT,RENDER_UI,createRenderUITool}=await import(E+'supabase/functions/_shared/core/src/generative-ui.mjs');
const {createTaskChatTools}=await import(E+'supabase/functions/_shared/proactive/chat-tools.mjs');
const {createAgentMemoryChatTools}=await import(E+'supabase/functions/_shared/agent-memory/chat-tools.mjs');
const {FREE_ROUTE_CATALOG}=await import(E+'supabase/functions/_shared/core/src/free-route-chain.mjs');
const here=new URL('.',import.meta.url),set=JSON.parse(readFileSync(new URL('cases.json',here),'utf8'));
const runs=Number(process.argv[process.argv.indexOf('--runs')+1]||1)||1;
const key=process.env.CATPAW_AGNES_API_KEY;if(!key){console.error('NOT RUN: CATPAW_AGNES_API_KEY missing; no offline substitute for model behaviour.');process.exit(2);}
const route=FREE_ROUTE_CATALOG.agnes,model=process.env.CATPAW_AGNES_MODEL||route.model;
const IOS_KINDS='card,choices,confirm,form,sheet,list,progress,place,event,followups';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let current=null,seen=null;
// Multi-step like the real agent loop: a non-render_ui tool call gets a canned result (CANNED; writes answer
// "needs the user's confirmation card" as the approval gate would), up to 4 steps; the first render_ui decides the type.
const CANNED={calendar_list:{status:'ok',data:{events:[]}},list_tasks:{tasks:[{id:'t1',title:'写周报',status:'open'},{id:'t2',title:'交水费',status:'open'},{id:'t3',title:'回复客户邮件',status:'open'}]},
  places_search:{status:'denied',data:{message:'没有定位权限'}},contacts_search:{status:'ok',data:{contacts:[]}},memory_search:{results:[]}};
const cannedFor=name=>CANNED[name]??{status:'pending_user_confirmation',note:'需要用户在卡片上确认后才会执行'};
async function post(body){
  for(let attempt=0;attempt<5;attempt++){
    const r=await realFetch(route.endpoint,{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(60000)}).catch(()=>({status:599,ok:false}));
    if(r.status===429||r.status>=500){await sleep(5000*(attempt+1));continue;}
    if(!r.ok)return {error:'http_'+r.status};
    return {message:(await r.json()).choices?.[0]?.message??{}};
  }
  return {error:'rate_limited'};
}
async function callModel(input){
  const msgs=[...input.messages];if(current.history){const i=msgs.length-1;msgs.splice(i,0,...set.fixtures[current.history]);}
  const convo=[{role:'system',content:input.system_prompt},...msgs];
  seen={system:input.system_prompt,tools:input.tools.map(t=>t.function.name)};
  const called=[],t0=Date.now();
  for(let step=0;step<4;step++){
    const r=await post({model,messages:convo,tools:input.tools,tool_choice:'auto',temperature:0});if(r.error)return {error:r.error,tools_called:called};
    const m=r.message,tcs=m.tool_calls??[];called.push(...tcs.map(t=>t.function?.name));
    const ui=tcs.find(t=>t.function?.name===RENDER_UI);
    if(ui){let kind;try{const a=JSON.parse(ui.function.arguments);kind=(a.block??a).kind??null;}catch{kind='unparsable';}return {got:'card',kind,tools_called:called,steps:step+1,latency_ms:Date.now()-t0};}
    if(!tcs.length)return {got:'text',kind:null,tools_called:called,steps:step+1,latency_ms:Date.now()-t0,text:(m.content??'').slice(0,80)};
    convo.push({role:'assistant',content:m.content??null,tool_calls:tcs});
    for(const t of tcs)convo.push({role:'tool',tool_call_id:t.id,content:JSON.stringify(cannedFor(t.function?.name))});
  }
  return {got:'text',kind:null,tools_called:called,steps:4,note:'step_limit'};
}
// A fresh fixture (new subject) per run: the server's per-subject daily turn limit would otherwise stop run 2.
let f;
async function freshFixture(){
f=await memoryHTTPFixture({stream:async function*(input){current.result=await callModel(input);yield {type:'text_delta',text:'·'};yield {type:'done',finish_reason:'stop'};}});
const open=m=>new Map([...m].map(([n,t])=>[n,{...t,offer:undefined}]));
f.runtime.chat.facade.gatedChatTools=new Map([...open(createTaskChatTools({service:{}})),[RENDER_UI,createRenderUITool()],...open(createAgentMemoryChatTools({service:{}})),...createDeviceTools()]);
}
const H='https://memory-test.example.invalid';
async function ask(c){
  const cid=await f.newConversation(),path=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
  await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
  const conv=(await f.json(await f.req(path))).conversation;current={history:c.history,result:null};
  const r=await f.runtime.api(new Request(H+path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,'X-Catpaw-Device-Contract':DEVICE_CONTRACT,'X-Catpaw-UI-Contract':UI_CONTRACT,'X-Catpaw-UI-Kinds':IOS_KINDS},
    body:JSON.stringify({turn_id:randomUUID(),expected_revision:conv.revision,expected_grant_epoch:conv.grant_epoch,message:{id:randomUUID(),text:c.text},context:[]})}));
  await r.text();await f.runtime.chat.waitIdle();return current.result??{error:'no_model_call_'+r.status};
}
const only=process.argv.includes('--only')?process.argv[process.argv.indexOf('--only')+1].split(','):null;
const rows=[];
for(let run=1;run<=runs;run++){await freshFixture();for(const c of set.cases.filter(c=>!only||only.includes(c.id))){
  const r=await ask(c),hit=!r.error&&(c.expect==='card'?r.got==='card'&&r.kind===c.kind:r.got==='text');
  rows.push({run,id:c.id,expect:c.expect,expect_kind:c.kind??null,...r,card_vs_text_hit:r.got===c.expect,hit});
  process.stdout.write(`${run}:${c.id}:${r.kind??r.got??r.error}${hit?'':' ✗ '+JSON.stringify([r.tools_called,r.text])} `);await sleep(3000);}}
const scored=rows.filter(r=>!r.error),hits=scored.filter(r=>r.hit).length,rate=scored.length?hits/scored.length:0,cvt=scored.filter(r=>r.card_vs_text_hit).length;
const perRun=[...Array(runs)].map((_,i)=>{const s=scored.filter(r=>r.run===i+1);return {run:i+1,hits:s.filter(r=>r.hit).length,scored:s.length};});
const out={ran_at:new Date().toISOString(),route:'agnes',model,runs,cases:set.cases.length,scored:scored.length,errors:rows.length-scored.length,
  type_hits:hits,type_hit_rate:Number(rate.toFixed(4)),card_vs_text_hits:cvt,card_vs_text_rate:Number((cvt/scored.length).toFixed(4)),per_run:perRun,threshold:0.85,pass:rate>=0.85&&scored.length===rows.length,
  tools_offered:seen?.tools??[],prompt_sha256:createHash('sha256').update(seen?.system??'').digest('hex'),cases_sha256:createHash('sha256').update(readFileSync(new URL('cases.json',here))).digest('hex'),rows};
if(only){console.log('\n'+hits+'/'+scored.length);process.exit(0);}
writeFileSync(new URL('RESULTS.json',here),JSON.stringify(out,null,1)+'\n');
const miss=rows.filter(r=>!r.hit).map(r=>`| ${r.run} | ${r.id} | ${r.expect_kind??r.expect} | ${r.error??(r.kind??r.got)} | ${(r.tools_called??[]).join(', ')} |`).join('\n')||'| – | – | – | – | – |';
writeFileSync(new URL('REPORT.md',here),`# chat-ux #3 card-type eval (v2)\n\n- Ran: ${out.ran_at} (UTC) · route agnes · model \`${model}\` · temperature 0 · ${runs} runs × ${set.cases.length} cases\n- **Type hit rate: ${hits}/${scored.length} = ${(rate*100).toFixed(1)}%** (threshold 85%) · per run ${perRun.map(p=>p.hits+'/'+p.scored).join(', ')} · errors ${out.errors} · ${out.pass?'PASS':'FAIL'}\n- Card-vs-text only (old metric): ${cvt}/${scored.length}\n- Scoring: card case = render_ui with the expected kind; text case = no render_ui.\n- Path: real chat service (createCloudRuntime, in-memory repo) with production gates on; system prompt sha256 \`${out.prompt_sha256.slice(0,16)}…\` is what the server built; tools offered (${out.tools_offered.length}): ${out.tools_offered.join(', ')}.\n- Limits: one provider route (Agnes; production chain also has OpenRouter/Gemini); memory tools offered without a memory snapshot prompt; tool calls recorded, not executed; history cases inject fixture tool results; other tool calls get canned results (CANNED in run-eval.mjs) and the loop continues up to 4 steps.\n\n## Misses\n\n| run | case | expected | got | tools called |\n|---|---|---|---|---|\n${miss}\n`);
console.log(`\ntype ${hits}/${scored.length} = ${(rate*100).toFixed(1)}% · card-vs-text ${cvt}/${scored.length} · errors=${out.errors} · tools=${out.tools_offered.length}`);
process.exit(0);
