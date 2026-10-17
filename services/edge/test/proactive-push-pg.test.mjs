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

// Runs first: later tests flush every pending row (any user).
test('pg: upgrade with old data — legacy rows seeded before 20261017020000/030000 are migrated', { skip: !url }, async () => {
  const sql = postgres(url, { max: 2, prepare: false, onnotice: () => {} });
  try {
    const rows = await sql`select dedupe_key, push_state, push_error, push_recovered, push_generation, push_claim from proactive.events where dedupe_key like 'upgrade-seed-%' order by dedupe_key`;
    assert.equal(rows.length, 3, 'seed present (scripts/pg-proactive-local.sh seeds before the PR90 migrations)');
    const m = Object.fromEntries(rows.map(r => [r.dedupe_key, r]));
    assert.deepEqual([m['upgrade-seed-pending'].push_state, m['upgrade-seed-pending'].push_generation], ['pending', 0], 'pending kept');
    assert.equal(m['upgrade-seed-sent'].push_state, 'sent', 'terminal kept');
    const s = m['upgrade-seed-sending'];
    assert.deepEqual([s.push_state, s.push_error, s.push_recovered], ['failed', 'outcome_unknown_legacy', 'unknown'], 'a legacy sending row is resolved, never stuck');
  } finally { await sql.end(); }
});

