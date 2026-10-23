// Family API behind the PRODUCTION Supabase token verifier (createSupabaseTokenVerifier, ES256, iss/aud/exp/role/session_id
// checks) on REAL Postgres. Only the key source differs from prod: a local JWKS (mode 'test') instead of the project's
// /auth/v1/.well-known/jwks.json. No GoTrue server runs here, so login itself (password/OTP -> token) is NOT exercised.
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-jwt-pg.test.mjs
import test from 'node:test'; import assert from 'node:assert/strict';
import { runtimeOf } from './support/pg-runtime.mjs';
import postgres from 'npm:postgres@3.4.7';
import { generateKeyPair, exportJWK, SignJWT } from 'npm:jose@6.2.12';
import { createPgFamilyStore } from '../supabase/functions/_shared/family/pg-store.mjs';
import { createFamilyService } from '../supabase/functions/_shared/family/service.mjs';
import { createMemoryRoute } from '../supabase/functions/_shared/family/memory.mjs';
import { createSupabaseTokenVerifier } from '../supabase/functions/_shared/core/src/supabase-auth.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const project = 'https://abcdefghijklmnopqrst.supabase.co';
const U = () => crypto.randomUUID();
const { privateKey, publicKey } = await generateKeyPair('ES256');
const jwk = { ...await exportJWK(publicKey), kid: 'family-offline-key', alg: 'ES256', use: 'sig' };
const other = await generateKeyPair('ES256');
const now = Math.floor(Date.now() / 1000);
const token = (sub, p = {}, key = privateKey) => new SignJWT({ iss: project + '/auth/v1', aud: 'authenticated', sub, session_id: U(), iat: now, exp: now + 600, role: 'authenticated', ...p })
  .setProtectedHeader({ alg: 'ES256', kid: jwk.kid, typ: 'JWT' }).sign(key);

test('family API with the production JWT verifier: valid session works, actor = sub; forged/expired/foreign/service_role rejected; cross-user 404', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const verifyToken = createSupabaseTokenVerifier({ projectUrl: project, mode: 'test', testJWKS: { keys: [jwk] } });
    // wired exactly like api.mjs: verifyUser = h => verifyToken(h)
    const svc = createFamilyService({ store: createPgFamilyStore(runtimeOf(sql)), extraRoutes: [createMemoryRoute()], verifyUser: h => verifyToken(h) });
    const call = async (auth, method, path, body) => { const r = await svc.handle(new Request('https://x/catpaw/family/v1' + path, { method, headers: { authorization: auth, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
    const A = U(), B = U(); await sql`insert into auth.users(id) values(${A}),(${B})`;
    const ta = 'Bearer ' + await token(A), tb = 'Bearer ' + await token(B);
    const e = await call(ta, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: U(), actor_user_id: B, payload: { name: '我们家' } });
    assert.equal(e.status, 200); const hh = e.body.objects[0].id;
    assert.deepEqual((await call(ta, 'GET', '/bootstrap')).body.household_ids, [hh]);
    const [{ owner_user_id }] = await sql`select owner_user_id from family.households where id = ${hh}`;
    assert.equal(owner_user_id, A, 'actor comes from the verified sub, never from the body');
    assert.equal((await call(tb, 'GET', `/households/${hh}/projection`)).status, 404, 'other user: invisible');
    for (const bad of [
      'Bearer ' + await token(A, { exp: now - 10, iat: now - 700 }),            // expired
      'Bearer ' + await token(A, { aud: 'anon' }),                               // wrong audience
      'Bearer ' + await token(A, { role: 'service_role' }),                      // privileged role
      'Bearer ' + await token(A, { iss: 'https://zzzzzzzzzzzzzzzzzzzz.supabase.co/auth/v1' }), // foreign project
      'Bearer ' + await token(A, {}, other.privateKey),                          // signed by another key
      'Bearer ' + await token(A, { session_id: undefined }),                     // no session id
      ta.slice(0, -4) + 'AAAA',                                                  // tampered signature
      'Bearer ' + A,                                                             // raw uuid (the old test shortcut)
      '',
    ]) assert.equal((await call(bad, 'GET', `/households/${hh}/projection`)).status, 401, `rejected: ${bad.slice(0, 20)}`);
  } finally { await sql.end(); }
});

test('auth key service outage is 503 (retryable), not a silent 401', { skip: !url }, async () => {
  const svc = createFamilyService({ store: {}, verifyUser: async () => { const e = new Error('jwks down'); e.status = 503; e.code = 'auth_key_service_unavailable'; throw e; } });
  const r = await svc.handle(new Request('https://x/catpaw/family/v1/bootstrap', { headers: { authorization: 'Bearer a.b.c' } }));
  assert.equal(r.status, 503); assert.equal((await r.json()).error.code, 'auth_unavailable');
});
