import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
export const sourceSha='789ad4feceb0680b8e2e5913083c5b834dc63db1';
const root=fileURLToPath(new URL('../../../',import.meta.url));
const hash=content=>createHash('sha256').update(content).digest('hex');
export function assertPinnedSources(entries){
 const pending=[...entries],seen=new Set(),sources=[];
 while(pending.length){const relative=pending.pop();if(seen.has(relative))continue;seen.add(relative);
  assert.ok(relative.startsWith('services/edge/')||relative.startsWith('apps/ios-conversation/'),'source read scope');
  const current=readFileSync(path.join(root,relative)),baseline=execFileSync('git',['show',`${sourceSha}:${relative}`],{cwd:root});
  assert.equal(hash(current),hash(baseline),`source differs from pinned base: ${relative}`);sources.push({path:relative,sha256:hash(current)});
  if(relative.endsWith('.mjs'))for(const match of current.toString('utf8').matchAll(/(?:from\s*|import\s*\(\s*|import\s*)['"](\.[^'"]+)['"]/g))pending.push(path.posix.normalize(path.posix.join(path.posix.dirname(relative),match[1])));
 }
 return {source_sha:sourceSha,audit_head:execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),source_files:sources.sort((a,b)=>a.path.localeCompare(b.path)),source_pin:'MATCH'};
}
