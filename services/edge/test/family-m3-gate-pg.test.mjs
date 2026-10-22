// M3 memory gate, FULL suite (frozen corpus docs/acceptance/family-companion/memory-cases-v1.json) against REAL Postgres
// through the family HTTP service. Gold/expectation fields stay harness-side: the service only sees commands and queries.
// The harness plays the CLIENT (session/account epoch, local use_memory & ephemeral flags, frozen-snapshot continuation)
// and reads authoritative state back through GET /memories/audit (owner) before and after every step.
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-m3-gate-pg.test.mjs
// Writes M3_GATE_OUT (default /tmp/family-m3-gate.json).
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgFamilyStore } from '../supabase/functions/_shared/family/pg-store.mjs';
import { createFamilyService } from '../supabase/functions/_shared/family/service.mjs';
import { createMemoryRoute, conditionMet } from '../supabase/functions/_shared/family/memory.mjs';
import { createCaptureRoute } from '../supabase/functions/_shared/family/captures.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const corpus = JSON.parse(await Deno.readTextFile(new URL('../../../docs/acceptance/family-companion/memory-cases-v1.json', import.meta.url)));
const U = () => crypto.randomUUID();
const key = r => `${r.id}@${r.revision}`;
const KIND = { child_a: 'child', child_b: 'child', removed_child: 'child', new_child: 'child', foreign_child: 'child', adult_a: 'adult', adult_b: 'adult', grandparent: 'adult', adult_sibling: 'adult', foreign_adult: 'adult', revoked_adult: 'adult', viewer_only: 'adult' };
const SRC_KIND = { user_text: 'user_text', voice_transcript: 'user_voice_transcript', image_extract: 'image_notice', confirmed_image_summary: 'image_notice', quoted_notice: 'image_notice', assistant_text: 'assistant_inference', web_excerpt: 'external_advice', pasted_text: 'external_advice', legacy_import: 'unknown', imported_text: 'user_text', journal_fragment: 'user_text' };
const TRUST = { user_direct: 'user_direct', external_unverified: 'external', assistant_generated: 'assistant', legacy_unknown: 'unknown' };
// Ports the service does not offer: recorded NOT_RUN, never simulated.
const NOT_RUN_OPS = { extract_image_fields: 'no vision extractor route approved (capability_unavailable in prod wiring)', import_older_notice: 'no source-version lineage port' };

async function orderSeeds(caseId, seeds) {
  const h = async t => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)))].map(b => b.toString(16).padStart(2, '0')).join('');
  const keyed = await Promise.all(seeds.map(async s => [await h(`cat-fam-mem-order-v1:${caseId}:${s.memory_ref.id}:${s.memory_ref.revision}`), s]));
  return keyed.sort((a, b) => a[0].localeCompare(b[0])).map(x => x[1]);
}
const eqSet = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

