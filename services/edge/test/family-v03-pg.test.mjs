// v0.3 on REAL Postgres: notice photo -> event cards (image pipeline) and 我们家 profile view / edit / delete.
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-v03-pg.test.mjs
// The vision model is NOT exercised here: the image extractor is injected and returns the notice text that a model
// would read. What is real: HTTP handler, image byte validation, extraction->propose->confirm, PG writes, RLS.
import test from 'node:test'; import assert from 'node:assert/strict';
import { runtimeOf } from './support/pg-runtime.mjs';
import postgres from 'npm:postgres@3.4.7';
import { createPgFamilyStore } from '../supabase/functions/_shared/family/pg-store.mjs';
import { createFamilyService } from '../supabase/functions/_shared/family/service.mjs';
import { createCaptureRoute } from '../supabase/functions/_shared/family/captures.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const U = () => crypto.randomUUID();
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwCAIAAAAuKetIAAAAZElEQVR4nO3PUQkAIBTAwNe/oxWsoCH8OITBAtzm7PV1wwUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY8dgF5+HnwkpVdigAAAABJRU5ErkJggg==';
const NOTICE = '秋游通知：10月30日（周五）秋游，8:00学校门口集合，请带水壶、帽子；11月2日前交费80元';
function rig(sql, extractors) {
  const seen = [];
  const svc = createFamilyService({ store: createPgFamilyStore(runtimeOf(sql)), now: () => Date.parse('2026-10-23T09:00:00+08:00'),
    extraRoutes: [createCaptureRoute({ extractors: extractors === null ? {} : { image: async ({ image }) => { seen.push(image); return NOTICE; } } })],
    verifyUser: async a => { const m = /^Bearer (.+)$/.exec(a); return m ? { sub: m[1] } : null; } });
  const call = async (who, method, path, body) => { const r = await svc.handle(new Request('https://x/catpaw/family/v1' + path, { method, headers: { authorization: 'Bearer ' + who, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { call, seen };
}
async function setup(sql, call) {
  const A = U(); await sql`insert into auth.users(id) values(${A})`;
  const r = await call(A, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: U() });
  return { A, hh: r.body.objects[0].id };
}
const cmd = (call, who, hh, c) => call(who, 'POST', `/households/${hh}/commands`, { command_id: U(), household_id: hh, ...c });

test('v0.3 photo notice -> 2 confirm cards (deadline kept), confirm one -> today; bytes not persisted', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { call, seen } = rig(sql); const { A, hh } = await setup(sql, call);
    const cap = { capture_id: U(), kind: 'image', image: { mime: 'image/png', data_base64: PNG } };
    const r = await call(A, 'POST', `/households/${hh}/captures`, cap);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(seen[0].size.width, 64); assert.equal(seen[0].bytes.length > 0, true);
    const [trip, fee] = r.body.cards;
    assert.deepEqual([trip.candidate.title, trip.candidate.local_date, trip.candidate.local_time, trip.candidate.place], ['秋游', '2026-10-30', '08:00', '学校门口']);
    assert.deepEqual(trip.candidate.bring, ['水壶', '帽子']);
    assert.deepEqual([fee.candidate.title, fee.candidate.local_date, fee.candidate.notes], ['交费80元', '2026-11-02', '截止日期']);
    const src = await sql`select source from family.items where id=${trip.item_id}`;
    assert.equal(src[0].source.source_kind, 'notification_extract');
    const dump = JSON.stringify(await sql`select i.*, p.patch from family.items i join family.proposals p on p.target_id=i.id where i.household_id=${hh}`);
    assert.equal(dump.includes(PNG.slice(20, 60)), false, 'image bytes never stored');
    let p = (await call(A, 'GET', `/households/${hh}/projection?local_date=2026-10-30`)).body;
    assert.equal(p.today.schedule.length, 0); assert.equal(p.today.pending_confirmations[0].source_kind, 'notification_extract');
    await cmd(call, A, hh, { type: 'item.confirm', target_id: trip.item_id, proposal_id: trip.proposal_id, expected_revision: 1 });
    p = (await call(A, 'GET', `/households/${hh}/projection?local_date=2026-10-30`)).body;
    assert.equal(p.today.schedule[0].title, '秋游');
    // retry of the same photo capture: same cards, no duplicates
    const again = await call(A, 'POST', `/households/${hh}/captures`, cap);
    assert.deepEqual(again.body.cards.map(c => c.item_id), r.body.cards.map(c => c.item_id));
    assert.equal((await sql`select count(*)::int n from family.items where household_id=${hh}`)[0].n, 2);
  } finally { await sql.end(); }
});

test('v0.3 image validation: wrong mime / garbage bytes rejected; no extractor -> capability_unavailable', { skip: !url }, async () => {
  const sql = postgres(url, { max: 2, prepare: false, onnotice: () => {} });
  try {
    const { call } = rig(sql); const { A, hh } = await setup(sql, call);
    assert.equal((await call(A, 'POST', `/households/${hh}/captures`, { capture_id: U(), kind: 'image', image: { mime: 'image/gif', data_base64: PNG } })).body.error.code, 'image_invalid');
    assert.equal((await call(A, 'POST', `/households/${hh}/captures`, { capture_id: U(), kind: 'image', image: { mime: 'image/png', data_base64: 'aGVsbG8=' } })).body.error.code, 'image_invalid');
    const off = rig(sql, null);
    assert.equal((await off.call(A, 'POST', `/households/${hh}/captures`, { capture_id: U(), kind: 'image', image: { mime: 'image/png', data_base64: PNG } })).body.error.code, 'capability_unavailable');
    const B = U(); await sql`insert into auth.users(id) values(${B})`;
    assert.equal((await call(B, 'POST', `/households/${hh}/captures`, { capture_id: U(), kind: 'image', image: { mime: 'image/png', data_base64: PNG } })).status, 404);
  } finally { await sql.end(); }
});

test('v0.3 我们家: view, edit child profile (CAS), record/correct/delete observation, delete child; other adult 404', { skip: !url }, async () => {
  const sql = postgres(url, { max: 2, prepare: false, onnotice: () => {} });
  try {
    const { call } = rig(sql); const { A, hh } = await setup(sql, call);
    assert.equal((await cmd(call, A, hh, { type: 'household.update', expected_revision: 1, payload: { name: '米家' } })).body.status, 'applied');
    const kid = (await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小米', birth_year: 2018, school_label: '实验小学', class_label: '二(3)班', teacher_label: '王老师' } })).body.objects[0].id;
    let h = (await call(A, 'GET', `/households/${hh}/home`)).body.home;
    assert.equal(h.household.name, '米家'); assert.equal(h.children[0].teacher_label, '王老师');
    assert.equal((await cmd(call, A, hh, { type: 'child.upsert', target_id: kid, expected_revision: 1, payload: { teacher_label: '李老师', class_label: null } })).body.status, 'applied');
    assert.equal((await cmd(call, A, hh, { type: 'child.upsert', target_id: kid, expected_revision: 1, payload: { teacher_label: '迟到' } })).body.error.code, 'revision_conflict');
    h = (await call(A, 'GET', `/households/${hh}/home`)).body.home;
    assert.deepEqual([h.children[0].teacher_label, h.children[0].class_label, h.children[0].revision], ['李老师', null, 2]);
    const SRC = { source_kind: 'user_text', source_ref: 'turn:o1' };
    const obs = (await cmd(call, A, hh, { type: 'observation.record', payload: { member_id: kid, text: '最近喜欢画恐龙', observed_on: '2026-10-22', source: SRC } })).body.objects[0].id;
    assert.equal((await cmd(call, A, hh, { type: 'observation.correct', target_id: obs, expected_revision: 1, payload: { text: '最近喜欢画恐龙和火车' } })).body.status, 'applied');
    h = (await call(A, 'GET', `/households/${hh}/home`)).body.home;
    assert.equal(h.observations[0].text, '最近喜欢画恐龙和火车');
    assert.equal((await cmd(call, A, hh, { type: 'observation.delete', target_id: obs, expected_revision: 2 })).body.status, 'applied');
    assert.equal((await call(A, 'GET', `/households/${hh}/home`)).body.home.observations.length, 0);
    assert.equal((await sql`select text from family.observations where id=${obs}`)[0].text, '已删除');
    const B = U(); await sql`insert into auth.users(id) values(${B})`;
    assert.equal((await call(B, 'GET', `/households/${hh}/home`)).status, 404);
    assert.equal((await cmd(call, B, hh, { type: 'child.delete', target_id: kid, expected_revision: 2 })).status, 404);
    assert.equal((await cmd(call, A, hh, { type: 'child.delete', target_id: kid, expected_revision: 2 })).body.status, 'applied');
    assert.equal((await call(A, 'GET', `/households/${hh}/home`)).body.home.children.length, 0);
    // a proposal naming a deleted child is rejected (no wrong-child cards)
    assert.equal((await cmd(call, A, hh, { type: 'item.propose', payload: { title: 'x', member_id: kid, source: SRC } })).body.error.code, 'member_not_found');
  } finally { await sql.end(); }
});
