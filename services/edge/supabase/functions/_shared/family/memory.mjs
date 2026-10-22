// Household memory recall (v0.4). Candidates are already filtered in SQL by owner, household, status, validity window,
// subject and visibility; ranking here is lexical (no embedding provider; new compute budget is zero).
import { FamilyError, PROTOCOL, UUID_RE } from './contract.mjs';

const STOP = new Set('的了是在和与及也都就把被给对向从为吗呢吧啊呀哦请帮我们你他她它这那一个些什么怎么哪里还有没有'.split(''));
const norm = s => String(s ?? '').toLowerCase().replace(/虚构(儿童|角色|成人)?[甲乙丙丁]?/g, ' ').replace(/[\s\p{P}\p{S}]+/gu, ' ');
export function grams(s) {
  const t = norm(s), out = new Map();
  for (const seg of t.split(' ').filter(Boolean)) {
    const chars = [...seg].filter(c => !STOP.has(c));
    for (let i = 0; i < chars.length; i++) {
      const uni = chars[i]; out.set('1:' + uni, (out.get('1:' + uni) ?? 0) + 0.3);
      if (i + 1 < chars.length) { const bi = chars[i] + chars[i + 1]; out.set('2:' + bi, (out.get('2:' + bi) ?? 0) + 1); }
    }
  }
  return out;
}
export function score(q, d) {
  let s = 0, nq = 0, nd = 0;
  for (const [k, v] of q) { nq += v * v; const w = d.get(k); if (w) s += v * w; }
  for (const v of d.values()) nd += v * v;
  return nq && nd ? s / Math.sqrt(nq * nd) : 0;
}
// Stable sort: equal scores keep SQL order (most recently updated first).
export function rank(query, candidates, k = 6) {
  const q = grams(query);
  return candidates.map(c => ({ c, s: score(q, grams(c.text)) })).sort((a, b) => b.s - a.s).slice(0, k).map(x => ({ ...x.c, score: Math.round(x.s * 1000) / 1000 }));
}

export function createMemoryRoute() {
  return async ({ req, url, actor, hh, sub, ctx }) => {
    if (req.method !== 'GET') return null;
    if (sub === '/memories') {
      const all = await ctx.store.recallCandidates(actor, hh, null, null, 'all');
      if (all === null) throw new FamilyError(404, 'not_found');
      return new Response(JSON.stringify({ protocol: PROTOCOL, schema_version: 1, household_id: hh, memories: all }), { status: 200, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
    }
    if (sub === '/memories/recall') {
      const q = url.searchParams.get('q') ?? '', member = url.searchParams.get('member_id'), at = url.searchParams.get('at') ?? new Date(ctx.now()).toISOString();
      if (!q.trim() || q.length > 500 || (member && !UUID_RE.test(member)) || isNaN(Date.parse(at))) throw new FamilyError(422, 'command_invalid');
      const cands = await ctx.store.recallCandidates(actor, hh, at, member, 'household');
      if (cands === null) throw new FamilyError(404, 'not_found');
      // client-declared policy: memory off on this device, or an ephemeral conversation -> recall nothing
      if (url.searchParams.get('use_memory') === 'false' || url.searchParams.get('ephemeral') === 'true') return new Response(JSON.stringify({ protocol: PROTOCOL, schema_version: 1, household_id: hh, top_k: 6, results: [] }), { status: 200, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
      // memory paused -> [] (never recalled); used refs are reported so callers can audit injection
      const top = rank(q, cands, 6);
      return new Response(JSON.stringify({ protocol: PROTOCOL, schema_version: 1, household_id: hh, top_k: 6, results: top.map(m => ({ memory_id: m.memory_id, revision: m.revision, member_id: m.member_id, text: m.text, source: m.source, score: m.score })) }), { status: 200, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
    }
    return null;
  };
}

// Reminder dispatcher tick (runs from the scheduler; push delivery consumes outbox `reminder.due`).
export async function runReminderTick(store, nowIso, { log = () => {} } = {}) {
  const claims = await store.claimDueReminders(nowIso, 50); let fired = 0, skipped = 0;
  for (const c of claims) {
    try { if (await store.fireReminder(c.reminder_id, c.claimed_at)) fired++; else skipped++; }
    catch (e) { skipped++; log('family_reminder_fire_failed', e?.code ?? e?.name ?? 'error'); await store.releaseReminder(c.reminder_id, c.claimed_at).catch(() => {}); }
  }
  return { claimed: claims.length, fired, skipped };
}
