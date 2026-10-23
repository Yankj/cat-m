// v0.5 fixes on REAL Postgres: household re-create after delete, home.children vs adults, memory model (kinds/statuses).
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-v05-pg.test.mjs
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgFamilyStore } from '../supabase/functions/_shared/family/pg-store.mjs';
import { createFamilyService } from '../supabase/functions/_shared/family/service.mjs';
import { createMemoryRoute } from '../supabase/functions/_shared/family/memory.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const U = () => crypto.randomUUID();
export function rig(sql) {
  const store = createPgFamilyStore(sql);
  const svc = createFamilyService({ store, extraRoutes: [createMemoryRoute()], verifyUser: async a => { const m = /^Bearer (.+)$/.exec(a); return m ? { sub: m[1] } : null; } });
  const call = async (who, method, path, body) => { const r = await svc.handle(new Request('https://x/catpaw/family/v1' + path, { method, headers: { authorization: 'Bearer ' + who, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  return { store, call };
}
const ensure = (call, who) => call(who, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: U(), payload: { name: '我们家' } });
const cmd = (call, who, hh, c) => call(who, 'POST', `/households/${hh}/commands`, { command_id: U(), household_id: hh, ...c });

test('v0.5 household.ensure after delete creates a NEW active household; old one is not_found', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { call } = rig(sql); const A = U(); await sql`insert into auth.users(id) values(${A})`;
    const hh1 = (await ensure(call, A)).body.objects[0].id;
    assert.equal((await ensure(call, A)).body.objects[0].id, hh1, 'ensure is idempotent while active');
    const rev = (await call(A, 'GET', `/households/${hh1}/projection`)).body.home.household.revision;
    assert.equal((await cmd(call, A, hh1, { type: 'household.delete', expected_revision: rev })).body.status, 'applied');
    const r = await ensure(call, A); assert.equal(r.body.status, 'applied');
    const hh2 = r.body.objects[0].id; assert.notEqual(hh2, hh1);
    assert.equal((await call(A, 'GET', `/households/${hh1}/projection`)).status, 404);
    assert.equal((await call(A, 'GET', `/households/${hh2}/projection`)).status, 200);
    assert.deepEqual((await call(A, 'GET', '/bootstrap')).body.household_ids, [hh2]);
  } finally { await sql.end(); }
});

test('v0.5 home.children lists children only; adults listed under home.adults', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { call } = rig(sql); const A = U(); await sql`insert into auth.users(id) values(${A})`;
    const hh = (await ensure(call, A)).body.objects[0].id;
    await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小米' } });
    await cmd(call, A, hh, { type: 'member.upsert', payload: { display_name: '外婆', member_kind: 'adult' } });
    const home = (await call(A, 'GET', `/households/${hh}/home`)).body.home;
    assert.deepEqual(home.children.map(k => k.display_name), ['小米']);
    assert.deepEqual(home.adults.map(k => [k.display_name, k.member_kind]), [['外婆', 'adult']]);
  } finally { await sql.end(); }
});

