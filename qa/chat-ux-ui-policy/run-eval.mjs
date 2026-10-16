// chat-ux #3 card-vs-text eval. Live: one real model call per case through the production Agnes route definition
// (free-route-chain.mjs; key from CATPAW_AGNES_API_KEY, never printed). Prompt = the server's uiPrompt (+ UI_POLICY)
// + GROUNDED_PROMPT, tools = [render_ui]. Hit = model chose render_ui ⇔ expect=card. Writes RESULTS.json + REPORT.md.
// Usage: node qa/chat-ux-ui-policy/run-eval.mjs [--runs N]
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {uiPrompt,GROUNDED_PROMPT,renderUITool} from '../../services/edge/supabase/functions/_shared/core/src/generative-ui.mjs';
import {FREE_ROUTE_CATALOG} from '../../services/edge/supabase/functions/_shared/core/src/free-route-chain.mjs';
const here=new URL('.',import.meta.url),set=JSON.parse(readFileSync(new URL('cases.json',here),'utf8'));
const runs=Number(process.argv[process.argv.indexOf('--runs')+1]||1)||1;
const key=process.env.CATPAW_AGNES_API_KEY;if(!key){console.error('NOT RUN: CATPAW_AGNES_API_KEY missing; no offline substitute for model behaviour.');process.exit(2);}
const route=FREE_ROUTE_CATALOG.agnes,model=process.env.CATPAW_AGNES_MODEL||route.model;
const system='你是 Catpaw，一只贴心、靠谱的猫咪助手，用简体中文回答。'+uiPrompt+GROUNDED_PROMPT;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function ask(c){
  const messages=[{role:'system',content:system},...(c.history?set.fixtures[c.history]:[]),{role:'user',content:c.text}];
  for(let attempt=0;attempt<4;attempt++){
    const t0=Date.now(),r=await fetch(route.endpoint,{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({model,messages,tools:[renderUITool],tool_choice:'auto',temperature:0})});
    if(r.status===429||r.status>=500){await sleep(5000*(attempt+1));continue;}
    if(!r.ok)return {error:'http_'+r.status};
    const j=await r.json(),m=j.choices?.[0]?.message??{},call=(m.tool_calls??[]).find(t=>t.function?.name==='render_ui');
    let kind=null;if(call){try{const a=JSON.parse(call.function.arguments);kind=(a.block??a).kind??null;}catch{kind='unparsable';}}
    return {got:call?'card':'text',kind,latency_ms:Date.now()-t0,text:(m.content??'').slice(0,80)};
  }
  return {error:'rate_limited'};
}
const rows=[];
for(let run=1;run<=runs;run++)for(const c of set.cases){const r=await ask(c);rows.push({run,id:c.id,expect:c.expect,expect_kind:c.kind??null,...r,hit:r.got===c.expect});process.stdout.write(`${c.id}:${r.got??r.error}${r.got===c.expect?'':' ✗'} `);await sleep(3200);}
const scored=rows.filter(r=>!r.error),hits=scored.filter(r=>r.hit).length,rate=scored.length?hits/scored.length:0;
const out={ran_at:new Date().toISOString(),route:'agnes',model,runs,cases:set.cases.length,scored:scored.length,errors:rows.length-scored.length,hits,hit_rate:Number(rate.toFixed(4)),threshold:0.85,pass:rate>=0.85&&scored.length===rows.length,
  prompt_sha256:createHash('sha256').update(system).digest('hex'),cases_sha256:createHash('sha256').update(readFileSync(new URL('cases.json',here))).digest('hex'),rows};
writeFileSync(new URL('RESULTS.json',here),JSON.stringify(out,null,1)+'\n');
const miss=rows.filter(r=>!r.hit).map(r=>`| ${r.run} | ${r.id} | ${r.expect} | ${r.got??r.error} | ${r.kind??''} |`).join('\n')||'| – | – | – | – | – |';
writeFileSync(new URL('REPORT.md',here),`# chat-ux #3 card-vs-text eval\n\n- Ran: ${out.ran_at} (UTC) · route agnes · model \`${model}\` · temperature 0 · ${runs} run(s) × ${set.cases.length} cases\n- **Hit rate: ${hits}/${scored.length} = ${(rate*100).toFixed(1)}%** (threshold 85%) · errors ${out.errors} · ${out.pass?'PASS':'FAIL'}\n- Prompt sha256 \`${out.prompt_sha256.slice(0,16)}…\` = server \`uiPrompt\` (incl. UI_POLICY) + \`GROUNDED_PROMPT\`; tools = [render_ui] only.\n- Limits: one provider route (Agnes; production chain also has OpenRouter/Gemini), tool list reduced to render_ui, no device tools; card *kind* is recorded but not scored.\n\n## Misses\n\n| run | case | expected | got | kind |\n|---|---|---|---|---|\n${miss}\n`);
console.log(`\nhit rate ${hits}/${scored.length} = ${(rate*100).toFixed(1)}% errors=${out.errors}`);
