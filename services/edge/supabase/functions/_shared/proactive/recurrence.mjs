// Recurrence: wall-clock aware (daily/weekly/monthly keep local time in task time_zone), or fixed interval.
export const FREQS = ['daily', 'weekly', 'monthly', 'interval'];
export function validateRecurrence(r) {
  if (r === null || r === undefined) return null;
  if (typeof r !== 'object' || Array.isArray(r)) throw bad('recurrence_invalid');
  const allowed = ['freq', 'interval', 'interval_seconds', 'until', 'count'];
  for (const k of Object.keys(r)) if (!allowed.includes(k)) throw bad('recurrence_invalid');
  if (!FREQS.includes(r.freq)) throw bad('recurrence_invalid');
  const out = { freq: r.freq };
  if (r.freq === 'interval') {
    if (!Number.isInteger(r.interval_seconds) || r.interval_seconds < 300 || r.interval_seconds > 31 * 86400) throw bad('recurrence_invalid');
    out.interval_seconds = r.interval_seconds;
  } else {
    const n = r.interval ?? 1;
    if (!Number.isInteger(n) || n < 1 || n > 365) throw bad('recurrence_invalid');
    out.interval = n;
  }
  if (r.until != null) { if (!Number.isFinite(Date.parse(r.until))) throw bad('recurrence_invalid'); out.until = new Date(r.until).toISOString(); }
  if (r.count != null) { if (!Number.isInteger(r.count) || r.count < 1 || r.count > 1000) throw bad('recurrence_invalid'); out.count = r.count; }
  return out;
}
export function bad(code, status = 422) { const e = new Error(code); e.code = code; e.status = status; return e; }

function localParts(ms, tz) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
    .formatToParts(new Date(ms)).filter(x => x.type !== 'literal').map(x => [x.type, Number(x.value)]));
  return p;
}
// convert a local wall time in tz to UTC ms (iterative offset fix; handles DST)
export function zonedToUtc(y, mo, d, h, mi, s, tz) {
  let guess = Date.UTC(y, mo - 1, d, h, mi, s);
  for (let i = 0; i < 3; i++) {
    const p = localParts(guess, tz);
    const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
    const diff = asUtc - Date.UTC(y, mo - 1, d, h, mi, s);
    if (diff === 0) break;
    guess -= diff;
  }
  return guess;
}
/** Next occurrence strictly after `afterMs`, given anchor due_at. Returns ISO or null. firedCount = occurrences already fired. */
export function nextOccurrence(dueAtIso, recurrence, tz, afterMs, firedCount = 0) {
  if (!recurrence) return null;
  if (recurrence.count != null && firedCount >= recurrence.count) return null;
  const anchor = Date.parse(dueAtIso);
  let next;
  if (recurrence.freq === 'interval') {
    const step = recurrence.interval_seconds * 1000;
    const k = Math.max(1, Math.floor((afterMs - anchor) / step) + 1);
    next = anchor + k * step;
  } else {
    const a = localParts(anchor, tz);
    const n = recurrence.interval;
    for (let k = 1; k < 5000; k++) {
      let y = a.year, mo = a.month, d = a.day;
      if (recurrence.freq === 'daily') { const t = new Date(Date.UTC(y, mo - 1, d + k * n)); y = t.getUTCFullYear(); mo = t.getUTCMonth() + 1; d = t.getUTCDate(); }
      else if (recurrence.freq === 'weekly') { const t = new Date(Date.UTC(y, mo - 1, d + 7 * k * n)); y = t.getUTCFullYear(); mo = t.getUTCMonth() + 1; d = t.getUTCDate(); }
      else { const total = (mo - 1) + k * n; y = a.year + Math.floor(total / 12); mo = (total % 12) + 1; const last = new Date(Date.UTC(y, mo, 0)).getUTCDate(); d = Math.min(a.day, last); }
      const c = zonedToUtc(y, mo, d, a.hour, a.minute, a.second, tz);
      if (c > afterMs) { next = c; break; }
    }
  }
  if (next == null) return null;
  if (recurrence.until && next > Date.parse(recurrence.until)) return null;
  return new Date(next).toISOString();
}
