// Codex p90h review (b43ad7d) → p90i: a dismiss / snooze that lands while a multi-device push is in flight stops the
// remaining devices; the generation argument is required on every push state write.
import test from 'node:test'; import assert from 'node:assert/strict';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';

const U = crypto.randomUUID(), BASE = '/catpaw/proactive/v1';
const TOK = { device_id: 'd1', kind: 'apns', token: 'ab'.repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw' };
const fakeLLM = { lastRoute: () => 'fake', decide: async () => ({ decision: 'notify', reason: '该出发了', confidence: 0.9, suggested_actions: ['snooze', 'dismiss'] }) };
function setup({ apns, store = createMemoryStore() } = {}) {
  const clock = { t: Date.parse('2026-10-15T02:00:00Z') };
  const decision = createDecisionService({ store, model: fakeLLM, now: () => clock.t });
  const svc = createProactiveService({ store, decision, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
  const call = async (method, path, body) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: 'Bearer u' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { clock, store, svc, call };
}
const meeting = () => ({ context: { time_zone: 'Asia/Shanghai', delivery: 'remote' }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'i-' + crypto.randomUUID(), data: { title: '评审', minutes_until: 20 } }] });

for (const action of ['dismiss', 'snooze']) {
  test(`p90i P2: a ${action} while d1 is being sent stops d2 (memory)`, async () => {
    let open; const g = new Promise(r => { open = r; }), calls = [];
    const apns = { configured: true, send: async t => { calls.push(t.device_id); if (t.device_id === 'd1') await g; return { ok: true }; } };
    const { call, svc, store } = setup({ apns });
    await store.upsertToken(U, TOK); await store.upsertToken(U, { ...TOK, device_id: 'd2', token: 'cd'.repeat(32) });
    const id = (await call('POST', BASE + '/evaluate', meeting())).body.event_id;
    const flush = svc.flushPush(); await new Promise(r => setTimeout(r, 20));
    assert.equal((await call('POST', `${BASE}/suggestions/${id}/action`, { action, operation_id: 'op-i-' + action, minutes: 10 })).status, 200);
    open(); await flush;
    assert.deepEqual(calls, ['d1'], 'no device is sent after the card was ' + action + 'ed');
    const ev = await store.getEvent(U, id);
    assert.notEqual(ev.push_state, 'sending', 'the row is finished, not left to the lease');
    assert.equal(ev.push_error, 'stopped_midsend:suggestion_' + (action === 'dismiss' ? 'dismissed' : 'snoozed'));
  });
}

test('p90i: the generation argument is required on push state writes (memory store)', async () => {
  const store = createMemoryStore();
  for (const [name, args] of [['setPush', ['x', 'skipped', 'r']], ['deferPush', ['x', new Date().toISOString()]], ['claimPush', ['x', new Date().toISOString()]], ['cancelPendingPush', [U, 'x', 'r']]]) {
    await assert.rejects(() => store[name](...args), /generation_required/, name);
  }
});
