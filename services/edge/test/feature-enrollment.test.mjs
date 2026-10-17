import test from 'node:test'; import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { readConfig, readFeatureGate, featureAllows } from '../supabase/functions/_shared/config.mjs';
import { normalizeInviteCode, hashInviteCode, FEATURES } from '../supabase/functions/_shared/enrollment/contract.mjs';
import { createEnrollmentRegistry } from '../supabase/functions/_shared/enrollment/registry.mjs';
import { createEnrollmentService } from '../supabase/functions/_shared/enrollment/service.mjs';
import { createMemoryEnrollmentStore } from '../supabase/functions/_shared/enrollment/memory-store.mjs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';

const U1 = randomUUID(), U2 = randomUUID();
const verifyUser = async h => h === 'Bearer u1' ? { id: U1 } : h === 'Bearer u2' ? { id: U2 } : null;
const req = (path, { method = 'POST', auth = 'Bearer u1', body } = {}) => new Request('https://x/catpaw-api' + path, { method, headers: { authorization: auth, 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
function setup(storeOpts) {
  const store = createMemoryEnrollmentStore(storeOpts), registry = createEnrollmentRegistry({ store }), logs = [];
  const svc = createEnrollmentService({ store, registry, verifyUser, features: FEATURES, log: (...a) => logs.push(a.join(' ')) });
  const call = async (path, o) => { const r = await svc.handle(req(path, o), path); return { status: r.status, body: await r.json() }; };
  return { store, registry, svc, call, logs };
}

test('gate: unset env → on (2026-10-17), explicit allowlist uses enrollment, explicit off stays off', () => {
  assert.equal(readFeatureGate(undefined), 'off'); assert.equal(readFeatureGate('', 'allowlist'), 'allowlist'); assert.equal(readFeatureGate('false', 'allowlist'), 'off');
  const c = readConfig(() => undefined);
  for (const k of ['agentMemory', 'taskTools', 'generativeUI', 'deviceTools', 'proactiveSuggestionsSSE', 'proactive']) assert.equal(c[k], 'on', k);
  const enrolled = { has: (uid, f) => uid === U1 && f === 'agent_memory' };
  assert.ok(featureAllows('allowlist', new Set(), U1, enrolled, 'agent_memory'));
  assert.ok(!featureAllows('allowlist', new Set(), U1, enrolled, 'device_tools'));
  assert.ok(!featureAllows('off', new Set(), U1, enrolled, 'agent_memory'));
  assert.ok(featureAllows('allowlist', new Set([U2]), U2, enrolled, 'device_tools'));
  assert.ok(!featureAllows('allowlist', new Set(), null, { has: () => true }, 'x'));
});

test('invite codes: normalization, hash matches the SQL formula, never stored or logged in plaintext', async () => {
  assert.equal(normalizeInviteCode('cp-abcd-efgh-jk23'), 'ABCDEFGHJK23'); assert.equal(normalizeInviteCode(' ABCD EFGH JK23 '), 'ABCDEFGHJK23');
  assert.equal(normalizeInviteCode('CP-ABCD-EFGH-JK2O'), null); assert.equal(normalizeInviteCode(42), null); assert.equal(normalizeInviteCode('A'.repeat(100)), null);
  assert.match(await hashInviteCode('ABCDEFGHJK23'), /^[0-9a-f]{64}$/);
  const sqlText = readFileSync(new URL('../supabase/migrations/20261016110000_feature_enrollment.sql', import.meta.url), 'utf8');
  assert.ok(sqlText.includes("extensions.digest('catpaw-invite-v1:' || normalized, 'sha256')"));
  assert.ok(!/CP-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}/.test(sqlText), 'no plaintext code in the migration');
  const { store, call, logs } = setup(); const code = await store.createInvite();
  assert.match(code, /^CP-[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}$/);
  await call('/catpaw/features/v1/enroll', { body: { invite_code: code } });
  assert.ok(logs.every(l => !l.includes(code.slice(3, 7))));
});

test('enroll: unauthenticated 401; valid code enables features at once; single-use; idempotent for the same user', async () => {
  const { store, registry, call } = setup(); const code = await store.createInvite({ features: ['agent_memory', 'proactive'] });
  assert.equal((await call('/catpaw/features/v1/enroll', { auth: 'Bearer nope', body: { invite_code: code } })).status, 401);
  let r = await call('/catpaw/features/v1/me', { method: 'GET' }); assert.equal(r.body.enrolled, false); assert.equal(r.body.features.agent_memory, false);
  r = await call('/catpaw/features/v1/enroll', { body: { invite_code: code.toLowerCase() } });
  assert.equal(r.status, 200); assert.equal(r.body.status, 'ok'); assert.deepEqual([r.body.features.agent_memory, r.body.features.proactive, r.body.features.device_tools], [true, true, false]);
  assert.ok(registry.has(U1, 'agent_memory'));
  r = await call('/catpaw/features/v1/enroll', { body: { invite_code: code } }); assert.equal(r.status, 200); assert.equal(r.body.status, 'already_enrolled');
  r = await call('/catpaw/features/v1/enroll', { auth: 'Bearer u2', body: { invite_code: code } }); assert.equal(r.status, 422); assert.equal(r.body.error.code, 'invite_invalid');
  // A second instance learns about the enrollment on refresh.
  const other = createEnrollmentRegistry({ store }); await other.fresh(); assert.deepEqual(other.features(U1), ['agent_memory', 'proactive']);
});

test('enroll: expired / revoked / malformed → same invite_invalid; brute force is rate limited per subject and globally', async () => {
  let t = 0; const { store, call } = setup({ now: () => t });
  const exp = await store.createInvite({ ttlMs: 1000 }); t = 2000;
  assert.equal((await call('/catpaw/features/v1/enroll', { body: { invite_code: exp } })).body.error.code, 'invite_invalid');
  assert.equal((await call('/catpaw/features/v1/enroll', { body: { invite_code: 'hello' } })).body.error.code, 'invite_invalid');
  assert.equal((await call('/catpaw/features/v1/enroll', { body: {} })).status, 422);
  for (let i = 0; i < 2; i++) await call('/catpaw/features/v1/enroll', { body: { invite_code: 'CP-AAAA-AAAA-AAAA' } });
  const good = await store.createInvite();
  const r = await call('/catpaw/features/v1/enroll', { body: { invite_code: good } }); assert.equal(r.status, 429); assert.equal(r.body.error.code, 'rate_limited');
  t += 16 * 60000; assert.equal((await call('/catpaw/features/v1/enroll', { body: { invite_code: good } })).status, 200);
  const g = setup({ globalMaxFailures: 3 }); for (let i = 0; i < 3; i++) await g.call('/catpaw/features/v1/enroll', { auth: i % 2 ? 'Bearer u1' : 'Bearer u2', body: { invite_code: 'CP-AAAA-AAAA-AAAA' } });
  assert.equal((await g.call('/catpaw/features/v1/enroll', { auth: 'Bearer u2', body: { invite_code: await g.store.createInvite() } })).status, 429);
  const l = setup(); let last; for (let i = 0; i < 11; i++) last = await l.call('/catpaw/features/v1/enroll', { body: { invite_code: 'x' } }); assert.equal(last.status, 429);
});

test('catpaw-proactive: same gate — unenrolled users get 403 feature_disabled, enrolled users pass', async () => {
  const es = createMemoryEnrollmentStore(), registry = createEnrollmentRegistry({ store: es }); const code = await es.createInvite({ features: ['proactive'] });
  const svc = createProactiveService({ store: createMemoryStore(), schedulerSecret: 's', verifyUser: async h => ({ sub: h === 'Bearer u1' ? U1 : U2 }),
    allow: async uid => { await registry.fresh(true); return featureAllows('allowlist', new Set(), uid, registry, 'proactive'); } });
  const list = auth => svc.handle(new Request('https://x/functions/v1/catpaw-proactive/tasks', { headers: { authorization: auth } }));
  let r = await list('Bearer u1'); assert.equal(r.status, 403); assert.match(await r.text(), /feature_disabled/);
  await es.redeem(U1, await hashInviteCode(normalizeInviteCode(code)));
  r = await list('Bearer u1'); assert.equal(r.status, 200);
  assert.equal((await list('Bearer u2')).status, 403);
});
