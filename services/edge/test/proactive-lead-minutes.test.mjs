// v10: server rules honour the client's context.lead_minutes (parity with iOS ProactiveRules.localLevel).
import test from 'node:test'; import assert from 'node:assert/strict';
import { ruleDecide, leadMinutes, createDecisionService, LEVELS } from '../supabase/functions/_shared/proactive/decision.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';

const mt = (until, travel) => [{ id: 's1', type: 'meeting_upcoming', source: 'calendar', data: { title: '产品评审会', minutes_until: until, ...(travel != null ? { travel_minutes: travel } : {}) } }];
const lv = (until, ctx, travel) => ruleDecide(mt(until, travel), ctx).decision;

test('lead 10, no travel: lead rule window 3..25; notify ≤ 15, card 16..25', () => {
  const c = { lead_minutes: 10 };
  assert.equal(lv(2, c), 'card'); assert.doesNotMatch(ruleDecide(mt(2), c).reason, /提前/);   // < 3: lead rule off, pre-v10 ≤10 card stays
  assert.equal(lv(3, c), 'notify'); assert.equal(lv(10, c), 'notify');
  assert.equal(lv(15, c), 'notify'); assert.equal(lv(16, c), 'card'); assert.equal(lv(23, c), 'card');
  assert.equal(lv(25, c), 'card'); assert.equal(lv(26, c), 'silent');
});

test('upper boundary includes travel: lead 10 + travel 20 → silent at 46, card at 45, notify at 35', () => {
  const c = { lead_minutes: 10 };
  assert.equal(lv(46, c, 20), 'silent'); assert.equal(lv(45, c, 20), 'card'); assert.equal(lv(36, c, 20), 'card'); assert.equal(lv(35, c, 20), 'notify');
  assert.equal(lv(20, c, 20), 'interrupt');   // pre-v10 travel rule still wins (highest level)
});

test('missing / invalid lead_minutes → pre-v10 behaviour exactly', () => {
  for (const ctx of [{}, { lead_minutes: null }, { lead_minutes: '10' }, { lead_minutes: 10.5 }, { lead_minutes: 0 }, { lead_minutes: -5 }, { lead_minutes: 181 }, { lead_minutes: NaN }, { lead_minutes: Infinity }, { lead_minutes: true }]) {
    assert.equal(leadMinutes(ctx), null, JSON.stringify(ctx));
    assert.equal(lv(23, ctx), 'silent'); assert.equal(lv(10, ctx), 'card'); assert.equal(lv(2, ctx), 'card'); assert.equal(lv(11, ctx), 'silent');
  }
  assert.equal(leadMinutes(undefined), null); assert.equal(leadMinutes({ lead_minutes: 1 }), 1); assert.equal(leadMinutes({ lead_minutes: 180 }), 180);
  assert.equal(lv(195, { lead_minutes: 180 }), 'card'); assert.equal(lv(196, { lead_minutes: 180 }), 'silent');
});

test('lead rule reason/confidence/actions', () => {
  const r = ruleDecide(mt(14), { lead_minutes: 10 });
  assert.equal(r.decision, 'notify'); assert.equal(r.confidence, 0.75); assert.match(r.reason, /按提前 10 分钟准备/); assert.doesNotMatch(r.reason, /习惯/);   // iOS sends its default 10 too
  assert.deepEqual(r.actions, ['create_reminder', 'notify_attendees', 'snooze', 'dismiss']);
});

async function evaluate(until, ctx, t = '2026-10-18T02:00:00Z') {
  const store = createMemoryStore();
  const svc = createDecisionService({ store, now: () => Date.parse(t) });
  return svc.evaluate(crypto.randomUUID(), { signals: mt(until), context: { time_zone: 'Asia/Shanghai', ...ctx } });
}
const levelOf = r => r.decision ?? r.body?.decision ?? r.explanation?.decision;

