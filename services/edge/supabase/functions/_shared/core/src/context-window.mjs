// v1.1.x context window (PLAN.md Rev 2). Deterministic, no model call, no route change.
// - model_messages keeps the exact v52 shape. Turn boundaries live in a parallel server-only conversation.model_message_meta
//   (aligned by index, bound by length + hash), so a rollback to v52 needs no stripping and adapters never see markers.
// - The window is cut only at real user turns. Its visible size follows the consented route wording exactly
//   ("本对话最近最多40条文本（80kB）", config.mjs data_fields conversation_text_history_max_40_messages_80kB), so route_hash is unchanged.
// - Over-budget order: (1) elide old tool results, (2) shrink the window by whole turns, (3) 413 conversation_too_long.
//   The current turn is never dropped.
// - Full history is kept: admission freezes window start + a hash of the pre-window prefix; complete() writes back
//   prefix + window + new messages after verifying it (mergeModelMessages), never a truncated history.
import { Buffer } from 'node:buffer';
import { check, hash, ApiError } from '../facade-r2/src/common.mjs';

export const CONTEXT_LIMITS = Object.freeze({
  window_max_visible_messages: 40,     // consented route: history_limit 40
  window_max_visible_bytes: 80000,     // consented route: 80 kB, measured like the old JSON(history) check
  history_budget_tokens: 40000,        // estimated tokens of the window sent to the model
  request_budget_tokens: 120000,       // window + reservations (system prompt, tools, memory, explicit context)
  system_reserve_tokens: 8000,         // chat prompt, device/UI prompts, tool schemas
  memory_reserve_tokens: 4000,         // agent-memory prompt (pinned <=1,500 tokens + top-k 6) and memory_usage
  old_tool_result_max_tokens: 1000,    // older tool results above this are elided in the sent window
  storage_max_visible_messages: 200,   // stored conversation (was a hard 40/80 kB wall)
  storage_max_visible_bytes: 300000,
  storage_max_model_bytes: 1500000,
});
/** Added to the system prompt only when earlier turns were left out of the window. */
export const WINDOW_NOTE = '\nOnly the most recent part of this conversation is included above. If the user refers to something earlier that you cannot see, say so and ask them to repeat it; do not guess, and do not redo actions (reminders, events, tasks) the user may already have confirmed earlier.';
/** Conservative token estimate: CJK/fullwidth = 1 token per char, everything else ~3.5 UTF-8 bytes per token. */
export function estimateTokens(value) {
  const s = typeof value === 'string' ? value : value == null ? '' : JSON.stringify(value);
  let cjk = 0, other = 0;
  for (const ch of s) { const c = ch.codePointAt(0); if ((c >= 0x2e80 && c <= 0x9fff) || (c >= 0xac00 && c <= 0xd7af) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0xff00 && c <= 0xffef) || (c >= 0x20000 && c <= 0x2fa1f)) cjk++; else other += Buffer.byteLength(ch); }
  return cjk + Math.ceil(other / 3.5);
}
const messageTokens = m => 4 + estimateTokens(m?.content) + (m?.tool_calls ? estimateTokens(m.tool_calls) : 0);

// Turn markers live OUTSIDE model_messages (rollback-safe: model_messages keeps the exact v52 shape, v52 ignores the extra field).
// conversation.model_message_meta = {schema:1, length, hash, entries}; entries[i] aligns with model_messages[i]:
// null for non-user entries, {turn_id, visible} for user entries (visible:false = synthetic, e.g. the revision payload).
// length + hash bind the meta to the exact model_messages it describes; a v52 write (rollback, then roll-forward) or any other
// drift makes it invalid, and resolveMeta() recomputes it from the user-visible messages or falls back to "one window".
export const META_SCHEMA = 1;
export const metaFor = (messages, entries) => ({ schema: META_SCHEMA, length: messages.length, hash: hash(messages), entries });
export const metaValid = (meta, messages) => !!meta && meta.schema === META_SCHEMA && Array.isArray(meta.entries) && meta.length === messages.length && meta.entries.length === messages.length && meta.hash === hash(messages);
const userEntry = (turnID, visible) => ({ turn_id: turnID ?? null, visible: visible === true });

const isRevisionPayload = m => { if (typeof m?.content !== 'string' || !m.content.startsWith('{')) return false; try { const v = JSON.parse(m.content); return v && typeof v === 'object' && Object.hasOwn(v, 'selected_report') && Object.hasOwn(v, 'instruction'); } catch { return false; } };
/** Legacy rule for rows without valid meta: every user entry except the synthetic revision payload starts a real turn. */
export const isLegacyBoundary = m => m?.role === 'user' && !isRevisionPayload(m);

