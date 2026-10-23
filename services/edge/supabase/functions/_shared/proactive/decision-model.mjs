import { errCode } from './safe-log.mjs';
// LLM adapter for proactive decisions. Reuses catpaw-api's route catalog + order (Gemini first, then OpenRouter/Groq/OpenCode, Agnes last);
// keys come only from env via `get` and are held in this closure (never logged or returned).
import { FREE_ROUTE_CATALOG, ROUTE_META, readFreeRouteChain, readRouteModels } from '../core/src/free-route-chain.mjs';
import { hash } from '../core/facade-r2/src/common.mjs';
// p90 F4 / final-513a1b1 B1: without the user's valid consent for that exact route (route hash) only OpenRouter (privacy
// + $0 price fields below) and routes tagged zero_retention are used; every other route (Gemini, Groq, Agnes, …) is
// skipped (default deny → rules fallback).
const NEEDS_CONSENT = id => id !== 'openrouter' && ROUTE_META[id]?.data_note !== 'zero_retention';
// Agnes: only the $0 promo flash models (free-route-chain.mjs catalog note); Pro models are paid.
const AGNES_FREE_MODELS = new Set(['agnes-3.0-flash', 'agnes-2.5-flash']);
const OPENROUTER_PROVIDER = Object.freeze({ data_collection: 'deny', allow_fallbacks: false, max_price: { prompt: 0, completion: 0, request: 0, image: 0 } });
/** Routes exactly as catpaw-api's chain validates them (order, CATPAW_<ID>_MODEL free checks, OpenCode base URL, Gemini
 * switch). A lone OpenRouter key keeps the frozen single route (model checked by readRouteModels). Invalid config → none. */
function readRoutes(get, log) {
  try {
    const chain = readFreeRouteChain(get);
    if (chain) return chain.routes.map(r => ({ ...r, endpoint: r.id === 'gemini' ? FREE_ROUTE_CATALOG.gemini.compat_endpoint : r.endpoint, key: chain.secrets[r.id] }));
    const key = get(FREE_ROUTE_CATALOG.openrouter.secret);
    if (!key) return [];
    const r = FREE_ROUTE_CATALOG.openrouter, model = get('CATPAW_OPENROUTER_MODEL') || r.model;
    readRouteModels(get, 'openrouter', model);
    return [{ id: 'openrouter', endpoint: r.endpoint, model, policy_url: r.policy_url, key }];
  } catch (e) { log('route_config_invalid', errCode(e)); return []; }
}
const SYSTEM = `你是 mimi（小咪）的主动式助理决策器，场景是会议与出行。根据 signals、context、memories 和 weights 判断是否该主动打扰用户。
decision 取值：silent（不打扰）、card（应用内卡片）、notify（普通推送）、interrupt（紧急、打断式）。只有真的会造成损失（迟到、误机、冲突）才用 notify/interrupt。
weights 是用户对该类提醒的历史反馈，weight<1 表示用户不喜欢，应更保守。
只输出一个 JSON 对象，不要 markdown：{"decision":"...","title":"不超过 16 字的卡片标题","reason":"一句简体中文，说明为什么","confidence":0到1,"trigger":"主要信号类型","suggested_actions":["create_reminder"|"notify_attendees"|"snooze"|"dismiss"],"used_memory_ids":["用到的记忆 id"]}`;
export function createDecisionModel({ get, fetchImpl = fetch, timeoutMs = 15000, log = () => {}, consent = async () => false }) {
  const routes = readRoutes(get, log).filter(r => r.key && (r.id !== 'agnes' || AGNES_FREE_MODELS.has(r.model)))
    .map(r => ({ ...r, needsConsent: NEEDS_CONSENT(r.id), routeHash: hash({ id: r.id, endpoint: r.endpoint, model: r.model, policy_url: r.policy_url }) }));
  if (!routes.length) return null;
  let last = null;
  return {
    routes: routes.map(r => r.id), lastRoute: () => last,
    async decide(input, { uid = null } = {}) {
      let err = null;
      for (const r of routes) {
        if (r.needsConsent) {
          let okc = false; try { okc = !!uid && await consent(uid, { id: r.id, routeHash: r.routeHash }) === true; } catch { okc = false; }
          if (!okc) { log('route_skipped_no_consent', r.id); continue; }
        }
        const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), timeoutMs);
        try {
          const body = { model: r.model, temperature: 0.2, max_tokens: 400, stream: false, messages: [{ role: 'system', content: SYSTEM }, { role: 'user', content: JSON.stringify(input) }] };
          if (r.id === 'openrouter') { body.response_format = { type: 'json_object' }; body.provider = structuredClone(OPENROUTER_PROVIDER); }
          const res = await fetchImpl(r.endpoint, { method: 'POST', signal: ctl.signal, headers: { authorization: 'Bearer ' + r.key, 'content-type': 'application/json', 'x-title': 'catpaw-proactive' }, body: JSON.stringify(body) });
          if (!res.ok) throw new Error(`${r.id}_http_${res.status}`);
          const text = (await res.json())?.choices?.[0]?.message?.content ?? '';
          const m = String(text).replace(/<think>[\s\S]*?<\/think>/g, '').match(/\{[\s\S]*\}/); if (!m) throw new Error(`${r.id}_no_json`);
          last = r.id; return JSON.parse(m[0]);
        } catch (e) { err = e; log('route_failed', r.id, errCode(e)); }
        finally { clearTimeout(t); }
      }
      throw err ?? new Error('no_route');
    },
  };
}
