// catpaw.connectors.gmail.extract.v1 — pure, deterministic schedule-item extraction from already-fetched Gmail messages.
// No I/O, no model call. The optional model pass (see docs/connectors/gmail-v1.1.md §6) must go through assertConsent + route checks
// and only refines candidates produced here; this function alone is enough for invites (text/calendar) and common patterns.
export const EXTRACT_SCHEMA_VERSION = 'gmail-schedule-item.v1';
export const ITEM_KINDS = ['meeting', 'flight', 'deadline', 'appointment'];
const MAX_BODY = 20000;

const header = (msg, name) => {
  const h = (msg?.payload?.headers ?? msg?.headers ?? []).find(x => String(x?.name).toLowerCase() === name.toLowerCase());
  return h ? String(h.value ?? '') : '';
};

/** Unfold + parse the first VEVENT of an iCalendar body. Returns null when absent/invalid. */
export function parseICS(text) {
  if (typeof text !== 'string' || !/BEGIN:VEVENT/.test(text)) return null;
  const lines = text.replace(/\r\n[ \t]/g, '').replace(/\n[ \t]/g, '').split(/\r?\n/);
  const ev = {}; let method = null, inEvent = false;
  for (const line of lines) {
    if (line.startsWith('METHOD:')) method = line.slice(7).trim().toUpperCase();
    if (line === 'BEGIN:VEVENT') { inEvent = true; continue; }
    if (line === 'END:VEVENT') break;
    if (!inEvent) continue;
    const i = line.indexOf(':'); if (i < 0) continue;
    const [name, ...params] = line.slice(0, i).split(';');
    ev[name.toUpperCase()] = { value: line.slice(i + 1), params };
  }
  const start = icsDate(ev.DTSTART); if (!start) return null;
  return { method, uid: ev.UID?.value ?? null, summary: unescapeICS(ev.SUMMARY?.value ?? ''), location: unescapeICS(ev.LOCATION?.value ?? '') || null,
    start, end: icsDate(ev.DTEND), status: ev.STATUS?.value?.toUpperCase() ?? null, sequence: Number(ev.SEQUENCE?.value ?? 0) || 0 };
}
const unescapeICS = s => s.replace(/\\n/gi, ' ').replace(/\\([,;\\])/g, '$1').trim();
function icsDate(prop) {
  const v = prop?.value; if (!v) return null;
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/.exec(v.trim()); if (!m) return null;
  const [, y, mo, d, h = '00', mi = '00', s = '00', z] = m;
  const tz = prop.params.find(p => p.startsWith('TZID='))?.slice(5) ?? null;
  return { iso: `${y}-${mo}-${d}T${h}:${mi}:${s}${z ? 'Z' : ''}`, allDay: m[4] === undefined, tzid: z ? 'UTC' : tz };
}

const DATE_RE = /\b(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T]+(\d{1,2}):(\d{2}))?|(20\d{2})年(\d{1,2})月(\d{1,2})日(?:\s*(\d{1,2})[:：](\d{2}))?/;
function findDate(text) {
  const m = DATE_RE.exec(text); if (!m) return null;
  const y = m[1] ?? m[6], mo = m[2] ?? m[7], d = m[3] ?? m[8], h = m[4] ?? m[9], mi = m[5] ?? m[10];
  const p = n => String(n).padStart(2, '0');
  if (+mo < 1 || +mo > 12 || +d < 1 || +d > 31) return null;
  return { iso: `${y}-${p(mo)}-${p(d)}T${h ? p(h) : '00'}:${mi ?? '00'}:00`, allDay: !h, tzid: null };
}
const FLIGHT_RE = /\b(?:flight|航班)\s*(?:no\.?|number|号)?\s*[:：]?\s*([A-Z0-9]{2}\s?\d{2,4})\b|\b([A-Z]{2}\d{3,4})\b(?=[^\n]{0,40}(?:depart|起飞|出发|boarding|登机))/i;
const DEADLINE_RE = /(deadline|due (?:date|by)|截止|最晚|请于|before)/i;
const APPT_RE = /(appointment|reservation|booking confirmed|预约|挂号|就诊|预订成功)/i;

/** Gmail message → candidate schedule items. Input: Gmail API `messages.get(format=full)`-like object with a decoded
 *  `bodyText` and optional `calendarText` (text/calendar part). Output items conform to EXTRACT_SCHEMA_VERSION. */
export function extractScheduleItems(msg) {
  if (!msg || typeof msg.id !== 'string') return [];
  const subject = header(msg, 'Subject').slice(0, 300);
  const from = header(msg, 'From').slice(0, 300);
  const body = String(msg.bodyText ?? '').slice(0, MAX_BODY);
  const base = { schema: EXTRACT_SCHEMA_VERSION, source: { provider: 'gmail', message_id: msg.id, thread_id: msg.threadId ?? null }, from };
  const ics = parseICS(msg.calendarText);
  if (ics) {
    const cancelled = ics.method === 'CANCEL' || ics.status === 'CANCELLED';
    return [item({ ...base, kind: 'meeting', title: ics.summary || subject, start: ics.start, end: ics.end, location: ics.location,
      external_uid: ics.uid, sequence: ics.sequence, action: cancelled ? 'cancel' : 'create', confidence: 0.95, evidence: 'text/calendar' })];
  }
  const text = `${subject}\n${body}`;
  const date = findDate(text); if (!date) return [];
  const fl = FLIGHT_RE.exec(text);
  if (fl) { const no = (fl[1] ?? fl[2]).replace(/\s/g, '').toUpperCase();
    return [item({ ...base, kind: 'flight', title: `Flight ${no}`, start: date, end: null, location: null, external_uid: `flight:${no}:${date.iso.slice(0, 10)}`, action: 'create', confidence: 0.7, evidence: 'pattern:flight' })]; }
  if (APPT_RE.test(text)) return [item({ ...base, kind: 'appointment', title: subject || 'Appointment', start: date, end: null, location: null, external_uid: null, action: 'create', confidence: 0.6, evidence: 'pattern:appointment' })];
  if (DEADLINE_RE.test(text)) return [item({ ...base, kind: 'deadline', title: subject || 'Deadline', start: date, end: null, location: null, external_uid: null, action: 'create', confidence: 0.55, evidence: 'pattern:deadline' })];
  return [];
}
function item(x) { return { ...x, sequence: x.sequence ?? 0, dedupe_key: dedupeKey(x) }; }

/** Stable key: provider UID when present, else kind + normalized title + start minute. Same key ⇒ same card. */
export function dedupeKey(x) {
  if (x.external_uid) return `uid:${x.external_uid}`;
  const t = String(x.title ?? '').toLowerCase().replace(/^(re|fwd?|回复|转发)\s*[:：]\s*/g, '').replace(/\s+/g, ' ').trim();
  return `k:${x.kind}:${t}:${x.start?.iso?.slice(0, 16) ?? ''}`;
}

/** Drop items that already exist (as cards or device calendar events by key) and keep only the newest SEQUENCE per key. */
export function dedupeAgainst(items, existingKeys = new Set()) {
  const best = new Map();
  for (const it of items) { const prev = best.get(it.dedupe_key); if (!prev || it.sequence > prev.sequence) best.set(it.dedupe_key, it); }
  return [...best.values()].filter(it => it.action === 'cancel' || !existingKeys.has(it.dedupe_key));
}
