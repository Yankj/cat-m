import { validateRecurrence, bad } from './recurrence.mjs';
export const TASK_TOOL_CONTRACT = 'catpaw.task-tools.v1';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const isUUID = v => typeof v === 'string' && UUID.test(v);
const iso = v => typeof v === 'string' && Number.isFinite(Date.parse(v)) && /[zZ]|[+-]\d\d:?\d\d$/.test(v);
export function validTimeZone(tz) { try { new Intl.DateTimeFormat('en-US', { timeZone: tz }).format(0); return typeof tz === 'string' && tz.length <= 100; } catch { return false; } }
const STATUSES = ['open', 'done', 'cancelled', 'snoozed'];

function title(v) { if (typeof v !== 'string' || !v.trim() || v.length > 512 || /[\u0000-\u001f\u007f]/.test(v)) throw bad('title_invalid'); return v.trim(); }
function notes(v) { if (v == null) return null; if (typeof v !== 'string' || v.length > 4000) throw bad('notes_invalid'); return v; }
function only(v, keys) { if (!v || typeof v !== 'object' || Array.isArray(v)) throw bad('schema_invalid'); for (const k of Object.keys(v)) if (!keys.includes(k)) throw bad('unknown_field:' + k); }

export function validateTaskCreate(v) {
  only(v, ['operation_id', 'title', 'notes', 'due_at', 'time_zone', 'recurrence', 'remind_lead_seconds', 'conversation_id', 'source_turn_id']);
  if (!isUUID(v.operation_id)) throw bad('operation_id_invalid');
  const out = { operation_id: v.operation_id, title: title(v.title), notes: notes(v.notes) };
  if (v.due_at != null) { if (!iso(v.due_at)) throw bad('due_at_invalid'); out.due_at = new Date(v.due_at).toISOString(); } else out.due_at = null;
  out.time_zone = v.time_zone ?? 'Asia/Shanghai'; if (!validTimeZone(out.time_zone)) throw bad('time_zone_invalid');
  out.recurrence = validateRecurrence(v.recurrence); if (out.recurrence && !out.due_at) throw bad('recurrence_requires_due_at');
  out.remind_lead_seconds = v.remind_lead_seconds ?? 0; if (!Number.isInteger(out.remind_lead_seconds) || out.remind_lead_seconds < 0 || out.remind_lead_seconds > 604800) throw bad('remind_lead_invalid');
  for (const k of ['conversation_id', 'source_turn_id']) { if (v[k] != null && !isUUID(v[k])) throw bad(k + '_invalid'); out[k] = v[k] ?? null; }
  return out;
}
export function validateTaskPatch(v) {
  only(v, ['expected_revision', 'title', 'notes', 'due_at', 'time_zone', 'recurrence', 'status', 'remind_lead_seconds', 'snooze_until']);
  const out = {};
  if (v.expected_revision != null) { if (!Number.isInteger(v.expected_revision) || v.expected_revision < 1) throw bad('expected_revision_invalid'); out.expected_revision = v.expected_revision; }
  if ('title' in v) out.title = title(v.title);
  if ('notes' in v) out.notes = notes(v.notes);
  if ('due_at' in v) { if (v.due_at !== null && !iso(v.due_at)) throw bad('due_at_invalid'); out.due_at = v.due_at && new Date(v.due_at).toISOString(); }
  if ('time_zone' in v) { if (!validTimeZone(v.time_zone)) throw bad('time_zone_invalid'); out.time_zone = v.time_zone; }
  if ('recurrence' in v) out.recurrence = validateRecurrence(v.recurrence);
  if ('status' in v) { if (!STATUSES.includes(v.status)) throw bad('status_invalid'); out.status = v.status; }
  if ('remind_lead_seconds' in v) { if (!Number.isInteger(v.remind_lead_seconds) || v.remind_lead_seconds < 0 || v.remind_lead_seconds > 604800) throw bad('remind_lead_invalid'); out.remind_lead_seconds = v.remind_lead_seconds; }
  if ('snooze_until' in v) { if (!iso(v.snooze_until)) throw bad('snooze_until_invalid'); out.snooze_until = new Date(v.snooze_until).toISOString(); out.status = 'snoozed'; }
  if (Object.keys(out).filter(k => k !== 'expected_revision').length === 0) throw bad('empty_patch');
  return out;
}
export function computeNextFire(task, nowMs) {
  if (!['open', 'snoozed'].includes(task.status)) return null;
  if (task.status === 'snoozed' && task.snooze_until) return task.snooze_until;
  if (!task.due_at) return null;
  const fire = Date.parse(task.due_at) - (task.remind_lead_seconds || 0) * 1000;
  return new Date(fire).toISOString(); // past due -> fires on next tick
}

/** OpenAI/OpenRouter-compatible tool definitions for the chat model. */
export const TASK_TOOLS = Object.freeze([
  { type: 'function', function: { name: 'create_task', description: 'Create a task or reminder for the user. Use when the user asks to be reminded, schedules something, or agrees to a follow-up. Always give due_at as an absolute ISO-8601 time with offset, computed from the user time zone.', parameters: { type: 'object', additionalProperties: false, required: ['title'], properties: {
    title: { type: 'string', maxLength: 512 }, notes: { type: 'string', maxLength: 4000 }, due_at: { type: 'string', description: 'ISO-8601 with offset, e.g. 2026-10-16T09:00:00+08:00' },
    time_zone: { type: 'string', description: 'IANA zone, default Asia/Shanghai' }, remind_lead_seconds: { type: 'integer', minimum: 0, maximum: 604800 },
    recurrence: { type: 'object', additionalProperties: false, properties: { freq: { enum: ['daily', 'weekly', 'monthly', 'interval'] }, interval: { type: 'integer', minimum: 1 }, interval_seconds: { type: 'integer', minimum: 300 }, until: { type: 'string' }, count: { type: 'integer', minimum: 1 } }, required: ['freq'] } } } } },
  { type: 'function', function: { name: 'update_task', description: 'Change, reschedule, snooze, complete or cancel an existing task. Get task_id from list_tasks.', parameters: { type: 'object', additionalProperties: false, required: ['task_id'], properties: {
    task_id: { type: 'string' }, title: { type: 'string' }, notes: { type: 'string' }, due_at: { type: 'string' }, status: { enum: ['open', 'done', 'cancelled'] }, snooze_until: { type: 'string' }, recurrence: { type: ['object', 'null'] } } } } },
  { type: 'function', function: { name: 'list_tasks', description: 'List the user\'s tasks/reminders.', parameters: { type: 'object', additionalProperties: false, properties: { status: { enum: ['open', 'done', 'cancelled', 'snoozed', 'all'] }, limit: { type: 'integer', minimum: 1, maximum: 50 } } } } },
]);