/**
 * Meta for the stored model history (before the new user entry is appended).
 * stored → the record's meta is valid for these exact messages;
 * recomputed → legacy rule, accepted only if it yields exactly one boundary per user-visible user message;
 * none → boundaries unknown (entries all null): packWindow treats the history as one window.
 */
export function resolveMeta(models, meta, visibleMessages) {
  if (metaValid(meta, models)) return { entries: meta.entries, source: 'stored' };
  const entries = models.map(m => m?.role === 'user' ? userEntry(null, isLegacyBoundary(m)) : null);
  const derived = entries.filter(e => e?.visible).length, visible = (visibleMessages ?? []).filter(m => m?.role === 'user').length;
  if (derived === visible) return { entries, source: 'recomputed' };
  return { entries: models.map(() => null), source: 'none' };
}
export const boundariesOf = entries => entries.reduce((a, e, i) => (e?.visible === true && a.push(i), a), []);

const elided = tokens => JSON.stringify({ status: 'elided', reason: 'older_tool_result_omitted_to_save_context', original_tokens_estimate: tokens, note: 'This older tool result was omitted. Call the tool again if you need the details.' });
/** Older tool results (before currentStart) above the cap become a short placeholder. Current-turn results are never touched. */
export function elideOldToolResults(window, currentStart, cap = CONTEXT_LIMITS.old_tool_result_max_tokens) {
  return window.map((m, i) => { if (i >= currentStart || m?.role !== 'tool') return m; const t = estimateTokens(m.content); return t > cap ? { ...m, content: elided(t) } : m; });
}

/** Storage caps (replaces the old 422 history_limit_reached at 40 messages / 80 kB). */
export function assertStorageLimits(history, full, limits = CONTEXT_LIMITS) {
  check(history.length <= limits.storage_max_visible_messages && Buffer.byteLength(JSON.stringify(history)) <= limits.storage_max_visible_bytes && Buffer.byteLength(JSON.stringify(full)) <= limits.storage_max_model_bytes, 413, 'conversation_too_long');
}

/**
 * Choose the window. full = stored model history including the new user entry at the end; entries = its aligned meta entries;
 * history = visible messages including the new user message; extraTokens = explicit context etc. counted on top of reservations.
 * Returns {start, window, prefix_hash, kept_turns, estimated_tokens, elided}.
 */
export function packWindow({ full, entries, history, extraTokens = 0, limits = CONTEXT_LIMITS }) {
  check(Array.isArray(entries) && entries.length === full.length, 500, 'context_window_invalid');
  let bounds = boundariesOf(entries);
  check(bounds.length > 0 && bounds.at(-1) === full.length - 1, 500, 'context_window_invalid');
  // Unknown boundaries (meta "none"): the only safe cuts are "everything" and "current turn only".
  if (bounds.length === 1 && full.length > 1) bounds = [0, ...bounds];
  const userIdx = history.reduce((a, m, i) => (m?.role === 'user' && a.push(i), a), []);
  const reserve = limits.system_reserve_tokens + limits.memory_reserve_tokens + extraTokens;
  let best = null;
  for (let k = 1; k <= bounds.length; k++) {
    const start = bounds[bounds.length - k], raw = full.slice(start), currentStart = full.length - 1 - start;
    const window = elideOldToolResults(raw, currentStart, limits.old_tool_result_max_tokens);
    const tokens = window.reduce((n, m) => n + messageTokens(m), 0);
    const vs = start === 0 ? 0 : userIdx.length ? userIdx[Math.max(0, userIdx.length - k)] : Math.max(0, history.length - 1), visible = history.slice(vs);
    const fits = visible.length <= limits.window_max_visible_messages && Buffer.byteLength(JSON.stringify(visible)) <= limits.window_max_visible_bytes
      && tokens <= limits.history_budget_tokens && tokens + reserve <= limits.request_budget_tokens;
    if (k === 1) {
      // The current turn is never dropped; only the whole-request budget can refuse it.
      check(tokens + reserve <= limits.request_budget_tokens, 413, 'conversation_too_long');
      best = { start, window, tokens };
      continue;
    }
    if (!fits) break;
    best = { start, window, tokens };
  }
  return { start: best.start, window: best.window, prefix_hash: hash(full.slice(0, best.start)), full_length: full.length, kept_turns: bounds.filter(b => b >= best.start).length, estimated_tokens: best.tokens + reserve, elided: best.window.filter((m, i) => m !== full[best.start + i]).length };
}

