// v0.2 text loop end-to-end on REAL Postgres: HTTP handler -> pg-store -> family.apply_command (all migrations applied).
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-v02-pg.test.mjs
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgFamilyStore } from '../supabase/functions/_shared/family/pg-store.mjs';
import { createFamilyService } from '../supabase/functions/_shared/family/service.mjs';
import { requestHash } from '../supabase/functions/_shared/family/contract.mjs';
import { createCaptureRoute } from '../supabase/functions/_shared/family/captures.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const U = () => crypto.randomUUID();
const SRC = { source_kind: 'user_text', source_ref: 'turn:t1', captured_at: '2026-10-23T08:00:00+08:00' };

async function rig(sql, opts = {}) {
  const svc = createFamilyService({ store: createPgFamilyStore(sql), extraRoutes: [createCaptureRoute(opts.capture ?? {})], now: () => Date.parse('2026-10-23T09:00:00+08:00'), verifyUser: async a => { const m = /^Bearer (.+)$/.exec(a); return m ? { sub: m[1] } : null; } });
  const mk = async () => { const id = U(); await sql`insert into auth.users(id) values(${id})`; return id; };
  const call = async (who, method, path, body, raw) => {
    const r = await svc.handle(new Request('https://x/functions/v1/catpaw-api/catpaw/family/v1' + path, { method, headers: { authorization: who ? 'Bearer ' + who : '', 'content-type': 'application/json' }, body: raw ?? (body ? JSON.stringify(body) : undefined) }));
    return { status: r.status, body: await r.json() };
  };
  return { svc, mk, call };
}
async function family(call, who) {
  const hh = U(); const r = await call(who, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: hh, payload: { name: '我们家' } });
  assert.equal(r.body.status, 'applied'); return r.body.objects[0].id;
}
const cmd = (call, who, hh, c) => call(who, 'POST', `/households/${hh}/commands`, { command_id: U(), household_id: hh, ...c });

test('v0.2 text loop: propose -> pending (not schedule) -> confirm -> today schedule; receipts; reschedule needs consent; cancel', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { mk, call } = await rig(sql); const A = await mk(); const hh = await family(call, A);
    // ensure again: returns the same household, never a second one
    const again = await call(A, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: U(), payload: { name: 'x' } });
    assert.equal(again.body.objects[0].id, hh);
    assert.deepEqual((await call(A, 'GET', '/bootstrap')).body.household_ids, [hh]);
    const kid = (await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小米', class_label: '二(3)班' } })).body.objects[0].id;
    const prop = await cmd(call, A, hh, { type: 'item.propose', payload: { title: '游泳课', member_id: kid, local_date: '2026-11-05', local_time: '16:30', place: '少年宫', bring: ['泳镜', '毛巾'], source: SRC } });
    assert.equal(prop.body.status, 'applied');
    const item = prop.body.objects.find(o => o.type === 'item'), pid = prop.body.objects.find(o => o.type === 'proposal').id;
    let p = (await call(A, 'GET', `/households/${hh}/projection?local_date=2026-11-05`)).body;
    assert.equal(p.today.schedule.length, 0, 'unconfirmed is never schedule');
    assert.equal(p.today.pending_confirmations[0].title, '游泳课');
    assert.equal(p.today.pending_confirmations[0].child_display_name, '小米');
    // stale confirm -> rejected receipt, replay returns same receipt, domain unchanged
    const badId = U(); const bad = { command_id: badId, household_id: hh, type: 'item.confirm', target_id: item.id, proposal_id: pid, expected_revision: 9 };
    const r1 = await call(A, 'POST', `/households/${hh}/commands`, bad); assert.equal(r1.body.status, 'rejected'); assert.equal(r1.body.error.code, 'revision_conflict'); assert.equal(r1.body.error.recoverable, 'reread');
    const r2 = await call(A, 'POST', `/households/${hh}/commands`, bad); assert.deepEqual(r2.body, r1.body);
    const r3 = await call(A, 'POST', `/households/${hh}/commands`, { ...bad, expected_revision: 1 }); assert.equal(r3.status, 409); assert.equal(r3.body.error.code, 'idempotency_conflict');
    assert.equal(JSON.stringify(r3.body).includes('游泳'), false);
    // confirm
    const confId = U();
    const conf = await call(A, 'POST', `/households/${hh}/commands`, { command_id: confId, household_id: hh, type: 'item.confirm', target_id: item.id, proposal_id: pid, expected_revision: 1 });
    assert.equal(conf.body.status, 'applied');
    assert.equal((await call(A, 'GET', `/commands/${confId}`)).body.outcome, 'applied');
    p = (await call(A, 'GET', `/households/${hh}/projection?local_date=2026-11-05`)).body;
    assert.equal(p.today.schedule.length, 1); assert.equal(p.today.pending_confirmations.length, 0);
    assert.deepEqual(p.today.schedule[0].bring, ['泳镜', '毛巾']); assert.equal(p.today.schedule[0].local_time, '16:30');
    assert.equal(p.today.schedule[0].revision, 2);
    // reschedule without consent: rejected, nothing moves
    const noConsent = await cmd(call, A, hh, { type: 'item.reschedule', target_id: item.id, expected_revision: 2, payload: { local_date: '2026-11-06', scope: 'one_occurrence' } });
    assert.equal(noConsent.body.error.code, 'confirmation_required');
    const ok = await cmd(call, A, hh, { type: 'item.reschedule', target_id: item.id, expected_revision: 2, payload: { local_date: '2026-11-06', local_time: '17:00', scope: 'one_occurrence' }, consent: { actions: ['update_item'] } });
    assert.equal(ok.body.status, 'applied');
    assert.equal((await call(A, 'GET', `/households/${hh}/projection?local_date=2026-11-05`)).body.today.schedule.length, 0);
    assert.equal((await call(A, 'GET', `/households/${hh}/projection?local_date=2026-11-06`)).body.today.schedule[0].local_time, '17:00');
    // correct cannot smuggle a date change
    assert.equal((await cmd(call, A, hh, { type: 'item.correct', target_id: item.id, expected_revision: 3, payload: { local_date: '2026-12-01' } })).body.error.code, 'confirmation_required');
    assert.equal((await cmd(call, A, hh, { type: 'item.correct', target_id: item.id, expected_revision: 3, payload: { bring: ['泳帽'] } })).body.status, 'applied');
    // cancel
    assert.equal((await cmd(call, A, hh, { type: 'item.cancel', target_id: item.id, expected_revision: 4 })).body.status, 'applied');
    p = (await call(A, 'GET', `/households/${hh}/projection?local_date=2026-11-06`)).body;
    assert.equal(p.today.schedule.length, 0);
    // changes feed: ordered, refs only (no titles)
    const ch = (await call(A, 'GET', `/households/${hh}/changes`)).body;
    assert.ok(ch.events.length >= 6); assert.equal(JSON.stringify(ch.events).includes('游泳'), false);
    const later = (await call(A, 'GET', `/households/${hh}/changes?after=${ch.events[2].cursor}`)).body.events;
    assert.equal(later[0].cursor, ch.events[3].cursor);
  } finally { await sql.end(); }
});

