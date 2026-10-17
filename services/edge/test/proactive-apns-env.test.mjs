// 三角 deploy question 1: catpaw-proactive reads APNS_* (what production v6 reads), catpaw-api's core reads CATPAW_APNS_*.
// The proactive function accepts both: a complete APNS_* set wins, else a complete CATPAW_APNS_* set; never a mix.
import test from 'node:test'; import assert from 'node:assert/strict';
import { readProactiveApnsEnv } from '../supabase/functions/_shared/proactive/apns-env.mjs';
const legacy = { APNS_KEY_ID: 'K1', APNS_TEAM_ID: 'T1', APNS_PRIVATE_KEY: 'P1', APNS_BUNDLE_ID: 'B1' };
const shared = { CATPAW_APNS_KEY_ID: 'K2', CATPAW_APNS_TEAM_ID: 'T2', CATPAW_APNS_P8: 'P2', CATPAW_APNS_BUNDLE_ID: 'B2' };
const get = o => n => o[n];
test('APNS_* (production) is used when complete', () => {
  assert.deepEqual(readProactiveApnsEnv(get({ ...legacy, ...shared })), { keyId: 'K1', teamId: 'T1', privateKeyPem: 'P1', topic: 'B1', source: 'APNS_*' });
});
test('CATPAW_APNS_* is used when APNS_* is absent', () => {
  assert.deepEqual(readProactiveApnsEnv(get(shared)), { keyId: 'K2', teamId: 'T2', privateKeyPem: 'P2', topic: 'B2', source: 'CATPAW_APNS_*' });
});
test('an incomplete APNS_* set never mixes with CATPAW_APNS_*', () => {
  assert.equal(readProactiveApnsEnv(get({ APNS_KEY_ID: 'K1', ...shared })).source, 'CATPAW_APNS_*');
  assert.equal(readProactiveApnsEnv(get({ APNS_KEY_ID: 'K1' })).source, 'none');
  assert.equal(readProactiveApnsEnv(get({ APNS_KEY_ID: 'K1' })).keyId, undefined);
});
test('the catpaw-proactive entry reads APNs through the resolver', async () => {
  const { readFileSync } = await import('node:fs');
  const src = readFileSync(new URL('../supabase/functions/catpaw-proactive/index.ts', import.meta.url), 'utf8');
  assert.match(src, /createApnsSender\(readProactiveApnsEnv\(env\)\)/);
});
