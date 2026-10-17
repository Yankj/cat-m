import test from 'node:test';
import assert from 'node:assert/strict';
import { readConfig, readFeatureGate, featureAllows, featureBlocked } from '../supabase/functions/_shared/config.mjs';
import { createAgentMemoryService } from '../supabase/functions/_shared/agent-memory/service.mjs';

const U1 = '11111111-1111-4111-8111-111111111111', U2 = '22222222-2222-4222-8222-222222222222';
const KEYS = ['taskTools', 'generativeUI', 'agentMemory', 'deviceTools', 'proactiveSuggestionsSSE', 'proactive'];
const ENV = { taskTools: 'CATPAW_TASK_TOOLS_ENABLED', generativeUI: 'CATPAW_GENERATIVE_UI_ENABLED', agentMemory: 'CATPAW_AGENT_MEMORY_ENABLED', deviceTools: 'CATPAW_DEVICE_TOOLS_ENABLED', proactiveSuggestionsSSE: 'CATPAW_PROACTIVE_SUGGESTIONS_SSE_ENABLED', proactive: 'CATPAW_PROACTIVE_ENABLED' };
const cfg = env => readConfig(n => env[n]);

test('unset / empty gate → on for everyone, for every gate', () => {
  for (const env of [{}, Object.fromEntries(Object.values(ENV).map(n => [n, ''])), Object.fromEntries(Object.values(ENV).map(n => [n, '  ']))]) {
    const c = cfg(env);
    for (const k of KEYS) { assert.equal(c[k], 'on', k); assert.ok(featureAllows(c[k], c.featureAllowlist, U1), k); }
  }
  assert.equal(readFeatureGate(undefined, 'on'), 'on');
});

test('explicit allowlist and off still work', () => {
  const c = cfg({ ...Object.fromEntries(Object.values(ENV).map(n => [n, 'allowlist'])), CATPAW_FEATURE_ALLOWLIST_SUBJECTS: U1 });
  for (const k of KEYS) { assert.equal(c[k], 'allowlist'); assert.ok(featureAllows(c[k], c.featureAllowlist, U1)); assert.ok(!featureAllows(c[k], c.featureAllowlist, U2)); }
  const enrolled = { has: (uid, f) => uid === U2 && f === 'agent_memory' };
  assert.ok(featureAllows('allowlist', c.featureAllowlist, U2, enrolled, 'agent_memory'));
  for (const v of ['false', 'off', 'OFF', 'no', 'yes', 'tru']) { const o = cfg({ CATPAW_AGENT_MEMORY_ENABLED: v, CATPAW_FEATURE_ALLOWLIST_SUBJECTS: U1 }); assert.equal(o.agentMemory, 'off', v); assert.ok(!featureAllows(o.agentMemory, o.featureAllowlist, U1, { has: () => true }, 'agent_memory'), v); }
});

test('blocklist wins over on, allowlist and enrollment, for every feature; invalid UUIDs ignored', () => {
  const c = cfg({ CATPAW_FEATURE_BLOCKLIST_SUBJECTS: ` ${U1.toUpperCase()} , not-a-uuid,, 1234`, CATPAW_FEATURE_ALLOWLIST_SUBJECTS: U1, CATPAW_GENERATIVE_UI_ENABLED: 'allowlist', CATPAW_TASK_TOOLS_ENABLED: 'true' });
  const everything = { has: () => true };
  for (const k of KEYS) { assert.ok(!featureAllows(c[k], c.featureAllowlist, U1, everything, 'agent_memory'), k); assert.ok(featureAllows(c[k] === 'allowlist' ? 'on' : c[k], c.featureAllowlist, U2), k); }
  assert.ok(featureBlocked(c.featureAllowlist, U1)); assert.ok(!featureBlocked(c.featureAllowlist, U2));
  assert.equal(c.featureAllowlist.blocked.size, 1, 'only the valid UUID is kept');
  assert.ok(!c.featureAllowlist.has(U2));
  // explicit blocklist parameter (callers that keep their own Set)
  assert.ok(!featureAllows('on', new Set(), U2, null, null, new Set([U2])));
  // the env allowlist Set stays a plain Set for existing callers
  assert.deepEqual([...c.featureAllowlist], [U1]);
});

test('unmigrated agent memory schema: chat recall degrades to no memory instead of throwing (no 500)', async () => {
  for (const code of ['42P01', '42703']) {
    const err = Object.assign(new Error('missing'), { code });
    const s1 = createAgentMemoryService({ store: { getSettings: async () => { throw err; } }, allow: () => true });
    assert.equal(await s1.recallForTurn({ subjectID: U1, query: 'hi' }), null, code);
    const s2 = createAgentMemoryService({ store: { getSettings: async () => ({ use_memory: true, consented_at: '2026-10-17T00:00:00Z' }), list: async () => { throw err; } }, allow: () => true });
    assert.equal(await s2.recallForTurn({ subjectID: U1, query: 'hi' }), null, code);
  }
  const other = createAgentMemoryService({ store: { getSettings: async () => { throw Object.assign(new Error('down'), { code: '08006' }); } }, allow: () => true });
  await assert.rejects(other.recallForTurn({ subjectID: U1, query: 'hi' }), /down/);
});
