// Postgres store for catpaw.family.v1. Every call goes through SECURITY DEFINER functions that re-filter by owner.
export function createPgFamilyStore(sql) {
  const one = async (q, args) => (await sql.unsafe(q, args))[0]?.r ?? null;
  return {
    async apply(actor, cmd, hash) {
      try { return await one('select family.apply_command($1::uuid, $2::text::jsonb, $3) as r', [actor, JSON.stringify(cmd), hash]); }
      catch (e) { if (e?.code === 'FA002') { const err = new Error(e.message); err.familyCode = e.message; throw err; } throw e; }
    },
    receipt: (actor, id) => one('select family.get_receipt($1::uuid, $2::uuid) as r', [actor, id]),
    households: (actor) => one('select family.my_households($1::uuid) as r', [actor]),
    // today / conversation / home + memories + settings from ONE repeatable-read snapshot (api-v1 §9)
    projection: (actor, hh, date) => sql.begin('isolation level repeatable read read only', async tx => {
      const p = (await tx.unsafe('select family.projection($1::uuid, $2::uuid, $3::date) as r', [actor, hh, date]))[0]?.r ?? null;
      if (!p) return null;
      p.home.memories = (await tx.unsafe('select family.memories_for($1::uuid, $2::uuid, null, null, $3) as r', [actor, hh, 'all']))[0].r ?? [];
      p.home.settings = (await tx.unsafe('select family.settings_for($1::uuid, $2::uuid) as r', [actor, hh]))[0].r;
      return p;
    }),
    recallCandidates: (actor, hh, at, member, visibility = 'household') => one('select family.memories_for($1::uuid, $2::uuid, $3::timestamptz, $4::uuid, $5) as r', [actor, hh, at, member, visibility]),
    reader: (actor, hh) => one('select family.reader($1::uuid, $2::uuid) as r', [actor, hh]),
    resolveRefs: (actor, hh, refs) => one('select family.resolve_refs($1::uuid, $2::uuid, $3::text::jsonb) as r', [actor, hh, JSON.stringify(refs)]),
    memoryAudit: (actor, hh) => one('select family.memory_audit($1::uuid, $2::uuid) as r', [actor, hh]),
    claimDueReminders: async (nowIso, limit = 50) => sql.unsafe('select * from family.claim_due_reminders($1::timestamptz, $2)', [nowIso, limit]),
    fireReminder: async (id, claimedAt) => (await sql.unsafe('select family.fire_reminder($1::uuid, $2::timestamptz) as r', [id, claimedAt]))[0].r,
    releaseReminder: async (id, claimedAt) => { await sql.unsafe('select family.release_reminder($1::uuid, $2::timestamptz)', [id, claimedAt]); },
    changes: (actor, hh, after, limit) => one('select family.changes($1::uuid, $2::uuid, $3::bigint, $4::integer) as r', [actor, hh, after, limit]),
  };
}
