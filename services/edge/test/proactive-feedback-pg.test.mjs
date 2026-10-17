// 20261017050000: proactive.feedback.kind accepts 'intrusive' (iOS sends it; the server maps legacy 'disturbing' to it).
// Before the fix the insert violated feedback_kind_check -> 500. Run via scripts/pg-proactive-local.sh.
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgStore } from '../supabase/functions/_shared/proactive/pg-store.mjs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const fakeLLM = { lastRoute: () => 'fake', decide: async () => ({ decision: 'card', reason: '会议冲突', confidence: 0.9, suggested_actions: ['dismiss'] }) };
const signal = () => ({ context: { time_zone: 'Asia/Shanghai', delivery: 'device' }, signals: [{ type: 'meeting_conflict', source: 'calendar', dedupe_key: 'fb-' + crypto.randomUUID(), data: { title: '评审' } }] });

test('pg: feedback kinds — intrusive / legacy disturbing alias / helpful / not_helpful persist; bogus rejected; legacy row kept', { skip: !url }, async () => {
  const sql = postgres(url, { max: 2, prepare: false, onnotice: () => {} });
  try {
    const U = crypto.randomUUID(); await sql`insert into auth.users(id) values(${U})`;
    const store = createPgStore(sql), clock = { t: Date.parse('2026-10-17T02:00:00Z') };
    const decision = createDecisionService({ store, model: fakeLLM, now: () => clock.t });
    const svc = createProactiveService({ store, decision, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
    const call = async (m, p, b) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + p, { method: m, headers: { authorization: 'Bearer u' }, body: b ? JSON.stringify(b) : undefined })); return { status: r.status, body: await r.json() }; };
    const ev = async () => { const r = await call('POST', '/catpaw/proactive/v1/evaluate', signal()); assert.equal(r.status, 200, JSON.stringify(r.body)); return r.body.event_id; };
    // iOS wire: POST …/suggestions/{id}/feedback {"value":"intrusive"} — the request that used to 500.
    const a = await ev(), fa = await call('POST', `/catpaw/proactive/v1/suggestions/${a}/feedback`, { value: 'intrusive' });
    assert.equal(fa.status, 200, JSON.stringify(fa.body)); assert.equal(fa.body.applied, true); assert.equal(fa.body.kind, 'intrusive');
    const b = await ev(), fb = await call('POST', '/catpaw/proactive/v1/feedback', { event_id: b, kind: 'disturbing' });
    assert.equal(fb.status, 200, JSON.stringify(fb.body)); assert.equal(fb.body.kind, 'intrusive');
    for (const k of ['helpful', 'not_helpful']) { const id = await ev(), r = await call('POST', `/catpaw/proactive/v1/suggestions/${id}/feedback`, { value: k }); assert.equal(r.status, 200, JSON.stringify(r.body)); assert.equal(r.body.applied, true); }
    const rows = await sql`select kind, count(*)::int n from proactive.feedback where user_id = ${U} group by kind order by kind`;
    assert.deepEqual(rows.map(r => [r.kind, r.n]), [['helpful', 1], ['intrusive', 2], ['not_helpful', 1]]);
    const c = await ev(), bogus = await call('POST', `/catpaw/proactive/v1/suggestions/${c}/feedback`, { value: 'bogus' });
    assert.equal(bogus.status, 422, JSON.stringify(bogus.body)); assert.equal(bogus.body.error, 'feedback_invalid');
    await assert.rejects(sql`insert into proactive.feedback(event_id, user_id, kind) values (${c}, ${U}, 'bogus')`, e => e.code === '23514');
    const legacy = await sql`select kind from proactive.feedback where event_id = '00000000-0000-4000-8000-0000000000f2'`;
    assert.deepEqual(legacy.map(r => r.kind), ['disturbing'], 'legacy row seeded before 20261017050000 survives');
    const def = await sql`select pg_get_constraintdef(oid) d from pg_constraint where conrelid = 'proactive.feedback'::regclass and conname = 'feedback_kind_check'`;
    for (const k of ['helpful', 'not_helpful', 'intrusive', 'disturbing']) assert.ok(def[0].d.includes(`'${k}'`), def[0].d);
  } finally { await sql.end(); }
});