test('v0.2 isolation: second adult sees nothing (HTTP + RLS as authenticated); authenticated cannot call apply_command', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { mk, call } = await rig(sql); const A = await mk(), B = await mk(); const hh = await family(call, A);
    const kidCmd = U();
    await call(A, 'POST', `/households/${hh}/commands`, { command_id: kidCmd, household_id: hh, type: 'child.upsert', payload: { display_name: '秘密名' } });
    assert.equal((await call(B, 'GET', `/households/${hh}/projection`)).status, 404);
    const w = await cmd(call, B, hh, { type: 'child.upsert', payload: { display_name: 'evil' } }); assert.equal(w.status, 404);
    assert.equal(JSON.stringify(w.body).includes('秘密'), false);
    assert.equal((await call(B, 'GET', `/commands/${kidCmd}`)).body.outcome, 'not_found');
    assert.equal((await call(B, 'GET', `/households/${hh}/changes`)).status, 404);
    // B's own household is separate; using A's household_id in ensure cannot take it over
    const take = await call(B, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: hh });
    assert.equal(take.status, 404);
    assert.equal((await call(null, 'GET', '/bootstrap')).status, 401);
    const rls = async (who) => sql.begin(async tx => { await tx`set local role authenticated`; await tx`select set_config('request.jwt.claim.sub', ${who}, true)`; return (await tx`select display_name from family.members where household_id=${hh}`).length; });
    assert.equal(await rls(A), 1); assert.equal(await rls(B), 0);
    await assert.rejects(sql.begin(async tx => { await tx`set local role authenticated`; await tx`select set_config('request.jwt.claim.sub', ${A}, true)`; await tx`insert into family.members(id,household_id,display_name) values(${U()},${hh},'x')`; }));
    await assert.rejects(sql.begin(async tx => { await tx`set local role authenticated`; await tx`select family.apply_command(${A}::uuid, '{}'::jsonb, 'x')`; }));
    await assert.rejects(sql.begin(async tx => { await tx`set local role authenticated`; await tx`select family.cmd_child_upsert(${A}::uuid, ${hh}::uuid, '{}'::jsonb)`; }));
    await assert.rejects(sql.begin(async tx => { await tx`set local role anon`; await tx`select * from family.households`; }));
  } finally { await sql.end(); }
});

