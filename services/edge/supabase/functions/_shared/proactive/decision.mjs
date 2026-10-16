// catpaw.proactive.decision.v1 — "should the assistant speak up?" for meeting & travel signals.
// Pipeline: validate → signal_hash dedupe (window) → learned trigger weights → memory recall →
// LLM structured decision (fallback: deterministic rules) → confidence threshold degrade →
// quiet hours / daily cap (B2 throttle) → write one proactive event with an explanation payload.
import { isQuiet, localDayStart } from './throttle.mjs';
import { bad } from './recurrence.mjs';

export const DECISION_CONTRACT = 'catpaw.proactive.decision.v1';
export const LEVELS = ['silent', 'card', 'notify', 'interrupt'];
export const FEEDBACK_KINDS = ['helpful', 'not_helpful', 'intrusive'];
const FEEDBACK_ALIASES = { disturbing: 'intrusive' };
export const SUGGESTION_ACTIONS = ['create_reminder', 'notify_attendees', 'snooze', 'dismiss'];
const ACTION_STATUS = { create_reminder: 'done', notify_attendees: 'done', snooze: 'snoozed', dismiss: 'dismissed' };
const SIGNAL_TYPES = ['meeting_upcoming', 'meeting_conflict', 'flight_status', 'traffic', 'location', 'calendar_change', 'weather', 'message', 'custom'];
const ACTION_KINDS = SUGGESTION_ACTIONS;
// Codex P0-5: effect actions have their own state; the suggestion is done only when every offered effect is done.
const EFFECTS = ['create_reminder', 'notify_attendees'];
const actionStates = st => Object.fromEntries((st.taken ?? []).filter(t => EFFECTS.includes(t.action)).map(t => [t.action, 'done']));
const lvl = d => LEVELS.indexOf(d);
const UNDO_IRREVERSIBLE = ['notify_attendees'];

export async function signalHash(s) {
  const canon = JSON.stringify([s.type, s.source ?? null, s.dedupe_key ?? stable(s.data ?? {})]);
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canon)));
  return [...d].map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 32);
}
function stable(v) { if (Array.isArray(v)) return v.map(stable); if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map(k => [k, stable(v[k])])); return v; }

export function validateEvaluate(b) {
  if (!b || typeof b !== 'object' || !Array.isArray(b.signals) || b.signals.length < 1 || b.signals.length > 20) throw bad('signals_invalid');
  const signals = b.signals.map((s, i) => {
    if (!s || typeof s !== 'object' || !SIGNAL_TYPES.includes(s.type)) throw bad('signal_type_invalid');
    if (s.data != null && (typeof s.data !== 'object' || JSON.stringify(s.data).length > 4000)) throw bad('signal_data_invalid');
    return { id: typeof s.id === 'string' ? s.id.slice(0, 80) : `s${i + 1}`, type: s.type, source: typeof s.source === 'string' ? s.source.slice(0, 60) : null, at: typeof s.at === 'string' ? s.at : null, dedupe_key: typeof s.dedupe_key === 'string' ? s.dedupe_key.slice(0, 200) : undefined, data: s.data ?? {} };
  });
  const context = b.context && typeof b.context === 'object' ? b.context : {};
  if (JSON.stringify(context).length > 8000) throw bad('context_too_large', 413);
  return { signals, context };
}

