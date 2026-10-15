// Memory port for proactive decisions. B1 (catpaw.agent-memory.v1, PR #41) is not on this base branch and its
// recall runs inside catpaw-api's process; until it merges this is an interface + in-memory stand-in.
// Port: { recall(uid, query, k) -> [{id, content, kind?}], save?(uid, content) -> id }
export function createInMemoryRecall(seed = {}) {
  const items = new Map(Object.entries(seed).map(([u, list]) => [u, list.map((m, i) => ({ id: m.id ?? `m${i + 1}`, ...m }))]));
  const toks = s => new Set(String(s).toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean).flatMap(w => /\p{Script=Han}/u.test(w) ? [...w] : [w]));
  return {
    async recall(uid, query, k = 5) {
      const q = toks(query), list = items.get(uid) ?? [];
      return list.map(m => ({ m, s: [...toks(m.content)].filter(t => q.has(t)).length + (m.pinned ? 2 : 0) })).filter(x => x.s > 0).sort((a, b) => b.s - a.s).slice(0, k).map(x => ({ id: x.m.id, content: x.m.content, kind: x.m.kind ?? 'fact' }));
    },
    async save(uid, content) { const list = items.get(uid) ?? []; const id = 'm' + (list.length + 1) + '-' + crypto.randomUUID().slice(0, 8); list.push({ id, content, kind: 'preference' }); items.set(uid, list); return id; },
    all: uid => items.get(uid) ?? [],
  };
}
