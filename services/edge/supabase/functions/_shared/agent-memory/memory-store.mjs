// In-memory store with the same semantics as pg-store.mjs (tests / local dev). Every method is scoped by user id:
// a row is only visible to the user that owns it (the RLS policy `user_id = auth.uid()` in the migration).
export function createAgentMemoryStore() {
  const rows = new Map(), settings = new Map(), fragments = [];
  const c = v => structuredClone(v), mine = (uid, r) => r && r.user_id === uid;
  return {
    _dump: () => ({ rows: [...rows.values()].map(c), settings: Object.fromEntries(settings), fragments: fragments.map(c) }),
    async getSettings(uid) { return settings.has(uid) ? c(settings.get(uid)) : null; },
    async putSettings(uid, s) { settings.set(uid, c(s)); return c(s); },
    async insert(uid, row) {
      for (const r of rows.values()) if (r.user_id === uid && row.operation_id && r.operation_id === row.operation_id) return { row: c(r), created: false };
      const full = { ...c(row), user_id: uid }; rows.set(full.id, full); return { row: c(full), created: true };
    },
    async get(uid, id) { const r = rows.get(id); return mine(uid, r) ? c(r) : null; },
    async list(uid) { return [...rows.values()].filter(r => r.user_id === uid).map(c); },
    async count(uid) { let n = 0; for (const r of rows.values()) if (r.user_id === uid) n++; return n; },
    async update(uid, id, fields) { const r = rows.get(id); if (!mine(uid, r)) return null; Object.assign(r, c(fields)); return c(r); },
    async remove(uid, ids) { let n = 0; for (const id of ids) { const r = rows.get(id); if (mine(uid, r)) { rows.delete(id); n++; } } return n; },
    async removeAll(uid) { let n = 0; for (const [id, r] of rows) if (r.user_id === uid) { rows.delete(id); n++; } for (let i = fragments.length - 1; i >= 0; i--) if (fragments[i].user_id === uid) fragments.splice(i, 1); return n; },
    async byUndoHash(uid, hash) { for (const r of rows.values()) if (r.user_id === uid && r.undo_token_hash === hash) return c(r); return null; },
    async appendFragment(uid, f) { if (fragments.some(x => x.user_id === uid && x.turn_id === f.turn_id)) return false; fragments.push({ ...c(f), user_id: uid }); return true; },
    async takeFragments(day) { const out = new Map(); for (let i = fragments.length - 1; i >= 0; i--) if (fragments[i].day === day) { const f = fragments.splice(i, 1)[0]; if (!out.has(f.user_id)) out.set(f.user_id, []); out.get(f.user_id).unshift(f); } return [...out.entries()].map(([user_id, items]) => ({ user_id, items })); },
  };
}
