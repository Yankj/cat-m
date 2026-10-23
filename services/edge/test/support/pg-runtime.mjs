// Real-PG tests: the stores catpaw-api runs in-process (family, agent-memory) must connect like production — a LOGIN in
// catpaw_records without SUPERUSER/BYPASSRLS — so missing grants/policies fail here instead of in prod.
// runtimeOf(admin) returns a pool on CATPAW_PG_RUNTIME_URL that is closed with the admin pool. Required in the script run.
import postgres from 'npm:postgres@3.4.7';
export function runtimeOf(admin, opts = {}) {
  const u = Deno.env.get('CATPAW_PG_RUNTIME_URL');
  if (!u) throw new Error('CATPAW_PG_RUNTIME_URL unset: run via scripts/pg-all-migrations-local.sh (non-superuser runtime role)');
  const rt = postgres(u, { max: 4, prepare: false, onnotice: () => {}, ...opts });
  const end = admin.end.bind(admin);
  admin.end = async o => { await rt.end(o); return end(o); };
  return rt;
}
