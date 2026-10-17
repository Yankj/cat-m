// Enrollment registry: a per-instance cache of feature_access.enrollments so chat-tool gates stay synchronous.
// fresh() is awaited once per API request (cheap while within ttl); add() makes a fresh enrollment visible immediately
// on this instance; other instances see it after at most ttlMs.
export function createEnrollmentRegistry({ store, ttlMs = 30000, now = () => Date.now(), log = () => {} }) {
  let map = new Map(), loadedAt = -Infinity, inflight = null;
  async function load() {
    try { const rows = await store.listEnrollments(); const m = new Map(); for (const { subject_id, feature } of rows) { const k = String(subject_id).toLowerCase(); if (!m.has(k)) m.set(k, new Set()); m.get(k).add(feature); } map = m; loadedAt = now(); }
    catch (e) { log('enrollment_load_failed', e?.code ?? e?.name ?? 'error'); loadedAt = now() - ttlMs + 5000; } // keep last good copy, retry in ~5 s
    finally { inflight = null; }
  }
  return {
    has(subjectID, feature) { const s = map.get(String(subjectID ?? '').toLowerCase()); return !!s && (feature == null || s.has(feature)); },
    features(subjectID) { return [...(map.get(String(subjectID ?? '').toLowerCase()) ?? [])].sort(); },
    add(subjectID, features) { const k = String(subjectID).toLowerCase(); const s = map.get(k) ?? new Set(); for (const f of features) s.add(f); map.set(k, s); },
    async fresh(force = false) { if (!force && now() - loadedAt < ttlMs) return; inflight ??= load(); await inflight; },
  };
}
