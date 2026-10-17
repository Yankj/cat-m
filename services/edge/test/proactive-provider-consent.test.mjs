// p90 F4 (deploy-approval §9): catpaw-proactive never calls Gemini (or any free-tier-may-train route) without the user's
// consent for that route, and each provider only ever sees its own key.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readConfig } from '../supabase/functions/_shared/config.mjs';
import { reminderModelFor } from '../supabase/functions/_shared/proactive/model.mjs';
import { createDecisionModel } from '../supabase/functions/_shared/proactive/decision-model.mjs';

const OR = 'or-key-AAAA', GM = 'gm-key-BBBB';
const env = { CATPAW_PRIVATE_MODEL_KEY: OR, CATPAW_GEMINI_API_KEY: GM, CATPAW_MODEL_ROUTE_ORDER: 'gemini,openrouter' };
const get = n => env[n];
const ok = content => Response.json({ choices: [{ message: { content } }] });
const task = { title: '交房租', notes: '私密备注', time_zone: 'Asia/Shanghai', fire_count: 0, recurrence: null };

test('F4 reminder text (scheduler tick → model.reminder): pinned to OpenRouter even when the chain starts with Gemini', async () => {
  const cfg = readConfig(get);
  const calls = [];
  const m = reminderModelFor(cfg, get, { fetchImpl: async (u, o) => { calls.push({ u: String(u), auth: o.headers.authorization, body: o.body }); return ok('记得交房租'); } });
  assert.equal(await m.reminder(task, Date.UTC(2026, 9, 17)), '记得交房租');
  assert.equal(calls.length, 1);
  assert.ok(calls.every(c => !c.u.includes('googleapis.com')), 'no Gemini call for reminder text');
  assert.equal(calls[0].u, 'https://openrouter.ai/api/v1/chat/completions');
  assert.equal(calls[0].auth, 'Bearer ' + OR);
  assert.ok(!calls.some(c => c.u.includes('googleapis.com') && c.auth.includes(OR)), 'OpenRouter key never sent to Google');
});

test('F4 decision model: no consent → Gemini skipped, OpenRouter used with its own key only', async () => {
  const calls = [];
  const m = createDecisionModel({ get, fetchImpl: async (u, o) => { calls.push({ u: String(u), auth: o.headers.authorization }); return ok('{"decision":"card"}'); } });
  await m.decide({ signals: [] }, { uid: 'u1' });
  assert.ok(calls.every(c => !c.u.includes('googleapis.com')), 'Gemini not called without consent');
  assert.equal(calls[0].auth, 'Bearer ' + OR);
});

test('F4 decision model: no consent and only Gemini keyed → no call at all (rules fallback)', async () => {
  const calls = [];
  const m = createDecisionModel({ get: n => ({ CATPAW_GEMINI_API_KEY: GM })[n], fetchImpl: async u => { calls.push(String(u)); return ok('{}'); } });
  await assert.rejects(() => m.decide({ signals: [] }, { uid: 'u1' }));
  assert.deepEqual(calls, []);
});

test('F4 decision model: valid consent for the current route → Gemini used with only the Gemini key', async () => {
  const calls = [], asked = [];
  const consent = async (uid, route) => { asked.push([uid, route.id, route.routeHash]); return uid === 'u1' && route.id === 'gemini'; };
  const m = createDecisionModel({ get, consent, fetchImpl: async (u, o) => { calls.push({ u: String(u), auth: o.headers.authorization }); return ok('{"decision":"card"}'); } });
  await m.decide({ signals: [] }, { uid: 'u1' });
  assert.ok(calls[0].u.includes('googleapis.com'));
  assert.equal(calls[0].auth, 'Bearer ' + GM);
  assert.ok(calls.every(c => !c.auth.includes(OR) || !c.u.includes('googleapis.com')));
  assert.equal(asked[0][0], 'u1'); assert.match(asked[0][2], /^[0-9a-f]{16,}$/, 'consent is checked against the route hash');
  // another user without consent → no Gemini
  calls.length = 0; await m.decide({ signals: [] }, { uid: 'u2' });
  assert.ok(calls.every(c => !c.u.includes('googleapis.com')));
});
