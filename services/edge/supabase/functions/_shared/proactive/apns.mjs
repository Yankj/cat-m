// APNs HTTP/2 sender (token-based auth, ES256). Inactive until APNS_* secrets are set.
import { importPKCS8, SignJWT } from 'npm:jose@6.2.12';
export function createApnsSender({ keyId, teamId, privateKeyPem, topic, fetchImpl = fetch, now = () => Date.now() }) {
  const configured = !!(keyId && teamId && privateKeyPem && topic);
  let cached = null, cachedAt = 0, key = null;
  async function jwt() {
    if (cached && now() - cachedAt < 45 * 60 * 1000) return cached;
    key ??= await importPKCS8(privateKeyPem.replace(/\\n/g, '\n'), 'ES256');
    cached = await new SignJWT({}).setProtectedHeader({ alg: 'ES256', kid: keyId }).setIssuer(teamId).setIssuedAt(Math.floor(now() / 1000)).sign(key); cachedAt = now();
    return cached;
  }
  return {
    configured,
    payloadFor(t, ev) {
      if (t.kind === 'live_activity_update') return { pushType: 'liveactivity', topic: (t.bundle_id || topic) + '.push-type.liveactivity', body: { aps: { timestamp: Math.floor(now() / 1000), event: 'update', 'content-state': { title: ev.title, body: ev.body, kind: ev.kind, taskID: ev.task_id }, alert: { title: ev.title, body: ev.body } } } };
      return { pushType: 'alert', topic: t.bundle_id || topic, body: { aps: { alert: { title: ev.title, body: ev.body }, sound: 'default', 'thread-id': ev.conversation_id ?? 'proactive', category: ev.kind === 'reminder_due' ? 'CATPAW_REMINDER' : undefined, 'interruption-level': 'time-sensitive' }, catpaw: { event_id: ev.id, task_id: ev.task_id, conversation_id: ev.conversation_id, kind: ev.kind } } };
    },
    async send(t, ev) {
      if (!configured) return { ok: false, reason: 'apns_not_configured' };
      if (t.kind === 'live_activity_start') return { ok: false, reason: 'start_token_not_used_for_events' };
      const p = this.payloadFor(t, ev), host = t.environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
      const r = await fetchImpl(`${host}/3/device/${t.token}`, { method: 'POST', headers: { authorization: 'bearer ' + await jwt(), 'apns-topic': p.topic, 'apns-push-type': p.pushType, 'apns-priority': '10', 'apns-collapse-id': String(ev.id).slice(0, 64), 'content-type': 'application/json' }, body: JSON.stringify(p.body) });
      if (r.ok) return { ok: true };
      let reason = 'http_' + r.status; try { reason = (await r.json()).reason ?? reason; } catch {}
      return { ok: false, reason, unregistered: r.status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered' };
    },
  };
}
