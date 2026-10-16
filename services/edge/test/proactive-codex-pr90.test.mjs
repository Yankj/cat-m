// Codex PR #90 review (61fa86d) regressions: cloud evaluated≠delivered, APNs delivery ownership/level/time zone.
import test from 'node:test'; import assert from 'node:assert/strict';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';

const U = crypto.randomUUID(), BASE = '/catpaw/proactive/v1';
const TOK = { device_id: 'd1', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw' };
function setup({ t = '2026-10-15T02:00:00Z', model = null } = {}) {
  const clock = { t: Date.parse(t) }, store = createMemoryStore(), sent = [];
  const apns = { configured: true, send: async (tk, ev) => { sent.push(ev); return { ok: true }; } };
  const decision = createDecisionService({ store, model, now: () => clock.t });
  const svc = createProactiveService({ store, decision, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
  const call = async (method, path, body) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: 'Bearer u' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { clock, store, svc, call, sent };
}
const meeting = (until, ctx = {}) => ({ context: { time_zone: 'Asia/Shanghai', ...ctx }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'evt-codex-1', data: { title: '评审', location: '会议室', minutes_until: until } }] });
const fakeLLM = out => ({ lastRoute: () => 'fake', decide: async () => out });

test('PR90 #1: an early silent verdict does not extend the dedupe window — the meeting is re-evaluated as it nears', async () => {
  const { call, clock } = setup();
  const seen = [];
  for (const until of [60, 50, 40, 30, 20, 10]) { const r = (await call('POST', BASE + '/evaluate', meeting(until))).body; seen.push(`${until}:${r.decision}/${r.source}`); clock.t += 10 * 60_000; }
  assert.deepEqual(seen.slice(0, 5).map(s => s.split('/')[1]), ['rules', 'rules', 'rules', 'rules', 'rules'], seen.join(' '));
  assert.equal(seen[5], '10:card/rules', seen.join(' '));
  // Delivered (non-silent) → now deduped within the window.
  assert.equal((await call('POST', BASE + '/evaluate', meeting(5))).body.source, 'dedupe');
});

test('PR90 #2: client-evaluated decisions are delivered by the device, never also by APNs', async () => {
  const { call, svc, store, sent } = setup({ model: fakeLLM({ decision: 'interrupt', reason: '来不及了', confidence: 0.95 }) });
  await store.upsertToken(U, TOK);
  const r = (await call('POST', BASE + '/evaluate', meeting(20))).body;
  assert.equal(r.decision, 'interrupt'); assert.equal(r.delivery, 'device');
  await svc.tick();
  assert.equal(sent.length, 0, 'no second (APNs) path for a device-owned decision');
});

test('PR90 #2: remote-owned decisions keep the user time zone — Honolulu 23:30 is quiet hours, not Shanghai daytime', async () => {
  // 2026-10-15T09:30Z = 23:30 Honolulu (UTC−10) = 17:30 Shanghai.
  const { call, svc, store, sent } = setup({ t: '2026-10-15T09:30:00Z', model: fakeLLM({ decision: 'interrupt', reason: '来不及了', confidence: 0.95 }) });
  await store.upsertToken(U, TOK);
  const r = (await call('POST', BASE + '/evaluate', meeting(20, { time_zone: 'Pacific/Honolulu', delivery: 'remote' }))).body;
  assert.equal(r.decision, 'card', 'same on-device rule: quiet hours → card, even for a confident interrupt');
  const ev = await store.getEvent(U, r.event_id); assert.equal(ev.payload.time_zone, 'Pacific/Honolulu');
  await svc.tick(); assert.equal(sent.length, 0);
});
