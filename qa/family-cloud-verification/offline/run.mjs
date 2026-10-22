#!/usr/bin/env node
// Run only this lane, preserve raw output under its ignored build directory.
import {spawnSync} from 'node:child_process';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve, relative} from 'node:path';
import {createHash} from 'node:crypto';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const ROOT = resolve(HERE, '../../..');
const BASE = '789ad4feceb0680b8e2e5913083c5b834dc63db1';
const PLAN = '2419db9b98e2e3bc0e8c850da62418d216fd3bb8';
const mode = process.argv[2] ?? 'all';
const candidate = process.argv[3] === '--candidate' ? process.argv[4] : BASE;
if (!['all', 'probes', 'targets'].includes(mode) || ![2, 3, 5].includes(process.argv.length) || (process.argv.length === 5 && process.argv[3] !== '--candidate') || !/^[0-9a-f]{40}$/.test(candidate ?? '')) throw Error('Usage: node qa/family-cloud-verification/offline/run.mjs [all|probes|targets] [--candidate <reviewed-full-commit-sha>]');
if (Number(process.versions.node.split('.')[0]) < 24) throw Error('Node v24+ is required; no dependency installation is performed.');
const git = (...args) => {
  const r = spawnSync('git', args, {cwd: ROOT, encoding: 'utf8', env: {PATH: process.env.PATH ?? ''}});
  if (r.status !== 0) throw Error('Git read failed: ' + args.join(' '));
  return r.stdout.trim();
};
const roots = ['services/edge/supabase/functions', 'services/edge/supabase/migrations'];
if (git('rev-parse', '--verify', candidate + '^{commit}') !== candidate) throw Error('Candidate must name an existing full commit SHA.');
// HEAD can contain QA commits. Only maintenance inputs must still match the pinned base.
if (git('diff', '--name-only', candidate, '--', ...roots) || git('ls-files', '--others', '--exclude-standard', '--', ...roots)) {
  throw Error('Maintenance inputs differ from pinned candidate; refusing mixed-candidate evidence. Supply --candidate with an explicitly reviewed full commit SHA.');
}
const sourcePaths = [
  'services/edge/supabase/functions/_shared/bootstrap.ts',
  'services/edge/supabase/functions/_shared/postgres-pool.mjs',
  'services/edge/supabase/functions/_shared/proactive/service.mjs',
  'services/edge/supabase/functions/_shared/proactive/memory-store.mjs',
  'services/edge/supabase/functions/_shared/proactive/pg-store.mjs',
  'services/edge/supabase/functions/_shared/agent-memory/service.mjs',
  'services/edge/supabase/functions/_shared/agent-memory/memory-store.mjs',
  'services/edge/supabase/functions/_shared/agent-memory/pg-store.mjs',
  'services/edge/supabase/migrations/20261015120000_proactive_tasks.sql',
];
const sha256 = data => createHash('sha256').update(data).digest('hex');
const started = new Date().toISOString();
const runID = 'family-offline-' + started.replace(/[:.]/g, '-');
const out = resolve(HERE, 'build', runID); mkdirSync(out, {recursive: true});
const files = ['bootstrap.test.mjs', 'memory.test.mjs', 'reminder.test.mjs', 'network-guard.test.mjs'];
const caseIDs = ['BOOT-01', 'BOOT-02', 'BOOT-03', 'MEM-01', 'MEM-02', 'MEM-03', 'MEM-04', 'MEM-05', 'REM-01', 'REM-02', 'REM-03', 'REM-04', 'REM-05', 'REM-06', 'REM-07', 'REM-08', 'REM-09', 'SAFE-01'];
const results = [];
for (const selected of mode === 'all' ? ['probes', 'targets'] : [mode]) {
  const args = ['--disable-warning=ExperimentalWarning', '--import', resolve(HERE, 'offline-prelude.mjs'), '--import', resolve(HERE, 'offline-loader.mjs'), '--test', '--test-reporter=tap', '--test-concurrency=1', ...files.map(f => resolve(HERE, f))];
  const child = spawnSync(process.execPath, args, {cwd: ROOT, encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024, env: {FAMILY_QA_MODE: selected, TZ: 'UTC', NODE_NO_WARNINGS: '1'}});
  const raw = (child.stdout ?? '') + (child.stderr ?? '');
  const outputFile = resolve(out, selected + '.tap'); writeFileSync(outputFile, raw);
  const observations = [...raw.matchAll(/^# FAMILY_OBSERVATION (.+)$/gm)].map(match => JSON.parse(match[1]));
  const counters = Object.fromEntries(['tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo'].map(k => [k, Number(new RegExp('^# ' + k + ' (\\d+)$', 'm').exec(raw)?.[1] ?? -1)]));
  const denominatorComplete = JSON.stringify(observations.map(r => r.id).sort()) === JSON.stringify([...caseIDs].sort()) && counters.tests === caseIDs.length && counters.cancelled === 0 && counters.skipped === 0;
  results.push({mode: selected, exit_code: child.status, signal: child.signal, error: child.error?.code ?? null, ...counters, denominator_complete: denominatorComplete, observation_count: observations.length, product_target_pass: observations.filter(r => r.product_status === 'PASS').length, product_target_fail: observations.filter(r => r.product_status === 'FAIL').length, observations, output: relative(ROOT, outputFile), output_sha256: sha256(raw)});
  console.log(JSON.stringify({mode: selected, exit_code: child.status, ...counters, product_target_pass: results.at(-1).product_target_pass, product_target_fail: results.at(-1).product_target_fail, output: relative(ROOT, outputFile)}));
}
const report = {
  schema_version: 1, run_id: runID, started_at: started, ended_at: new Date().toISOString(), lane: 'cloud-offline-A', host_alias: 'cloud-offline-node', branch: git('branch', '--show-current'), worktree_alias: 'family-offline',
  base_sha: BASE, candidate_sha: candidate, candidate_head: git('rev-parse', 'HEAD'), plan_sha: PLAN,
  maintenance_source_tree: git('rev-parse', candidate + ':services/edge/supabase/functions'), maintenance_inputs_equal_candidate: true, expected_case_ids: caseIDs,
  source_fingerprints: sourcePaths.map(path => ({path, git_blob: git('rev-parse', candidate + ':' + path), sha256: sha256(readFileSync(resolve(ROOT, path)))})),
  requested_model: 'gpt-6.1-sol', requested_effort: 'ultra', accepted_model: 'gpt-6.1-sol', accepted_effort: 'ultra',
  model_evidence: {source: 'parent delegation reports explicit spawn accepted', effective_model: null, effective_effort: null, status: 'UNVERIFIED'},
  parent_goal_id: null, objective_version: null, native_goal_status: 'NOT_CREATED_BY_THIS_TASK',
  protocol: ['existing catpaw.task-tools.v1', 'existing catpaw.agent-memory.v1'], test_data_version: 'synthetic-family-offline-v1', release_manifest: null,
  authorization_ref: 'parent-delegated isolated offline verification; no product implementation or real service calls',
  evidence_layer: 'offline/fixture', node: process.version, deno_run: false, swift_run: false,
  status: results.every(r => r.exit_code === 0 && r.denominator_complete) ? (mode === 'probes' ? 'PROBES_REPRODUCED' : 'OFFLINE_TARGETS_PASS') : 'OFFLINE_TARGETS_FAIL',
  product_acceptance: 'NOT_ACCEPTED', results,
};
writeFileSync(resolve(out, 'RESULTS.json'), JSON.stringify(report, null, 2) + '\n');
console.log('Run evidence: ' + relative(ROOT, resolve(out, 'RESULTS.json')));
process.exitCode = results.some(r => r.exit_code !== 0 || !r.denominator_complete) ? 1 : 0;
