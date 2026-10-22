// catpaw.family.v1 HTTP service (api-v1). actor_user_id comes only from the verified session.
import { PROTOCOL, PREFIX, MAX_BODY, UUID_RE, FamilyError, parseStrict, requestHash, validateCommand } from './contract.mjs';
import { errCode } from '../proactive/safe-log.mjs';

const HTTP = { not_found: 404, idempotency_conflict: 409, command_invalid: 422, json_invalid: 422, timezone_invalid: 422, forbidden: 403 };
const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
const err = (status, code, extra = {}) => json(status, { protocol: PROTOCOL, schema_version: 1, error: { code, ...extra } });

export function todayIn(tz, now = Date.now()) {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(now));
  return p; // en-CA yields YYYY-MM-DD
}

export function createFamilyService({ store, verifyUser, allow = () => true, log = () => {}, extraRoutes = [], now = () => Date.now() }) {
  async function actorOf(req) {
    // a key-service outage is not a bad session: surface it as retryable 503 instead of logging the user out
    const u = await verifyUser(req.headers.get('authorization') ?? '').catch(e => { if (e?.status === 503) throw new FamilyError(503, 'auth_unavailable', { retryable: true }); return null; });
    if (!u?.sub) throw new FamilyError(401, 'session_required');
    if (!allow(u.sub)) throw new FamilyError(404, 'not_found');
    return u.sub;
  }
  async function body(req, max = MAX_BODY) {
    const len = Number(req.headers.get('content-length') ?? 0);
    if (len > max) throw new FamilyError(413, 'request_too_large');
    const buf = new Uint8Array(await req.arrayBuffer());
    if (buf.length > max) throw new FamilyError(413, 'request_too_large');
    if (!/^application\/json\b/i.test(req.headers.get('content-type') ?? '')) throw new FamilyError(422, 'json_invalid');
    let text; try { text = new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch { throw new FamilyError(422, 'json_invalid'); }
    return parseStrict(text);
  }
  async function apply(actor, raw, hhPath) {
    const cmd = validateCommand(raw, { householdFromPath: hhPath });
    const hash = await requestHash(cmd);
    try { return await store.apply(actor, cmd, hash); }
    catch (e) { if (e.familyCode) throw new FamilyError(HTTP[e.familyCode] ?? 422, e.familyCode); throw e; }
  }
  const ctx = { store, apply, body, now, todayIn };
  async function route(req) {
    const url = new URL(req.url);
    const path = url.pathname.replace(/^.*?(?=\/catpaw\/family\/v1(?:\/|$))/, '');
    if (!path.startsWith(PREFIX)) throw new FamilyError(404, 'not_found');
    const rest = path.slice(PREFIX.length);
    const actor = await actorOf(req);
    let m;
    if (rest === '/bootstrap' && req.method === 'GET') return json(200, { protocol: PROTOCOL, schema_version: 1, enabled: true, household_ids: await store.households(actor) });
    if (rest === '/commands' && req.method === 'POST') return json(200, await apply(actor, await body(req), null));
    if ((m = /^\/commands\/([0-9a-f-]{36})$/.exec(rest)) && req.method === 'GET') {
      if (!UUID_RE.test(m[1])) throw new FamilyError(404, 'not_found');
      return json(200, await store.receipt(actor, m[1]));
    }
    if ((m = /^\/households\/([0-9a-f-]{36})(\/.*)$/.exec(rest))) {
      const hh = m[1], sub = m[2];
      if (!UUID_RE.test(hh)) throw new FamilyError(404, 'not_found');
      if (sub === '/commands' && req.method === 'POST') return json(200, await apply(actor, await body(req), hh));
      if (sub === '/projection' && req.method === 'GET') {
        let date = url.searchParams.get('local_date');
        if (date !== null && !/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new FamilyError(422, 'command_invalid');
        if (date === null) date = todayIn('Asia/Shanghai', now());
        const p = await store.projection(actor, hh, date);
        if (!p) throw new FamilyError(404, 'not_found');
        return json(200, p);
      }
      if (sub === '/changes' && req.method === 'GET') {
        const after = url.searchParams.get('after');
        if (after !== null && !/^\d{1,18}$/.test(after)) return err(409, 'cursor_expired');
        const events = await store.changes(actor, hh, after === null ? 0 : Number(after), 200);
        if (!events) throw new FamilyError(404, 'not_found');
        return json(200, { protocol: PROTOCOL, schema_version: 1, household_id: hh, events, next_cursor: events.length ? events[events.length - 1].cursor : (after === null ? 0 : Number(after)) });
      }
      if (sub === '/home' && req.method === 'GET') {
        const p = await store.projection(actor, hh, todayIn('Asia/Shanghai', now()));
        if (!p) throw new FamilyError(404, 'not_found');
        return json(200, { protocol: PROTOCOL, schema_version: 1, household_id: hh, projection_revision: p.projection_revision, home: p.home });
      }
      for (const r of extraRoutes) { const out = await r({ req, url, actor, hh, sub, ctx }); if (out) return out; }
    }
    throw new FamilyError(404, 'not_found');
  }
  return {
    async handle(req) {
      try { return await route(req); }
      catch (e) {
        if (e instanceof FamilyError) return err(e.status, e.code, e.extra);
        log('family_error', errCode(e));
        return err(503, 'unavailable', { retryable: false });
      }
    },
  };
}
