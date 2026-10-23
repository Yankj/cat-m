// In-memory store with the same semantics as pg-store.mjs (tests / local dev). Every method is scoped by user id:
// a row is only visible to the user that owns it (the RLS policy `user_id = auth.uid()` in the migration).
export function createAgentMemoryStore() {
  const rows = new Map(), settings = new Map(), fragments = [], tombstones = [], clears = new Map();
  // M1 MEM-04: a tombstone also remembers the deleted row's operation_id, so replaying that operation cannot recreate it.
  const tomb = (uid, id, op = null) => tombstones.push({ user_id: uid, id, operation_id: op, deleted_at: new Date().toISOString() });
  const c = v => structuredClone(v), mine = (uid, r) => r && r.user_id === uid;
  return {
    _dump: () => ({ rows: [...rows.values()].map(c), settings: Object.fromEntries(settings), fragments: fragments.map(c) }),
    async getSettings(uid) { return settings.has(uid) ? c(settings.get(uid)) : null; },
    async putSettings(uid, s) { const seq = settings.get(uid)?.use_memory_seq; settings.set(uid, c({ ...s, ...(seq !== undefined ? { use_memory_seq: seq } : {}) })); return c(s); },
    /** Codex p91w B1: partial update — only the named columns change (use_memory_seq and the rest are kept). */
    async patchSettings(uid, fields, { unsequencedOnly = false } = {}) { const cur = settings.get(uid) ?? { use_memory: false, auto_save: false, consented_at: null }; if (unsequencedOnly && cur.use_memory_seq !== undefined && cur.use_memory_seq !== null) return null; const n = { ...cur, ...c(fields) }; settings.set(uid, c(n)); const { use_memory_seq, ...out } = n; return c(out); },
    /** Codex PR91 v3-2: atomic last-writer-by-sequence (null when `seq` is not newer than the stored one). */
    async putSettingsIfNewer(uid, s, seq) {
      const prev = settings.get(uid)?.use_memory_seq ?? 0; if (seq <= prev) return null;
      settings.set(uid, c({ ...s, use_memory_seq: seq })); return c(s);
    },
    /** M1 MEM-03: clear generation; a write fenced on an older generation is refused. */
    async clearGeneration(uid) { return clears.get(uid) ?? 0; },
    async insert(uid, row, { fence } = {}) {
      if (fence !== undefined && (clears.get(uid) ?? 0) !== fence) return { row: null, created: false, refused: 'cleared' };
      if (row.operation_id && tombstones.some(t => t.user_id === uid && t.operation_id === row.operation_id)) return { row: null, created: false, refused: 'deleted' };
      for (const r of rows.values()) if (r.user_id === uid && row.operation_id && r.operation_id === row.operation_id) return { row: c(r), created: false };
      const full = { ...c(row), user_id: uid }; rows.set(full.id, full); return { row: c(full), created: true };
    },
    async get(uid, id) { const r = rows.get(id); return mine(uid, r) ? c(r) : null; },
    async list(uid) { return [...rows.values()].filter(r => r.user_id === uid).map(c); },
    async count(uid) { let n = 0; for (const r of rows.values()) if (r.user_id === uid) n++; return n; },
    async update(uid, id, fields, { expectVersion } = {}) { const r = rows.get(id); if (!mine(uid, r)) return null; if (expectVersion !== undefined && r.updated_at !== expectVersion) return { conflict: true }; Object.assign(r, c(fields)); return c(r); },
    async remove(uid, ids) { let n = 0; for (const id of ids) { const r = rows.get(id); if (mine(uid, r)) { rows.delete(id); tomb(uid, id, r.operation_id ?? null); n++; } } return n; },
    async removeAll(uid) { clears.set(uid, (clears.get(uid) ?? 0) + 1); let n = 0; for (const [id, r] of rows) if (r.user_id === uid) { rows.delete(id); tomb(uid, id, r.operation_id ?? null); n++; } for (let i = fragments.length - 1; i >= 0; i--) if (fragments[i].user_id === uid) fragments.splice(i, 1); return n; },
    async changedSince(uid, sinceIso) { return { rows: [...rows.values()].filter(r => r.user_id === uid && r.updated_at > sinceIso).map(c), deleted: tombstones.filter(t => t.user_id === uid && t.deleted_at > sinceIso).map(t => ({ id: t.id, deleted_at: t.deleted_at })) }; },
    async byUndoHash(uid, hash) { for (const r of rows.values()) if (r.user_id === uid && r.undo_token_hash === hash) return c(r); return null; },
    async appendFragment(uid, f) { if (fragments.some(x => x.user_id === uid && x.turn_id === f.turn_id)) return false; fragments.push({ ...c(f), user_id: uid }); return true; },
    async restoreFragments(groups) { for (const { user_id, items } of groups) for (const f of items) if (!fragments.some(x => x.user_id === user_id && x.turn_id === f.turn_id)) fragments.push({ ...c(f), user_id }); },
    async takeFragments(day) { const out = new Map(); for (let i = fragments.length - 1; i >= 0; i--) if (fragments[i].day === day) { const f = fragments.splice(i, 1)[0]; if (!out.has(f.user_id)) out.set(f.user_id, []); out.get(f.user_id).unshift(f); } return [...out.entries()].map(([user_id, items]) => ({ user_id, items })); },
  };
}
