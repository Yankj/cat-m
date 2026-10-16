// Codex PR90 round 3 (b8f6d95): server push ownership at the sender, shared rev protocol for every payload writer.
import test from 'node:test'; import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';

const U = crypto.randomUUID(), BASE = '/catpaw/proactive/v1';
const TOK = { device_id: 'd1', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw' };
const fakeLLM = out => ({ lastRoute: () => 'fake', decide: async () => out });
function setup({ t = '2026-10-15T02:00:00Z', wrap = s => s } = {}) {
  const clock = { t: Date.parse(t) }, store = wrap(createMemoryStore()), sent = [];
  const apns = { configured: true, send: async (tk, ev) => { sent.push(ev); return { ok: true }; } };
  const decision = createDecisionService({ store, model: fakeLLM({ decision: 'notify', reason: '该出发了', confidence: 0.9, suggested_actions: ['create_reminder', 'snooze', 'dismiss'] }), now: () => clock.t });
  const svc = createProactiveService({ store, decision, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
  const call = async (method, path, body) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: 'Bearer u' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { clock, store, svc, call, sent };
}
const meeting = (ctx = {}) => ({ context: { time_zone: 'Asia/Shanghai', ...ctx }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'evt-c3-' + crypto.randomUUID(), data: { title: '评审', minutes_until: 20 } }] });

test('PR90c #2: snooze expiry never re-arms an APNs push for a device-owned decision', async () => {
  const { call, svc, store, clock, sent } = setup(); await store.upsertToken(U, TOK);
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-s', minutes: 10 });
  clock.t += 11 * 60_000; await svc.tick(); await svc.tick();
  assert.equal(sent.length, 0, 'device delivers its own snooze; server must not push');
  assert.equal((await store.getEvent(U, id)).payload.suggestion.status, 'pending', 'still resurfaces in the inbox');
});

test('PR90c #2: the sender refuses device-owned / legacy pending events (historical rows), remote ones still go', async () => {
  const { svc, store, sent } = setup(); await store.upsertToken(U, TOK);
  const legacy = await store.insertEvent({ user_id: U, task_id: null, conversation_id: null, kind: 'proactive_decision', title: 'old', body: 'b', payload: { decision: 'notify', time_zone: 'Asia/Shanghai' }, dedupe_key: 'legacy-1', push_state: 'pending' });
  await svc.tick(); assert.equal(sent.length, 0, 'legacy device/unknown-owned row is not pushed');
  const remote = await store.insertEvent({ user_id: U, task_id: null, conversation_id: null, kind: 'proactive_decision', title: 'r', body: 'b', payload: { decision: 'notify', delivery: 'remote', time_zone: 'Asia/Shanghai' }, dedupe_key: 'remote-1', push_state: 'pending' });
  await svc.tick();
  assert.deepEqual(sent.map(e => e.id), [remote.id]);
  assert.equal((await store.getEvent(U, legacy.id)).push_state, 'skipped');
});

test('PR90c #2: migration fixes the SQL resurface function and historical pending rows', () => {
  const dir = new URL('../supabase/migrations/', import.meta.url), f = readdirSync(dir).find(n => n.includes('proactive_delivery_owner'));
  assert.ok(f, 'migration file exists'); const sql = readFileSync(new URL(f, dir), 'utf8');
  assert.match(sql, /create or replace function proactive\.resurface_snoozed_suggestions/);
  assert.match(sql, /payload->>'delivery'/); assert.match(sql, /'rev'/);
  assert.match(sql, /update proactive\.events[\s\S]*push_state\s*=\s*'skipped'[\s\S]*delivery/);
});

test('PR90c #3: a chat claim between an action read and its CAS write is never overwritten (no double claim)', async () => {
  let hook = null;
  const { call, store } = setup({ wrap: s => ({ ...s, async updateEventPayload(...a) { if (hook) { const h = hook; hook = null; await h(); } return s.updateEventPayload(...a); } }) });
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  hook = () => store.claimSuggestionsForChat(U, { limit: 5, at: '2026-10-15T02:00:01Z', turnID: 't1' });
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'create_reminder', operation_id: 'op-r' });
  const ev = await store.getEvent(U, id);
  assert.equal(ev.payload.suggestion.chat_turn_id, 't1', 'claim survived the action write');
  assert.equal(ev.payload.suggestion.taken.length, 1, 'action re-applied after reload');
  assert.equal((await store.claimSuggestionsForChat(U, { limit: 5, at: '2026-10-15T02:00:02Z', turnID: 't2' })).length, 0, 'no second claim');
});

test('PR90c #3: snooze resurfacing bumps rev (memory store + pg claim SQL share the protocol)', async () => {
  const { call, store, clock } = setup();
  const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-s', minutes: 10 });
  const rev = (await store.getEvent(U, id)).payload.suggestion.rev;
  await store.resurfaceSnoozed(new Date(clock.t + 11 * 60_000).toISOString());
  assert.equal((await store.getEvent(U, id)).payload.suggestion.rev, rev + 1);
  const pg = readFileSync(new URL('../supabase/functions/_shared/proactive/pg-store.mjs', import.meta.url), 'utf8');
  assert.match(pg.slice(pg.indexOf('claimSuggestionsForChat')), /'\{suggestion,rev\}'/);
});
