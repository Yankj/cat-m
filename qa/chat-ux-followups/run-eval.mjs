// chat-ux #4 follow-up eval. Same path as qa/chat-ux-ui-policy/run-eval.mjs: real chat service with production gates on and
// the iOS kinds header (incl. followups), forwarded to the production Agnes route (key from CATPAW_AGNES_API_KEY, never printed).
// Usage (from services/edge): node --no-warnings --import ./test/support/node-strip-loader.mjs ../../qa/chat-ux-followups/run-eval.mjs --runs 3
import {readFileSync,writeFileSync} from 'node:fs';
import {randomUUID,createHash} from 'node:crypto';
const realFetch=globalThis.fetch,E='../../services/edge/';
const {memoryHTTPFixture}=await import(E+'test/fixtures/memory-http-fixture.mjs');
const {APPROVAL_CONTRACT}=await import(E+'supabase/functions/_shared/core/src/approval.mjs');
const {createDeviceTools,DEVICE_CONTRACT}=await import(E+'supabase/functions/_shared/core/src/device-call.mjs');
const {UI_CONTRACT,RENDER_UI,createRenderUITool}=await import(E+'supabase/functions/_shared/core/src/generative-ui.mjs');
const {createTaskChatTools}=await import(E+'supabase/functions/_shared/proactive/chat-tools.mjs');
const {FREE_ROUTE_CATALOG}=await import(E+'supabase/functions/_shared/core/src/free-route-chain.mjs');
const here=new URL('.',import.meta.url),set=JSON.parse(readFileSync(new URL('cases.json',here),'utf8'));
const runs=Number(process.argv[process.argv.indexOf('--runs')+1]||1)||1;
const key=process.env.CATPAW_AGNES_API_KEY;if(!key){console.error('NOT RUN: CATPAW_AGNES_API_KEY missing.');process.exit(2);}
const route=FREE_ROUTE_CATALOG.agnes,model=process.env.CATPAW_AGNES_MODEL||route.model,sleep=ms=>new Promise(r=>setTimeout(r,ms));
// Port of FollowUpSuggestions.parse (iOS) + the prompt's 18-char rule.
export function parseFollowUps(text){
  const m=/```catpaw-card:followups\n([\s\S]*?)```\s*$/.exec(text??'');if(!m)return {items:[],fence:false};
  const out=[];for(let line of m[1].split('\n')){line=line.trim().replace(/^([-*•]|\d+[.、)])\s*/,'').replace(/^[ "“”「」]+|[ "“”「」]+$/g,'');
    if(!line||[...line].length>30||line.includes('```')||out.includes(line))continue;out.push(line);if(out.length===3)break;}
  return {items:out.length>=2?out:[],fence:true};
}
let current=null;
// A fresh fixture (new subject) per run: the server's per-subject daily turn limit would otherwise stop run 2.
let f;
async function freshFixture(){
f=await memoryHTTPFixture({stream:async function*(input){
  const body={model,messages:[{role:'system',content:input.system_prompt},...input.messages],tools:input.tools,tool_choice:'auto',temperature:0};
  for(let a=0;a<5;a++){const r=await realFetch(route.endpoint,{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(60000)}).catch(()=>({status:599,ok:false}));
    if(r.status===429||r.status>=500){await sleep(5000*(a+1));continue;}
    if(!r.ok){current={error:'http_'+r.status};break;}const m=(await r.json()).choices?.[0]?.message??{};current={text:m.content??'',tools_called:(m.tool_calls??[]).map(t=>t.function?.name),prompt:input.system_prompt};break;}
  yield {type:'text_delta',text:'·'};yield {type:'done',finish_reason:'stop'};}});
f.runtime.chat.facade.gatedChatTools=new Map([...createTaskChatTools({service:{}}),[RENDER_UI,createRenderUITool()],...createDeviceTools()]);
}
const H='https://memory-test.example.invalid';
async function ask(c){
  const cid=await f.newConversation(),path=`/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
  await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`,{decision:'allow',expected_revision:0,route_hash:f.config.routeHash}));
  const conv=(await f.json(await f.req(path))).conversation;current=null;
  const r=await f.runtime.api(new Request(H+path+'/turns',{method:'POST',headers:{Authorization:'Bearer memory-fixture','Content-Type':'application/json','X-Catpaw-Approval-Contract':APPROVAL_CONTRACT,'X-Catpaw-Device-Contract':DEVICE_CONTRACT,'X-Catpaw-UI-Contract':UI_CONTRACT,'X-Catpaw-UI-Kinds':'card,choices,confirm,form,sheet,list,progress,place,event,followups'},
    body:JSON.stringify({turn_id:randomUUID(),expected_revision:conv.revision,expected_grant_epoch:conv.grant_epoch,message:{id:randomUUID(),text:c.text},context:[]})}));
  await r.text();await f.runtime.chat.waitIdle();return current??{error:'no_model_call'};
}
const rows=[];let prompt='';
for(let run=1;run<=runs;run++){await freshFixture();for(const c of set.cases){
  const r=await ask(c);if(r.prompt)prompt=r.prompt;const p=parseFollowUps(r.text);
  const short=p.items.every(q=>[...q].length<=18),distinct=!p.items.includes(c.text);
  const pass=!r.error&&p.items.length>=2&&short&&distinct;
  rows.push({run,id:c.id,error:r.error,fence:p.fence,items:p.items,all_le_18:short,pass,tools_called:r.tools_called});
  process.stdout.write(`${run}:${c.id}:${pass?'ok':'✗'+JSON.stringify(p.items)} `);await sleep(3000);}}
const scored=rows.filter(r=>!r.error),pass=scored.filter(r=>r.pass).length,rate=pass/scored.length;
const per=[...Array(runs)].map((_,i)=>scored.filter(r=>r.run===i+1&&r.pass).length+'/'+scored.filter(r=>r.run===i+1).length);
const out={ran_at:new Date().toISOString(),model,runs,cases:set.cases.length,scored:scored.length,errors:rows.length-scored.length,pass,pass_rate:Number(rate.toFixed(4)),per_run:per,
  fence_rate:Number((scored.filter(r=>r.fence).length/scored.length).toFixed(4)),prompt_sha256:createHash('sha256').update(prompt).digest('hex'),rows};
writeFileSync(new URL('RESULTS.json',here),JSON.stringify(out,null,1)+'\n');
writeFileSync(new URL('REPORT.md',here),`# chat-ux #4 follow-up suggestions eval\n\n- Ran: ${out.ran_at} (UTC) · agnes \`${model}\` · temperature 0 · ${runs} runs × ${set.cases.length} cases\n- **Pass: ${pass}/${scored.length} = ${(rate*100).toFixed(1)}%** · per run ${per.join(', ')} · fence present ${(out.fence_rate*100).toFixed(0)}% · errors ${out.errors}\n- Pass = iOS parser yields 2–3 items, each ≤ 18 chars, none repeating the question. Quality (are they good questions) is not scored.\n- Path: real chat service with production gates and the iOS kinds header (incl. followups); one provider route.\n\n## Failures\n\n| run | case | items |\n|---|---|---|\n${rows.filter(r=>!r.pass).map(r=>`| ${r.run} | ${r.id} | ${r.error??JSON.stringify(r.items)} |`).join('\n')||'| – | – | – |'}\n`);
console.log(`\nfollowups ${pass}/${scored.length} = ${(rate*100).toFixed(1)}% per run ${per.join(', ')}`);process.exit(0);