test('v0.5 memory model: disputed kept disputed, inference only proposed, confirm, source retract, settings sequence, share, restore', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { call } = rig(sql); const A = U(); await sql`insert into auth.users(id) values(${A})`;
    const hh = (await ensure(call, A)).body.objects[0].id;
    const kid = (await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小米' } })).body.objects[0].id;
    const SRC = { source_kind: 'user_text', source_ref: 'turn:1' };
    const mem = async p => (await cmd(call, A, hh, { type: 'memory.upsert', payload: { member_id: kid, source: SRC, ...p } })).body;
    const d = (await mem({ text: '小米喜欢游泳', status: 'disputed' })).objects[0];
    const inf = (await mem({ text: '小米可能怕水', kind: 'inference', status: 'active' })).objects[0];
    const rec = async (q, x = '') => (await call(A, 'GET', `/households/${hh}/memories/recall?q=${encodeURIComponent(q)}${x}`)).body;
    let r = await rec('小米喜欢游泳吗');
    assert.deepEqual(r.results.map(x => [x.memory_id, x.status]), [[d.id, 'disputed']], 'disputed recalled as disputed; proposed inference never recalled');
    assert.equal(r.answer.assertions[0].status, 'disputed');
    const list = (await call(A, 'GET', `/households/${hh}/memories`)).body.memories;
    assert.equal(list.find(m => m.memory_id === inf.id).status, 'proposed');
    assert.equal((await cmd(call, A, hh, { type: 'memory.confirm', target_id: inf.id, expected_revision: 1 })).body.status, 'applied');
    assert.ok((await rec('小米怕水')).results.some(x => x.memory_id === inf.id && x.status === 'active'));
    // source retract -> dependent memory retracted, never recalled again
    const sid = (await cmd(call, A, hh, { type: 'source.register', payload: { kind: 'image_notice', trust: 'external', raw_media_available: true } })).body.objects[0].id;
    const sm = (await mem({ text: '周六九点集合', source_ids: [sid] })).objects[0];
    assert.ok((await rec('周六几点集合')).results.some(x => x.memory_id === sm.id));
    const rr = (await cmd(call, A, hh, { type: 'source.retract', target_id: sid, expected_revision: 1 })).body;
    assert.equal(rr.status, 'applied'); assert.ok(rr.objects.some(o => o.id === sm.id));
    assert.ok(!(await rec('周六几点集合')).results.some(x => x.memory_id === sm.id));
    assert.equal((await mem({ text: '又一条', source_ids: [sid] })).error.code, 'source_inactive');
    // settings: monotonic choice sequence
    assert.equal((await cmd(call, A, hh, { type: 'memory.settings', payload: { use_memory: false, choice_sequence: 12 } })).body.status, 'applied');
    assert.equal((await cmd(call, A, hh, { type: 'memory.settings', payload: { use_memory: true, choice_sequence: 11 } })).body.error.code, 'stale_sequence');
    assert.deepEqual((await rec('小米喜欢游泳吗')).results, []);
    assert.equal((await cmd(call, A, hh, { type: 'memory.settings', payload: { use_memory: true, choice_sequence: 13 } })).body.status, 'applied');
    // share private needs explicit visibility confirmation; restore of a forgotten fact is undo_expired
    const pv = (await mem({ text: '我的阅读目标', visibility: 'private', member_id: null })).objects[0];
    assert.equal((await cmd(call, A, hh, { type: 'memory.share', target_id: pv.id, expected_revision: 1, payload: {} })).body.error.code, 'visibility_confirmation_required');
    assert.equal((await cmd(call, A, hh, { type: 'memory.delete', target_id: d.id, expected_revision: 1 })).body.status, 'applied');
    assert.equal((await cmd(call, A, hh, { type: 'memory.restore', target_id: d.id })).body.error.code, 'undo_expired');
  } finally { await sql.end(); }
});

test('v0.4 deploy review: grant commands refused (API 422 + command_types); a stray grant row still gives 404 on every memory route', { skip: !url }, async () => {
  const sql = postgres(url, { max: 4, prepare: false, onnotice: () => {} });
  try {
    const { call } = rig(sql); const A = U(), V = U(); await sql`insert into auth.users(id) values(${A}),(${V})`;
    const hh = (await ensure(call, A)).body.objects[0].id;
    const k1 = (await cmd(call, A, hh, { type: 'child.upsert', payload: { display_name: '小米' } })).body.objects[0].id;
    const m1 = (await cmd(call, A, hh, { type: 'memory.upsert', payload: { member_id: k1, text: '小米喜欢画画', source: { source_kind: 'user_text', source_ref: 'turn:1' } } })).body.objects[0];
    for (const type of ['grant.upsert', 'grant.revoke']) {
      const r = await cmd(call, A, hh, { type, payload: { user_id: V, member_scope: [k1] } });
      assert.equal(r.status, 422, type); assert.equal(r.body.error?.code ?? r.body.code, 'command_invalid');
    }
    assert.equal((await sql`select count(*)::int n from family.command_types where type like 'grant.%'`)[0].n, 0, 'migration removed grant types');
    // defence in depth: even if the API guard regressed, apply_command has no grant dispatch
    const db = (await sql`select family.apply_command(${A}::uuid, ${JSON.stringify({ command_id: U(), type: 'grant.upsert', household_id: hh, payload: { user_id: V } })}::jsonb, 'h') r`.catch(e => [{ r: { error: { code: e.message } } }]))[0].r;
    assert.match(JSON.stringify(db), /command_invalid/);
    assert.equal((await sql`select count(*)::int n from family.household_grants`)[0].n, 0);
    // a grant row that exists anyway (manual insert) must not open memory routes: owner-only, 404 like a stranger
    await sql`insert into family.household_grants(household_id, user_id) values(${hh}, ${V})`;
    for (const [m, p, b] of [['GET', '/memories'], ['GET', '/memories/audit'], ['GET', `/memories/recall?q=${encodeURIComponent('画画')}`], ['POST', '/memories/resolve', { refs: [{ memory_id: m1.id, revision: 1 }] }]])
      assert.equal((await call(V, m, `/households/${hh}${p}`, b)).status, 404, `grantee ${m} ${p}`);
    assert.equal((await call(A, 'GET', `/households/${hh}/memories/recall?q=${encodeURIComponent('画画')}`)).status, 200, 'owner still reads');
  } finally { await sql.end(); }
});
