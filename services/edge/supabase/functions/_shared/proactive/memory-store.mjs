// In-memory store with the same semantics as pg-store (tests / local dev).
const need = g => { if (g == null) throw new Error('generation_required'); };
export function createMemoryStore() {
  const LEASE_MS = 15 * 60 * 1000; /* = SQL claim_due_reminders lease (20261023100000) */ const tasks = new Map(), occ = new Map(), events = [], tokens = []; let seq = 0; const idem = new Map(), sig = new Map(), weights = new Map(), feedback = new Map();
  const id = () => crypto.randomUUID(), c = v => structuredClone(v);
  return {
    _dump: () => ({ tasks: [...tasks.values()], events, tokens }),
    async createTask(uid, t) {
      for (const r of tasks.values()) if (r.user_id === uid && r.operation_id === t.operation_id) return { row: c(r), created: false };
      const ts = new Date().toISOString();
      const row = { id: id(), user_id: uid, notes: null, snooze_until: null, revision: 1, created_at: ts, updated_at: ts, ...t };
      tasks.set(row.id, row); return { row: c(row), created: true };
    },
    async getTask(uid, tid) { const r = tasks.get(tid); return r && r.user_id === uid ? c(r) : null; },
    async listTasks(uid, { status, limit }) { return [...tasks.values()].filter(r => r.user_id === uid && (status === 'all' || r.status === status)).sort((a, b) => (a.due_at ?? '9').localeCompare(b.due_at ?? '9')).slice(0, limit).map(c); },
    async updateTask(uid, tid, f, rev) { const r = tasks.get(tid); if (!r || r.user_id !== uid || r.revision !== rev) return null; Object.assign(r, f, { revision: r.revision + 1, updated_at: new Date().toISOString() }); return c(r); },
    // M1 REM-01/02: an occurrence claim is a lease. A claim abandoned by a lost worker becomes claimable again after
    // LEASE_MS; generated occurrences never are. Expired leases are filtered BEFORE the limit so they cannot starve later rows.
    async claimDue(nowIso, limit) {
      const out = [], nowMs = Date.parse(nowIso);
      const free = r => { const o = occ.get(r.id + '|' + r.next_fire_at); return !o || (o.state === 'claimed' && nowMs - o.at >= LEASE_MS); };
      for (const r of [...tasks.values()].filter(r => ['open', 'snoozed'].includes(r.status) && r.next_fire_at && r.next_fire_at <= nowIso && free(r)).sort((a, b) => a.next_fire_at.localeCompare(b.next_fire_at)).slice(0, limit)) {
        occ.set(r.id + '|' + r.next_fire_at, { state: 'claimed', at: nowMs });
        out.push({ task_id: r.id, user_id: r.user_id, conversation_id: r.conversation_id, title: r.title, notes: r.notes, due_at: r.due_at, time_zone: r.time_zone, recurrence: r.recurrence, scheduled_at: r.next_fire_at, fire_count: r.fire_count });
      }
      return out;
    },
    // M1 REM-04/05/06: a failed fire releases the claim and keeps the due, instead of discarding it.
    async releaseOccurrence(cl) { const k = cl.task_id + '|' + cl.scheduled_at, o = occ.get(k); if (o && o.state === 'claimed') occ.delete(k); },
    async finishOccurrence(cl, f) { const r = tasks.get(cl.task_id); if (!r || r.next_fire_at !== cl.scheduled_at) return; occ.set(cl.task_id + '|' + cl.scheduled_at, { state: 'generated', at: 0 }); Object.assign(r, f, { snooze_until: null, revision: r.revision + 1 }); if (f.next_fire_at && r.recurrence) r.due_at = f.next_fire_at === null ? r.due_at : r.due_at; },
    async insertEvent(ev) { if (ev.kind === 'reminder_due' && ev.task_id) { const t = tasks.get(ev.task_id); if (!t || !['open', 'snoozed'].includes(t.status) || t.next_fire_at !== ev.payload?.scheduled_at) return null; } if (events.some(e => e.user_id === ev.user_id && e.dedupe_key === ev.dedupe_key)) return null; const row = { id: id(), push_state: 'pending', push_error: null, read_at: null, created_at: new Date(Date.now() + seq++).toISOString(), ...ev }; events.push(row); return c(row); },
    async listEvents(uid, after, limit) { return events.filter(e => e.user_id === uid && (!after || e.created_at > after)).slice(-limit).map(c); },
    async getEvent(uid, eid) { const e = events.find(e => e.id === eid && e.user_id === uid); return e ? c(e) : null; },
    async recordPushAction(uid, eid, action, at) { const e = events.find(e => e.id === eid && e.user_id === uid); if (!e || e.action) return false; e.action = action; e.opened_at ??= at; e.read_at ??= at; return true; },
    async seenSignalHashes(uid, hashes, sinceIso) { return hashes.filter(h => (sig.get(uid + '|' + h) ?? '') > sinceIso); },
    async markSignalHashes(uid, hashes, atIso) { for (const h of hashes) sig.set(uid + '|' + h, atIso); },
    async getTriggerWeights(uid) { return c(weights.get(uid) ?? {}); },
    async setTriggerWeight(uid, t, w) { const m = weights.get(uid) ?? {}; m[t] = { ...w }; weights.set(uid, m); },
    // v10 P1-1: the cap counts distinct meetings (first signal_hash; rows without one count individually), and a meeting
    // in excludeHashes (the request being judged) never counts against itself.
    async countDecisionsForDay(uid, startIso, endIso, levels, excludeHashes = []) { const keys = new Set(); for (const e of events) { if (e.user_id !== uid || e.kind !== 'proactive_decision' || !levels.includes(e.payload?.decision)) continue; const t = Date.parse(e.payload?.deliver_at ?? e.created_at); if (!(t >= Date.parse(startIso) && t < Date.parse(endIso))) continue; const h = e.payload?.signals?.[0]?.signal_hash; if (h && excludeHashes.includes(h)) continue; keys.add(h ?? 'id:' + e.id); } return keys.size; },
    // v10 P1-2: newest delivered (non-silent) decision since sinceIso that carried one of these signal hashes.
    async lastDecisionForHashes(uid, hashes, sinceIso) { const m = events.filter(e => e.user_id === uid && e.kind === 'proactive_decision' && e.payload?.decision !== 'silent' && (e.payload?.evaluated_at ?? e.created_at) > sinceIso && (e.payload?.signals ?? []).some(s => hashes.includes(s.signal_hash))); return m.length ? c(m[m.length - 1]) : null; },
    async countDecisionsSince(uid, sinceIso, levels) { return events.filter(e => e.user_id === uid && e.kind === 'proactive_decision' && levels.includes(e.payload?.decision) && e.created_at >= sinceIso).length; },
    async getFeedback(uid, eid) { return feedback.get(uid + '|' + eid) ?? null; },
    async insertFeedback(uid, eid, kind, at) { const k = uid + '|' + eid; if (feedback.has(k)) return false; feedback.set(k, { kind, created_at: at }); return true; },
    async updateEventPayload(uid, eid, payload, expectedRev) { const e = events.find(e => e.id === eid && e.user_id === uid); if (!e) return null; if (expectedRev !== undefined && (e.payload?.suggestion?.rev ?? 0) !== expectedRev) return null; e.payload = c(payload); return c(e); },
    async claimSuggestionsForChat(uid, { limit, at, conversationID, turnID }) {
      const out = [];
      for (const e of events) {
        if (out.length >= limit) break;
        const st = e.payload?.suggestion;
        if (e.user_id !== uid || e.kind !== 'proactive_decision' || e.payload.decision === 'silent' || st?.status !== 'pending' || st.chat_delivered_at) continue;
        st.chat_delivered_at = at; st.chat_turn_id = turnID; st.rev = (st.rev ?? 0) + 1; out.push(c(e));
      }
      return out;
    },
    async resurfaceSnoozed(nowIso) {
      const out = [];
      for (const e of events) { const st = e.payload?.suggestion; if (e.kind === 'proactive_decision' && st?.status === 'snoozed' && st.snooze_until && st.snooze_until <= nowIso) { st.status = 'pending'; st.resurfaced_at = nowIso; st.rev = (st.rev ?? 0) + 1; delete st.snooze_until; delete st.chat_delivered_at; if (['notify', 'interrupt'].includes(e.payload.decision) && e.payload.delivery === 'remote') { e.push_state = 'pending'; e.push_after = null; e.push_generation = (e.push_generation ?? 0) + 1; e.push_claim = null; e.push_attempts = 0; } out.push(e.id); } }
      return out;
    },
    async idemGet(uid, key) { return idem.get(uid + '|' + key) ?? null; },
    async idemPut(uid, key, rec) { const k = uid + '|' + key; if (idem.has(k)) return false; idem.set(k, c(rec)); return true; },
    async markRead(uid, eid, at) { const e = events.find(e => e.id === eid && e.user_id === uid); if (!e) return false; e.read_at ??= at; return true; },
    async pendingPushEvents(limit, nowIso) { const r = events.filter(e => e.push_state === 'pending' && (e.push_attempts ?? 0) < 5 && (!e.push_after || !nowIso || e.push_after <= nowIso)).slice(0, limit); for (const e of r) { e.push_attempts = (e.push_attempts ?? 0) + 1; e.push_generation ??= 0; } return r.map(c); },
    async deferPush(eid, until, generation) { need(generation); const e = events.find(e => e.id === eid); if (!e || e.push_state !== 'pending' || (e.push_generation ?? 0) !== generation) return; e.push_after = until; e.push_attempts = Math.max((e.push_attempts ?? 0) - 1, 0); },
    async countPushedSince(uid, sinceIso) { return events.filter(e => e.user_id === uid && e.push_state === 'sent' && (e.pushed_at ?? e.created_at) >= sinceIso).length; },
    // PR90h #1: bound to the generation (and suggestion status) the action saw — a cancel arriving after a resurface is a no-op.
    async cancelPendingPush(uid, eid, reason, generation, status = null) { need(generation); const e = events.find(e => e.id === eid && e.user_id === uid && e.push_state === 'pending'); if (!e || (e.push_generation ?? 0) !== generation || (status != null && e.payload?.suggestion?.status !== status)) return; e.push_state = 'skipped'; e.push_error = reason; },
    // Pre-claim dispositions only (skipped / no_device / …): never touches a claimed or finished row.
    async setPush(eid, state, err, generation) { need(generation); const e = events.find(e => e.id === eid); if (!e || e.push_state !== 'pending' || (e.push_generation ?? 0) !== generation) return; e.push_state = state; e.push_error = err; if (state === 'sent') e.pushed_at = new Date().toISOString(); },
    // Codex PR90f #4: send licence = claim token for the current generation.
    async claimPush(eid, nowIso = new Date().toISOString(), generation) { need(generation); const e = events.find(e => e.id === eid); if (!e || e.push_state !== 'pending' || (e.push_generation ?? 0) !== generation || (e.payload?.suggestion?.status ?? 'pending') !== 'pending') return null; e.push_state = 'sending'; e.push_claim = crypto.randomUUID(); e.push_claimed_at = nowIso; e.push_attempted_at = null; e.push_generation ??= 0; return { claim: e.push_claim, generation: e.push_generation }; },
    async markPushAttempt(eid, claim, nowIso = new Date().toISOString()) { const e = events.find(e => e.id === eid); if (!claim || !e || e.push_state !== 'sending' || e.push_claim !== claim || (e.payload?.suggestion?.status ?? 'pending') !== 'pending') return false; e.push_attempted_at = nowIso; return true; },
    async finishPush(eid, claim, state, err, nowIso = new Date().toISOString()) { const e = events.find(e => e.id === eid); if (!e || e.push_state !== 'sending' || !claim || e.push_claim !== claim) return false; e.push_state = state; e.push_error = err; e.push_claim = null; if (state === 'sent') e.pushed_at = nowIso; return true; },
    async recoverStalePush(nowIso, leaseSeconds) { let n = 0; const cut = new Date(Date.parse(nowIso) - leaseSeconds * 1000).toISOString(); for (const e of events) if (e.push_state === 'sending' && (!e.push_claimed_at || e.push_claimed_at < cut)) { const unknown = !!e.push_attempted_at; e.push_state = unknown ? 'failed' : 'pending'; if (unknown) e.push_error = 'outcome_unknown'; e.push_attempts = 0; e.push_recovered = unknown ? 'unknown' : 'unsent'; e.push_generation = (e.push_generation ?? 0) + 1; e.push_claim = null; e.push_claimed_at = null; n++; } return n; },
    async getEventByDedupe(uid, key) { const e = events.find(e => e.user_id === uid && e.dedupe_key === key); return e ? c(e) : null; },
    async tokensFor(uid) { return tokens.filter(t => t.user_id === uid).map(c); },
    async upsertToken(uid, t) { let r = tokens.find(x => x.user_id === uid && x.device_id === t.device_id && x.kind === t.kind && (x.activity_id ?? '') === (t.activity_id ?? '')); if (r) Object.assign(r, t, { enabled: true, last_error: null }); else { r = { id: id(), user_id: uid, enabled: true, last_error: null, ...t }; tokens.push(r); } return c(r); },
    async deleteToken(uid, dev, kind) { let n = 0; for (let i = tokens.length - 1; i >= 0; i--) if (tokens[i].user_id === uid && tokens[i].device_id === dev && (!kind || tokens[i].kind === kind)) { tokens.splice(i, 1); n++; } return n; },
    async disableToken(tid, reason) { const t = tokens.find(t => t.id === tid); if (t) { t.enabled = false; t.last_error = reason; } },
  };
}
