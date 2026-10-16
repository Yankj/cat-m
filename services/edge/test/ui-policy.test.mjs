import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {uiPrompt,UI_POLICY,GROUNDED_PROMPT} from '../supabase/functions/_shared/core/src/generative-ui.mjs';
test('uiPrompt carries the card-vs-text policy with 3 positive + 3 negative examples; eval set is fixed at 20 and disjoint',()=>{
 assert.ok(uiPrompt.endsWith(UI_POLICY));
 const pos=UI_POLICY.split('正例')[1].split('反例')[0],neg=UI_POLICY.split('反例')[1];
 assert.equal((pos.match(/^- 「/gm)??[]).length,3);assert.equal((neg.match(/^- 「/gm)??[]).length,3);assert.match(UI_POLICY,/不确定时用文字/);
 assert.match(GROUNDED_PROMPT,/不要自己编地点或日程/);
 const set=JSON.parse(readFileSync(new URL('../../../qa/chat-ux-ui-policy/cases.json',import.meta.url),'utf8'));
 assert.equal(set.cases.length,20);assert.equal(set.cases.filter(c=>c.expect==='card').length,10);
 const examples=[...UI_POLICY.matchAll(/「([^」]+)」/g)].map(m=>m[1]);for(const c of set.cases)assert.ok(!examples.includes(c.text),c.id);
 const res=JSON.parse(readFileSync(new URL('../../../qa/chat-ux-ui-policy/RESULTS.json',import.meta.url),'utf8'));assert.ok(res.hit_rate>=0.85&&res.errors===0,'committed live result meets the bar');
});