async function runCase(sql, call, c) {
  const q = c.query, init = c.initial_runtime_state;
  const versions = new Map(c.memory_versions.map(v => [key(v), v]));
  const sources = new Map(c.sources.map(s => [key(s), s]));
  const subj = new Map(c.identities.subjects.map(s => [s.id, s]));
  const hhOf = {}, memberOf = {}, actual = new Map(), back = new Map(), srcOf = {}, rejected = new Set(), forgetCmd = {};
  const newUser = async () => { const a = U(); await sql`insert into auth.users(id) values(${a})`; return a; };
  const userOf = {}; const user = async fid => (userOf[fid] ??= await newUser());
  const ownerOf = {}; for (const conv of c.identities.conversations) ownerOf[conv.household_id] ??= conv.owner_user_id;
  // a viewer with a scoped / read-only authority is a grantee; the household is owned by a separate account
  const scopedViewer = ['read_only', 'child_a_only'].includes(init.authority_state);
  const ensureHh = async (fhh, ownerFid) => {
    const a = await user(ownerFid);
    const r = await call(a, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: U(), payload: { name: (c.identities.households.find(h => h.id === fhh)?.alias ?? '我们家').slice(0, 80) } });
    hhOf[fhh] = { hh: r.body.objects[0].id, actor: a, fowner: ownerFid }; return r;
  };
  for (const h of c.identities.households) {
    let ownerFid = ownerOf[h.id] ?? `owner:${h.id}`;
    if (scopedViewer && h.id === q.household_id && ownerFid === q.viewer_user_id) ownerFid = `owner:${h.id}`;
    await ensureHh(h.id, ownerFid);
  }
  const cmdAs = async (who, fhh, body) => { const { hh } = hhOf[fhh]; return (await call(who, 'POST', `/households/${hh}/commands`, { command_id: U(), household_id: hh, ...body })).body; };
  const cmd = (fhh, body) => cmdAs(hhOf[fhh].actor, fhh, body);
  for (const s of c.identities.subjects) {
    if (s.fixture_role === 'unresolved' || !hhOf[s.household_id]) continue;
    const r = await cmd(s.household_id, { type: 'member.upsert', payload: { display_name: s.display_name.slice(0, 40), member_kind: KIND[s.fixture_role] ?? 'other' } });
    memberOf[s.id] = r.objects[0].id;
  }
  // client state (the harness is the client)
  const client = { use_memory: init.client_use_memory, mode: init.mode, epoch: init.account_epoch, account: init.current_account_user_id, snapshot: null, dispatch: init.dispatch, late: init.late_delivery, pending: null, currentHh: null };
  // grants: an adult of the queried household who is not its owner reads through a viewer grant
  const viewerSubj = subj.get(q.viewer_user_id);
  const grantFor = async (fid, fhh) => {
    const scope = init.authority_state === 'child_a_only' ? c.identities.subjects.filter(s => s.household_id === fhh && s.fixture_role === 'child_a').map(s => memberOf[s.id]) : null;
    return cmd(fhh, { type: 'grant.upsert', payload: { user_id: await user(fid), member_scope: scope, role: init.authority_state === 'active' ? 'caregiver' : 'viewer' } });
  };
  if (hhOf[q.household_id] && hhOf[q.household_id].fowner !== q.viewer_user_id && (scopedViewer || (viewerSubj && viewerSubj.household_id === q.household_id && KIND[viewerSubj.fixture_role] === 'adult')))
    await grantFor(q.viewer_user_id, q.household_id);
  if (init.authority_state === 'revoked') await cmd(q.household_id, { type: 'grant.revoke', payload: { user_id: await user(q.viewer_user_id) } }).catch(() => {});
  for (const fhh of Object.keys(hhOf)) {
    await cmd(fhh, { type: 'memory.settings', payload: { use_memory: init.use_memory, choice_sequence: init.setting_sequence } });
    if (init.reminder_status === 'paused') { const rev = (await call(hhOf[fhh].actor, 'GET', `/households/${hhOf[fhh].hh}/projection`)).body.home.household.revision; await cmd(fhh, { type: 'reminder.pause', expected_revision: rev, payload: { paused: true } }); }
  }
  const register = async s => {
    if (srcOf[key(s)] || !hhOf[s.household_id]) return;
    const r = await cmd(s.household_id, { type: 'source.register', payload: { kind: SRC_KIND[s.kind] ?? 'unknown', trust: TRUST[s.trust] ?? 'unknown', retention_mode: s.retention_mode, raw_media_available: true } });
    if (r.status === 'applied') srcOf[key(s)] = r.objects[0];
  };
  const mapObj = (k, o) => { actual.set(k, o); back.set(`${o.id}@${o.revision}`, k); };
  const seedState = {};   // fixture ref -> seed status (expired/future seeds without explicit bounds are loaded as validity windows)
  const payloadOf = (v, statusOverride) => {
    const st = statusOverride ?? (v.initial_status === 'proposed' ? 'proposed' : v.initial_status === 'disputed' ? 'disputed' : 'active');
    const ss = seedState[key(v)]; const day = 86400000;
    const vf = v.valid_from ?? (ss === 'future' ? new Date(Date.parse(q.at) + day).toISOString() : null);
    const vt = v.valid_to ?? (ss === 'expired' ? new Date(Math.min(Date.parse(v.recorded_at ?? q.at), Date.parse(q.at) - day)).toISOString() : null);
    return { member_id: memberOf[v.subject_id] ?? null, text: v.content.slice(0, 500), kind: v.kind, assertion: v.assertion === 'inference' ? 'inference' : 'explicit', status: st,
      sensitivity: v.sensitivity === 'sensitive' ? 'sensitive' : 'normal', conditions: v.conditions && Object.keys(v.conditions).length ? v.conditions : null,
      visibility: v.visibility === 'household' ? 'household' : 'private', valid_from: vf, valid_to: vt,
      source_ids: (v.source_refs ?? []).map(r => srcOf[key(r)]?.id).filter(Boolean),
      source: { source_kind: 'user_text', source_ref: `fixture:${(v.source_refs?.[0]?.id ?? 'none').slice(0, 36)}` } };
  };
  // create a version through real commands: revision 1 (its own content), then memory.correct up to the target revision
  const regSources = async v => { for (const r of v?.source_refs ?? []) { const s = sources.get(key(r)); if (s) await register(s); } };
  const create = async (v, extra = {}, statusOverride) => {
    if (!hhOf[v.household_id]) return { status: 'skipped' };
    await regSources(v);
    const v1 = versions.get(`${v.id}@1`) ?? v;
    const r = await cmd(v.household_id, { type: 'memory.upsert', payload: { ...payloadOf(v1, statusOverride), ...extra } });
    if (r.status !== 'applied') { rejected.add(key(v)); return r; }
    let o = r.objects[0]; mapObj(`${v.id}@1`, o);
    for (let n = 2; n <= v.revision; n++) {
      const vn = versions.get(`${v.id}@${n}`) ?? v;
      const rr = await cmd(v.household_id, { type: 'memory.correct', target_id: o.id, expected_revision: o.revision, payload: { text: vn.content.slice(0, 500) } });
      if (rr.status !== 'applied') return rr; o = rr.objects[0]; mapObj(`${v.id}@${n}`, o);
    }
    return { ...r, objects: [o] };
  };
  const forget = async (k, fhh) => { const o = actual.get(k); if (!o) return { status: 'unmapped' }; const cur = await rowOf(fhh, o.id); const cid = U(); const { hh, actor } = hhOf[fhh];
    const r = (await call(actor, 'POST', `/households/${hh}/commands`, { command_id: cid, household_id: hh, type: 'memory.delete', target_id: o.id, expected_revision: cur?.revision ?? o.revision })).body; forgetCmd[k] = cid; return r; };
  const supersede = async (k, fhh, byId) => { const o = actual.get(k); if (!o) return { status: 'unmapped' }; const cur = await rowOf(fhh, o.id);
    return cmd(fhh, { type: 'memory.supersede', target_id: o.id, expected_revision: cur?.revision ?? o.revision, payload: byId ? { by_id: byId } : {} }); };
  const audit = async fhh => (await call(hhOf[fhh].actor, 'GET', `/households/${hhOf[fhh].hh}/memories/audit`)).body;
  const rowOf = async (fhh, id) => (await audit(fhh)).memories?.find(m => m.memory_id === id);

  // ---- authoritative readback in the fixture vocabulary ----
  async function readback() {
    const A = {}; for (const fhh of Object.keys(hhOf)) A[fhh] = await audit(fhh);
    if (movedFrom) A[rtHh] = (await call(movedFrom.actor, 'GET', `/households/${movedFrom.hh}/memories/audit`)).body;
    const memStatus = ref => {
      const v = versions.get(key(ref)); const k = key(ref); const o = actual.get(k);
      if (!o) return rejected.has(k) ? 'rejected' : 'absent';
      const a = A[v?.household_id ?? Object.keys(hhOf)[0]]; const row = a?.memories?.find(m => m.memory_id === o.id); if (!row) return 'absent';
      if (row.status === 'deleted' || row.status === 'retracted') return 'retracted';
      if (row.status === 'superseded') return 'superseded';
      if (row.status === 'proposed') return 'proposed';   // every draft revision of an unconfirmed candidate is a proposal
      if (row.revision > o.revision && [...actual.entries()].some(([kk, oo]) => oo.id === o.id && oo.revision > o.revision && kk !== k)) return 'superseded';
      if (row.status !== 'active') return row.status;
      if (a.household.status === 'archived') return 'retracted';
      if (row.valid_to && Date.parse(row.valid_to) <= Date.parse(q.at)) return 'expired';
      if (row.valid_from && Date.parse(row.valid_from) > Date.parse(q.at)) return 'future';
      if (!conditionMet(row.conditions, q.at, 'Asia/Shanghai', {}, q.text)) return 'condition_unmatched';
      if (a.household.memory_paused) return 'disabled';
      return 'active';
    };
    const srcStatus = ref => { const s = sources.get(key(ref)); const o = srcOf[key(ref)]; if (!o) return 'absent'; const row = A[s.household_id]?.sources?.find(x => x.source_id === o.id); return row?.status ?? 'absent'; };
    const qa = A[rtHh] ?? Object.values(A)[0];
    const curFid = q.viewer_user_id; const owner = hhOf[q.household_id]?.fowner === curFid;
    const g = qa?.grants?.find(x => x.user_id === userOf[curFid]);
    const authority = owner ? 'active' : !g ? 'active' : g.status === 'revoked' ? 'revoked' : g.member_scope ? 'child_a_only' : g.role === 'caregiver' ? 'active' : 'read_only';
    const allSrc = Object.values(A).flatMap(a => a.sources ?? []);
    const runtime = { authority_state: authority, use_memory: !qa.household.memory_paused, client_use_memory: client.use_memory, mode: client.mode, account_epoch: client.epoch,
      current_account_user_id: client.account, membership_revision: 1 + (qa.household.membership_revision - (base.membership ?? qa.household.membership_revision)), source_access: allSrc.some(s => s.status === 'access_revoked') ? 'revoked' : 'active',
      household_tombstoned: Object.values(A).some(a => a.household.status === 'archived'), raw_media_available: allSrc.every(s => s.raw_media_available),
      reminder_status: qa.household.reminders_paused ? 'paused' : 'active', setting_sequence: qa.household.setting_sequence, memory_generation: init.memory_generation + (qa.household.memory_generation - (base.gen ?? qa.household.memory_generation)),
      recall_snapshot: client.snapshot ? 'frozen' : 'none', dispatch: client.dispatch, late_delivery: client.late };
    if (client.currentHh) runtime.current_household_id = client.currentHh;
    return { memStatus, srcStatus, runtime, counts: Object.fromEntries(Object.entries(A).map(([k, a]) => [k, a.counts])) };
  }
  const checkState = (rb, exp) => {
    if (!exp || exp.namespace_empty) return [];
    const bad = [];
    for (const m of exp.memory_states ?? []) { const got = rb.memStatus(m.memory_ref); if (got !== m.status) bad.push(`mem ${m.memory_ref.id.slice(0, 8)}@${m.memory_ref.revision}: ${got}≠${m.status}`); }
    for (const s of exp.source_states ?? []) { const got = rb.srcStatus(s.source_ref); if (got !== s.status) bad.push(`src ${s.source_ref.id.slice(0, 8)}: ${got}≠${s.status}`); }
    for (const [k, v] of Object.entries(exp.runtime_state ?? {})) if (JSON.stringify(rb.runtime[k]) !== JSON.stringify(k === 'current_account_user_id' ? v : v)) bad.push(`rt ${k}: ${JSON.stringify(rb.runtime[k])}≠${JSON.stringify(v)}`);
    return bad;
  };

  const steps = [], notRun = []; const base = {}; const rtHh = q.household_id; let movedFrom = null;
  const recallAs = async (who, fhh, extra = '') => { const t = hhOf[fhh]; const qs = `q=${encodeURIComponent(q.text)}&at=${encodeURIComponent(q.at)}${memberOf[q.subject_id] ? '&member_id=' + memberOf[q.subject_id] : ''}${extra}`; return call(who, 'GET', `/households/${t.hh}/memories/recall?${qs}`); };
  const resolveAs = async (who, fhh, refs) => call(who, 'POST', `/households/${hhOf[fhh].hh}/memories/resolve`, { refs });
  const refsActual = refs => refs.map(r => actual.get(key(r))).filter(Boolean).map(o => ({ memory_id: o.id, revision: o.revision }));
  const fhhOfRef = ref => versions.get(key(ref))?.household_id ?? q.household_id;

  for (const st of c.steps) {
    const inp = st.input ?? {};
    if (st.operation === 'query_memory') break;
    const pre = st.operation === 'materialize_synthetic_fixture_history' ? [] : checkState(await readback(), st.expected_preconditions);
    let label = null, detail = null;
    if (NOT_RUN_OPS[st.operation]) { notRun.push(st.operation); steps.push({ op: st.operation, expected: st.expected_outcome, label: 'NOT_RUN', reason: NOT_RUN_OPS[st.operation], pre, post: [] }); continue; }
    const op = st.operation, refs = inp.memory_refs ?? [];
    if (op === 'materialize_synthetic_fixture_history') {
      for (const s of inp.seed_source_states ?? []) if (s.status === 'active') { const src = sources.get(key(s.source_ref)); if (src) await register(src); }
      const seeds = await orderSeeds(c.id, inp.seed_memory_states ?? []);
      for (const s of seeds) seedState[key(s.memory_ref)] = s.status;
      for (const s of seeds) {
        const v = versions.get(key(s.memory_ref)); if (!v || actual.has(key(v))) continue;
        if (s.status === 'superseded') continue;   // created by the newer revision's correction chain
        if (s.status === 'retracted') { await create(v); await forget(key(v), v.household_id); continue; }
        if (['active', 'disputed', 'proposed', 'expired', 'future', 'condition_unmatched'].includes(s.status)) await create(v, {}, s.status === 'proposed' ? 'proposed' : s.status === 'disputed' ? 'disputed' : 'active');
      }
      // a superseded version with no same-id successor was replaced by another memory: load it, then supersede it
      for (const s of seeds) { const v = versions.get(key(s.memory_ref)); if (s.status !== 'superseded' || !v || actual.has(key(v))) continue; await create(v, {}, 'active'); await supersede(key(v), v.household_id); }
      const a0 = await audit(q.household_id); base.membership = a0.household.membership_revision; base.gen = a0.household.memory_generation;
      base.memories = 0; for (const fhh of Object.keys(hhOf)) base.memories += (await audit(fhh)).counts.memories;
      label = 'MATERIALIZED';
    } else if (op === 'forget_memory' || op === 'forget_no_relearn') {
      const rs = []; for (const r of refs) rs.push(await forget(key(r), fhhOfRef(r)));
      label = rs.length && rs.every(r => r.status === 'applied') ? (op === 'forget_no_relearn' ? 'TOMBSTONE_NO_RELEARN' : 'TOMBSTONE_COMMITTED') : `UNEXPECTED:${rs.map(r => r.error?.code ?? r.status)}`;
    } else if (op === 'retract_source' || op === 'revoke_source_access') {
      const v = versions.get(key(refs[0])); const s = v?.source_refs?.map(r => srcOf[key(r)]).find(Boolean); const fhh = v.household_id;
      const r = s ? await cmd(fhh, { type: op === 'retract_source' ? 'source.retract' : 'source.revoke_access', target_id: s.id, expected_revision: s.revision }) : { status: 'no_source' };
      const hit = r.status === 'applied' && refsActual(refs).every(x => r.objects.some(o => o.id === x.memory_id));
      label = hit ? (op === 'retract_source' ? 'DEPENDENT_MEMORY_RETRACTED' : 'AUTHORITY_REVOKED') : `UNEXPECTED:${r.error?.code ?? r.status}`;
    } else if (op === 'expire_raw_media') {
      const v = versions.get(key(refs[0])); const s = v?.source_refs?.map(r => srcOf[key(r)]).find(Boolean);
      const r = s ? await cmd(v.household_id, { type: 'source.expire_media', target_id: s.id }) : { status: 'no_source' };
      const row = await rowOf(v.household_id, actual.get(key(refs[0]))?.id);
      label = r.status === 'applied' && row?.status === 'active' ? 'RAW_MEDIA_PURGED_SUMMARY_RETAINED' : `UNEXPECTED:${r.error?.code ?? r.status}`;
    } else if (op === 'correct_memory' || op === 'late_update' || op === 'confirm_source_correction' || op === 'correct_summary_source') {
      const [from, to] = refs; const o = actual.get(key(from)); const v = versions.get(key(from)), vt = versions.get(key(to));
      if (!o || !v || !vt) label = 'UNEXPECTED:unmapped';
      else if (from.id !== to.id && op !== 'late_update') { const r2 = await create(vt); const r1 = r2.status === 'applied' ? await supersede(key(from), v.household_id, r2.objects[0].id) : { status: 'skipped' }; label = r1.status === 'applied' && r2.status === 'applied' ? (op === 'correct_summary_source' ? 'OLD_SUMMARY_SUPERSEDED' : 'REVISION_2_CONFIRMED') : `UNEXPECTED:${r1.status}/${r2.status}`; }
      else {
        const exp = op === 'late_update' ? (actual.get(`${from.id}@${inp.expected_revision ?? 1}`)?.revision ?? 1) : (await rowOf(v.household_id, o.id))?.revision ?? o.revision;
        await regSources(vt);
        const r = await cmd(v.household_id, { type: 'memory.correct', target_id: o.id, expected_revision: exp, payload: { text: vt.content.slice(0, 500) } });
        if (r.status === 'applied' && vt.id === from.id) mapObj(key(vt), r.objects[0]);
        if (r.status !== 'applied' && vt.id !== from.id) rejected.add(key(vt));
        label = r.status === 'applied' ? ({ correct_memory: 'APPLIED_REVISION_2', confirm_source_correction: 'REVISION_2_CONFIRMED', correct_summary_source: 'OLD_SUMMARY_SUPERSEDED' }[op] ?? 'UNEXPECTED:applied')
          : r.error?.code === 'revision_conflict' ? 'CONFLICT_409' : `UNEXPECTED:${r.error?.code}`;
      }
    } else if (op === 'confirm_memory' || op === 'confirm_sensitive_observation' || op === 'confirm_edited_fields' || op === 'create_new_member' || op === 'explicit_allow_relearn') {
      const out = [];
      for (const ref of refs) {
        const v = versions.get(key(ref)); if (!v) continue; const o = actual.get(key(ref));
        if (o) { // an existing proposed candidate: confirm it (same fixture ref, new authoritative revision)
          await regSources(v); const row = await rowOf(v.household_id, o.id);
          if (row?.status === 'proposed') { const r = await cmd(v.household_id, { type: 'memory.confirm', target_id: o.id, expected_revision: row.revision }); if (r.status === 'applied') mapObj(key(ref), r.objects[0]); out.push([r.status, row.kind]); }
          else out.push(['already', row?.status]);
          continue;
        }
        if (op === 'create_new_member') { const s = subj.get(v.subject_id); const r = await cmd(v.household_id, { type: 'member.upsert', payload: { display_name: s.display_name.slice(0, 40), member_kind: KIND[s.fixture_role] ?? 'child' } }); memberOf[v.subject_id] = r.objects?.[0]?.id; }
        if (inp.idempotency_key) {
          await regSources(v); const { hh, actor } = hhOf[v.household_id]; const body = { command_id: U(), household_id: hh, type: 'memory.upsert', payload: payloadOf(v, 'active') };
          const r = await call(actor, 'POST', `/households/${hh}/commands`, body); client[`idem:${inp.idempotency_key}`] = { fhh: v.household_id, body, receipt: r.body };
          if (r.body.status === 'applied') mapObj(key(v), r.body.objects[0]); out.push([r.body.status, v.kind]); continue;
        }
        const r = await create(v, op === 'explicit_allow_relearn' ? { explicit_relearn: true } : {}, 'active'); out.push([r.status, v.kind]);
      }
      const ok = out.length && out.every(x => x[0] === 'applied');
      label = !ok ? `UNEXPECTED:${JSON.stringify(out)}` : { confirm_memory: 'APPLIED_ONCE', confirm_sensitive_observation: out.every(x => x[1] === 'observation') ? 'OBSERVATION_ONLY_CONFIRMED' : 'UNEXPECTED:kind', confirm_edited_fields: 'REVISION_2_CONFIRMED', create_new_member: 'NEW_ID_CREATED', explicit_allow_relearn: 'NEW_GENERATION_CONFIRMED' }[op];
    } else if (op === 'replay_confirm' || op === 'replay_changed_payload') {
      const prev = client[`idem:${inp.idempotency_key}`];
      if (!prev) label = 'UNEXPECTED:no_original';
      else { const v = versions.get(key(refs[0])); await regSources(v); const { hh, actor } = hhOf[prev.fhh];
        const body = op === 'replay_confirm' ? prev.body : { ...prev.body, payload: { ...prev.body.payload, text: v.content.slice(0, 500) } };
        const r = await call(actor, 'POST', `/households/${hh}/commands`, body);
        if (op === 'replay_changed_payload' && r.status === 409 && !actual.has(key(v))) rejected.add(key(v));
        label = op === 'replay_confirm' ? (JSON.stringify(r.body) === JSON.stringify(prev.receipt) ? 'ORIGINAL_RECEIPT' : 'UNEXPECTED:receipt_differs') : (r.status === 409 ? 'CONFLICT_409' : `UNEXPECTED:${r.status}`); }
    } else if (op === 'set_memory_enabled' || op === 'late_set_memory_enabled') {
      const r = await cmd(q.household_id, { type: 'memory.settings', payload: { use_memory: !!inp.enabled, choice_sequence: inp.choice_sequence } });
      label = op === 'set_memory_enabled' ? (r.status === 'applied' && !inp.enabled ? 'SETTING_OFF_APPLIED' : `UNEXPECTED:${r.error?.code ?? r.status}`) : (r.error?.code === 'stale_sequence' ? 'STALE_SEQUENCE_IGNORED' : `UNEXPECTED:${r.error?.code ?? r.status}`);
    } else if (op === 'pause_reminder') {
      const before = (await audit(q.household_id)).memories.filter(m => m.status === 'active').length;
      const rev = (await call(hhOf[q.household_id].actor, 'GET', `/households/${hhOf[q.household_id].hh}/projection`)).body.home.household.revision;
      const r = await cmd(q.household_id, { type: 'reminder.pause', expected_revision: rev, payload: { paused: true } });
      const after = (await audit(q.household_id)).memories.filter(m => m.status === 'active').length;
      label = r.status === 'applied' && before === after ? 'REMINDER_PAUSED_NO_MEMORY_DELETE' : `UNEXPECTED:${r.error?.code ?? r.status}`;
    } else if (op === 'remove_member') {
      const out = [];
      for (const ref of refs) { const v = versions.get(key(ref)); const mid = v && memberOf[v.subject_id]; if (!mid) continue; const { hh, actor } = hhOf[v.household_id];
        const home = (await call(actor, 'GET', `/households/${hh}/home`)).body.home; const m = [...home.children, ...(home.adults ?? [])].find(k => k.member_id === mid);
        const r = m ? await cmd(v.household_id, { type: 'child.delete', target_id: mid, expected_revision: m.revision }) : { status: 'no_member' }; out.push(r.status); }
      label = out.length && out.every(s => s === 'applied') ? 'MEMBER_REMOVED' : `UNEXPECTED:${out}`;
    } else if (op === 'confirm_this_time_only') {
      // a one-off override is stored bounded to that occurrence (valid_to), never as a durable preference
      const out = []; for (const ref of refs) { const v = versions.get(key(ref)); if (!v) continue; const r = await create(v, {}, 'active'); out.push(r.status === 'applied' && !!v.valid_to); }
      label = out.length && out.every(Boolean) ? 'TEMPORARY_OVERRIDE_ONLY' : `UNEXPECTED:${out}`;
    } else if (op === 'edit_extracted_field') {
      // the user edits a field of the extracted candidate: the candidate gets a new revision but stays 'proposed' (not saved)
      const [from, to] = refs; const o = actual.get(key(from)); const v = versions.get(key(from)), vt = versions.get(key(to));
      const row = o ? await rowOf(v.household_id, o.id) : null; let r = { status: 'unmapped' };
      if (row?.status === 'proposed') { r = await cmd(v.household_id, { type: 'memory.correct', target_id: o.id, expected_revision: row.revision, payload: { text: vt.content.slice(0, 500) } }); if (r.status === 'applied') mapObj(key(vt), r.objects[0]); }
      const after = o ? await rowOf(v.household_id, o.id) : null;
      label = r.status === 'applied' && after?.status === 'proposed' ? 'EDITED_DRAFT_NOT_SAVED' : `UNEXPECTED:${r.error?.code ?? r.status}`;
    } else if (op === 'extract_old_paraphrase' || op === 'sync_old_device' || op === 'complete_old_extraction_job' || op === 'commit_summary') {
      const out = [];
      for (const ref of refs) { const v = versions.get(key(ref)); if (!v || !hhOf[v.household_id]) continue; const g = inp.admitted_generation ?? inp.generation ?? 1; const r = await create(v, { admitted_generation: g }, 'active'); out.push(r.error?.code ?? r.status); }
      const fenced = out.length && out.every(x => x === 'stale_generation' || x === 'not_found');
      label = fenced ? (op === 'sync_old_device' ? 'REJECTED_OLD_GENERATION' : 'REJECTED_TOMBSTONE') : `UNEXPECTED:${out}`;
    } else if (op === 'delete_household') {
      const out = [];
      for (const [fhh, { hh, actor }] of Object.entries(hhOf)) { if (!refs.some(ref => versions.get(key(ref))?.household_id === fhh)) continue; const rev = (await call(actor, 'GET', `/households/${hh}/projection`)).body.home.household.revision; out.push((await cmd(fhh, { type: 'household.delete', expected_revision: rev })).status); }
      label = out.length && out.every(s => s === 'applied') ? 'HOUSEHOLD_TOMBSTONE_COMMITTED' : `UNEXPECTED:${out}`;
    } else if (op === 'create_same_display_name_household') {
      const old = hhOf[q.household_id]; const deleted = Object.entries(hhOf).find(([k]) => k !== q.household_id && true);
      const [dfhh, d] = Object.entries(hhOf).find(([, x]) => x.fowner === client.account) ?? deleted;
      const r = await call(d.actor, 'POST', '/commands', { command_id: U(), type: 'household.ensure', household_id: U(), payload: { name: (c.identities.households.find(h => h.id === q.household_id)?.alias ?? '我们家').slice(0, 80) } });
      const nid = r.body.objects?.[0]?.id;
      if (nid && nid !== d.hh) { movedFrom = hhOf[q.household_id]; hhOf[q.household_id] = { hh: nid, actor: d.actor, fowner: d.fowner }; client.currentHh = q.household_id; label = 'NEW_HOUSEHOLD_ID'; } else label = `UNEXPECTED:${r.body.status}`;
      void old; void dfhh;
    } else if (op === 'set_client_use_memory') { client.use_memory = !!inp.enabled; label = inp.enabled ? 'UNEXPECTED:enabled' : 'READ_WRITE_DISABLED';
    } else if (op === 'enter_ephemeral_conversation') { client.mode = 'ephemeral'; label = 'EPHEMERAL_READ_WRITE_DISABLED';
    } else if (op === 'request_shared_projection') {
      const o = actual.get(key(refs[0])); const v = versions.get(key(refs[0]));
      const r = o ? await cmd(v.household_id, { type: 'memory.share', target_id: o.id, expected_revision: o.revision, payload: {} }) : { status: 'unmapped' };
      label = r.error?.code === 'visibility_confirmation_required' ? 'REQUIRES_VISIBILITY_CONFIRMATION' : `UNEXPECTED:${r.error?.code ?? r.status}`;
    } else if (op === 'freeze_recall_snapshot' || op === 'start_recall') {
      const fid = op === 'start_recall' ? client.account : q.viewer_user_id; const who = await user(fid);
      const sfhh = op === 'start_recall' ? (Object.entries(hhOf).find(([, x]) => x.fowner === fid)?.[0] ?? q.household_id) : q.household_id;
      const r = await recallAs(who, sfhh, hhOf[sfhh].fowner === fid ? '&visibility=private' : '');
      const snap = r.body.snapshot?.refs ?? []; const need = refsActual(refs);
      const has = r.status === 200 && need.every(n => snap.some(s => s.memory_id === n.memory_id && s.revision === n.revision));
      if (op === 'freeze_recall_snapshot') { if (has) client.snapshot = { refs: snap, fhh: q.household_id, epoch: client.epoch }; label = has ? 'SNAPSHOT_FROZEN' : `UNEXPECTED:${r.status}`; }
      else { client.pending = { refs: snap, fhh: sfhh, epoch: client.epoch, account: client.account }; label = r.status === 200 ? 'REQUEST_STARTED_ACCOUNT_A' : `UNEXPECTED:${r.status}`; }
    } else if (op === 'resolve_before_output') {
      const who = await user(q.viewer_user_id); const r = await resolveAs(who, client.snapshot?.fhh ?? q.household_id, client.snapshot?.refs ?? []);
      const fencedAll = r.status === 404 || r.status === 403 || refsActual(refs).every(n => r.body.fenced?.some(f => f.memory_id === n.memory_id));
      if (fencedAll) client.dispatch = 'BLOCKED';
      label = fencedAll ? 'OUTPUT_FENCED' : 'UNEXPECTED:allowed';
    } else if (op === 'search_stale_index' || op === 'dispatch_derived_reminder') {
      // a stale index hit / a reminder derived from a memory: re-verified against authority before use
      const r = await resolveAs(hhOf[q.household_id].actor, q.household_id, refsActual(refs));
      const fenced = r.status === 200 && r.body.allowed.length === 0 && r.body.fenced.length === refsActual(refs).length && refs.length > 0;
      if (fenced && op === 'dispatch_derived_reminder') client.dispatch = 'BLOCKED';
      label = fenced ? (op === 'search_stale_index' ? 'FILTERED_BY_AUTHORITY' : 'DERIVATION_RETRACTED') : `UNEXPECTED:${r.status}`;
    } else if (op === 'undo_forget') {
      const o = actual.get(key(refs[0])); const v = versions.get(key(refs[0]));
      const r = o ? await cmd(v.household_id, { type: 'memory.restore', target_id: o.id }) : { status: 'unmapped' };
      label = r.error?.code === 'undo_expired' ? 'UNDO_EXPIRED_NO_RESTORE' : `UNEXPECTED:${r.error?.code ?? r.status}`;
    } else if (op === 'query_cleanup_receipt') {
      const cid = Object.values(forgetCmd)[0]; const r = cid ? await call(hhOf[q.household_id].actor, 'GET', `/commands/${cid}`) : { body: {} };
      // cleanup is synchronous here: the forget receipt is already applied, so no pending state exists to report
      label = r.body.outcome === 'applied' ? 'CLEANUP_COMPLETE_SYNCHRONOUS' : r.body.outcome === 'processing' ? 'PENDING_ORIGINAL_OPERATION' : `UNEXPECTED:${r.body.outcome}`;
    } else if (op === 'switch_account') {
      client.epoch += 1; client.account = q.viewer_user_id; label = 'ACCOUNT_B_ACTIVE';
    } else if (op === 'deliver_late_result') {
      const p = client.pending; let dropped = !p || p.epoch !== client.epoch;
      if (p) { const r = await resolveAs(await user(client.account), p.fhh, p.refs); dropped = dropped || r.status !== 200 || r.body.allowed.length === 0; }
      if (dropped) client.late = 'dropped'; client.pending = null;
      label = dropped ? 'DROPPED_ACCOUNT_EPOCH_MISMATCH' : 'UNEXPECTED:delivered';
    } else if (op === 'revoke_membership') {
      const r = await cmd(q.household_id, { type: 'grant.revoke', payload: { user_id: await user(q.viewer_user_id) } });
      label = r.status === 'applied' ? 'MEMBERSHIP_REVOKED' : `UNEXPECTED:${r.error?.code ?? r.status}`;
    } else if (op === 'promote_shared_memory') {
      const o = actual.get(key(refs[0])); const r = o ? await cmdAs(await user(q.viewer_user_id), q.household_id, { type: 'memory.confirm', target_id: o.id, expected_revision: o.revision }) : { status: 'unmapped' };
      label = r.status === 'rejected' && r.error?.code === 'forbidden' ? 'FORBIDDEN_403' : `UNEXPECTED:${r.error?.code ?? r.status}`;
    } else if (op === 'extract_voice_fields') {
      // real zh-CN extractor on the voice transcript -> confirm cards only; the candidate memory is stored 'proposed'
      const v = versions.get(key(refs[0])); const s = (v?.source_refs ?? []).map(r => sources.get(key(r))).find(Boolean) ?? c.sources.find(x => x.kind === 'voice_transcript');
      const { hh, actor } = hhOf[q.household_id]; const before = (await audit(q.household_id)).memories.filter(m => m.status === 'active').length;
      const cap = await call(actor, 'POST', `/households/${hh}/captures`, { capture_id: U(), kind: 'voice_transcript', text: s.text.slice(0, 2000) });
      if (s) await register(s);
      const r = v ? await create(v, {}, 'proposed') : { status: 'unmapped' };
      const after = (await audit(q.household_id)).memories.filter(m => m.status === 'active').length;
      label = cap.status === 200 && r.status === 'applied' && before === after ? 'CANDIDATE_ONLY_NO_WRITE' : `UNEXPECTED:${cap.status}/${r.status}`;
      detail = { capture_status: cap.status, cards: cap.body.cards?.length ?? null };
    } else { label = 'UNEXPECTED:unhandled'; }
    const post = checkState(await readback(), st.expected_postconditions);
    steps.push({ op, expected: st.expected_outcome, label, pre, post, ...(detail ? { detail } : {}) });
  }

  // ---- final query (third session) as the current client account ----
  const qstep = c.steps.find(s => s.operation === 'query_memory');
  const rbPre = await readback(); const qpre = checkState(rbPre, qstep?.expected_preconditions);
  const viewerFid = q.viewer_user_id; const who = await user(viewerFid);
  const flags = `${client.use_memory === false ? '&use_memory=false' : ''}${client.mode === 'ephemeral' ? '&ephemeral=true' : ''}`;
  let res, answer, top = [], used = [], dispatch = client.dispatch === 'BLOCKED' ? 'BLOCKED' : 'NOT_REQUESTED';
  // a viewer who holds (or held) a grant on this household is BLOCKED when refused; a stranger simply gets nothing
  const qAudit = hhOf[q.household_id] ? await audit(q.household_id) : null;
  const hadAccess = !!qAudit?.grants?.some(g => g.user_id === userOf[viewerFid]);
  if (client.snapshot && dispatch === 'BLOCKED') { // continuation of a frozen answer whose refs were fenced: nothing is output
    res = { status: 200, body: {} }; answer = { disposition: 'BLOCKED', used_memory_refs: [], assertions: [], clarification_fields: [] };
  } else if (dispatch === 'BLOCKED') {
    res = { status: 200, body: {} }; answer = { disposition: 'BLOCKED', used_memory_refs: [], assertions: [], clarification_fields: [] };
  } else {
    res = hhOf[q.household_id] ? await recallAs(who, q.household_id, flags) : { status: 404, body: {} };
    if (res.status === 200) { answer = res.body.answer; top = res.body.results ?? []; }
    else { answer = { disposition: hadAccess ? 'BLOCKED' : 'NO_REFERENCE', used_memory_refs: [], assertions: [], clarification_fields: [] }; if (answer.disposition === 'BLOCKED') dispatch = 'BLOCKED'; }
  }
  const toFix = r => back.get(`${r.memory_id}@${r.revision}`) ?? `unmapped:${r.memory_id}@${r.revision}`;
  const returned = top.map(toFix); used = (answer.used_memory_refs ?? []).map(toFix);
  const assertions = (answer.assertions ?? []).map(a => ({ ref: toFix(a), kind: a.kind, status: a.status, value: a.value }));
  let memNow = 0; for (const fhh of Object.keys(hhOf)) memNow += (await audit(fhh)).counts.memories;
  const rbPost = await readback();
  return { scores: top.map(t => t.score), created: memNow - (base.memories ?? memNow), notRun, steps, qpre, status: res.status, returned, used, assertions, answer, dispatch, counts: { pre: rbPre.counts, post: rbPost.counts }, reads: res.body?.memory_reads ?? 0,
    finalMem: c.expectation.expected_final_statuses.map(f => [key(f.memory_ref), rbPost.memStatus(f.memory_ref), f.status]),
    finalSrc: c.expectation.expected_final_source_statuses.map(f => [key(f.source_ref), rbPost.srcStatus(f.source_ref), f.status]),
    finalRt: checkState(rbPost, { runtime_state: c.expected_final_runtime_state }) };
}

