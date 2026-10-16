// Postgres store for catpaw.agent-memory.v1 (migration 20261016090000, not applied). Same semantics as memory-store.mjs.
// Runs as the DB role in SUPABASE_DB_URL; every query is explicitly filtered by user_id (RLS is the second layer).
const COLS = 'id,user_id,kind,content,pinned,expires_at,source_conversation_id,source_turn_id,operation_id,created_by,undo_token_hash,undo_expires_at,created_at,updated_at,embedding::text as embedding';
const fix = r => { if (!r) return r; for (const k of ['expires_at', 'undo_expires_at', 'created_at', 'updated_at']) if (r[k] instanceof Date) r[k] = r[k].toISOString(); r.embedding = typeof r.embedding === 'string' ? JSON.parse(r.embedding) : null; return r; };
const vec = v => Array.isArray(v) ? JSON.stringify(v) : null;
export function createPgAgentMemoryStore(sql) {
  return {
    async getSettings(uid) { const r = await sql.unsafe('select use_memory,auto_save,consented_at from agent_memory.memory_settings where user_id=$1', [uid]); if (!r.length) return null; const s = r[0]; return { use_memory: s.use_memory, auto_save: s.auto_save, consented_at: s.consented_at instanceof Date ? s.consented_at.toISOString() : s.consented_at }; },
    /** Codex PR91 v3-2: conditional upsert — only a strictly newer use_memory_seq wins (migration 20261017030000). */
    async putSettingsIfNewer(uid, s, seq) {
      const r = await sql.unsafe('insert into agent_memory.memory_settings(user_id,use_memory,auto_save,consented_at,use_memory_seq,updated_at) values($1,$2,$3,$4,$5,now()) on conflict(user_id) do update set use_memory=excluded.use_memory,auto_save=excluded.auto_save,consented_at=excluded.consented_at,use_memory_seq=excluded.use_memory_seq,updated_at=now() where coalesce(agent_memory.memory_settings.use_memory_seq,0) < excluded.use_memory_seq returning user_id', [uid, s.use_memory, s.auto_save, s.consented_at, seq]);
      return r.length ? { ...s } : null;
    },
    async putSettings(uid, s) { await sql.unsafe('insert into agent_memory.memory_settings(user_id,use_memory,auto_save,consented_at,updated_at) values($1,$2,$3,$4,now()) on conflict(user_id) do update set use_memory=excluded.use_memory,auto_save=excluded.auto_save,consented_at=excluded.consented_at,updated_at=now()', [uid, s.use_memory, s.auto_save, s.consented_at]); return { ...s }; },
    async insert(uid, r) {
      const ins = await sql.unsafe(`insert into agent_memory.memories(id,user_id,kind,content,embedding,pinned,expires_at,source_conversation_id,source_turn_id,operation_id,created_by,undo_token_hash,undo_expires_at,created_at,updated_at)
        values($1,$2,$3,$4,$5::extensions.vector,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) on conflict(user_id,operation_id) do nothing returning ${COLS}`,
        [r.id, uid, r.kind, r.content, vec(r.embedding), r.pinned, r.expires_at, r.source_conversation_id, r.source_turn_id, r.operation_id, r.created_by, r.undo_token_hash, r.undo_expires_at, r.created_at, r.updated_at]);
      if (ins.length) return { row: fix(ins[0]), created: true };
      return { row: fix((await sql.unsafe(`select ${COLS} from agent_memory.memories where user_id=$1 and operation_id=$2`, [uid, r.operation_id]))[0]), created: false };
    },
    async get(uid, id) { return fix((await sql.unsafe(`select ${COLS} from agent_memory.memories where user_id=$1 and id=$2`, [uid, id]))[0] ?? null); },
    async list(uid) { return (await sql.unsafe(`select ${COLS} from agent_memory.memories where user_id=$1 order by updated_at desc limit 1000`, [uid])).map(fix); },
    async count(uid) { return Number((await sql.unsafe('select count(*)::int as n from agent_memory.memories where user_id=$1', [uid]))[0].n); },
    async update(uid, id, f) {
      const sets = [], args = [uid, id];
      for (const [k, v] of Object.entries(f)) { if (!['content', 'pinned', 'updated_at', 'embedding'].includes(k)) continue; args.push(k === 'embedding' ? vec(v) : v); sets.push(`${k}=$${args.length}${k === 'embedding' ? '::extensions.vector' : ''}`); }
      return fix((await sql.unsafe(`update agent_memory.memories set ${sets.join(',')} where user_id=$1 and id=$2 returning ${COLS}`, args))[0] ?? null);
    },
    async changedSince(uid, sinceIso) {
      const rows = (await sql.unsafe(`select ${COLS} from agent_memory.memories where user_id=$1 and updated_at > $2::timestamptz order by updated_at limit 500`, [uid, sinceIso])).map(fix);
      const deleted = (await sql.unsafe('select memory_id as id, deleted_at from agent_memory.memory_tombstones where user_id=$1 and deleted_at > $2::timestamptz order by deleted_at limit 500', [uid, sinceIso])).map(r => ({ id: r.id, deleted_at: r.deleted_at instanceof Date ? r.deleted_at.toISOString() : r.deleted_at }));
      return { rows, deleted };
    },
    async remove(uid, ids) { return ids.length ? (await sql.unsafe('delete from agent_memory.memories where user_id=$1 and id = any($2::uuid[]) returning id', [uid, ids])).length : 0; },
    async removeAll(uid) { await sql.unsafe('delete from agent_memory.journal_fragments where user_id=$1', [uid]); return (await sql.unsafe('delete from agent_memory.memories where user_id=$1 returning id', [uid])).length; },
    async byUndoHash(uid, h) { return fix((await sql.unsafe(`select ${COLS} from agent_memory.memories where user_id=$1 and undo_token_hash=$2`, [uid, h]))[0] ?? null); },
    async appendFragment(uid, f) { return (await sql.unsafe('insert into agent_memory.journal_fragments(user_id,day,turn_id,conversation_id,text,at) values($1,$2,$3,$4,$5,$6) on conflict do nothing returning turn_id', [uid, f.day, f.turn_id, f.conversation_id, f.text, f.at])).length > 0; },
    async takeFragments(day) {
      const rows = await sql.unsafe('delete from agent_memory.journal_fragments where day=$1 returning user_id,turn_id,conversation_id,text,at', [day]); const out = new Map();
      for (const r of rows.sort((a, b) => String(a.at).localeCompare(String(b.at)))) { if (!out.has(r.user_id)) out.set(r.user_id, []); out.get(r.user_id).push({ ...r, day }); }
      return [...out.entries()].map(([user_id, items]) => ({ user_id, items }));
    },
  };
}
