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
    projection: (actor, hh, date) => one('select family.projection($1::uuid, $2::uuid, $3::date) as r', [actor, hh, date]),
    changes: (actor, hh, after, limit) => one('select family.changes($1::uuid, $2::uuid, $3::bigint, $4::integer) as r', [actor, hh, after, limit]),
  };
}
