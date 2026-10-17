// p90i v7: catpaw-proactive's feature gates, exactly #89's rules (9aa7333) — no second implementation:
// readFeatureGate(value, 'on') (unset = on for everyone; 'allowlist' / 'off' honoured when set explicitly) and
// featureAllows (CATPAW_FEATURE_BLOCKLIST_SUBJECTS wins over 'on', the allowlist and enrollment).
import { readFeatureGate, readAllowlist, withBlocklist, featureAllows } from '../config.mjs';

/** @param {any} cfg @param {(n: string) => any} get @param {any} [enrolled] */
export function proactiveGates(cfg, get, enrolled = null) {
  const gate = (field, name) => cfg?.[field] ?? readFeatureGate(get(name), 'on');
  const allowlist = cfg?.featureAllowlist ?? withBlocklist(readAllowlist(get('CATPAW_FEATURE_ALLOWLIST_SUBJECTS')), readAllowlist(get('CATPAW_FEATURE_BLOCKLIST_SUBJECTS')));
  return {
    proactive: gate('proactive', 'CATPAW_PROACTIVE_ENABLED'),
    agentMemory: gate('agentMemory', 'CATPAW_AGENT_MEMORY_ENABLED'),
    allows: (g, uid, feature) => featureAllows(g, allowlist, uid, enrolled, feature),
  };
}