/** Deterministic baseline (also the LLM-unavailable fallback). Returns per-signal severity + chosen action set. */
export function ruleDecide(signals, context) {
  let best = { decision: 'silent', reason: '没有需要打扰你的事情。', confidence: 0.6, actions: [], trigger: signals[0]?.type ?? 'custom' };
  const consider = (decision, reason, confidence, actions, trigger) => { if (lvl(decision) > lvl(best.decision)) best = { decision, reason, confidence, actions, trigger }; };
  for (const s of signals) {
    const d = s.data ?? {};
    if (s.type === 'meeting_upcoming') {
      const until = Number(d.minutes_until), travel = Number(d.travel_minutes ?? 0);
      if (Number.isFinite(until) && travel > 0 && travel + 5 >= until) consider(until <= travel ? 'interrupt' : 'notify', `「${d.title ?? '会议'}」${until} 分钟后开始，但去${d.location ?? '会场'}需要约 ${travel} 分钟，现在出发${until <= travel ? '已经来不及' : '刚好'}。`, 0.85, acts('create_reminder', 'notify_attendees'), s.type);
      else if (Number.isFinite(until) && until <= 10) consider('card', `「${d.title ?? '会议'}」${until} 分钟后开始。`, 0.7, acts('create_reminder'), s.type);
    } else if (s.type === 'flight_status') {
      const delay = Number(d.delay_minutes ?? 0);
      if (d.status === 'cancelled') consider('interrupt', `航班 ${d.flight ?? ''} 已取消。`, 0.9, acts('notify_attendees', 'create_reminder'), s.type);
      else if (delay >= 60 && d.affects_meeting) consider('interrupt', `航班 ${d.flight ?? ''} 延误 ${delay} 分钟，会影响落地后的「${d.affects_meeting}」。`, 0.8, acts('notify_attendees', 'create_reminder'), s.type);
      else if (delay >= 30) consider('notify', `航班 ${d.flight ?? ''} 延误 ${delay} 分钟。`, 0.75, acts('create_reminder'), s.type);
      else if (d.gate_changed) consider('card', `航班 ${d.flight ?? ''} 登机口改为 ${d.gate ?? '新登机口'}。`, 0.7, acts('create_reminder'), s.type);
    } else if (s.type === 'meeting_conflict') {
      consider(Number(d.minutes_until ?? 999) <= 60 ? 'notify' : 'card', `「${d.a ?? '会议 A'}」和「${d.b ?? '会议 B'}」时间冲突。`, 0.75, acts('notify_attendees', 'create_reminder'), s.type);
    } else if (s.type === 'traffic' && Number(d.extra_minutes ?? 0) >= 15) consider('notify', `路上比平时多堵 ${d.extra_minutes} 分钟。`, 0.65, acts('create_reminder'), s.type);
  }
  if (context.focus_mode && best.decision === 'interrupt' && best.confidence < 0.9) best = { ...best, decision: 'notify', reason: best.reason + '（你在专注模式）' };
  return best;
}
const RULE_TITLES = { meeting_upcoming: '该出发了', flight_status: '航班有变化', meeting_conflict: '会议时间冲突', traffic: '路上会堵' };
const acts = (...k) => [...k, 'snooze', 'dismiss'];

export function validateModelDecision(j, memoryIds) {
  if (!j || typeof j !== 'object' || !LEVELS.includes(j.decision)) throw new Error('decision_invalid');
  const confidence = Number(j.confidence); if (!(confidence >= 0 && confidence <= 1)) throw new Error('confidence_invalid');
  if (typeof j.reason !== 'string' || !j.reason.trim()) throw new Error('reason_invalid');
  const raw = (Array.isArray(j.suggested_actions) ? j.suggested_actions : []).map(x => typeof x === 'string' ? x : x?.kind).filter(k => ACTION_KINDS.includes(k));
  const actions = [...new Set([...raw, 'snooze', 'dismiss'])];
  const title = typeof j.title === 'string' && j.title.trim() ? j.title.trim().slice(0, 40) : null;
  const used = (Array.isArray(j.used_memory_ids) ? j.used_memory_ids : []).filter(id => memoryIds.includes(id));
  return { decision: j.decision, title, reason: j.reason.trim().slice(0, 400), confidence, actions, used, trigger: typeof j.trigger === 'string' ? j.trigger : null };
}

