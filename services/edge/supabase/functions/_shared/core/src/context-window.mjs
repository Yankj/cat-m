// v1.1.x context window (PLAN.md Rev 2). Deterministic, no model call, no route change.
// - Every user entry written into conversation.model_messages at admission carries server-only markers:
//   `_turn_id` and `_visible` (true on the real user message, false on synthetic user entries such as the revision payload).
//   stripMarkers() removes every `_`-prefixed key; the chat loop and every provider adapter call it before sending.
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
export const TURN_MARK = '_turn_id', VISIBLE_MARK = '_visible';

/** Conservative token estimate: CJK/fullwidth = 1 token per char, everything else ~3.5 UTF-8 bytes per token, +4 per message. */
export function estimateTokens(value) {
  const s = typeof value === 'string' ? value : value == null ? '' : JSON.stringify(value);
  let cjk = 0, other = 0;
  for (const ch of s) { const c = ch.codePointAt(0); if ((c >= 0x2e80 && c <= 0x9fff) || (c >= 0xac00 && c <= 0xd7af) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0xff00 && c <= 0xffef) || (c >= 0x20000 && c <= 0x2fa1f)) cjk++; else other += Buffer.byteLength(ch); }
  return cjk + Math.ceil(other / 3.5);
}
const messageTokens = m => 4 + estimateTokens(m?.content) + (m?.tool_calls ? estimateTokens(m.tool_calls) : 0);

/** Remove server-only markers (every own key starting with "_") from a message list. Never mutates the input. */
export function stripMarkers(messages) {
  return (messages ?? []).map(m => { if (!m || typeof m !== 'object' || Array.isArray(m)) return m; let out = null; for (const k of Object.keys(m)) if (k.startsWith('_')) { out ??= { ...m }; delete out[k]; } return out ?? m; });
}
export const markUser = (message, turnID, visible) => ({ ...message, [TURN_MARK]: turnID, [VISIBLE_MARK]: visible === true });

const isRevisionPayload = m => { if (typeof m?.content !== 'string' || !m.content.startsWith('{')) return false; try { const v = JSON.parse(m.content); return v && typeof v === 'object' && Object.hasOwn(v, 'selected_report') && Object.hasOwn(v, 'instruction'); } catch { return false; } };
/** A real user turn starts here. Legacy (unmarked) rows: every user entry except the synthetic revision payload. */
export function isTurnBoundary(m) {
  if (m?.role !== 'user') return false;
  if (Object.hasOwn(m, VISIBLE_MARK)) return m[VISIBLE_MARK] === true;
  return !isRevisionPayload(m);
}
export const turnBoundaries = messages => messages.reduce((a, m, i) => (isTurnBoundary(m) && a.push(i), a), []);

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
 * Choose the window. full = stored model history including the new (marked) user entry at the end;
 * history = visible messages including the new user message; extraTokens = explicit context etc. counted on top of reservations.
 * Returns {start, window, prefix_hash, kept_turns, estimated_tokens, elided}.
 */
export function packWindow({ full, history, extraTokens = 0, limits = CONTEXT_LIMITS }) {
  const bounds = turnBoundaries(full);
  check(bounds.length > 0 && bounds.at(-1) === full.length - 1, 500, 'context_window_invalid');
  const userIdx = history.reduce((a, m, i) => (m?.role === 'user' && a.push(i), a), []);
  const reserve = limits.system_reserve_tokens + limits.memory_reserve_tokens + extraTokens;
  let best = null;
  for (let k = 1; k <= bounds.length; k++) {
    const start = bounds[bounds.length - k], raw = full.slice(start), currentStart = full.length - 1 - start;
    const window = elideOldToolResults(raw, currentStart, limits.old_tool_result_max_tokens);
    const tokens = window.reduce((n, m) => n + messageTokens(m), 0);
    const vs = userIdx.length ? userIdx[Math.max(0, userIdx.length - k)] : Math.max(0, history.length - 1), visible = history.slice(vs);
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
  return { start: best.start, window: best.window, prefix_hash: hash(full.slice(0, best.start)), full_length: full.length, kept_turns: turnBoundaries(full.slice(best.start)).length, estimated_tokens: best.tokens + reserve, elided: best.window.filter((m, i) => m !== full[best.start + i]).length };
}

/**
 * Write-back for complete(): stored = c.model_messages (full, frozen at admission), messages = the loop's messages, which start
 * with turn.model_history (the sent window, possibly elided). Verifies the frozen prefix under the conversation lock and returns
 * stored + the turn's new entries. Legacy turns (admitted before this change, no window fields) keep the old behaviour.
 */
export function mergeModelMessages(stored, turn, messages) {
  if (!Number.isInteger(turn?.model_window_start)) return messages;
  const base = stored ?? [];
  if (base.length !== turn.model_full_length || hash(base.slice(0, turn.model_window_start)) !== turn.model_prefix_hash) throw new ApiError(409, 'model_history_conflict');
  const sent = turn.model_history?.length ?? 0;
  check(messages.length >= sent, 409, 'model_history_conflict');
  return [...base, ...messages.slice(sent)];
}

/** GET …/conversations/{id}: model-side history (tool results, server markers) and future v1.2 summary/ledger stay server-side. */
export function projectConversation(c) { if (!c || typeof c !== 'object') return c; const { model_messages, context_summary, context_ledger, ...rest } = c; return rest; }
