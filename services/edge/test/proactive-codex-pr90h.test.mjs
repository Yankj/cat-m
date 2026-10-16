// Codex PR90 round 8 (4a0035a review, p90h): the cancel write is bound to the generation the action saw; every new
// external send of a multi-device push re-checks the licence.
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

test('PR90h #1: an old snooze\'s cancel that lands after the snooze resurfaced (next generation) never cancels the new round', async () => {
  const store = createMemoryStore(), g = gate(); let hold = true;
  const real = store.cancelPendingPush.bind(store);
  store.cancelPendingPush = async (...a) => { if (hold) { hold = false; await g.p; } return real(...a); };
  const { call, clock } = setup({ store }); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  const snooze = call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-h1', minutes: 10 });
  await new Promise(r => setTimeout(r, 20));                                       // snooze applied, cancel paused
  clock.t += 11 * 60_000; await store.resurfaceSnoozed(new Date(clock.t).toISOString());   // gen 1, pending again
  g.open(); await snooze;                                                         // the old cancel resumes
  const ev = await store.getEvent(U, id);
  assert.deepEqual([ev.push_state, ev.push_generation, ev.push_error ?? null], ['pending', 1, null], 'gen 1 reminder not swallowed by the gen 0 cancel');
  assert.equal(ev.payload.suggestion.status, 'pending');
});

test('PR90h #1: the cancel of the current generation still works', async () => {
  const { call, store } = setup(); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'dismiss', operation_id: 'op-h2' });
  const ev = await store.getEvent(U, id);
  assert.deepEqual([ev.push_state, ev.push_error], ['skipped', 'suggestion_dismissed']);
});

test('PR90h #2: multi-device — a lease that expires mid-send stops the remaining devices', async () => {
  const store = createMemoryStore(), g = gate(), calls = [];
  const apns = { configured: true, send: async t => { calls.push(t.device_id); if (t.device_id === 'd1') await g.p; return { ok: true }; } };
  const { call, svc, clock } = setup({ store, apns });
  await store.upsertToken(U, TOK); await store.upsertToken(U, { ...TOK, device_id: 'd2', token: 'cd'.repeat(32) });
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  const old = svc.flushPush(); await new Promise(r => setTimeout(r, 20));         // d1 in flight
  clock.t += 10 * 60_000; await svc.flushPush();                                  // lease expired → failed / outcome_unknown, gen 1
  g.open(); await old;
  const ev = await store.getEvent(U, id);
  assert.deepEqual([ev.push_state, ev.push_error, ev.push_generation], ['failed', 'outcome_unknown', 1]);
  assert.deepEqual(calls, ['d1'], 'no new external send after the licence was lost');
});

test('PR90h #2: multi-device — with the licence held, every device is sent', async () => {
  const calls = [], apns = { configured: true, send: async t => { calls.push(t.device_id); return { ok: true }; } };
  const { call, svc, store } = setup({ apns });
  await store.upsertToken(U, TOK); await store.upsertToken(U, { ...TOK, device_id: 'd2', token: 'cd'.repeat(32) });
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  await svc.flushPush();
  assert.deepEqual(calls.sort(), ['d1', 'd2']); assert.equal((await store.getEvent(U, id)).push_state, 'sent');
});

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
test('PR90h #3: a cloud card carries its write-back identity (server_id) on the wire the client decodes', async () => {
  const { call } = setup();
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  const got = (await call('GET', `${BASE}/suggestions/${id}`)).body.suggestion;
  assert.equal(got.server_id, id, 'server_id = the record the device writes back to');
  const norm = JSON.parse(JSON.stringify({ id: got.id, server_id: got.server_id, title: got.title, reason: got.reason, status: got.status, actions: got.actions, taken: got.taken, createdAt: got.createdAt }).replaceAll(id, 'SERVER-ID'));
  norm.createdAt = '2026-10-15T02:00:00.000Z';
  const url = new URL('./fixtures/proactive-cloud-card.json', import.meta.url);
  if (process.env.CATPAW_WRITE_GOLDEN === '1') writeFileSync(url, JSON.stringify(norm, null, 2) + '\n');
  assert.ok(existsSync(url), 'cloud card fixture committed'); assert.deepEqual(norm, JSON.parse(readFileSync(url)));
});
test('PR90h #3: an offline-created card comes back with its client_id (the device maps it onto its own card)', async () => {
  const { call } = setup();
  const r = await call('POST', BASE + '/suggestions', { client_id: 'local-abc', title: '离线建议', reason: 'r', actions: ['snooze', 'dismiss'] });
  assert.equal(r.body.suggestion.client_id, 'local-abc'); assert.equal(r.body.suggestion.server_id, r.body.event_id);
});
test('PR90h #3: full round trip — the device requests for a cloud card, replayed on the real service (snooze → dismiss → undo restores → undo again)', async () => {
  const g = JSON.parse(readFileSync(new URL('./fixtures/proactive-cloud-card-requests.json', import.meta.url)));
  const { call, clock } = setup();
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  const seen = [];
  for (const [i, r] of g.requests.entries()) {
    const body = JSON.parse(JSON.stringify(r.body).replaceAll('SERVER-ID', id));
    if (body.action === 'snooze') body.until = new Date(clock.t + 10 * 60_000).toISOString();
    const res = await call('POST', BASE + '/' + r.path.replaceAll('SERVER-ID', id), body);
    assert.equal(res.status, 200, r.path);
    seen.push((await call('GET', `${BASE}/suggestions/${id}`)).body.suggestion.status);
    if (i === 2) { const s = (await call('GET', `${BASE}/suggestions/${id}`)).body.suggestion; assert.equal(Date.parse(s.taken.at(-1).until), clock.t + 10 * 60_000, 'restored snooze keeps its own until'); }
  }
  assert.deepEqual(seen, g.expect_status_after);
});