export function createDecisionService({ store, model = null, memory = null, now = () => Date.now(), log = () => {}, config = {} }) {
  const cfg = { threshold: 0.6, dedupeWindowSec: 1800, quietHours: { start: 22, end: 8 }, dailyCap: 5, silentMargin: 0.3, timeZone: 'Asia/Shanghai', ...config };

  async function evaluate(uid, input) {
    const { signals, context } = validateEvaluate(input), at = now(), tz = context.time_zone || cfg.timeZone;
    // Codex PR90d P2: a pre-scheduled notification is judged at its future fire instant (quiet hours / daily cap),
    // bounded to [now, now+36h]; anything else is ignored and the request time is used.
    const ea = typeof context.evaluate_at === 'string' ? Date.parse(context.evaluate_at) : NaN;
    const when = Number.isFinite(ea) && ea >= at && ea <= at + 36 * 3600_000 ? ea : at;
    const hashes = await Promise.all(signals.map(signalHash));
    const since = new Date(at - cfg.dedupeWindowSec * 1000).toISOString();
    const seen = await store.seenSignalHashes(uid, hashes, since);
    const fresh = signals.filter((_, i) => !seen.includes(hashes[i]));
    const weights = await store.getTriggerWeights(uid);
    const w = t => weights[t] ?? { weight: 1, threshold_bump: 0 };
    const memories = memory ? await memory.recall(uid, signals.map(s => [s.type, s.data?.title, s.data?.location, s.data?.flight].filter(Boolean).join(' ')).join('; '), 5).catch(e => { log('memory_failed', e.message); return []; }) : [];
    const trace = [];
    let r, source;
    if (!fresh.length) { r = { decision: 'silent', reason: '同样的情况刚刚已经评估过，不重复打扰。', confidence: 1, actions: [], used: [], trigger: signals[0].type }; source = 'dedupe'; trace.push('dedupe: all signals seen within window'); }
    else {
      const rule = ruleDecide(fresh, context);
      if (model) {
        try { r = validateModelDecision(await model.decide({ signals: fresh, context, memories, weights: Object.fromEntries(fresh.map(s => [s.type, w(s.type)])), now_iso: new Date(at).toISOString(), time_zone: tz }), memories.map(m => m.id)); r.trigger ??= rule.trigger; source = 'llm:' + (model.lastRoute?.() ?? 'model'); }
        catch (e) { log('decision_model_failed', e.message); trace.push('llm unavailable: ' + String(e.message).slice(0, 60)); }
      }
      if (!r) { r = { ...rule, title: RULE_TITLES[rule.trigger] ?? null, used: rule.decision === 'silent' ? [] : memories.map(m => m.id) }; source = 'rules'; }
      if (!SIGNAL_TYPES.includes(r.trigger)) r.trigger = fresh[0].type;
    }
    const proposed = r.decision; let decision = r.decision;
    // learned weight scales confidence; threshold rises with negative feedback
    const tw = w(r.trigger), conf = Math.max(0, Math.min(1, r.confidence * tw.weight)), threshold = Math.min(0.95, cfg.threshold + tw.threshold_bump);
    // Codex P0-3: far below the bar → say nothing (a 1% guess must not become a card).
    if (decision !== 'silent' && conf < threshold - cfg.silentMargin) { trace.push(`confidence ${conf.toFixed(2)} < ${(threshold - cfg.silentMargin).toFixed(2)}: ${proposed} → silent`); decision = 'silent'; }
    else if (decision !== 'silent' && conf < threshold) { const steps = conf < threshold - 0.15 ? 2 : 1; decision = LEVELS[Math.max(1, lvl(decision) - steps)]; trace.push(`confidence ${conf.toFixed(2)} < threshold ${threshold.toFixed(2)}: ${proposed} → ${decision}`); }
    if (lvl(decision) >= 2 && isQuiet(when, tz, cfg.quietHours)) { trace.push(`quiet hours: ${decision} → card`); decision = 'card'; }
    if (lvl(decision) >= 2) { const d0 = localDayStart(when, tz), n = await store.countDecisionsForDay(uid, new Date(d0).toISOString(), new Date(d0 + 86_400_000).toISOString(), ['notify', 'interrupt']); if (n >= cfg.dailyCap) { trace.push(`daily cap ${cfg.dailyCap} reached: ${decision} → card`); decision = 'card'; } }
    // Codex PR90 #1: "evaluated" ≠ "delivered" in the cloud too. Only a delivered (non-silent) decision closes the
    // dedupe window; a silent verdict (incl. a dedupe hit) never refreshes seen_at, so the meeting is re-evaluated as it nears.
    if (decision !== 'silent') await store.markSignalHashes(uid, hashes, new Date(at).toISOString());
    const used = memories.filter(m => r.used.includes(m.id));
    // Codex PR90 #2: one delivery owner per decision. A device-evaluated decision is delivered by the device's own
    // gate (local notification); APNs only delivers decisions the client explicitly hands off (context.delivery='remote').
    const delivery = context.delivery === 'remote' ? 'remote' : 'device';
    const explanation = {
      time_zone: tz, delivery, deliver_at: new Date(when).toISOString(),   // Codex PR90e P2: the cap counts the delivery day, not the creation day
      contract: DECISION_CONTRACT, why: r.reason, proposed, decision, source, trigger: r.trigger,
      confidence: Number(conf.toFixed(3)), raw_confidence: r.confidence, threshold: Number(threshold.toFixed(3)), weight: tw.weight, trace,
      signals: signals.map((s, i) => ({ ...s, signal_hash: hashes[i], duplicate: seen.includes(hashes[i]) })),
      memories: used, actions: r.actions,
      undo: { kind: 'dismiss', method: 'POST', path: '/push/action', body_template: { action: 'dismiss' }, feedback_path: '/proactive/feedback' },
    };
    explanation.title = r.title || titleFor(decision, r);
    explanation.suggestion = { status: decision === 'silent' ? 'dismissed' : 'pending', taken: [], history: [], ops: {} };
    const ev = await store.insertEvent({ user_id: uid, task_id: null, conversation_id: context.conversation_id ?? null, kind: 'proactive_decision', title: explanation.title, body: r.reason, payload: explanation, dedupe_key: 'decision:' + crypto.randomUUID(), push_state: delivery === 'remote' && lvl(decision) >= 2 ? 'pending' : 'skipped' });
    return { event_id: ev.id, suggestion: toSuggestion(ev), decision, delivery, reason: r.reason, confidence: explanation.confidence, used_memories: used, suggested_actions: r.actions, source, trace };
  }

  async function feedback(uid, b) {
    if (b && b.value && !b.kind) b = { ...b, kind: b.value };
    if (b && FEEDBACK_ALIASES[b.kind]) b = { ...b, kind: FEEDBACK_ALIASES[b.kind] };
    if (!b || typeof b.event_id !== 'string' || !/^[0-9a-f-]{36}$/i.test(b.event_id) || !FEEDBACK_KINDS.includes(b.kind)) throw bad('feedback_invalid');
    const ev = await store.getEvent(uid, b.event_id); if (!ev || ev.kind !== 'proactive_decision') throw bad('event_not_found', 404);
    const prior = await store.getFeedback(uid, ev.id);
    if (prior) return { event_id: ev.id, kind: prior.kind, applied: false, weights: await store.getTriggerWeights(uid) };
    if (!(await store.insertFeedback(uid, ev.id, b.kind, new Date(now()).toISOString()))) return { event_id: ev.id, applied: false };
    const triggers = [...new Set([ev.payload?.trigger, ...(ev.payload?.signals ?? []).map(s => s.type)].filter(Boolean))];
    const cur = await store.getTriggerWeights(uid), next = {};
    for (const t of triggers) {
      const c = cur[t] ?? { weight: 1, threshold_bump: 0 };
      const [mw, db] = b.kind === 'helpful' ? [1.05, -0.02] : b.kind === 'not_helpful' ? [0.85, 0.05] : [0.7, 0.1];
      next[t] = { weight: round(clamp(c.weight * mw, 0.3, 1.5)), threshold_bump: round(clamp(c.threshold_bump + db, -0.1, 0.3)) };
      await store.setTriggerWeight(uid, t, next[t]);
    }
    let memory_id = null;
    if (memory?.save && b.kind !== 'helpful' && b.save_preference !== false) memory_id = await memory.save(uid, `用户觉得关于「${ev.payload?.trigger}」的主动提醒${b.kind === 'intrusive' ? '打扰到自己' : '没有帮助'}（${ev.title}）。`).catch(() => null);
    return { event_id: ev.id, kind: b.kind, applied: true, weights: next, memory_id };
  }

  // Codex PR90 #7: read-modify-write under compare-and-set on suggestion.rev; a lost race reloads and re-applies.
  async function mutate(uid, id, apply) {
    for (let i = 0; i < 6; i++) {
      const ev = await load(uid, id), st = ev.payload.suggestion, rev = st.rev ?? 0;
      if (!apply(ev, st)) return toSuggestion(ev);
      st.rev = rev + 1;
      const saved = await store.updateEventPayload(uid, id, ev.payload, rev);
      if (saved) return toSuggestion(saved);
    }
    throw bad('suggestion_write_conflict', 409);
  }
  async function act(uid, id, b) {
    const action = b?.action; if (!SUGGESTION_ACTIONS.includes(action)) throw bad('action_invalid');
    const opId = typeof b.operation_id === 'string' ? b.operation_id.slice(0, 80) : null;
    let applied = false, seenGen = null;
    return mutate(uid, id, (ev, st) => {
      applied = false; seenGen = ev.push_generation ?? 0;   // PR90h #1: the generation this action acted on
      if (opId && st.ops[opId]) return false;
      const last = st.taken.at(-1), effect = EFFECTS.includes(action);
      // A cancelled / unavailable / failed effect is never recorded (and never turns the suggestion done).
      if (effect && typeof b.outcome === 'string' && !['succeeded', 'sent', 'done'].includes(b.outcome)) return false;
      if (!opId && (effect ? st.taken.some(t => t.action === action) : (last?.action === action && st.status === ACTION_STATUS[action]))) return false;
      const at = new Date(now()).toISOString();
      st.history.push({ status: st.status, taken_len: st.taken.length });
      st.taken.push({ action, at, ...(typeof b.detail === 'string' ? { detail: b.detail.slice(0, 200) } : {}) });
      if (effect) { const offered = (ev.payload.actions ?? []).filter(a => EFFECTS.includes(a)), done = actionStates(st); st.status = offered.every(a => done[a]) ? 'done' : 'pending'; }
      else st.status = ACTION_STATUS[action];
      if (opId) st.ops[opId] = action;
      if (action === 'snooze') {
        // Codex PR90e #5: the device's own until (one per snooze intent) is the cloud's, so both sides undo to the same one.
        // Codex PR90f #3: a late sync keeps the device's own until (bounded: ≤ 7 days old, ≤ 24 h ahead). Already past →
        // recorded as expired and resurfaced by the next resurface pass; never silently replaced by "now + 10 min".
        const u = typeof b.until === 'string' ? Date.parse(b.until) : NaN, t = now();
        // PR90g #3: any past until is kept (expired); only a malformed or > 24 h-ahead one falls back.
        const valid = Number.isFinite(u) && u <= t + 1440 * 60000;
        const until = valid ? u : t + (Number(b.minutes) > 0 ? Math.min(Number(b.minutes), 1440) : 10) * 60000;
        const entry = st.taken.at(-1); entry.until = st.snooze_until = new Date(until).toISOString(); if (until <= t) entry.expired = true;
      }
      applied = true;
      return true;
    }).then(async sug => {
      // Codex PR90d #5 / PR90e: a dismissed / snoozed suggestion must not be pushed by a still-pending row — only when this
      // call actually applied it (a replayed old op must never cancel a push that was re-armed since).
      if (applied && sug.status === ACTION_STATUS[action] && (action === 'dismiss' || action === 'snooze') && store.cancelPendingPush) await store.cancelPendingPush(uid, id, 'suggestion_' + ACTION_STATUS[action], seenGen, ACTION_STATUS[action]);
      return sug;
    });
  }
  async function undo(uid, id, b = {}) {
    const opId = typeof b.operation_id === 'string' ? b.operation_id.slice(0, 80) : null;
    return mutate(uid, id, (ev, st) => {
      if (opId && st.ops['undo:' + opId]) return false;
      // catpaw.proactive.undo.v1 (same as the device's ProactiveUndo): revert the most recent reversible action; a sent
      // SMS is irreversible and kept; status derived from what remains. Nothing reversible → no-op.
      const i = st.taken.findLastIndex(t => !UNDO_IRREVERSIBLE.includes(t.action)); if (i < 0) return false;
      const [removed] = st.taken.splice(i, 1);
      const last = st.taken.at(-1)?.action, offered = (ev.payload.actions ?? []).filter(a => EFFECTS.includes(a)), done = actionStates(st);
      st.status = last === 'snooze' ? 'snoozed' : last === 'dismiss' ? 'dismissed' : (offered.length && offered.every(a => done[a]) ? 'done' : 'pending');
      // Codex PR90d #4: back to snoozed → the remaining (previous) snooze's own until, so it still resurfaces on time.
      if (st.status === 'snoozed') { const prev = st.taken.findLast(t => t.action === 'snooze'); const until = prev?.until ?? (prev && new Date(Date.parse(prev.at) + 10 * 60000).toISOString()); if (until) st.snooze_until = until; else delete st.snooze_until; }
      else delete st.snooze_until;
      st.history.push({ undo: removed.action, at: new Date(now()).toISOString() });
      if (opId) st.ops['undo:' + opId] = true;
      return true;
    });
  }
  async function createFromDevice(uid, b) {
    const cid = typeof b?.client_id === 'string' ? b.client_id.trim().slice(0, 120) : '';
    if (!cid || typeof b.title !== 'string') throw bad('suggestion_invalid');
    const key = 'client:' + cid, decision = ['card', 'notify', 'interrupt'].includes(b.decision) ? b.decision : 'card';
    const created = Date.parse(b.created_at), at = Number.isFinite(created) && created <= now() ? created : now();
    const payload = { decision, delivery: 'device', origin: 'device_offline', client_id: cid, title: b.title.slice(0, 80), why: String(b.reason ?? '').slice(0, 300),
      actions: (Array.isArray(b.actions) ? b.actions : []).filter(a => SUGGESTION_ACTIONS.includes(a)), device_created_at: new Date(at).toISOString(),
      suggestion: { status: 'pending', taken: [], history: [], ops: {} } };
    const ev = await store.insertEvent({ user_id: uid, task_id: null, conversation_id: null, kind: 'proactive_decision', title: payload.title, body: payload.why, payload, dedupe_key: key, push_state: 'skipped' })
      ?? await store.getEventByDedupe(uid, key);
    if (!ev) throw bad('suggestion_write_conflict', 409);
    return { suggestion: toSuggestion(ev), event_id: ev.id, created: ev.payload?.client_id === cid };
  }
  async function load(uid, id) {
    const ev = /^[0-9a-f-]{36}$/i.test(id) && await store.getEvent(uid, id); if (!ev || ev.kind !== 'proactive_decision') throw bad('suggestion_not_found', 404);
    ev.payload.suggestion ??= { status: 'pending', taken: [], history: [], ops: {} }; return ev;
  }
  // S1: Idempotency-Key on POST decision routes. Same key + same request → stored response replayed (header
  // Idempotent-Replayed: true); same key + different request → 422 idempotency_key_reused. Errors are not stored.
  async function route(uid, req, rawPath, url, readBody) {
    const key = req.headers.get('idempotency-key');
    if (req.method !== 'POST' || key === null) return routeInner(uid, req, rawPath, url, readBody);
    if (!/^[\x21-\x7e]{8,200}$/.test(key)) throw bad('idempotency_key_invalid');
    let parsed; const read = async () => (parsed ??= await readBody());
    const reqHash = await signalHash({ type: 'idem', source: rawPath, data: await read() });
    const prior = await store.idemGet(uid, key);
    if (prior) { if (prior.route !== rawPath || prior.request_hash !== reqHash) throw bad('idempotency_key_reused'); return [prior.status, typeof prior.response === 'string' ? JSON.parse(prior.response) : prior.response, { 'idempotent-replayed': 'true' }]; }
    const out = await routeInner(uid, req, rawPath, url, read);
    if (out && out[0] < 300) await store.idemPut(uid, key, { route: rawPath, request_hash: reqHash, status: out[0], response: out[1] });
    return out;
  }
  async function routeInner(uid, req, rawPath, url, readBody) {
    const path = rawPath.replace(/^\/catpaw\/proactive\/v1(?=\/)/, '/proactive');
    if (path === '/proactive/suggestions' && req.method === 'GET') { const st = url.searchParams.get('status'); const rows = (await store.listEvents(uid, null, Math.min(Number(url.searchParams.get('limit')) || 50, 200))).filter(e => e.kind === 'proactive_decision' && e.payload?.decision !== 'silent').reverse().map(toSuggestion); return [200, { suggestions: st ? rows.filter(r => r.status === st) : rows }]; }
    // Codex PR90f #5: offline compensation — a suggestion the device made without the cloud is created here once (dedupe
    // by the device's id), device-owned (never pushed), so its queued actions can then be replayed in order.
    if (path === '/proactive/suggestions' && req.method === 'POST') return [200, await createFromDevice(uid, await readBody())];
    let sm = path.match(/^\/proactive\/suggestions\/([^/]+)\/(action|undo|feedback)$/);
    if (sm && req.method === 'POST') {
      const b = await readBody();
      if (sm[2] === 'action') return [200, { suggestion: await act(uid, sm[1], b) }];
      if (sm[2] === 'undo') return [200, { suggestion: await undo(uid, sm[1], b) }];
      return [200, await feedback(uid, { ...b, event_id: sm[1] })];
    }
    sm = path.match(/^\/proactive\/suggestions\/([^/]+)$/);
    if (sm && req.method === 'GET') return [200, { suggestion: toSuggestion(await load(uid, sm[1])) }];
    if (path === '/proactive/evaluate' && req.method === 'POST') return [200, await evaluate(uid, await readBody())];
    if (path === '/proactive/feedback' && req.method === 'POST') return [200, await feedback(uid, await readBody())];
    if (path === '/proactive/events' && req.method === 'GET') { const rows = await store.listEvents(uid, null, Math.min(Number(url.searchParams.get('limit')) || 50, 200)); return [200, { events: rows.filter(e => e.kind === 'proactive_decision').reverse().map(view) }]; }
    const m = path.match(/^\/proactive\/events\/([0-9a-fA-F-]{36})$/);
    if (m && req.method === 'GET') { const ev = await store.getEvent(uid, m[1]); if (!ev || ev.kind !== 'proactive_decision') throw bad('event_not_found', 404); return [200, { event: view(ev), feedback: (await store.getFeedback(uid, ev.id))?.kind ?? null }]; }
    if (path === '/proactive/weights' && req.method === 'GET') return [200, { weights: await store.getTriggerWeights(uid) }];
    return null;
  }
  return { evaluate, feedback, act, undo, route };
}
/** Client shape (方块 PR #54/#56 ProactiveSuggestion; also the SSE `proactive_suggestion` payload). */
export function toSuggestion(e) {
  const p = e.payload ?? {}, st = p.suggestion ?? { status: 'pending', taken: [] };
  // PR90h #3: server_id = the record a device writes back to; client_id = the device's own id of an offline-created card.
  return { id: e.id, server_id: e.id, ...(p.client_id ? { client_id: p.client_id } : {}), title: p.title ?? e.title, reason: p.why ?? e.body, memories: (p.memories ?? []).map(m => ({ id: m.id, content: m.content })),
    actions: (p.actions ?? []).filter(x => SUGGESTION_ACTIONS.includes(x)), signals: (p.signals ?? []).map(signalView), status: st.status,
    createdAt: e.created_at, taken: st.taken.map(t => ({ action: t.action, at: t.at, ...(t.detail ? { detail: t.detail } : {}), ...(t.until ? { until: t.until } : {}) })),
    action_states: actionStates(st), decision: p.decision, confidence: p.confidence, trigger: p.trigger ?? null };
}
const SIGNAL_KIND = { meeting_upcoming: 'calendar', meeting_conflict: 'calendar', calendar_change: 'calendar', flight_status: 'travel', traffic: 'travel', location: 'location', weather: 'weather', message: 'message', custom: 'custom' };
export function signalView(s) {
  const d = s.data ?? {}; let text;
  if (typeof d.text === 'string') text = d.text;
  else if (s.type === 'meeting_upcoming') text = `${d.title ?? '会议'}${d.minutes_until != null ? ` · ${d.minutes_until} 分钟后` : ''}${d.location ? ` · ${d.location}` : ''}${d.travel_minutes ? ` · 路上约 ${d.travel_minutes} 分钟` : ''}`;
  else if (s.type === 'meeting_conflict') text = `${d.a ?? '会议 A'} 与 ${d.b ?? '会议 B'} 冲突`;
  else if (s.type === 'flight_status') text = `${d.flight ?? '航班'} ${d.status === 'cancelled' ? '取消' : d.delay_minutes ? `延误 ${d.delay_minutes} 分钟` : d.gate_changed ? `登机口 ${d.gate ?? '变更'}` : '正常'}`;
  else if (s.type === 'traffic') text = `路况比平时多 ${d.extra_minutes ?? '?'} 分钟`;
  else text = s.type;
  return { kind: SIGNAL_KIND[s.type] ?? 'custom', text: text.slice(0, 120) };
}
const view = e => ({ id: e.id, created_at: e.created_at, decision: e.payload?.decision, title: e.title, reason: e.body, push_state: e.push_state, action: e.action ?? null, explanation: e.payload ? { ...e.payload, undo: { ...e.payload.undo, body_template: { action: 'dismiss', event_id: e.id } } } : null });
const titleFor = (d, r) => d === 'interrupt' ? '小猫有急事找你' : d === 'notify' ? '小猫提醒' : d === 'card' ? '小猫建议' : '（静默）';
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v)), round = v => Math.round(v * 1000) / 1000;
