// v0.4 on REAL Postgres: household memory correct / pause / delete + recall, restrained reminders + dispatcher lease.
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-v04-pg.test.mjs
import test from 'node:test'; import assert from 'node:assert/strict';
import { runtimeOf } from './support/pg-runtime.mjs';
import postgres from 'npm:postgres@3.4.7';
import { createPgFamilyStore } from '../supabase/functions/_shared/family/pg-store.mjs';
import { createFamilyService } from '../supabase/functions/_shared/family/service.mjs';
import { createMemoryRoute, runReminderTick } from '../supabase/functions/_shared/family/memory.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const U = () => crypto.randomUUID();
const SRC = { source_kind: 'user_text', source_ref: 'turn:m1' };
function rig(sql) {
  const store = createPgFamilyStore(runtimeOf(sql));
  const svc = createFamilyService({ store, extraRoutes: [createMemoryRoute()], verifyUser: async a => { const m = /^Bearer (.+)$/.exec(a); return m ? { sub: m[1] } : null; } });
  const call = async (who, method, path, body) => { const r = await svc.handle(new Request('https://x/catpaw/family/v1' + path, { method, headers: { authorization: 'Bearer ' + who, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { store, call };
}
async function setup(sql, call) {
  const A = U(); await sql`insert into auth.users(id) values(${A})`;
  const hh = (await call(A, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: U() })).body.objects[0].id;
  return { A, hh };
}
const cmd = (call, who, hh, c) => call(who, 'POST', `/households/${hh}/commands`, { command_id: U(), household_id: hh, ...c });
const recall = (call, who, hh, q, extra = '') => call(who, 'GET', `/households/${hh}/memories/recall?q=${encodeURIComponent(q)}${extra}`);

test('v0.4 memory: save, recall across sessions, correct (CAS, old text gone), delete (no revival), pause/resume', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { call } = rig(sql); const { A, hh } = await setup(sql, call);
    const kid = (await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小米' } })).body.objects[0].id;
    const other = (await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小豆' } })).body.objects[0].id;
    const m1 = (await cmd(call, A, hh, { type: 'memory.upsert', payload: { member_id: kid, text: '小米对花生过敏', source: SRC } })).body.objects[0];
    await cmd(call, A, hh, { type: 'memory.upsert', payload: { member_id: other, text: '小豆喜欢吃花生酱', source: SRC } });
    await cmd(call, A, hh, { type: 'memory.upsert', payload: { member_id: kid, text: '小米周三下午游泳', source: SRC } });
    // new session = new service instance, same DB
    const s2 = rig(sql);
    let r = (await recall(s2.call, A, hh, '小米能吃花生吗', `&member_id=${kid}`)).body.results;
    assert.equal(r[0].memory_id, m1.id); assert.equal(r.some(x => x.member_id === other), false, 'other child filtered out');
    // late correction against old revision is rejected and keeps newer text
    assert.equal((await cmd(call, A, hh, { type: 'memory.correct', target_id: m1.id, expected_revision: 1, payload: { text: '小米对花生和腰果过敏' } })).body.status, 'applied');
    const late = await cmd(call, A, hh, { type: 'memory.correct', target_id: m1.id, expected_revision: 1, payload: { text: '旧的更正' } });
    assert.equal(late.body.error.code, 'revision_conflict');
    r = (await recall(call, A, hh, '花生 过敏', `&member_id=${kid}`)).body.results;
    assert.equal(r[0].text, '小米对花生和腰果过敏'); assert.equal(JSON.stringify(r).includes('旧的更正'), false);
    // delete: tombstone, replay returns same receipt, upsert by id refused, never recalled
    const delCmd = { command_id: U(), household_id: hh, type: 'memory.delete', target_id: m1.id, expected_revision: 2 };
    const d1 = await call(A, 'POST', `/households/${hh}/commands`, delCmd), d2 = await call(A, 'POST', `/households/${hh}/commands`, delCmd);
    assert.equal(d1.body.status, 'applied'); assert.deepEqual(d2.body, d1.body);
    assert.equal((await cmd(call, A, hh, { type: 'memory.upsert', target_id: m1.id, expected_revision: 3, payload: { text: '小米对花生过敏', source: SRC } })).body.error.code, 'previously_deleted');
    r = (await recall(call, A, hh, '花生 过敏', `&member_id=${kid}`)).body.results;
    assert.equal(r.some(x => x.memory_id === m1.id), false);
    assert.equal((await sql`select text from family.memories where id=${m1.id}`)[0].text, '已删除');
    assert.equal((await call(A, 'GET', `/households/${hh}/memories`)).body.memories.some(x => x.memory_id === m1.id), false);
    // pause: nothing recalled, nothing saved; resume restores existing facts
    const hrev = (await call(A, 'GET', `/households/${hh}/projection`)).body.home.settings.revision;
    assert.equal((await cmd(call, A, hh, { type: 'memory.pause', expected_revision: hrev, payload: { paused: true } })).body.status, 'applied');
    assert.deepEqual((await recall(call, A, hh, '游泳')).body.results, []);
    assert.equal((await cmd(call, A, hh, { type: 'memory.upsert', payload: { text: '暂停期间', source: SRC } })).body.error.code, 'memory_paused');
    assert.equal((await cmd(call, A, hh, { type: 'memory.pause', expected_revision: hrev + 1, payload: { paused: false } })).body.status, 'applied');
    assert.equal((await recall(call, A, hh, '游泳')).body.results[0].text, '小米周三下午游泳');
    // projection home shows memories with source
    const home = (await call(A, 'GET', `/households/${hh}/projection`)).body.home;
    assert.equal(home.memories.length, 2); assert.ok(home.memories.every(m => m.source?.source_kind));
    // another adult: 404 and nothing leaks
    const B = U(); await sql`insert into auth.users(id) values(${B})`;
    const x = await recall(call, B, hh, '小米'); assert.equal(x.status, 404); assert.equal(JSON.stringify(x.body).includes('小米'), false);
  } finally { await sql.end(); }
});

async function scheduledItem(call, A, hh, date = '2027-03-10') {
  const p = (await cmd(call, A, hh, { type: 'item.propose', payload: { title: '春游', local_date: date, local_time: '09:00', source: SRC } })).body.objects;
  await cmd(call, A, hh, { type: 'item.confirm', target_id: p[0].id, proposal_id: p[1].id, expected_revision: 1 });
  return p[0].id;
}
const rem = (call, A, hh, item, rev, fire, extra = {}) => cmd(call, A, hh, { type: 'reminder.schedule', target_id: item, expected_revision: rev, payload: { kind: 'bring_item', why_now: '明早出发前要带水壶', fire_at: fire, ...extra } });

test('v0.4 reminders: confirmed only, quiet 21:00–08:00, max 2/day, cancel/reschedule consent, pause', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { call } = rig(sql); const { A, hh } = await setup(sql, call);
    const p = (await cmd(call, A, hh, { type: 'item.propose', payload: { title: '未确认', local_date: '2027-03-10', source: SRC } })).body.objects;
    assert.equal((await rem(call, A, hh, p[0].id, 1, '2027-03-09T19:00:00+08:00')).body.error.code, 'confirmation_required');
    assert.equal((await sql`select count(*)::int n from family.reminders where household_id=${hh}`)[0].n, 0);
    const item = await scheduledItem(call, A, hh);
    assert.equal((await rem(call, A, hh, item, 2, '2027-03-09T21:30:00+08:00')).body.error.code, 'quiet_hours');
    assert.equal((await rem(call, A, hh, item, 2, '2027-03-09T07:59:00+08:00')).body.error.code, 'quiet_hours');
    assert.equal((await rem(call, A, hh, item, 2, '2027-03-09T13:00:00Z')).body.error.code, 'quiet_hours', '13:00Z = 21:00 Shanghai');
    assert.equal((await rem(call, A, hh, item, 2, '2027-03-09T20:59:00+08:00')).body.status, 'applied');
    assert.equal((await rem(call, A, hh, item, 2, '2027-03-09T08:00:00+08:00')).body.status, 'applied');
    assert.equal((await rem(call, A, hh, item, 2, '2027-03-09T12:00:00+08:00')).body.error.code, 'daily_limit');
    assert.equal((await rem(call, A, hh, item, 2, '2027-03-09T19:00:00+08:00', { kind: 'nag' })).status, 422);
    assert.equal((await rem(call, A, hh, item, 2, '2027-03-09T19:00:00+08:00', { why_now: 'x'.repeat(81) })).status, 422);
    let proj = (await call(A, 'GET', `/households/${hh}/projection?local_date=2027-03-09`)).body;
    assert.equal(proj.today.reminders.length, 2); assert.equal(proj.today.reminders[0].why_now, '明早出发前要带水壶');
    // reschedule without replace_reminder would orphan reminders -> rejected; with it -> old reminders void
    assert.equal((await cmd(call, A, hh, { type: 'item.reschedule', target_id: item, expected_revision: 2, payload: { local_date: '2027-03-11', scope: 'one_occurrence' }, consent: { actions: ['update_item'] } })).body.error.code, 'confirmation_required');
    assert.equal((await cmd(call, A, hh, { type: 'item.reschedule', target_id: item, expected_revision: 2, payload: { local_date: '2027-03-11', scope: 'one_occurrence' }, consent: { actions: ['update_item', 'replace_reminder'] } })).body.status, 'applied');
    proj = (await call(A, 'GET', `/households/${hh}/projection?local_date=2027-03-09`)).body;
    assert.equal(proj.today.reminders.length, 0);
    // cancel item cancels its reminders; reminder.cancel leaves item
    const item2 = await scheduledItem(call, A, hh, '2027-04-02');
    const r2 = (await rem(call, A, hh, item2, 2, '2027-04-01T19:00:00+08:00')).body.objects[0];
    assert.equal((await cmd(call, A, hh, { type: 'reminder.cancel', target_id: r2.id, expected_revision: 1 })).body.status, 'applied');
    assert.equal((await call(A, 'GET', `/households/${hh}/projection?local_date=2027-04-02`)).body.today.schedule.length, 1);
    await rem(call, A, hh, item2, 2, '2027-04-01T18:00:00+08:00');
    await cmd(call, A, hh, { type: 'item.cancel', target_id: item2, expected_revision: 2 });
    assert.equal((await sql`select count(*)::int n from family.reminders where item_id=${item2} and status='scheduled'`)[0].n, 0);
    // pause reminders: new ones refused
    const hrev = (await call(A, 'GET', `/households/${hh}/projection`)).body.home.settings.revision;
    await cmd(call, A, hh, { type: 'reminder.pause', expected_revision: hrev, payload: { paused: true } });
    const item3 = await scheduledItem(call, A, hh, '2027-05-02');
    assert.equal((await rem(call, A, hh, item3, 2, '2027-05-01T19:00:00+08:00')).body.error.code, 'reminders_paused');
  } finally { await sql.end(); }
});

test('v0.4 dispatcher: 30 s lease, fire once -> outbox reminder.due, cancel-first wins, paused household not fired', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    // dispatcher functions have no API caller and stay service_role-only: drive them with the admin (service) pool;
    // the API runtime role must be refused (B2 least privilege)
    const { call } = rig(sql), store = createPgFamilyStore(sql); const { A, hh } = await setup(sql, call);
    await assert.rejects(createPgFamilyStore(runtimeOf(sql)).claimDueReminders(new Date().toISOString()), /permission denied/);
    const item = await scheduledItem(call, A, hh, '2027-06-02');
    const r1 = (await rem(call, A, hh, item, 2, '2027-06-01T19:00:00+08:00')).body.objects[0];
    const r2 = (await rem(call, A, hh, item, 2, '2027-06-01T10:00:00+08:00')).body.objects[0];
    const T = Date.parse('2027-06-01T19:00:05+08:00');
    const mine = rows => rows.filter(x => x.household_id === hh);
    const c1 = mine(await store.claimDueReminders(new Date(T).toISOString()));
    assert.equal(c1.length, 2);
    assert.equal(mine(await store.claimDueReminders(new Date(T + 10_000).toISOString())).length, 0, 'lease held');
    // cancel r1 after claim, before fire: fire must not happen
    await cmd(call, A, hh, { type: 'reminder.cancel', target_id: r1.id, expected_revision: 1 });
    const byId = Object.fromEntries(c1.map(c => [c.reminder_id, c]));
    assert.equal(await store.fireReminder(r1.id, byId[r1.id].claimed_at), false);
    // r2: lost worker -> reclaimed after 30 s; the stale claim can no longer fire
    const c2 = mine(await store.claimDueReminders(new Date(T + 31_000).toISOString()));
    assert.deepEqual(c2.map(c => c.reminder_id), [r2.id]);
    assert.equal(await store.fireReminder(r2.id, byId[r2.id].claimed_at), false, 'stale claim loses');
    assert.equal(await store.fireReminder(r2.id, c2[0].claimed_at), true);
    assert.equal(await store.fireReminder(r2.id, c2[0].claimed_at), false, 'fires once');
    const due = await sql`select aggregate_id from family.outbox where household_id=${hh} and type='reminder.due'`;
    assert.deepEqual(due.map(d => d.aggregate_id), [r2.id]);
    // paused household: due reminders are not claimed
    const item2 = await scheduledItem(call, A, hh, '2027-07-02');
    await rem(call, A, hh, item2, 2, '2027-07-01T19:00:00+08:00');
    const hrev = (await call(A, 'GET', `/households/${hh}/projection`)).body.home.settings.revision;
    await cmd(call, A, hh, { type: 'reminder.pause', expected_revision: hrev, payload: { paused: true } });
    const t = await runReminderTick(store, '2027-07-01T19:00:10+08:00');
    assert.equal((await sql`select count(*)::int n from family.outbox where household_id=${hh} and type='reminder.due'`)[0].n, 1);
    assert.ok(t.claimed >= 0);
  } finally { await sql.end(); }
});
