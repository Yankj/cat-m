// final-513a1b1 B1 (NoBug probe final-513a1b1-agnes-probe.txt): the proactive decision model only calls a route
// without consent when it is OpenRouter (privacy + $0 price fields set) or tagged zero_retention; never a paid model.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createDecisionModel } from '../supabase/functions/_shared/proactive/decision-model.mjs';
import { ROUTE_META } from '../supabase/functions/_shared/core/src/free-route-chain.mjs';

const KEYS = { CATPAW_PRIVATE_MODEL_KEY: 'k-or', CATPAW_AGNES_API_KEY: 'k-ag', CATPAW_GEMINI_API_KEY: 'k-gm', CATPAW_GROQ_API_KEY: 'k-gq', CATPAW_OPENCODE_API_KEY: 'k-oc' };
const HOST = { 'openrouter.ai': 'openrouter', 'apihub.agnes-ai.com': 'agnes', 'generativelanguage.googleapis.com': 'gemini', 'api.groq.com': 'groq', 'opencode.ai': 'opencode' };
const ok = () => Response.json({ choices: [{ message: { content: '{"decision":"card"}' } }] });
function harness(env, { status = {} } = {}) {
  const calls = [];
  const fetchImpl = async (u, o) => {
    const url = new URL(String(u)), id = HOST[url.host] ?? url.host, body = JSON.parse(o.body);
    calls.push({ id, model: body.model, provider: body.provider ?? null, auth: o.headers.authorization });
    return status[id] ? new Response('busy', { status: status[id] }) : ok();
  };
  return { calls, model: createDecisionModel({ get: n => env[n], fetchImpl }) };
}
const PAID = /gpt-5|pro$|paid/;
function assertSafe(calls) {
  for (const c of calls) {
    const meta = ROUTE_META[c.id];
    assert.ok(c.id === 'openrouter' || meta?.data_note === 'zero_retention', `unconsented call to ${c.id}`);
    assert.ok(!PAID.test(c.model), `paid model ${c.model}`);
    if (c.id === 'openrouter') {
      assert.ok(c.model.endsWith(':free'));
      assert.equal(c.provider?.data_collection, 'deny'); assert.equal(c.provider?.allow_fallbacks, false);
      assert.deepEqual(c.provider?.max_price, { prompt: 0, completion: 0, request: 0, image: 0 });
    }
    assert.equal(c.auth, 'Bearer ' + KEYS[{ openrouter: 'CATPAW_PRIVATE_MODEL_KEY', agnes: 'CATPAW_AGNES_API_KEY', gemini: 'CATPAW_GEMINI_API_KEY', groq: 'CATPAW_GROQ_API_KEY', opencode: 'CATPAW_OPENCODE_API_KEY' }[c.id]], 'each provider only its own key');
  }
}

test('B1 probe D: only Agnes configured → no Agnes call without consent (rules fallback)', async () => {
  const { calls, model } = harness({ CATPAW_AGNES_API_KEY: 'k-ag' });
  if (model) await assert.rejects(() => model.decide({ signals: [] }, { uid: 'u1' }));
  assert.deepEqual(calls, []);
});
test('B1 probe B: OpenRouter 429 → no downgrade to Agnes without consent', async () => {
  const { calls, model } = harness({ CATPAW_PRIVATE_MODEL_KEY: 'k-or', CATPAW_AGNES_API_KEY: 'k-ag' }, { status: { openrouter: 429 } });
  await assert.rejects(() => model.decide({ signals: [] }, { uid: 'u1' }));
  assert.deepEqual(calls.map(c => c.id), ['openrouter']); assertSafe(calls);
});
test('B1 probe C: CATPAW_MODEL_ROUTE_ORDER=agnes,openrouter → Agnes skipped, OpenRouter with privacy + $0 price', async () => {
  const { calls, model } = harness({ CATPAW_PRIVATE_MODEL_KEY: 'k-or', CATPAW_AGNES_API_KEY: 'k-ag', CATPAW_MODEL_ROUTE_ORDER: 'agnes,openrouter' });
  await model.decide({ signals: [] }, { uid: 'u1' });
  assert.deepEqual(calls.map(c => c.id), ['openrouter']); assertSafe(calls);
});
test('B1 probe A: all keys, OpenRouter + OpenCode busy → only OpenRouter / zero-retention OpenCode tried; no Gemini/Groq/Agnes', async () => {
  const { calls, model } = harness(KEYS, { status: { openrouter: 429, opencode: 429 } });
  await assert.rejects(() => model.decide({ signals: [] }, { uid: 'u1' }));
  assert.deepEqual(calls.map(c => c.id).sort(), ['opencode', 'openrouter']); assertSafe(calls);
});
test('B1 probes F/G/H: paid model overrides never called', async () => {
  for (const env of [{ CATPAW_PRIVATE_MODEL_KEY: 'k-or', CATPAW_OPENROUTER_MODEL: 'openai/gpt-5' },
    { CATPAW_AGNES_API_KEY: 'k-ag', CATPAW_AGNES_MODEL: 'agnes-2.5-pro' },
    { CATPAW_OPENCODE_API_KEY: 'k-oc', CATPAW_OPENCODE_MODEL: 'claude-paid' }]) {
    const consentAll = async () => true;
    const calls = [];
    const m = createDecisionModel({ get: n => env[n], consent: consentAll, fetchImpl: async (u, o) => { calls.push(JSON.parse(o.body).model); return ok(); } });
    if (m) await m.decide({ signals: [] }, { uid: 'u1' }).catch(() => {});
    assert.deepEqual(calls, [], `paid override ${JSON.stringify(env)} must not be called`);
  }
});
test('B1: Agnes with consent only for agnes-3.0-flash / agnes-2.5-flash', async () => {
  for (const [model, allowed] of [['agnes-3.0-flash', true], ['agnes-2.5-flash', true], ['agnes-3.0-pro', false]]) {
    const calls = [];
    const m = createDecisionModel({ get: n => ({ CATPAW_AGNES_API_KEY: 'k-ag', CATPAW_AGNES_MODEL: model })[n], consent: async () => true, fetchImpl: async (u, o) => { calls.push(o.headers.authorization); return ok(); } });
    if (m) await m.decide({ signals: [] }, { uid: 'u1' }).catch(() => {});
    assert.equal(calls.length, allowed ? 1 : 0, model); if (allowed) assert.equal(calls[0], 'Bearer k-ag');
  }
});
test('B1: CATPAW_OPENCODE_BASE_URL is honoured (validated by the chain)', async () => {
  const urls = [];
  const m = createDecisionModel({ get: n => ({ CATPAW_OPENCODE_API_KEY: 'k-oc', CATPAW_OPENCODE_BASE_URL: 'https://oc.example.com/v1' })[n], fetchImpl: async u => { urls.push(String(u)); return ok(); } });
  await m.decide({ signals: [] }, { uid: 'u1' });
  assert.deepEqual(urls, ['https://oc.example.com/v1/chat/completions']);
});
