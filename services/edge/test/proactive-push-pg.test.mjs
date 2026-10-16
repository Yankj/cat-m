// Codex PR90f #4/#6: push generation + claim token + lease recovery on REAL Postgres (multi-connection).
// Run via scripts/pg-proactive-local.sh (creates a scratch DB, applies the stub + proactive migrations, runs deno).
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgStore } from '../supabase/functions/_shared/proactive/pg-store.mjs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const fakeLLM = { lastRoute: () => 'fake', decide: async () => ({ decision: 'notify', reason: '该出发了', confidence: 0.9, suggested_actions: ['snooze', 'dismiss'] }) };
const meeting = () => ({ context: { time_zone: 'Asia/Shanghai', delivery: 'remote' }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'pg-' + crypto.randomUUID(), data: { title: '评审', minutes_until: 20 } }] });

function rig(sql, apns, clock) {
  const U = crypto.randomUUID(), store = createPgStore(sql);
  const decision = createDecisionService({ store, model: fakeLLM, now: () => clock.t });
  const svc = createProactiveService({ store, decision, apns, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
  const call = async (m, p, b) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + p, { method: m, headers: { authorization: 'Bearer u' }, body: b ? JSON.stringify(b) : undefined })); return { status: r.status, body: await r.json() }; };
  return { U, store, svc, call };
}

test('pg: migrations — sending state + generation/claim columns', { skip: !url }, async () => {
  const sql = postgres(url, { max: 2, prepare: false, onnotice: () => {} });
  try {
    const c = await sql`select pg_get_constraintdef(oid) d from pg_constraint where conname = 'events_push_state_check'`;
    assert.match(c[0].d, /sending/);
    const cols = (await sql`select column_name from information_schema.columns where table_schema='proactive' and table_name='events'`).map(r => r.column_name);
    for (const k of ['push_generation', 'push_claim', 'push_claimed_at', 'push_attempted_at', 'push_recovered']) assert.ok(cols.includes(k), k);
  } finally { await sql.end(); }
});

test('pg: concurrent claims → exactly one claim token; claim vs dismiss → exactly one wins', { skip: !url }, async () => {
  const sql = postgres(url, { max: 8, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    const claims = await Promise.all(Array.from({ length: 8 }, () => store.claimPush(id)));
    assert.equal(claims.filter(Boolean).length, 1, JSON.stringify(claims));
    for (let i = 0; i < 10; i++) {
      const e = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
      const [c] = await Promise.all([store.claimPush(e), store.cancelPendingPush(U, e, 'suggestion_dismissed')]);
      const st = (await sql`select push_state from proactive.events where id=${e}`)[0].push_state;
      assert.ok((c && st === 'sending') || (!c && st === 'skipped'), `round ${i}: claim=${!!c} state=${st}`);
    }
  } finally { await sql.end(); }
});

test('pg: old completion after re-arm cannot swallow the new round; wrong claim never completes', { skip: !url }, async () => {
  const sql = postgres(url, { max: 5, prepare: false, onnotice: () => {} });
  try {
    let release, held = true; const sent = [];
    const apns = { configured: true, send: async (t, ev) => { if (held) { held = false; await new Promise(r => { release = r; }); } sent.push(ev.id); return { ok: true }; } };
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, svc, call } = rig(sql, apns, clock);
    await sql`insert into auth.users(id) values(${U})`;
    await call('PUT', '/devices/tokens', { device_id: 'd', kind: 'apns', token: 'ab'.repeat(32), bundle_id: 'b' });
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    const first = svc.flushPush(); await new Promise(r => setTimeout(r, 100));
    assert.equal((await sql`select push_state from proactive.events where id=${id}`)[0].push_state, 'sending');
    await call('POST', `/catpaw/proactive/v1/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-pg-s', minutes: 10 });
    await sql`select count(*) from proactive.resurface_snoozed_suggestions(${new Date(clock.t + 11 * 60_000).toISOString()}::timestamptz)`;
    const g = (await sql`select push_state, push_generation from proactive.events where id=${id}`)[0];
    assert.equal(g.push_state, 'pending'); assert.equal(g.push_generation, 1);
    release(); await first;
    assert.equal((await sql`select push_state from proactive.events where id=${id}`)[0].push_state, 'pending', 'old claim lost');
    clock.t += 11 * 60_000; await svc.flushPush();
    assert.equal(sent.length, 2);
    assert.equal(await store.finishPush(id, crypto.randomUUID(), 'failed', 'x'), false);
  } finally { await sql.end(); }
});

test('pg: lease recovery — unsent and unknown claims are re-armed exactly once', { skip: !url }, async () => {
  const sql = postgres(url, { max: 5, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const a = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id, b = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    const ca = await store.claimPush(a), cb = await store.claimPush(b); await store.markPushAttempt(b, cb.claim);
    const later = new Date(Date.now() + 10 * 60_000).toISOString();
    const n = await Promise.all([store.recoverStalePush(later, 120), store.recoverStalePush(later, 120)]);
    assert.ok(n[0] + n[1] >= 2, 'both stale claims recovered');
    const rows = await sql`select id, push_state, push_recovered, push_generation from proactive.events where id in (${a}, ${b})`;
    const m = Object.fromEntries(rows.map(r => [r.id, r]));
    assert.equal(m[a].push_generation, 1); assert.equal(m[b].push_generation, 1, 'two concurrent recoverers re-arm each row exactly once');
    assert.equal(m[a].push_state, 'pending'); assert.equal(m[a].push_recovered, 'unsent'); assert.equal(m[b].push_recovered, 'unknown');
    assert.equal(await store.finishPush(a, ca.claim, 'sent', null), false, 'stale claim cannot complete after recovery');
  } finally { await sql.end(); }
});

test('pg: offline device suggestion create is idempotent across concurrent calls (dedupe by client id)', { skip: !url }, async () => {
  const sql = postgres(url, { max: 5, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const body = { client_id: 'local-' + crypto.randomUUID(), title: '评审', reason: 'r', actions: ['snooze', 'dismiss'], decision: 'notify' };
    const rs = await Promise.all([1, 2, 3].map(() => call('POST', '/catpaw/proactive/v1/suggestions', body)));
    assert.ok(rs.every(r => r.status === 200), JSON.stringify(rs.map(r => r.body)));
    assert.equal(new Set(rs.map(r => r.body.suggestion.id)).size, 1, 'one cloud record');
    const row = (await sql`select push_state, payload->>'delivery' d from proactive.events where id=${rs[0].body.suggestion.id}`)[0];
    assert.equal(row.push_state, 'skipped'); assert.equal(row.d, 'device');
  } finally { await sql.end(); }
});
