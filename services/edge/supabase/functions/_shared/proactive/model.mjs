// Proactive reminder text via the existing OpenRouter free route (same key + route policy as catpaw-api).
// p90 F4: reminder text is pinned to the frozen OpenRouter route (never cfg.route, which becomes the Gemini chain when
// a Gemini key is deployed) and only ever carries the OpenRouter key.
export const OPENROUTER_ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions';
export function reminderModelFor(cfg, get, opts = {}) {
  const r = cfg?.route, policy = r?.endpoint === OPENROUTER_ENDPOINT ? r.routing_policy : { only: ['novita/bf16'], allow_fallbacks: false, require_parameters: true, data_collection: 'deny', max_price: { prompt: 0, completion: 0, request: 0, image: 0 } };
  return createReminderModel({ apiKey: cfg?.modelKey ?? get('OPENROUTER_API_KEY'), route: { endpoint: OPENROUTER_ENDPOINT, model: r?.endpoint === OPENROUTER_ENDPOINT ? r.model : 'apodex/apodex-1.1-mini:free', routing_policy: policy }, ...opts });
}
export function createReminderModel({ apiKey, route, fetchImpl = fetch, timeoutMs = 12000 }) {
  if (!apiKey || !route || route.endpoint !== OPENROUTER_ENDPOINT) return null;   // F4: the OpenRouter key goes only to OpenRouter
  return {
    async reminder(c, nowMs) {
      const local = new Intl.DateTimeFormat('zh-CN', { timeZone: c.time_zone, dateStyle: 'medium', timeStyle: 'short' }).format(new Date(nowMs));
      const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const r = await fetchImpl(route.endpoint, { method: 'POST', signal: ctl.signal, headers: { authorization: 'Bearer ' + apiKey, 'content-type': 'application/json', 'x-title': 'catpaw-proactive' },
          body: JSON.stringify({ model: route.model, provider: route.routing_policy, max_tokens: 160, temperature: 0.5, stream: false, messages: [
            { role: 'system', content: '你是 mimi（小咪），一个主动、简洁、温暖的个人助理。现在到了用户设定的提醒时间。用一到两句简体中文主动提醒用户这件事，可附一个具体的下一步建议。不要使用 markdown，不要编造事实。' },
            { role: 'user', content: JSON.stringify({ now_local: local, task: c.title, notes: c.notes ?? null, occurrence: c.fire_count + 1, recurring: !!c.recurrence }) }] }) });
        if (!r.ok) throw new Error('model_http_' + r.status);
        const j = await r.json(); const text = j?.choices?.[0]?.message?.content;
        return typeof text === 'string' && text.trim() ? text.trim().slice(0, 600) : null;
      } finally { clearTimeout(t); }
    },
  };
}
