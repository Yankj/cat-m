// Dictation WER/CER harness. Input: a run file (JSON) from a device session:
//   {"device":"iPhone 13","os":"26.x","tier":"speechTranscriber|dictationTranscriber|onDeviceRecognizer|serverRecognizer","mode":"tap|hold","noise":"quiet|noisy",
//    "results":[{"id":"s01","hypothesis":"..."}]}
// Output: per-sentence CER (characters, punctuation and spaces removed, case-folded) and WER (whitespace tokens for
// en-US; for zh-CN each Han character is a token, so WER == CER there), plus totals. Also scores punctuation presence.
// Usage: node qa/dictation/score.mjs qa/dictation/runs/<file>.json [--json]
import {readFileSync} from 'node:fs';
const here=new URL('.',import.meta.url),corpus=JSON.parse(readFileSync(new URL('corpus.json',here),'utf8'));
export const strip=s=>s.replace(/（[^）]*）/g,'').normalize('NFKC').toLowerCase().replace(/[\p{P}\p{S}\s]/gu,'');
export function edits(a,b){const m=a.length,n=b.length;let prev=Array.from({length:n+1},(_,j)=>j);for(let i=1;i<=m;i++){const cur=[i];for(let j=1;j<=n;j++)cur[j]=Math.min(prev[j]+1,cur[j-1]+1,prev[j-1]+(a[i-1]===b[j-1]?0:1));prev=cur;}return prev[n];}
export function tokens(s,lang){const t=s.replace(/（[^）]*）/g,'').normalize('NFKC').toLowerCase();return lang.startsWith('zh')?[...t.replace(/[\p{P}\p{S}]/gu,' ')].filter(c=>c.trim()):t.replace(/[\p{P}\p{S}]/gu,' ').split(/\s+/).filter(Boolean);}
export function score(ref,hyp,lang){const r=[...strip(ref)],h=[...strip(hyp??'')],rt=tokens(ref,lang),ht=tokens(hyp??'',lang);
  return {cer:r.length?edits(r,h)/r.length:0,wer:rt.length?edits(rt,ht)/rt.length:0,ref_chars:r.length,ref_tokens:rt.length,char_edits:edits(r,h),token_edits:edits(rt,ht),punctuated:/[，。？！,.?!]/.test(hyp??'')};}
if(import.meta.url===`file://${process.argv[1]}`){
  const run=JSON.parse(readFileSync(process.argv[2],'utf8')),byID=new Map(run.results.map(r=>[r.id,r.hypothesis]));
  const rows=corpus.sentences.map(s=>({id:s.id,lang:s.lang,...score(s.text,byID.get(s.id),s.lang),missing:!byID.has(s.id)}));
  const sum=k=>rows.reduce((a,r)=>a+r[k],0),total={cer:sum('char_edits')/sum('ref_chars'),wer:sum('token_edits')/sum('ref_tokens'),punctuated:rows.filter(r=>r.punctuated).length,missing:rows.filter(r=>r.missing).length};
  if(process.argv.includes('--json'))console.log(JSON.stringify({run:{...run,results:undefined},total,rows},null,1));
  else{for(const r of rows)console.log(`${r.id} ${r.lang} CER ${(r.cer*100).toFixed(1)}% WER ${(r.wer*100).toFixed(1)}%${r.missing?' (missing)':''}`);console.log(`TOTAL CER ${(total.cer*100).toFixed(1)}% · WER ${(total.wer*100).toFixed(1)}% · punctuated ${total.punctuated}/20 · tier ${run.tier} · ${run.mode} · ${run.noise}`);}
}
