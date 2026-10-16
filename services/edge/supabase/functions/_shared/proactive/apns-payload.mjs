// Pure APNs payload builder (no crypto), so the level → alert mapping is testable. Codex PR90 #2:
// the push follows the decision level exactly like the device gate: card/silent are never pushed,
// notify is a normal alert, interrupt (and user reminders) are time-sensitive.
const INTERRUPTION = { notify: 'active', interrupt: 'time-sensitive' };
export function apnsPayload(t, ev, topic, nowSec) {
  if (t.kind === 'live_activity_update') return { pushType: 'liveactivity', topic: (t.bundle_id || topic) + '.push-type.liveactivity', body: { aps: { timestamp: nowSec, event: 'update', 'content-state': { title: ev.title, body: ev.body, kind: ev.kind, taskID: ev.task_id }, alert: { title: ev.title, body: ev.body } } } };
  let level = 'time-sensitive';
  if (ev.kind === 'proactive_decision') { level = INTERRUPTION[ev.payload?.decision]; if (!level) return null; }
  return { pushType: 'alert', topic: t.bundle_id || topic, body: { aps: { alert: { title: ev.title, body: ev.body }, sound: 'default', 'thread-id': ev.conversation_id ?? 'proactive', category: ev.kind === 'reminder_due' ? 'CATPAW_REMINDER' : undefined, 'interruption-level': level }, catpaw: { event_id: ev.id, task_id: ev.task_id, conversation_id: ev.conversation_id, kind: ev.kind } } };
}
