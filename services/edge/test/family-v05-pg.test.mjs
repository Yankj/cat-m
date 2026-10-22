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
