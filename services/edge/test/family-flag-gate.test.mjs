// Deploy review: CATPAW_FAMILY_ENABLED behaviour through the real API handler (createCloudRuntime + r.api).
// off (unset / empty / off / false / 0) -> every /catpaw/family/v1/* path is 404; on -> served; allowlist -> listed subject only.
import test from 'node:test'; import assert from 'node:assert/strict'; import { randomUUID } from 'node:crypto';
import { readConfig } from '../supabase/functions/_shared/config.mjs'; import { createCloudRuntime } from '../supabase/functions/_shared/api.mjs';
import { TestRepository } from '../supabase/functions/_shared/core/integration/server-foundation/src/test-repository.mjs';
const base = { CATPAW_DATABASE_URL: 'postgres://unit.invalid/db', CATPAW_PRIVATE_MODEL_KEY: 'offline-placeholder', CATPAW_TICK_HMAC_KEY: 'offline-hmac-placeholder-at-least-32', CATPAW_MEMORY_GUARD_KEY: 'offline-guard-placeholder', SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', CATPAW_PUBLISHABLE_KEY: 'offline-public-key' };
const A = randomUUID(), B = randomUUID();
const familyStore = { households: async () => [], reader: async () => null };   // only /bootstrap is exercised when on
async function api(env) {
  const config = readConfig(n => ({ ...base, ...env })[n]);
  const r = await createCloudRuntime({ repository: new TestRepository(), config, authenticate: () => { throw new Error('unused'); }, familyStore, autoKick: false,
    verifyToken: async h => { const m = /^Bearer (.+)$/.exec(h ?? ''); return m ? { iss: base.SUPABASE_URL + '/auth/v1', sub: m[1], exp: Math.floor(Date.now() / 1000) + 600 } : null; }, diagnostic: () => {} });
  return (who, path) => r.api(new Request('https://unit.invalid' + path, { headers: { Authorization: 'Bearer ' + who } })).then(x => x.status);
}
const PATHS = ['/catpaw/family/v1/bootstrap', `/catpaw/family/v1/households/${randomUUID()}/projection`, `/catpaw/family/v1/households/${randomUUID()}/memories/recall?q=x`];

for (const v of [undefined, '', 'off', 'false', '0']) {
  test(`CATPAW_FAMILY_ENABLED=${JSON.stringify(v)}: every family path 404`, async () => {
    const call = await api(v === undefined ? {} : { CATPAW_FAMILY_ENABLED: v });
    for (const p of PATHS) assert.equal(await call(A, p), 404, p);
  });
}
test('CATPAW_FAMILY_ENABLED=true: family served', async () => {
  const call = await api({ CATPAW_FAMILY_ENABLED: 'true' });
  assert.equal(await call(A, PATHS[0]), 200); assert.equal(await call(B, PATHS[0]), 200);
});
test('CATPAW_FAMILY_ENABLED=allowlist: only allowlisted subject is served, others 404; empty allowlist serves nobody', async () => {
  const call = await api({ CATPAW_FAMILY_ENABLED: 'allowlist', CATPAW_FEATURE_ALLOWLIST_SUBJECTS: A });
  assert.equal(await call(A, PATHS[0]), 200, 'allowlisted');
  for (const p of PATHS) assert.equal(await call(B, p), 404, 'not allowlisted ' + p);
  const none = await api({ CATPAW_FAMILY_ENABLED: 'allowlist' });
  assert.equal(await none(A, PATHS[0]), 404);
});
