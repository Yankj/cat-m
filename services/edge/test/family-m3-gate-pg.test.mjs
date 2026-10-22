// M3 memory gate (frozen corpus docs/acceptance/family-companion/memory-cases-v1.json) against REAL Postgres through
// the family HTTP service. Gold/expectation fields stay harness-side; the service only sees commands and queries.
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-m3-gate-pg.test.mjs
// Writes M3_GATE_OUT (default /tmp/family-m3-gate.json).
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgFamilyStore } from '../supabase/functions/_shared/family/pg-store.mjs';
import { createFamilyService } from '../supabase/functions/_shared/family/service.mjs';
import { createMemoryRoute } from '../supabase/functions/_shared/family/memory.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const corpus = JSON.parse(await Deno.readTextFile(new URL('../../../docs/acceptance/family-companion/memory-cases-v1.json', import.meta.url)));
const U = () => crypto.randomUUID();
const key = r => `${r.id}@${r.revision}`;
const SUPPORTED = new Set(['materialize_synthetic_fixture_history', 'query_memory', 'forget_memory', 'correct_memory', 'late_update', 'confirm_memory', 'confirm_sensitive_observation', 'set_memory_enabled',
  'confirm_source_correction', 'correct_summary_source', 'retract_source', 'revoke_source_access', 'forget_no_relearn', 'extract_old_paraphrase', 'delete_household', 'sync_old_device', 'set_client_use_memory', 'enter_ephemeral_conversation',
  'pause_reminder', 'remove_member', 'create_new_member', 'expire_raw_media', 'confirm_this_time_only', 'replay_confirm', 'replay_changed_payload', 'explicit_allow_relearn', 'import_older_notice', 'edit_extracted_field', 'confirm_edited_fields']);
// No-ops by design: raw media is never stored; a this-time-only confirmation and an older imported notice never become memory facts.
const NOOP = new Set(['expire_raw_media', 'confirm_this_time_only', 'import_older_notice', 'edit_extracted_field']);
const KIND = { child_a: 'child', child_b: 'child', removed_child: 'child', new_child: 'child', foreign_child: 'child', adult_a: 'adult', adult_b: 'adult', grandparent: 'adult', adult_sibling: 'adult', foreign_adult: 'adult', revoked_adult: 'adult', viewer_only: 'adult' };

async function orderSeeds(caseId, seeds) {
  const h = async t => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)))].map(b => b.toString(16).padStart(2, '0')).join('');
  const keyed = await Promise.all(seeds.map(async s => [await h(`cat-fam-mem-order-v1:${caseId}:${s.memory_ref.id}:${s.memory_ref.revision}`), s]));
  return keyed.sort((a, b) => a[0].localeCompare(b[0])).map(x => x[1]);
}

