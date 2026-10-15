// POST /catpaw/features/v1/enroll {invite_code}  and  GET /catpaw/features/v1/me
import { ENROLLMENT_CONTRACT, normalizeInviteCode, hashInviteCode } from './contract.mjs';
const json = (status, body, headers = {}) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers } });
const err = (status, code, extra = {}) => json(status, { contract: ENROLLMENT_CONTRACT, error: { code, ...extra } }, status === 429 ? { 'retry-after': String(extra.retry_after_sec ?? 900) } : {});
/**
 * @param store       { redeem(subjectID, codeHash) -> {status, features}, listEnrollments() }
 * @param registry    createEnrollmentRegistry(...)
 * @param verifyUser  async (authorizationHeader) -> { id } (Supabase user)
 * @param envAllows   (subjectID, feature) -> boolean : env gate/allowlist view, reported by /me
 */
export function createEnrollmentService({ store, registry, verifyUser, envAllows = () => false, features = [], log = () => {} }) {
  // Per-instance pre-filter in front of the DB limit (the DB limit in redeem_invite is the authoritative one).
  const recent = new Map();
  const local = uid => { const t = Date.now(), a = (recent.get(uid) ?? []).filter(x => t - x < 60000); a.push(t); recent.set(uid, a); if (recent.size > 5000) recent.clear(); return a.length > 10; };
  async function user(req) { if (typeof verifyUser !== 'function') throw Object.assign(new Error(), { status: 503, code: 'auth_unavailable' }); const u = await verifyUser(req.headers.get('authorization')).catch(() => null); if (!u?.id) throw Object.assign(new Error(), { status: 401, code: 'session_required' }); return u.id; }
  const me = uid => ({ contract: ENROLLMENT_CONTRACT, enrolled: registry.features(uid).length > 0, features: Object.fromEntries(features.map(f => [f, registry.has(uid, f) || envAllows(uid, f)])) });
  return {
    async handle(req, path) {
      try {
        if (path === '/catpaw/features/v1/me' && req.method === 'GET') { const uid = await user(req); await registry.fresh(); return json(200, me(uid)); }
        if (path === '/catpaw/features/v1/enroll' && req.method === 'POST') {
          const uid = await user(req);
          if (local(uid)) return err(429, 'rate_limited', { retry_after_sec: 60 });
          let body; try { body = await req.json(); } catch { return err(400, 'invalid_json'); }
          const code = normalizeInviteCode(body?.invite_code);
          // Malformed input still counts as an attempt (DB side) so it cannot be used to probe for free.
          const r = await store.redeem(uid, code ? await hashInviteCode(code) : 'malformed');
          log('enroll', r.status); // never the code or its hash
          if (r.status === 'ok' || r.status === 'already_enrolled') { registry.add(uid, r.features); return json(200, { ...me(uid), status: r.status }); }
          if (r.status === 'rate_limited') return err(429, 'rate_limited', { retry_after_sec: 900 });
          return err(422, 'invite_invalid'); // unknown / expired / revoked / used up: one indistinguishable answer
        }
        return err(404, 'not_found');
      } catch (e) { return err(e?.status ?? 500, e?.code ?? 'enrollment_unavailable'); }
    },
  };
}
