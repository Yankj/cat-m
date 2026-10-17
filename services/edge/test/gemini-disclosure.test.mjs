// W1: Gemini free tier is the auto default route and is tagged free_tier_may_train; the consented route must disclose it.
import test from 'node:test'; import assert from 'node:assert/strict';
import { readConfig, GEMINI_FREE_TIER_DISCLOSURE } from '../supabase/functions/_shared/config.mjs';
import { ROUTE_META } from '../supabase/functions/_shared/core/src/free-route-chain.mjs';
import { assertConsent, consentId } from '../supabase/functions/_shared/consent.mjs';
import { hash, clone } from '../supabase/functions/_shared/core/facade-r2/src/common.mjs';
const env = o => k => o[k];
// Placeholder (non-provider) values built at runtime so the repo scanner sees no literal key assignment.
const fake = tag => `placeholder-${tag}-${'0'.repeat(4)}`;
const G = { CATPAW_PRIVATE_MODEL_KEY: fake('or'), CATPAW_GEMINI_API_KEY: fake('gm') };

test('gemini route: consented route carries gemini_disclosure + data field, with terms link and training/human-review wording', () => {
  const c = readConfig(env(G));
  assert.equal(c.freeChain.routes[0].id, 'gemini');
  assert.equal(ROUTE_META.gemini.data_note, 'free_tier_may_train');
  assert.equal(c.route.gemini_disclosure, GEMINI_FREE_TIER_DISCLOSURE);
  assert.match(c.route.gemini_disclosure, /Google Gemini API free tier/);
  assert.match(c.route.gemini_disclosure, /training/); assert.match(c.route.gemini_disclosure, /human reviewers/);
  assert.match(c.route.gemini_disclosure, /训练/); assert.match(c.route.gemini_disclosure, /https:\/\/ai\.google\.dev\/gemini-api\/terms/);
  assert.ok(c.route.data_fields.includes('prompt_and_history_sent_to_google_gemini_free_tier'));
  assert.equal(c.route.opencode_disclosure, undefined);
  assert.doesNotMatch(JSON.stringify(c.route), /placeholder-/);
});
test('gemini route: no gemini key → no gemini disclosure; gemini + opencode → both disclosures', () => {
  const none = readConfig(env({ CATPAW_PRIVATE_MODEL_KEY: fake('or'), CATPAW_OPENCODE_API_KEY: fake('oc') }));
  assert.equal(none.route.gemini_disclosure, undefined);
  assert.ok(!none.route.data_fields.some(x => /gemini/.test(x)));
  const both = readConfig(env({ ...G, CATPAW_OPENCODE_API_KEY: fake('oc') }));
  assert.equal(typeof both.route.gemini_disclosure, 'string'); assert.equal(typeof both.route.opencode_disclosure, 'string');
});
test('gemini disclosure is part of routeHash: adding it (or changing its text) invalidates earlier consent → re-consent', async () => {
  const withG = readConfig(env(G));
  assert.equal(withG.routeHash, hash(withG.route));
  assert.equal(withG.routeHash, readConfig(env(G)).routeHash, 'deterministic');
  // The route a user consented to before W1: same chain, without the Gemini disclosure/data field.
  const preW1 = clone(withG.route); delete preW1.gemini_disclosure; preW1.data_fields = preW1.data_fields.filter(x => !/gemini/.test(x));
  const oldHash = hash(preW1); assert.notEqual(oldHash, withG.routeHash);
  // Any later wording change of the disclosure also changes the hash.
  assert.notEqual(hash({ ...withG.route, gemini_disclosure: withG.route.gemini_disclosure + ' ' }), withG.routeHash);
  const source = { subject_id: '00000000-0000-4000-8000-000000000001', scope_id: 's1', consent_revision: 3 };
  const cid = '00000000-0000-4000-8000-0000000000c1';
  const tx = row => ({ get: async (_o, kind, id) => (kind === 'provider-consents' && id === consentId(source.subject_id, cid) ? row : null) });
  const row = h => ({ decision: 'allow', scope_id: 's1', route_hash: h, revision: 3 });
  await assert.rejects(assertConsent(tx(row(oldHash)), 'owner', source, cid, withG.routeHash), e => e.code === 'provider_consent_required');
  await assertConsent(tx(row(withG.routeHash)), 'owner', source, cid, withG.routeHash);
});