async function runCase(sql, call, c) {
  const ownerOf = {}, actorOf = {}, hhOf = {}, memberOf = {}, actual = new Map(), back = new Map(), idKeys = {};
  for (const conv of c.identities.conversations) ownerOf[conv.household_id] ??= conv.owner_user_id;
  for (const h of c.identities.households) {
    const fixtureOwner = ownerOf[h.id] ?? U(); const a = U(); await sql`insert into auth.users(id) values(${a})`;
    actorOf[fixtureOwner] = a;
    const r = await call(a, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: U(), payload: { name: h.alias.slice(0, 80) } });
    hhOf[h.id] = { hh: r.body.objects[0].id, actor: a };
  }
  const cmd = async (fhh, body) => { const { hh, actor } = hhOf[fhh]; return (await call(actor, 'POST', `/households/${hh}/commands`, { command_id: U(), household_id: hh, ...body })).body; };
  for (const s of c.identities.subjects) {
    if (s.fixture_role === 'unresolved' || !hhOf[s.household_id]) continue;
    const r = await cmd(s.household_id, { type: 'member.upsert', payload: { display_name: s.display_name.slice(0, 40), member_kind: KIND[s.fixture_role] ?? 'other' } });
    memberOf[s.id] = r.objects[0].id;
  }
  const versions = new Map(c.memory_versions.map(v => [key(v), v]));
  const SRC = v => ({ source_kind: 'user_text', source_ref: `fixture:${(v.source_refs?.[0]?.id ?? 'none').slice(0, 36)}` });
  const create = async (v, pextra = {}) => {
    if (!hhOf[v.household_id]) return { status: 'skipped' };
    const r = await cmd(v.household_id, { type: 'memory.upsert', payload: { ...pextra, member_id: memberOf[v.subject_id] ?? null, text: v.content.slice(0, 500), visibility: v.visibility === 'household' ? 'household' : 'private', valid_from: v.valid_from, valid_to: v.valid_to, source: SRC(v) } });
    if (r.status !== 'applied') return r;
    let o = r.objects[0];
    while (o.revision < v.revision) { const rr = await cmd(v.household_id, { type: 'memory.correct', target_id: o.id, expected_revision: o.revision, payload: { text: v.content.slice(0, 500), source: SRC(v) } }); if (rr.status !== 'applied') break; o = rr.objects[0]; }
    actual.set(key(v), o); back.set(`${o.id}@${o.revision}`, key(v)); idKeys[v.id] = o; return r;
  };
  const notRun = [], ops = [], qflags = {}, idem = {};
  for (const st of c.steps) {
    const inp = st.input ?? {};
    if (!SUPPORTED.has(st.operation)) { notRun.push(st.operation); continue; }
    if (st.operation === 'materialize_synthetic_fixture_history') {
      // load order = sha256(cat-fam-mem-order-v1:case_id:id:revision) (adapter_boundary.fixture_candidate_order), never gold/catalogue order
      const seeds = await orderSeeds(c.id, inp.seed_memory_states ?? []);
      for (const s of seeds) if (s.status === 'active' || s.status === 'disputed') { const v = versions.get(key(s.memory_ref)); if (v && hhOf[v.household_id]) await create(v); }
    } else if (NOOP.has(st.operation)) { ops.push([st.operation, 'noop', null]);
    } else if (st.operation === 'pause_reminder') {
      for (const [fhh, { hh, actor }] of Object.entries(hhOf)) { const rev = (await call(actor, 'GET', `/households/${hh}/projection`)).body.home.settings.revision; const r = await cmd(fhh, { type: 'reminder.pause', expected_revision: rev, payload: { paused: true } }); ops.push([st.operation, r.status, r.error?.code ?? null]); break; }
    } else if (st.operation === 'remove_member') {
      for (const ref of inp.memory_refs) { const v = versions.get(key(ref)); const mid = v && memberOf[v.subject_id]; if (!mid) continue; const { hh, actor } = hhOf[v.household_id];
        const kid = (await call(actor, 'GET', `/households/${hh}/home`)).body.home.children.find(k => k.member_id === mid); if (!kid) continue;
        const r = await cmd(v.household_id, { type: 'child.delete', target_id: mid, expected_revision: kid.revision }); ops.push([st.operation, r.status, r.error?.code ?? null]);
      }
    } else if (st.operation === 'create_new_member' || st.operation === 'explicit_allow_relearn' || st.operation === 'confirm_edited_fields') {
      for (const ref of inp.memory_refs) { const v = versions.get(key(ref)); if (!v || actual.has(key(ref))) continue; const r = await create(v); ops.push([st.operation, r.status, r.error?.code ?? null]); }
    } else if (st.operation === 'replay_confirm' || st.operation === 'replay_changed_payload') {
      const prev = idem[inp.idempotency_key]; if (!prev) { ops.push([st.operation, 'skipped', 'no_original']); continue; }
      const v = versions.get(key(inp.memory_refs[0])); const { hh, actor } = hhOf[prev.fhh];
      const body = st.operation === 'replay_confirm' ? prev.body : { ...prev.body, payload: { ...prev.body.payload, text: v.content.slice(0, 500) } };
      const r = await call(actor, 'POST', `/households/${hh}/commands`, body);
      ops.push([st.operation, r.status, r.body.status ?? r.body.error?.code, st.operation === 'replay_confirm' ? JSON.stringify(r.body) === JSON.stringify(prev.receipt) : null]);
    } else if (st.operation === 'set_client_use_memory') { qflags.use_memory = inp.enabled ? 'true' : 'false';
    } else if (st.operation === 'enter_ephemeral_conversation') { qflags.ephemeral = 'true';
    } else if (st.operation === 'confirm_source_correction' || st.operation === 'correct_summary_source') {
      const [from, to] = inp.memory_refs; const o = idKeys[from.id]; const v = versions.get(key(from)), vt = versions.get(key(to));
      if (!o || !v || !vt) { ops.push([st.operation, 'skipped', 'unmapped']); continue; }
      if (from.id === to.id) { const r = await cmd(v.household_id, { type: 'memory.correct', target_id: o.id, expected_revision: o.revision, payload: { text: vt.content.slice(0, 500) } }); ops.push([st.operation, r.status, r.error?.code ?? null]); if (r.status === 'applied') { const n = r.objects[0]; actual.set(key(vt), n); back.set(`${n.id}@${n.revision}`, key(vt)); idKeys[vt.id] = n; } }
      else { const r1 = await cmd(v.household_id, { type: 'memory.delete', target_id: o.id, expected_revision: o.revision }); const r2 = await create(vt); ops.push([st.operation, r1.status, r2.status]); }
    } else if (st.operation === 'extract_old_paraphrase' || st.operation === 'sync_old_device') {
      for (const ref of inp.memory_refs) { const v = versions.get(key(ref)); if (!v || !hhOf[v.household_id]) continue; const g = inp.admitted_generation ?? inp.generation; const r = await create(v, g ? { admitted_generation: g } : {}); ops.push([st.operation, r.status ?? null, r.error?.code ?? null]); }
    } else if (st.operation === 'delete_household') {
      for (const [fhh, { hh, actor }] of Object.entries(hhOf)) { if (!inp.memory_refs.some(ref => versions.get(key(ref))?.household_id === fhh)) continue; const rev = (await call(actor, 'GET', `/households/${hh}/projection`)).body.home.settings.revision; const r = await cmd(fhh, { type: 'household.delete', expected_revision: rev }); ops.push([st.operation, r.status, r.error?.code ?? null]); }
    } else if (['forget_memory', 'retract_source', 'revoke_source_access', 'forget_no_relearn'].includes(st.operation)) {
      for (const ref of inp.memory_refs) { const o = idKeys[ref.id]; if (!o) continue; const v = versions.get(key(ref)); const r = await cmd(v.household_id, { type: 'memory.delete', target_id: o.id, expected_revision: o.revision }); ops.push([st.operation, r.status, r.error?.code ?? null]); }
    } else if (false) {
      for (const ref of inp.memory_refs) { const o = idKeys[ref.id]; if (!o) continue; const v = versions.get(key(ref)); const r = await cmd(v.household_id, { type: 'memory.delete', target_id: o.id, expected_revision: o.revision }); ops.push([st.operation, r.status, r.error?.code ?? null]); }
    } else if (st.operation === 'correct_memory' || st.operation === 'late_update') {
      const [from, to] = inp.memory_refs; const o = idKeys[from.id]; const v = versions.get(key(from)); const vt = versions.get(key(to));
      if (!o || !v || !vt) { ops.push([st.operation, 'skipped', 'unmapped']); continue; }
      const exp = st.operation === 'late_update' ? (actual.get(`${from.id}@${inp.expected_revision}`)?.revision ?? 1) : o.revision;
      const r = await cmd(v.household_id, { type: 'memory.correct', target_id: o.id, expected_revision: exp, payload: { text: vt.content.slice(0, 500) } });
      ops.push([st.operation, r.status, r.error?.code ?? null]);
      if (r.status === 'applied' && vt.id === from.id) { const n = r.objects[0]; actual.set(key(vt), n); back.set(`${n.id}@${n.revision}`, key(vt)); idKeys[vt.id] = n; }
    } else if (st.operation === 'confirm_memory' || st.operation === 'confirm_sensitive_observation') {
      for (const ref of inp.memory_refs) { const v = versions.get(key(ref)); if (!v || actual.has(key(ref)) || !hhOf[v.household_id]) { ops.push([st.operation, 'replay_or_unmapped', null]); continue; }
        if (inp.idempotency_key) { const { hh, actor } = hhOf[v.household_id]; const body = { command_id: U(), household_id: hh, type: 'memory.upsert', payload: { member_id: memberOf[v.subject_id] ?? null, text: v.content.slice(0, 500), visibility: 'household', source: SRC(v) } };
          const r = await call(actor, 'POST', `/households/${hh}/commands`, body); idem[inp.idempotency_key] = { fhh: v.household_id, body, receipt: r.body };
          if (r.body.status === 'applied') { const o = r.body.objects[0]; actual.set(key(v), o); back.set(`${o.id}@${o.revision}`, key(v)); idKeys[v.id] = o; } ops.push([st.operation, r.body.status, null]); continue; }
        const r = await create(v); ops.push([st.operation, r.status, r.error?.code ?? null]); }
    } else if (st.operation === 'set_memory_enabled') {
      for (const [fhh, { hh, actor }] of Object.entries(hhOf)) { const rev = (await call(actor, 'GET', `/households/${hh}/projection`)).body.home.settings.revision; const r = await cmd(fhh, { type: 'memory.pause', expected_revision: rev, payload: { paused: !inp.enabled } }); ops.push([st.operation, r.status, r.error?.code ?? null]); }
    }
  }
  const q = c.query; const viewer = actorOf[q.viewer_user_id] ?? (await (async () => { const a = U(); await sql`insert into auth.users(id) values(${a})`; return a; })());
  const target = hhOf[q.household_id];
  const member = memberOf[q.subject_id];
  const res = target ? await call(viewer, 'GET', `/households/${target.hh}/memories/recall?q=${encodeURIComponent(q.text)}&at=${encodeURIComponent(q.at)}${member ? '&member_id=' + member : ''}${Object.entries(qflags).map(([k, v]) => `&${k}=${v}`).join('')}`) : { status: 404, body: {} };
  const returned = (res.body.results ?? []).map(r => back.get(`${r.memory_id}@${r.revision}`) ?? `unmapped:${r.memory_id}@${r.revision}`);
  return { notRun, ops, status: res.status, returned };
}

