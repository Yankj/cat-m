// v0.1 log audit: no log/console call in edge functions may carry an exception message, stack, or user text fields.
import test from 'node:test'; import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs'; import { join } from 'node:path';
import { errCode } from '../supabase/functions/_shared/proactive/safe-log.mjs';
const root = new URL('../supabase/functions/', import.meta.url).pathname;
// http.mjs:130 logs only stack frame locations (slice(1,5) drops the message line), reviewed 2026-10-23.
const ALLOW = new Set(['_shared/core/src/http.mjs']);
const files = []; (function walk(d) { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) walk(p); else if (/\.(mjs|ts)$/.test(n)) files.push(p); } })(root);
test('no log/console call includes .message, .stack, title, content or body text', () => {
  const bad = [];
  for (const f of files) readFileSync(f, 'utf8').split('\n').forEach((l, i) => {
    for (const m of l.matchAll(/\b(?:console\.(?:log|info|warn|error|debug)|log|diagnostic)\(([^;]*?)\)\s*[;}]/g))
      if (/\.(message|stack)\b|\b(title|content|notes|body)\s*[,)]/.test(m[1])) { if (!ALLOW.has(f.slice(root.length))) bad.push(`${f.slice(root.length)}:${i + 1}`); };
  });
  assert.deepEqual(bad, []);
});
test('errCode keeps only stable codes', () => {
  assert.equal(errCode({ code: '23505', message: '孩子 小明 secret' }), '23505');
  assert.equal(errCode(new TypeError('小明 去 游泳')), 'TypeError');
  assert.equal(errCode({ code: 'has space 小明' }), 'error');
});
