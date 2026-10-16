// Codex PR90 round 7 (c8aee26): every push state change bound to its generation; a sender whose claim was recovered
// never sends; unknown outcomes are not blindly resent; per-generation retry budget; late until kept (any age).
import test from 'node:test'; import assert from 'node:assert/strict';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';

const U = crypto.randomUUID(), BASE = '/catpaw/proactive/v1';
const TOK = { device_id: 'd1', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw' };
const fakeLLM = { lastRoute: () => 'fake', decide: async () => ({ decision: 'notify', reason: '该出发了', confidence: 0.9, suggested_actions: ['snooze', 'dismiss'] }) };
function setup({ t = '2026-10-15T02:00:00Z', apns, store = createMemoryStore() } = {}) {
  const clock = { t: Date.parse(t) }, sent = [];
  apns ??= { configured: true, send: async (tk, ev) => { sent.push(ev.id); return { ok: true }; } };
  const decision = createDecisionService({ store, model: fakeLLM, now: () => clock.t });
  const svc = createProactiveService({ store, decision, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
  const call = async (method, path, body) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: 'Bearer u' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { clock, store, svc, call, sent };
}
const meeting = () => ({ context: { time_zone: 'Asia/Shanghai', delivery: 'remote' }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'g-' + crypto.randomUUID(), data: { title: '评审', minutes_until: 20 } }] });
const gate = () => { let open; const p = new Promise(r => { open = r; }); return { p, open }; };

test('PR90g #4: a pre-claim decision of an old generation cannot overwrite the re-armed round (no_device)', async () => {
  const store = createMemoryStore(), g = gate(); let hold = true;
  const real = store.tokensFor.bind(store);
  store.tokensFor = async uid => { if (hold) { hold = false; await g.p; return []; } return real(uid); };
  const { call, svc, clock } = setup({ store }); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  const old = svc.flushPush(); await new Promise(r => setTimeout(r, 10));        // old worker read gen 0, waits for tokens
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-g1', minutes: 10 });
  clock.t += 11 * 60_000; await store.resurfaceSnoozed(new Date(clock.t).toISOString());   // gen 1
  g.open(); await old;                                                            // old: "no tokens" → no_device
  const ev = await store.getEvent(U, id);
  assert.equal(ev.push_state, 'pending', 'gen 1 untouched by the gen 0 decision'); assert.equal(ev.push_generation, 1);
});

test('PR90g #4: a sender whose claim was recovered after the lease never sends (one send in total)', async () => {
  const store = createMemoryStore(), g = gate(); let hold = true, sends = 0;
  const real = store.markPushAttempt.bind(store);
  store.markPushAttempt = async (...a) => { if (hold) { hold = false; await g.p; } return real(...a); };
  const apns = { configured: true, send: async () => { sends++; return { ok: true }; } };
  const { call, svc, clock } = setup({ store, apns }); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  const old = svc.flushPush(); await new Promise(r => setTimeout(r, 10));        // claimed, paused before marking the attempt
  clock.t += 10 * 60_000; await svc.flushPush();                                  // lease expired → recovered (unsent) → resent
  g.open(); await old;
  assert.equal(sends, 1, 'the stale sender lost its licence');
  assert.equal((await store.getEvent(U, id)).push_state, 'sent');
});

test('PR90g #4: unknown outcome (attempted, then crashed) is not blindly resent — recorded as outcome_unknown', async () => {
  const { call, svc, store, clock, sent } = setup(); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  const iso = () => new Date(clock.t).toISOString();
  const c = await store.claimPush(id, iso(), 0); assert.ok(c); assert.equal(await store.markPushAttempt(id, c.claim, iso()), true);
  clock.t += 10 * 60_000; await svc.flushPush();
  const ev = await store.getEvent(U, id);
  assert.deepEqual([ev.push_state, ev.push_error, ev.push_recovered], ['failed', 'outcome_unknown', 'unknown']); assert.equal(sent.length, 0);
});

test('PR90g #4: retry budget is per generation (a re-armed round is picked again after 5 earlier attempts)', async () => {
  const { call, store, clock } = setup();
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  for (let i = 0; i < 5; i++) await store.pendingPushEvents(100, new Date(clock.t).toISOString());
  assert.equal((await store.pendingPushEvents(100, new Date(clock.t).toISOString())).some(e => e.id === id), false, 'budget of gen 0 spent');
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-g2', minutes: 10 });
  clock.t += 11 * 60_000; await store.resurfaceSnoozed(new Date(clock.t).toISOString());
  assert.equal((await store.pendingPushEvents(100, new Date(clock.t).toISOString())).some(e => e.id === id), true, 'gen 1 has its own budget');
});

test('PR90g #3: an until older than 7 days is still the device until (expired), never replaced by now+10min', async () => {
  const { call, store } = setup({ t: '2026-10-17T02:00:00Z' });
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-old', until: '2026-10-08T02:10:00Z' });
  const st = (await store.getEvent(U, id)).payload.suggestion;
  assert.equal(Date.parse(st.taken.at(-1).until), Date.parse('2026-10-08T02:10:00Z')); assert.equal(st.taken.at(-1).expired, true);
});

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
test('PR90g #3: golden round trip — the server response the client decodes (fixture shared with the Swift runner)', async () => {
  const g = JSON.parse(readFileSync(new URL('./fixtures/proactive-sync-golden.json', import.meta.url)));
  // Synced 20 minutes late: the cloud's `at` is the sync time, so only `until` can give back the device's instant.
  const { call } = setup({ t: new Date(Date.parse(g.server_now) + 20 * 60_000).toISOString() });
  const ev = await call('POST', BASE + '/evaluate', { context: { time_zone: 'Asia/Shanghai' }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'golden', data: { title: '评审', minutes_until: 20 } }] });
  const id = ev.body.event_id;
  for (const r of g.requests) assert.equal((await call('POST', `${BASE}/suggestions/${id}/${r.route}`, JSON.parse(JSON.stringify(r.body).replaceAll(g.local_id, id)))).status, 200);
  const got = (await call('GET', `${BASE}/suggestions/${id}`)).body.suggestion;
  const norm = JSON.parse(JSON.stringify({ status: got.status, actions: got.actions, taken: got.taken, snooze_until: got.snooze_until, id: got.id }).replaceAll(id, g.local_id));
  const url = new URL('./fixtures/proactive-sync-golden-response.json', import.meta.url);
  if (process.env.CATPAW_WRITE_GOLDEN === '1') writeFileSync(url, JSON.stringify(norm, null, 2) + '\n');
  assert.ok(existsSync(url), 'response fixture committed'); assert.deepEqual(norm, JSON.parse(readFileSync(url)));
  assert.equal(Date.parse(norm.taken.at(-1).until), Date.parse(g.expect.snooze_until), 'the kept snooze carries its own until on the wire');
  // The device decodes this (Swift runner pr90g_roundTrip) and its next undo removes the kept snooze → pending on both sides.
  assert.equal((await call('POST', `${BASE}/suggestions/${id}/undo`, { operation_id: `undo-${id}-g1` })).status, 200);
  assert.equal((await call('GET', `${BASE}/suggestions/${id}`)).body.suggestion.status, 'pending');
});