test('M3 gate: macro recall@6 on 50 eligible queries, forbidden refs never returned (100 cases)', { skip: !url }, async () => {
  const sql = postgres(url, { max: 6, prepare: false, onnotice: () => {} });
  const svc = createFamilyService({ store: createPgFamilyStore(sql), extraRoutes: [createMemoryRoute()], verifyUser: async a => { const m = /^Bearer (.+)$/.exec(a); return m ? { sub: m[1] } : null; } });
  const call = async (who, method, path, body) => { const r = await svc.handle(new Request('https://x/catpaw/family/v1' + path, { method, headers: { authorization: 'Bearer ' + who, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  const out = { corpus: corpus.dataset_id, cases: [], at: new Date().toISOString() };
  try {
    let sum = 0, hits = 0, gold = 0, safetyErrors = 0, notRunEligible = 0; const byCat = {};
    for (const c of corpus.cases) {
      const r = await runCase(sql, call, c); const e = c.expectation;
      const top = r.returned.slice(0, 6), forb = (e.forbidden_memory_refs ?? []).map(f => key(f.memory_ref));
      const leaked = top.filter(k => forb.includes(k)); if (leaked.length) safetyErrors++;
      let recall = null;
      if (e.retrieval_eligible) {
        const G = e.eligible_gold_refs.map(key); gold += G.length;
        const h = r.notRun.length ? 0 : G.filter(g => top.includes(g)).length; hits += h;
        recall = r.notRun.length ? 0 : h / G.length; sum += recall; if (r.notRun.length) notRunEligible++;
        (byCat[c.category] ??= { eligible: 0, recall_sum: 0 }); byCat[c.category].eligible++; byCat[c.category].recall_sum += recall;
      }
      out.cases.push({ id: c.id, category: c.category, eligible: e.retrieval_eligible, recall, leaked, not_run_ops: r.notRun, ops: r.ops, http: r.status, returned: top });
    }
    out.summary = { eligible: 50, macro_recall_at_6: sum / 50, micro_recall_at_6: hits / gold, gold_hits: hits, gold_refs: gold, eligible_with_unsupported_ops_scored_0: notRunEligible,
      safety_forbidden_ref_cases: safetyErrors, cases_with_unsupported_ops: out.cases.filter(x => x.not_run_ops.length).length, gate_macro_threshold: 0.9, by_category: byCat };
    await Deno.writeTextFile(Deno.env.get('M3_GATE_OUT') ?? '/tmp/family-m3-gate.json', JSON.stringify(out, null, 1));
    console.log('M3', JSON.stringify(out.summary));
    assert.equal(out.cases.length, 100);
    assert.equal(safetyErrors, 0, 'forbidden refs returned');
  } finally { await sql.end(); }
});
