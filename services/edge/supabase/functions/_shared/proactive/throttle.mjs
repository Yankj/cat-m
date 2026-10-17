// B2 proactive interruption guard: quiet hours (deferred + coalesced) and a per-user daily push cap.
// User-scheduled reminders (created_by='user', kind reminder_due) are exempt: the user asked for that exact time.
export function parseQuietHours(v, fallback = { start: 22, end: 8 }) {
  if (v === 'off') return null;
  const m = typeof v === 'string' && v.match(/^(\d{1,2})-(\d{1,2})$/);
  if (!m) return fallback;
  const start = Number(m[1]), end = Number(m[2]);
  return start < 24 && end < 24 && start !== end ? { start, end } : fallback;
}
function localParts(ms, tz) {
  let f; try { f = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
  catch { f = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Shanghai', hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
  const p = Object.fromEntries(f.formatToParts(new Date(ms)).map(x => [x.type, x.value]));
  return { y: +p.year, mo: +p.month, d: +p.day, h: +p.hour % 24, mi: +p.minute, s: +p.second };
}
const inWindow = (h, q) => q.start > q.end ? (h >= q.start || h < q.end) : (h >= q.start && h < q.end);
export function isQuiet(ms, tz, q) { return !!q && inWindow(localParts(ms, tz).h, q); }
/** Next instant (ms) when local hour == q.end, i.e. quiet window ends. */
export function quietEndsAt(ms, tz, q) {
  const p = localParts(ms, tz);
  let hoursAhead = (q.end - p.h + 24) % 24 || 24;
  return ms + hoursAhead * 3600_000 - p.mi * 60_000 - p.s * 1000 - (ms % 1000);
}
/** Start of the local calendar day containing ms (approximate across DST, good enough for a cap). */
export function localDayStart(ms, tz) { const p = localParts(ms, tz); return ms - (p.h * 3600 + p.mi * 60 + p.s) * 1000 - (ms % 1000); }
export function isExempt(ev) { return ev.kind === 'reminder_due' && ev.payload?.created_by === 'user'; }
