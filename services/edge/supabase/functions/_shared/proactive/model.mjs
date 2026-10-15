// Proactive reminder text via the existing OpenRouter free route (same key + route policy as catpaw-api).
export function createReminderModel({ apiKey, route, fetchImpl = fetch, timeoutMs = 12000 }) {
  if (!apiKey || !route) return null;
  return {
    async reminder(c, nowMs) {
      const local = new Intl.DateTimeFormat('zh-CN', { timeZone: c.time_zone, dateStyle: 'medium', timeStyle: 'short' }).format(new Date(nowMs));
      const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const r = await fetchImpl(route.endpoint, { method: 'POST', signal: ctl.signal, headers: { authorization: 'Bearer ' + apiKey, 'content-type': 'application/json', 'x-title': 'catpaw-proactive' },
          body: JSON.stringify({ model: route.model, provider: route.routing_policy, max_tokens: 160, temperature: 0.5, stream: false, messages: [
            { role: 'system', content: '你是 CatPaw，一个主动、简洁、温暖的个人助理。现在到了用户设定的提醒时间。用一到两句简体中文主动提醒用户这件事，可附一个具体的下一步建议。不要使用 markdown，不要编造事实。' },
            { role: 'user', content: JSON.stringify({ now_local: local, task: c.title, notes: c.notes ?? null, occurrence: c.fire_count + 1, recurring: !!c.recurrence }) }] }) });
        if (!r.ok) throw new Error('model_http_' + r.status);
        const j = await r.json(); const text = j?.choices?.[0]?.message?.content;
        return typeof text === 'string' && text.trim() ? text.trim().slice(0, 600) : null;
      } finally { clearTimeout(t); }
    },
  };
}