/**
 * Write-back for complete(): stored = c.model_messages (full, frozen at admission), messages = the loop's messages, which start
 * with turn.model_history (the sent window, possibly elided). Verifies the frozen prefix under the conversation lock and returns
 * {messages: stored + the turn's new entries, meta}. New user entries in a turn are synthetic (the real one was admitted).
 * Legacy turns (admitted before this change, no window fields) keep the old behaviour and drop the meta (recomputed next turn).
 */
export function mergeModelMessages(stored, storedMeta, turn, messages) {
  if (!Number.isInteger(turn?.model_window_start)) return { messages, meta: undefined };
  const base = stored ?? [];
  if (base.length !== turn.model_full_length || hash(base.slice(0, turn.model_window_start)) !== turn.model_prefix_hash) throw new ApiError(409, 'model_history_conflict');
  const sent = turn.model_history?.length ?? 0;
  check(messages.length >= sent, 409, 'model_history_conflict');
  const added = messages.slice(sent), merged = [...base, ...added];
  const baseEntries = metaValid(storedMeta, base) ? storedMeta.entries : base.map(() => null);
  return { messages: merged, meta: metaFor(merged, [...baseEntries, ...added.map(m => m?.role === 'user' ? userEntry(turn.id, false) : null)]) };
}

/**
 * model_history_conflict (complete() could not merge under the conversation lock): the failed turn's admitted user message is
 * taken back out of the stored conversation in the same locked write that records turn_failed, so the client's resend (a NEW turn
 * with the same text) neither shows a duplicate nor counts twice against the storage caps. Visible: the message with the turn's
 * message id. Model side: the entry only when it is provably this turn's (valid meta → entry {turn_id, visible:true} whose content
 * equals the admitted entry; no valid meta → the LAST entry when it equals the admitted entry; meta then dropped and recomputed
 * next turn). Otherwise model_messages is left alone (never guessed). model_messages keeps the v52 shape; no revision bump, so the
 * resend's expected_revision is still the one GET returns. Returns null when there is nothing to remove.
 */
export function withoutFailedTurnUser(c, t) {
  const mid = t?.input?.message?.id, admitted = t?.model_history?.at?.(-1);
  if (!c || !Array.isArray(c.messages)) return null;
  const messages = mid ? c.messages.filter(m => !(m?.id === mid && m.role === 'user')) : c.messages;
  let model_messages = c.model_messages, model_message_meta = c.model_message_meta, modelRemoved = false;
  if (Array.isArray(model_messages) && admitted?.role === 'user') {
    const same = m => m?.role === 'user' && hash(m) === hash(admitted);
    if (metaValid(model_message_meta, model_messages)) {
      const idx = model_message_meta.entries.reduce((a, e, i) => (e?.turn_id === t.id && e.visible === true && a.push(i), a), []);
      if (idx.length === 1 && same(model_messages[idx[0]])) {
        const keep = (_, i) => i !== idx[0], kept = model_messages.filter(keep);
        model_messages = kept; model_message_meta = metaFor(kept, model_message_meta.entries.filter(keep)); modelRemoved = true;
      }
    } else if (same(model_messages.at(-1))) { model_messages = model_messages.slice(0, -1); model_message_meta = undefined; modelRemoved = true; }
  }
  if (messages.length === c.messages.length && !modelRemoved) return null;
  return { conversation: { ...c, messages, model_messages, model_message_meta }, visible_removed: messages.length !== c.messages.length, model_removed: modelRemoved };
}

/** Admission: full history + new user entry, with aligned meta. */
export function admitModelHistory(c, userMessage, turnID) {
  const models = c.model_messages ?? c.messages.map(({ id, ...m }) => m), resolved = resolveMeta(models, c.model_message_meta, c.messages);
  const full = [...models, userMessage], entries = [...resolved.entries, userEntry(turnID, true)];
  return { full, entries, meta: metaFor(full, entries), meta_source: resolved.source };
}

/** GET …/conversations/{id}: model-side history (tool results, server markers) and future v1.2 summary/ledger stay server-side. */
export function projectConversation(c) { if (!c || typeof c !== 'object') return c; const { model_messages, model_message_meta, context_summary, context_ledger, ...rest } = c; return rest; }