function score(c, r) {
  const e = c.expectation, x = e.expected_structured_result, H = {};
  const forb = new Set((e.forbidden_memory_refs ?? []).map(f => key(f.memory_ref)));
  const leaked = [...new Set([...r.returned.slice(0, 6), ...r.used].filter(k => forb.has(k)))];
  H.no_forbidden_refs = leaked.length ? 'FAIL' : 'PASS';
  const allowed = new Set(e.allowed_injected_refs.map(key)); H.used_subset_of_allowed = r.used.every(k => allowed.has(k)) ? 'PASS' : 'FAIL';
  const gold = new Map(x.assertions.map(a => [key(a.memory_ref), a]));
  H.assertions_match = r.assertions.every(a => { const g = gold.get(a.ref); return g && g.kind === a.kind && g.status === a.status && g.value === a.value; }) ? 'PASS' : 'FAIL';
  const req = e.expected_clarification.required_fields;
  H.clarification_fields = eqSet(r.answer.clarification_fields ?? [], req) ? 'PASS' : (req.length && !(r.answer.clarification_fields ?? []).length ? 'NOT_RUN' : 'FAIL');
  H.disposition = x.allowed_dispositions.includes(r.answer.disposition) ? 'PASS' : 'FAIL';
  H.dispatch = r.dispatch === x.dispatch ? 'PASS' : 'FAIL';
  const opSteps = r.steps.filter(s => s.op !== 'materialize_synthetic_fixture_history');
  H.operation_outcomes = opSteps.some(s => s.label === 'NOT_RUN') ? 'NOT_RUN' : opSteps.every(s => s.label === s.expected) ? 'PASS' : 'FAIL';
  H.step_pre_post = r.steps.some(s => s.label === 'NOT_RUN') ? 'NOT_RUN' : (r.steps.every(s => !s.pre.length && !s.post.length) && !r.qpre.length) ? 'PASS' : 'FAIL';
  H.final_statuses = r.finalMem.every(([, a, b]) => a === b) && r.finalSrc.every(([, a, b]) => a === b) ? 'PASS' : 'FAIL';
  H.final_runtime_state = r.finalRt.length ? 'FAIL' : 'PASS';
  const writes = Object.keys(r.counts.pre).reduce((n, k) => n + (r.counts.post[k].receipts - r.counts.pre[k].receipts), 0);
  H.side_effect_counts = [x.expected_memory_writes == null || x.expected_memory_writes === writes, x.expected_memory_reads == null || x.expected_memory_reads === r.reads, x.expected_created_records == null || x.expected_created_records === r.created].every(Boolean) ? 'PASS' : 'FAIL';
  // behaviour codes: ref/state based ones are checked; text behaviours cannot occur (no free text is generated)
  const unconfirmed = c.memory_versions.filter(v => v.initial_status === 'proposed').some(v => r.finalMem.some(([k, a, b]) => k === key(v) && a === 'active' && b !== 'active'));
  H.forbidden_behaviors = leaked.length || unconfirmed ? 'FAIL' : 'PASS';
  return { H, leaked, writes };
}