// 三角 deploy question 3: what 20261017010000 does to production v6 rows (no payload.delivery). Runs early (before flushes).
test('pg: upgrade from v6 — legacy pending proactive rows without delivery are skipped auditable (legacy_no_delivery), never sent; explicit remote kept; non-proactive untouched', { skip: !url }, async () => {
  const sql = postgres(url, { max: 2, prepare: false, onnotice: () => {} });
  try {
    const rows = await sql`select dedupe_key, push_state, push_error from proactive.events where dedupe_key like 'v6-seed-%'`;
    const m = Object.fromEntries(rows.map(r => [r.dedupe_key, [r.push_state, r.push_error]]));
    assert.equal(rows.length, 5, 'seed present');
    assert.deepEqual(m['v6-seed-pending-null'], ['skipped', 'legacy_no_delivery'], 'legacy (ambiguous owner) → skipped with its own, reversible-by-query marker');
    assert.deepEqual(m['v6-seed-pending-device'], ['skipped', 'device_owned']);
    assert.deepEqual(m['v6-seed-pending-remote'][0], 'pending', 'an explicit remote hand-off is still pushed');
    assert.deepEqual(m['v6-seed-sent-null'], ['sent', null], 'terminal rows untouched');
    assert.deepEqual(m['v6-seed-agent'][0], 'pending', 'task / agent pushes untouched');
  } finally { await sql.end(); }
});

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
    const claims = await Promise.all(Array.from({ length: 8 }, () => store.claimPush(id, null, 0)));
    assert.equal(claims.filter(Boolean).length, 1, JSON.stringify(claims));
    for (let i = 0; i < 10; i++) {
      const e = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
      const [c] = await Promise.all([store.claimPush(e, null, 0), store.cancelPendingPush(U, e, 'suggestion_dismissed', 0)]);
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
    const ca = await store.claimPush(a, null, 0), cb = await store.claimPush(b, null, 0); await store.markPushAttempt(b, cb.claim);
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

test('pg: daily cap counts by delivery day (deliver_at), not creation day', { skip: !url }, async () => {
  const sql = postgres(url, { max: 3, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, call, store } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const m = ctx => ({ context: { time_zone: 'Asia/Shanghai', ...ctx }, signals: [{ type: 'meeting_upcoming', source: 'calendar', dedupe_key: 'evt-' + crypto.randomUUID(), data: { title: '评审', minutes_until: 20 } }] });
    for (let i = 0; i < 2; i++) await call('POST', '/catpaw/proactive/v1/evaluate', m({ evaluate_at: '2026-10-16T02:00:00.000Z' }));
    const day = (s, e) => store.countDecisionsForDay(U, s, e, ['notify', 'interrupt']);
    assert.equal(await day('2026-10-15T16:00:00Z', '2026-10-16T16:00:00Z'), 2, 'charged to the fire day');
    assert.equal(await day('2026-10-14T16:00:00Z', '2026-10-15T16:00:00Z'), 0, 'not to the creation day');
  } finally { await sql.end(); }
});

// ── Codex PR90g ────────────────────────────────────────────────────────────────────────────────────────────────
test('pg: every pre-claim change is bound to the generation it read (setPush / deferPush / claimPush)', { skip: !url }, async () => {
  const sql = postgres(url, { max: 3, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    await sql`update proactive.events set push_generation = 1 where id = ${id}`;             // re-armed meanwhile
    await store.setPush(id, 'no_device', null, 0); await store.deferPush(id, new Date(clock.t + 3600_000).toISOString(), 0);
    assert.equal(await store.claimPush(id, null, 0), null, 'old generation cannot claim');
    const r = (await sql`select push_state, push_after from proactive.events where id=${id}`)[0];
    assert.equal(r.push_state, 'pending'); assert.equal(r.push_after, null);
  } finally { await sql.end(); }
});

test('pg: a recovered claim cannot mark an attempt (stale sender blocked); unknown → outcome_unknown, never resent', { skip: !url }, async () => {
  const sql = postgres(url, { max: 3, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const a = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id, b = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    const t0 = '2026-10-15T02:00:00Z', later = '2026-10-15T02:10:00Z';
    const ca = await store.claimPush(a, t0, 0), cb = await store.claimPush(b, t0, 0);
    assert.equal(await store.markPushAttempt(b, cb.claim, t0), true);
    await store.recoverStalePush(later, 120);
    assert.equal(await store.markPushAttempt(a, ca.claim, later), false, 'recovered claim lost its licence');
    const m = Object.fromEntries((await sql`select id, push_state, push_error, push_recovered from proactive.events where id in (${a}, ${b})`).map(r => [r.id, r]));
    assert.equal(m[a].push_state, 'pending'); assert.equal(m[a].push_recovered, 'unsent');
    assert.deepEqual([m[b].push_state, m[b].push_error, m[b].push_recovered], ['failed', 'outcome_unknown', 'unknown']);
  } finally { await sql.end(); }
});

test('pg: retry budget per generation — resurface resets push_attempts', { skip: !url }, async () => {
  const sql = postgres(url, { max: 3, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    await call('POST', `/catpaw/proactive/v1/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-pg-b', minutes: 10 });
    await sql`update proactive.events set push_attempts = 5, push_state = 'sent' where id = ${id}`;
    await sql`select count(*) from proactive.resurface_snoozed_suggestions(${new Date(clock.t + 11 * 60_000).toISOString()}::timestamptz)`;
    const r = (await sql`select push_state, push_attempts, push_generation from proactive.events where id=${id}`)[0];
    assert.deepEqual([r.push_state, r.push_attempts, r.push_generation], ['pending', 0, 1]);
  } finally { await sql.end(); }
});

test('pg: evidence — concurrent claims really ran on distinct server connections', { skip: !url }, async () => {
  const sql = postgres(url, { max: 6, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    const r = await Promise.all(Array.from({ length: 6 }, () => sql.begin(async t => {
      const [p] = await t`select pg_backend_pid() pid`; await t`select pg_sleep(0.05)`;
      const c = await t`update proactive.events set push_state='sending', push_claim=gen_random_uuid() where id=${id} and push_state='pending' returning push_claim`;
      return { pid: p.pid, won: c.length === 1 };
    })));
    const pids = new Set(r.map(x => x.pid)); console.log(`pg-evidence: ${pids.size} backend pids ${[...pids].join(',')}; winners=${r.filter(x => x.won).length}`);
    assert.ok(pids.size >= 2, 'multi-connection'); assert.equal(r.filter(x => x.won).length, 1);
  } finally { await sql.end(); }
});

// PR90h #1 / #2 on real Postgres.
test('pg PR90h: an old snooze cancel arriving after the resurface (next generation) is a no-op', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    let open; const g = new Promise(r => { open = r; }), real = store.cancelPendingPush.bind(store); let hold = true;
    store.cancelPendingPush = async (...a) => { if (hold) { hold = false; await g; } return real(...a); };
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    const snooze = call('POST', `/catpaw/proactive/v1/suggestions/${id}/action`, { action: 'snooze', operation_id: 'op-pgh1', minutes: 10 });
    await new Promise(r => setTimeout(r, 100));
    clock.t += 11 * 60_000; await store.resurfaceSnoozed(new Date(clock.t).toISOString());
    open(); await snooze;
    const [r] = await sql`select push_state, push_generation, push_error, payload->'suggestion'->>'status' s from proactive.events where id=${id}`;
    assert.deepEqual([r.push_state, r.push_generation, r.push_error, r.s], ['pending', 1, null, 'pending']);
  } finally { await sql.end(); }
});
test('pg PR90h: multi-device — the lease expires during the first device send → no further device is sent', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    let open; const g = new Promise(r => { open = r; }), calls = [];
    const apns = { configured: true, send: async t => { calls.push(t.device_id); if (t.device_id === 'pgd1') await g; return { ok: true }; } };
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, svc, call } = rig(sql, apns, clock);
    await sql`insert into auth.users(id) values(${U})`;
    for (const d of ['pgd1', 'pgd2']) await store.upsertToken(U, { device_id: d, kind: 'apns', token: (d === 'pgd1' ? 'ab' : 'cd').repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw', activity_id: null });
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    await sql`update proactive.events set push_state='skipped' where push_state='pending' and id<>${id}`;   // isolate from other users' rows
    const old = svc.flushPush(); for (let i = 0; i < 50 && !calls.length; i++) await new Promise(r => setTimeout(r, 20));
    clock.t += 10 * 60_000; await store.recoverStalePush(new Date(clock.t).toISOString(), 300);
    open(); await old;
    const [r] = await sql`select push_state, push_error, push_generation from proactive.events where id=${id}`;
    assert.deepEqual([r.push_state, r.push_error, r.push_generation], ['failed', 'outcome_unknown', 1]);
    assert.deepEqual(calls, ['pgd1'], 'no new external send after the licence was lost');
  } finally { await sql.end(); }
});

// p90g review: the multi-connection evidence must come from the production claim (PgStore.claimPush), not inline SQL.
test('pg evidence: PgStore.claimPush from 6 connections — all observed waiting on distinct backends, exactly one claim', { skip: !url }, async () => {
  const sql = postgres(url, { max: 6, prepare: false, onnotice: () => {} }), lock = postgres(url, { max: 1, prepare: false, onnotice: () => {} }), obs = postgres(url, { max: 1, prepare: false, onnotice: () => {} });
  try {
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, call } = rig(sql, { configured: true, send: async () => ({ ok: true }) }, clock);
    await sql`insert into auth.users(id) values(${U})`;
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    let release; const held = new Promise(r => { release = r; });
    const locker = lock.begin(async t => { await t`select id from proactive.events where id=${id} for update`; await held; });
    await new Promise(r => setTimeout(r, 50));
    const claims = Array.from({ length: 6 }, () => store.claimPush(id, new Date(clock.t).toISOString(), 0));
    let waiting = [];
    for (let i = 0; i < 100 && waiting.length < 6; i++) {
      waiting = (await obs`select pid from pg_stat_activity where wait_event_type='Lock' and query like '%push_claim=gen_random_uuid()%'`).map(r => r.pid);
      await new Promise(r => setTimeout(r, 20));
    }
    release(); await locker;
    const won = (await Promise.all(claims)).filter(Boolean);
    console.log(`pg-evidence: PgStore.claimPush waiting on ${new Set(waiting).size} distinct backends ${waiting.join(',')}; winners=${won.length}`);
    assert.equal(new Set(waiting).size, 6, 'six production claims really ran concurrently on six server connections');
    assert.equal(won.length, 1, 'exactly one claim token');
  } finally { await sql.end(); await lock.end(); await obs.end(); }
});

// p90i P2 on real Postgres: a dismiss during a multi-device push stops the remaining devices.
test('pg p90i: dismiss while d1 is being sent → d2 is not sent, row finished stopped_midsend', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    let open; const g = new Promise(r => { open = r; }), calls = [];
    const apns = { configured: true, send: async t => { calls.push(t.device_id); if (t.device_id === 'pid1') await g; return { ok: true }; } };
    const clock = { t: Date.parse('2026-10-15T02:00:00Z') }, { U, store, svc, call } = rig(sql, apns, clock);
    await sql`insert into auth.users(id) values(${U})`;
    for (const d of ['pid1', 'pid2']) await store.upsertToken(U, { device_id: d, kind: 'apns', token: (d === 'pid1' ? 'ab' : 'cd').repeat(32), environment: 'sandbox', bundle_id: 'app.catpaw', activity_id: null });
    const id = (await call('POST', '/catpaw/proactive/v1/evaluate', meeting())).body.event_id;
    await sql`update proactive.events set push_state='skipped' where push_state='pending' and id<>${id}`;
    const flush = svc.flushPush(); for (let i = 0; i < 50 && !calls.length; i++) await new Promise(r => setTimeout(r, 20));
    assert.equal((await call('POST', `/catpaw/proactive/v1/suggestions/${id}/action`, { action: 'dismiss', operation_id: 'op-pgi' })).status, 200);
    open(); await flush;
    const [r] = await sql`select push_state, push_error from proactive.events where id=${id}`;
    assert.deepEqual(calls, ['pid1']);
    assert.deepEqual([r.push_state === 'sending', r.push_error], [false, 'stopped_midsend:suggestion_dismissed']);
  } finally { await sql.end(); }
});
