// Live text previews for SSE (opt-in `X-Catpaw-Live-Text: 1`). The DB cadence is unchanged: TextBatcher still commits
// text_delta events at 512 chars / 250 ms plus the final flush. This in-process mirror of the same deltas lets the turn's
// own instance push `text_preview` frames to opted-in observers: the first delta of each step immediately, then at most
// one frame per interval (default 100 ms, clamped 80-120 ms).
//
// Replay / offset contract (see IOS-NOTE.md):
// - text_preview is live-only: never stored, never replayed, it does not advance the cursor. Its envelope `sequence`/`cursor`
//   are the last PERSISTED event this stream has delivered (data.base_sequence), so using it as after_sequence is harmless.
// - data.offset is a UTF-16 code-unit index into the assistant message text (message_id) and is never larger than the text
//   carried by the text_delta events with sequence <= base_sequence. data.text is the live text from offset on (cumulative
//   tail, not an increment): display = persisted + text.slice(persisted.length - offset).
// - Persisted text_delta events stay authoritative and unchanged. On turn_completed all text is persisted; on turn_failed /
//   cancel the preview tail is dropped.
export const LIVE_TEXT_HEADER = 'X-Catpaw-Live-Text';
export const LIVE_TEXT_DEFAULT_MS = 100, LIVE_TEXT_MIN_MS = 80, LIVE_TEXT_MAX_MS = 120, LIVE_TEXT_PREVIEW_MAX_CHARS = 4000;
/** CATPAW_SSE_TEXT_INTERVAL_MS → integer ms clamped to 80..120; unset/invalid → 100. */
export function liveTextIntervalMs(value) {
  const s = String(value ?? '').trim(), n = Number(s);
  return s && Number.isFinite(n) ? Math.min(LIVE_TEXT_MAX_MS, Math.max(LIVE_TEXT_MIN_MS, Math.round(n))) : LIVE_TEXT_DEFAULT_MS;
}
const isHigh = c => c >= 0xd800 && c <= 0xdbff;

export class LiveText {
  /** persisted = the turn's existing text_delta events for this message (resume / restart); startSequence = turn.events.length. */
  constructor({ messageID, envelope, persisted = '', startSequence = 0, intervalMs = LIVE_TEXT_DEFAULT_MS, now = Date.now }) {
    Object.assign(this, { messageID, envelope, intervalMs: liveTextIntervalMs(intervalMs), now });
    this.text = persisted; this.checkpoints = [{ sequence: startSequence, chars: persisted.length }];
    this.listeners = new Set(); this.timer = null; this.lastEmit = -Infinity; this.firstInStep = true; this.closed = false; this.emits = 0;
  }
  /** A new model step: its first delta is pushed immediately. */
  startStep() { this.firstInStep = true; }
  push(delta) {
    if (this.closed || typeof delta !== 'string' || !delta) return;
    this.text += delta;
    if (!this.listeners.size) { this.firstInStep = false; return; } // no opted-in observer: no timers
    if (this.firstInStep) { this.firstInStep = false; this.clearTimer(); this.emit(); return; }
    if (this.timer === null) this.timer = setTimeout(() => { this.timer = null; this.emit(); }, Math.max(0, this.lastEmit + this.intervalMs - this.now()));
  }
  /** After a text_delta event committed (same text, same order as push). */
  persisted(sequence, chars) { const last = this.checkpoints.at(-1); if (sequence > last.sequence) this.checkpoints.push({ sequence, chars: last.chars + chars }); }
  /** Persisted chars known to a client that has every event <= sequence; null before the first checkpoint. */
  baseAt(sequence) { let base = null; for (const c of this.checkpoints) { if (c.sequence <= sequence) base = c.chars; else break; } return base; }
  /** Preview for an observer at `sequence` that already received text up to `sentEnd`; null when there is nothing new. */
  preview(sequence, sentEnd = 0) {
    const base = this.baseAt(sequence);
    if (base === null || sequence < 1 || this.text.length <= Math.max(base, sentEnd)) return null;
    let end = Math.min(this.text.length, base + LIVE_TEXT_PREVIEW_MAX_CHARS);
    if (end < this.text.length && isHigh(this.text.charCodeAt(end - 1))) end--;
    if (end <= Math.max(base, sentEnd)) return null;
    return { offset: base, text: this.text.slice(base, end), end };
  }
  event(sequence, p) {
    const e = this.envelope;
    return { schema_version: 1, contract: 'catpaw.native-chat.v1', scope_id: e.scope_id, conversation_id: e.conversation_id, turn_id: e.turn_id, sequence, cursor: `${e.turn_id}:${sequence}`, grant_epoch: e.grant_epoch, model_reality: e.model_reality, type: 'text_preview', data: { message_id: this.messageID, offset: p.offset, text: p.text, base_sequence: sequence, live: true } };
  }
  emit() { this.lastEmit = this.now(); this.emits++; for (const f of this.listeners) try { f(); } catch {} }
  clearTimer() { if (this.timer !== null) { clearTimeout(this.timer); this.timer = null; } }
  close() { this.closed = true; this.clearTimer(); for (const f of this.listeners) try { f(); } catch {} }
}