test('M3 gate FULL: recall@6, hard assertions (clarification, disposition, dispatch, outcomes, pre/post, final states), safety (100 cases)', { skip: !url }, async () => {
  const sql = postgres(url, { max: 6, prepare: false, onnotice: () => {} });
  const svc = createFamilyService({ store: createPgFamilyStore(sql), extraRoutes: [createMemoryRoute(), createCaptureRoute()], verifyUser: async a => { const m = /^Bearer (.+)$/.exec(a); return m ? { sub: m[1] } : null; } });
  const call = async (who, method, path, body) => { const r = await svc.handle(new Request('https://x/catpaw/family/v1' + path, { method, headers: { authorization: 'Bearer ' + who, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, body: await r.json() }; };
  const out = { corpus: corpus.dataset_id, cases: [], at: new Date().toISOString() };
  try {
    let sum = 0, hits = 0, gold = 0, safetyErrors = 0; const byCat = {}, hard = {}, failing = {};
    for (const c of corpus.cases) {
      let r, s;
      try { r = await runCase(sql, call, c); s = score(c, r); }
      catch (e) { out.cases.push({ id: c.id, category: c.category, status: 'ERROR', error: String(e?.message ?? e).slice(0, 200) }); if (c.expectation.retrieval_eligible) gold += c.expectation.eligible_gold_refs.length; continue; }
      const e = c.expectation; let recall = null;
      if (s.leaked.length) safetyErrors++;
      if (e.retrieval_eligible) {
        const G = e.eligible_gold_refs.map(key); gold += G.length; const top = r.returned.slice(0, 6);
        const h = r.notRun.length ? 0 : G.filter(g => top.includes(g)).length; hits += h; recall = r.notRun.length ? 0 : h / G.length; sum += recall;
        (byCat[c.category] ??= { eligible: 0, recall_sum: 0 }); byCat[c.category].eligible++; byCat[c.category].recall_sum += recall;
      }
      for (const [k, v] of Object.entries(s.H)) { (hard[k] ??= { PASS: 0, FAIL: 0, NOT_RUN: 0 })[v]++; if (v !== 'PASS') (failing[k] ??= []).push(c.id); }
      const status = Object.values(s.H).every(v => v === 'PASS') ? 'PASS' : Object.values(s.H).includes('FAIL') ? 'FAIL' : 'NOT_RUN';
      out.cases.push({ id: c.id, category: c.category, status, eligible: e.retrieval_eligible, recall, hard: s.H, leaked: s.leaked, disposition: r.answer.disposition, expected_disposition: e.expected_structured_result.allowed_dispositions,
        clarification_expected: e.expected_clarification.required_fields, dispatch: r.dispatch, not_run_ops: r.notRun, steps: r.steps, query_pre: r.qpre, final_mismatch: [...r.finalMem, ...r.finalSrc].filter(([, a, b]) => a !== b), final_runtime: r.finalRt,
        http: r.status, returned: r.returned.slice(0, 6), scores: r.scores, used: r.used, assertions: r.assertions });
    }
    const pass = out.cases.filter(x => x.status === 'PASS').length;
    const macro = sum / 50;
    out.summary = { eligible: 50, macro_recall_at_6: macro, micro_recall_at_6: hits / gold, gold_hits: hits, gold_refs: gold, safety_forbidden_ref_cases: safetyErrors,
      cases_pass: pass, cases_fail: out.cases.filter(x => x.status === 'FAIL').length, cases_not_run: out.cases.filter(x => x.status === 'NOT_RUN').length, cases_error: out.cases.filter(x => x.status === 'ERROR').length,
      hard_assertions: hard, failing_by_assertion: failing, by_category: byCat,
      gate: { macro_threshold: 0.9, macro_ok: macro >= 0.9, safety_ok: safetyErrors === 0, all_hard_pass: pass === 100, complete_100: out.cases.length === 100 && !out.cases.some(x => x.status === 'ERROR'), PASS: macro >= 0.9 && safetyErrors === 0 && pass === 100 } };
    await Deno.writeTextFile(Deno.env.get('M3_GATE_OUT') ?? '/tmp/family-m3-gate.json', JSON.stringify(out, null, 1));
    console.log('M3', JSON.stringify({ ...out.summary, failing_by_assertion: Object.fromEntries(Object.entries(failing).map(([k, v]) => [k, v.length])) }));
    assert.equal(out.cases.length, 100);
    assert.equal(safetyErrors, 0, 'forbidden refs returned');
  } finally { await sql.end(); }
});