test('full pipeline (rules, daytime): pre-scheduled check at until = lead gets ≥ notify (iOS ProactiveQuota.prescheduleDecision needs ≥ notify)', async () => {
  for (const lead of [5, 10, 15]) {
    const r = await evaluate(lead, { lead_minutes: lead, evaluate_at: '2026-10-18T02:10:00Z' });
    assert.ok(LEVELS.indexOf(levelOf(r)) >= LEVELS.indexOf('notify'), `lead ${lead}: ${levelOf(r)}`);
  }
  assert.equal(levelOf(await evaluate(23, { lead_minutes: 10 })), 'card');
  assert.equal(levelOf(await evaluate(10, {})), 'card');      // old clients unchanged
});

test('quiet hours still degrade the lead-rule notify to card', async () => {
  assert.equal(levelOf(await evaluate(10, { lead_minutes: 10 }, '2026-10-18T15:00:00Z')), 'card');   // 23:00 Asia/Shanghai
});

// ── v10 P1-1 / P1-2: repeated pre-scheduling ──────────────────────────────────────────────────────────────────
const BASE_T = Date.parse('2026-10-18T06:00:00Z');   // meeting M1 at 14:00 Asia/Shanghai
function rig() {
  const clock = { t: 0 }, store = createMemoryStore(), svc = createDecisionService({ store, now: () => clock.t });
  const pre = (key = 'M1') => svc.evaluate('u', { signals: [{ type: 'meeting_upcoming', source: 'bg_refresh', dedupe_key: key, data: { title: '评审', minutes_until: 10 } }], context: { time_zone: 'Asia/Shanghai', lead_minutes: 10, evaluate_at: new Date(BASE_T - 10 * 60_000).toISOString() } });
  return { clock, store, svc, pre };
}

test('P1-1: pre-scheduling one meeting 6 times (35 min apart, past the dedupe window) uses one cap slot; another meeting still gets interrupt', async () => {
  const { clock, store, svc, pre } = rig();
  for (let m = 210; m >= 35; m -= 35) { clock.t = BASE_T - m * 60_000; assert.equal((await pre()).decision, 'notify', `T-${m}`); }
  const rows = (await store.listEvents('u', null, 100)).filter(e => e.payload?.decision === 'notify').length;
  assert.equal(rows, 6, 'six evaluations recorded');
  // fill 3 more distinct meetings → 4 distinct used of 5
  for (const k of ['A', 'B', 'C']) assert.equal((await pre(k)).decision, 'notify', k);
  clock.t = BASE_T - 20 * 60_000;
  const x = await svc.evaluate('u', { signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'M2', data: { title: '外出', minutes_until: 20, travel_minutes: 25 } }], context: { time_zone: 'Asia/Shanghai', lead_minutes: 10 } });
  assert.equal(x.decision, 'interrupt', JSON.stringify(x.trace));
  // a 6th distinct meeting now hits the cap (5 distinct: M1, A, B, C, M2)
  assert.equal((await pre('D')).decision, 'card');
  // ...but a meeting that already holds a slot is never capped by itself
  clock.t += 31 * 60_000; assert.equal((await pre('M1')).decision, 'notify');
});

test('P1-2: second pre-schedule inside the dedupe window replays the same notify decision (same event_id, no new row)', async () => {
  const { clock, store, pre } = rig();
  clock.t = BASE_T - 40 * 60_000; const a = await pre();
  clock.t = BASE_T - 35 * 60_000; const b = await pre();
  assert.equal(a.decision, 'notify'); assert.equal(b.decision, 'notify'); assert.equal(b.source, 'dedupe'); assert.equal(b.replayed, true);
  assert.equal(b.event_id, a.event_id, 'same delivery id → iOS replaces, never duplicates');
  assert.equal(b.suggestion.id, a.suggestion.id); assert.equal(b.reason, a.reason);
  assert.equal((await store.listEvents('u', null, 100)).length, 1, 'replay writes nothing');
});

test('P1-2: a dismissed suggestion is not revived by a replay (stays silent)', async () => {
  const { clock, store, pre } = rig();
  clock.t = BASE_T - 40 * 60_000; const a = await pre();
  const ev = await store.getEvent('u', a.event_id); ev.payload.suggestion.status = 'dismissed'; await store.updateEventPayload('u', a.event_id, ev.payload, ev.payload.suggestion.rev ?? 0);
  clock.t = BASE_T - 35 * 60_000; const b = await pre();
  assert.equal(b.decision, 'silent'); assert.equal(b.source, 'dedupe');
});
