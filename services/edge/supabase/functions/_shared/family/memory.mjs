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

const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
// zh cues for stored condition codes (lexical, no model): a condition other than the weekday counts as met only when the
// caller states it in `context` (key=value) or the query itself carries one of its cues.
export const CONDITION_CUES = {
  'weather=rain': ['下雨', '雨天', '雨时'], 'context=after_outdoor_sport': ['户外运动后', '运动后'], 'context=home_reading': ['阅读', '看书'],
  'school_stage=kindergarten': ['幼儿园'], 'school_stage=primary': ['小学'], 'before_participation=visit_venue': ['参加', '去不去', '愿意'],
};
export function conditionMet(cond, atIso, tz = 'Asia/Shanghai', context = {}, queryText = '') {
  if (!cond || !Object.keys(cond).length) return true;
  return Object.entries(cond).every(([k, v]) => {
    if (k === 'weekday') return new Intl.DateTimeFormat('en-US', { timeZone: tz, weekday: 'long' }).format(new Date(atIso)) === v;
    if (context[k] !== undefined) return context[k] === v;
    return (CONDITION_CUES[`${k}=${v}`] ?? []).some(cue => queryText.includes(cue));
  });
}
void WEEKDAYS;
// Deterministic answer plan (no model): which recalled memories may be asserted and the disposition. Field-level
// clarification wording needs a model route and is NOT produced here (clarification_fields stays []).
export const ASSERT_MIN = 0.25;
export function planAnswer(results, pendingRelevant = false, { disabled = false } = {}) {
  if (disabled) return { disposition: 'NO_REFERENCE', used_memory_refs: [], assertions: [], clarification_fields: [] };
  const top = results[0];
  if (!top || top.score < ASSERT_MIN) return { disposition: pendingRelevant ? 'CLARIFY' : 'NO_REFERENCE', used_memory_refs: [], assertions: [], clarification_fields: [] };
  const asserted = results.filter(r => r.score >= ASSERT_MIN && r.score >= top.score * 0.9);
  return { disposition: 'ANSWER_WITH_REFERENCES', clarification_fields: [],
    used_memory_refs: asserted.map(r => ({ memory_id: r.memory_id, revision: r.revision })),
    assertions: asserted.map(r => ({ memory_id: r.memory_id, revision: r.revision, kind: r.kind, status: r.status, value: r.text })) };
}
const J = (status, body) => new Response(JSON.stringify({ protocol: PROTOCOL, schema_version: 1, ...body }), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

export function createMemoryRoute() {
  return async ({ req, url, actor, hh, sub, ctx }) => {
    if (sub === '/memories/resolve' && req.method === 'POST') {
      const b = await ctx.body(req, 16 * 1024);
      const refs = b?.refs;
      if (!Array.isArray(refs) || refs.length > 50 || refs.some(r => !r || typeof r.memory_id !== 'string' || !UUID_RE.test(r.memory_id) || !Number.isSafeInteger(r.revision))) throw new FamilyError(422, 'command_invalid');
      const out = await ctx.store.resolveRefs(actor, hh, refs.map(r => ({ memory_id: r.memory_id, revision: r.revision })));
      if (out === null) throw new FamilyError(404, 'not_found');
      return J(200, { household_id: hh, allowed: out.allowed, fenced: out.fenced, dispatch: out.fenced.length ? 'BLOCKED' : 'ALLOWED' });
    }
    if (req.method !== 'GET') return null;
    if (sub === '/memories') {
      const all = await ctx.store.recallCandidates(actor, hh, null, null, 'all');
      if (all === null) throw new FamilyError(404, 'not_found');
      return J(200, { household_id: hh, memories: all });
    }
    if (sub === '/memories/audit') {
      const a = await ctx.store.memoryAudit(actor, hh);
      if (a === null) throw new FamilyError(404, 'not_found');
      return J(200, { household_id: hh, ...a });
    }
    if (sub === '/memories/recall') {
      const q = url.searchParams.get('q') ?? '', member = url.searchParams.get('member_id'), at = url.searchParams.get('at') ?? new Date(ctx.now()).toISOString();
      if (!q.trim() || q.length > 500 || (member && !UUID_RE.test(member)) || isNaN(Date.parse(at))) throw new FamilyError(422, 'command_invalid');
      const context = Object.fromEntries([...url.searchParams].filter(([k]) => k.startsWith('ctx.')).map(([k, v]) => [k.slice(4), v]).slice(0, 8));
      const reader = await ctx.store.reader(actor, hh);
      if (!reader) throw new FamilyError(404, 'not_found');
      if (member && Array.isArray(reader.scope) && !reader.scope.includes(member)) throw new FamilyError(403, 'forbidden');
      const empty = { household_id: hh, top_k: 6, results: [], snapshot: { refs: [], at }, answer: planAnswer([], false, { disabled: true }), memory_reads: 0, memory_writes: 0 };
      // client-declared policy: memory off on this device, or an ephemeral conversation -> no read, no write
      if (url.searchParams.get('use_memory') === 'false' || url.searchParams.get('ephemeral') === 'true') return J(200, empty);
      const cands = await ctx.store.recallCandidates(actor, hh, at, member, 'household');
      if (cands === null) throw new FamilyError(404, 'not_found');
      const usable = cands.filter(m => conditionMet(m.conditions, at, 'Asia/Shanghai', context, q));
      const top = rank(q, usable, 6);
      // relevant but not answerable (unconfirmed / outside validity) -> ask instead of guessing
      let pending = false;
      if (!top.length || top[0].score < ASSERT_MIN) {
        const listing = (await ctx.store.recallCandidates(actor, hh, null, member, 'household')) ?? [];
        const ids = new Set(usable.map(m => m.memory_id));
        pending = rank(q, listing.filter(m => !ids.has(m.memory_id)), 1).some(m => m.score >= ASSERT_MIN);
      }
      const results = top.map(m => ({ memory_id: m.memory_id, revision: m.revision, member_id: m.member_id, text: m.text, kind: m.kind, status: m.status, sensitivity: m.sensitivity, source: m.source, score: m.score }));
      return J(200, { household_id: hh, top_k: 6, results, snapshot: { refs: results.map(r => ({ memory_id: r.memory_id, revision: r.revision })), at },
        answer: planAnswer(results, pending), memory_reads: results.length, memory_writes: 0 });
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