test('v0.2 concurrency + idempotency on real PG: one confirm wins; same command_id twice = one write', { skip: !url }, async () => {
  const sql = postgres(url, { max: 8, prepare: false, onnotice: () => {} });
  try {
    const { mk, call } = await rig(sql); const A = await mk(); const hh = await family(call, A);
    const prop = await cmd(call, A, hh, { type: 'item.propose', payload: { title: '家长会', local_date: '2026-11-07', source: SRC } });
    const item = prop.body.objects[0].id, pid = prop.body.objects[1].id;
    const rs = await Promise.all([1, 2, 3, 4].map(() => cmd(call, A, hh, { type: 'item.confirm', target_id: item, proposal_id: pid, expected_revision: 1 })));
    assert.equal(rs.filter(r => r.body.status === 'applied').length, 1);
    assert.equal(rs.filter(r => r.body.status === 'rejected').length, 3);
    const same = { command_id: U(), household_id: hh, type: 'child.upsert', payload: { display_name: '一次' } };
    const two = await Promise.all([1, 2, 3].map(() => call(A, 'POST', `/households/${hh}/commands`, same)));
    assert.equal(new Set(two.map(t => t.body.objects?.[0]?.id)).size, 1);
    assert.equal((await sql`select count(*)::int n from family.members where household_id=${hh} and display_name='一次'`)[0].n, 1);
  } finally { await sql.end(); }
});

test('v0.2 tombstones + wire rules: deleted child never revived; duplicate keys/too large/unsafe numbers rejected; actor ignored in hash', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { mk, call } = await rig(sql); const A = await mk(); const hh = await family(call, A);
    const kid = (await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小豆' } })).body.objects[0].id;
    assert.equal((await cmd(call, A, hh, { type: 'child.delete', target_id: kid, expected_revision: 1 })).body.status, 'applied');
    const revive = await cmd(call, A, hh, { type: 'child.upsert', target_id: kid, expected_revision: 2, payload: { display_name: '小豆' } });
    assert.equal(revive.body.error.code, 'deleted');
    const p = (await call(A, 'GET', `/households/${hh}/projection`)).body;
    assert.equal(p.home.children.length, 0);
    assert.equal((await sql`select display_name from family.members where id=${kid}`)[0].display_name, '已删除', 'tombstone keeps no name');
    assert.equal((await call(A, 'POST', `/households/${hh}/commands`, null, `{"command_id":"${U()}","command_id":"${U()}"}`)).body.error.code, 'json_invalid');
    assert.equal((await call(A, 'POST', `/households/${hh}/commands`, null, JSON.stringify({ command_id: U(), household_id: hh, type: 'child.upsert', payload: { display_name: 'x'.repeat(40000) } }))).status, 413);
    assert.equal((await call(A, 'POST', `/households/${hh}/commands`, null, `{"command_id":"${U()}","household_id":"${hh}","type":"child.upsert","expected_revision":1.5}`)).body.error.code, 'json_invalid');
    const base = { command_id: U(), household_id: hh, type: 'observation.record', payload: { member_id: kid, text: 'x', source: SRC } };
    assert.equal(await requestHash({ ...base, actor_user_id: U() }), await requestHash(base));
    assert.equal((await cmd(call, A, hh, { type: 'household.update', expected_revision: 1, payload: { timezone: 'Mars/Base' } })).body.error.code, 'timezone_invalid');
  } finally { await sql.end(); }
});

test('v0.2 text capture -> confirm cards (pending only) -> confirm -> today; retry is idempotent', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { mk, call } = await rig(sql); const A = await mk(); const hh = await family(call, A);
    const kid = (await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小米' } })).body.objects[0].id;
    const cap = { capture_id: U(), kind: 'text', text: '下周三下午4点半小米游泳课，带泳镜和毛巾；周五3点接小米' };
    const r = await call(A, 'POST', `/households/${hh}/captures`, cap);
    assert.equal(r.status, 200); assert.equal(r.body.cards.length, 2);
    const [swim, pick] = r.body.cards;
    assert.deepEqual([swim.candidate.title, swim.candidate.local_date, swim.candidate.local_time, swim.candidate.member_id], ['游泳课', '2026-10-28', '16:30', kid]);
    assert.deepEqual(pick.candidate.missing, ['local_time'], '"3点" without am/pm stays unknown');
    const again = await call(A, 'POST', `/households/${hh}/captures`, cap);
    assert.deepEqual(again.body.cards.map(c => c.item_id), r.body.cards.map(c => c.item_id));
    assert.equal((await sql`select count(*)::int n from family.items where household_id=${hh}`)[0].n, 2, 'retry made no duplicates');
    let p = (await call(A, 'GET', `/households/${hh}/projection?local_date=2026-10-28`)).body;
    assert.equal(p.today.schedule.length, 0); assert.equal(p.today.pending_confirmations.length, 2);
    await cmd(call, A, hh, { type: 'item.confirm', target_id: swim.item_id, proposal_id: swim.proposal_id, expected_revision: 1 });
    p = (await call(A, 'GET', `/households/${hh}/projection?local_date=2026-10-28`)).body;
    assert.equal(p.today.schedule[0].title, '游泳课'); assert.equal(p.today.schedule[0].child_display_name, '小米');
    assert.equal(p.today.pending_confirmations.length, 1);
    assert.equal(p.conversation.recent_receipts[0].status, 'applied');
  } finally { await sql.end(); }
});
