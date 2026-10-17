// p90i v7 (NoBug via Grok Bot): catpaw-proactive's feature gates follow #89 9aa7333 — unset = on for everyone,
// CATPAW_FEATURE_BLOCKLIST_SUBJECTS wins, an explicit 'allowlist' / 'off' is honoured. Uses #89's readFeatureGate /
// featureAllows (no second implementation), and never falls back to 'off' when cfg lacks a field.
import test from 'node:test'; import assert from 'node:assert/strict';
import { readConfig } from '../supabase/functions/_shared/config.mjs';
import { proactiveGates } from '../supabase/functions/_shared/proactive/gates.mjs';

const A = '00000000-0000-4000-8000-0000000000a1', B = '00000000-0000-4000-8000-0000000000b2';
const gates = env => { const get = n => env[n]; return proactiveGates(readConfig(get), get); };

test('p90i gate: unset → proactive and agent memory on for everyone', () => {
  const g = gates({});
  assert.deepEqual([g.proactive, g.agentMemory], ['on', 'on']);
  assert.equal(g.allows(g.proactive, A, 'proactive'), true);
});
test('p90i gate: the blocklist wins over default-on (and over an explicit allowlist)', () => {
  const g = gates({ CATPAW_FEATURE_BLOCKLIST_SUBJECTS: B });
  assert.deepEqual([g.allows(g.proactive, A, 'proactive'), g.allows(g.proactive, B, 'proactive'), g.allows(g.agentMemory, B, 'agent_memory')], [true, false, false]);
  const h = gates({ CATPAW_PROACTIVE_ENABLED: 'allowlist', CATPAW_FEATURE_ALLOWLIST_SUBJECTS: `${A},${B}`, CATPAW_FEATURE_BLOCKLIST_SUBJECTS: B });
  assert.deepEqual([h.allows(h.proactive, A, 'proactive'), h.allows(h.proactive, B, 'proactive')], [true, false]);
});
test('p90i gate: explicit allowlist / off are honoured', () => {
  const g = gates({ CATPAW_PROACTIVE_ENABLED: 'allowlist', CATPAW_FEATURE_ALLOWLIST_SUBJECTS: A });
  assert.deepEqual([g.proactive, g.allows(g.proactive, A, 'proactive'), g.allows(g.proactive, B, 'proactive')], ['allowlist', true, false]);
  const o = gates({ CATPAW_PROACTIVE_ENABLED: 'off', CATPAW_AGENT_MEMORY_ENABLED: 'false' });
  assert.deepEqual([o.proactive, o.agentMemory, o.allows(o.proactive, A, 'proactive')], ['off', 'off', false]);
});
test('p90i gate: a cfg without the fields (partial config) still defaults ON via readFeatureGate, never "off"', () => {
  const g = proactiveGates({}, () => undefined);
  assert.deepEqual([g.proactive, g.agentMemory], ['on', 'on']);
  const b = proactiveGates({}, n => n === 'CATPAW_FEATURE_BLOCKLIST_SUBJECTS' ? A : undefined);
  assert.equal(b.allows(b.proactive, A, 'proactive'), false, 'blocklist read even without cfg.featureAllowlist');
});
