// Deploy review: behaviour with CATPAW_FAMILY_ENABLED unset/off, and the migration-order dependency of the
// agent-memory changes (tombstone operation_id / clear_generations from 20261023100100) that ship regardless of the flag.
// Run: PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-flag-off-pg.test.mjs
import test from 'node:test'; import assert from 'node:assert/strict';
import postgres from 'npm:postgres@3.4.7';
import { createPgAgentMemoryStore } from '../supabase/functions/_shared/agent-memory/pg-store.mjs';
const url = Deno.env.get('CATPAW_PG_TEST_URL');
const ROLLBACK = new Error('rollback');

// HTTP flag behaviour (404 when off, allowlist) is tested through the real handler in test/family-flag-gate.test.mjs.

test('flag off still needs 20261023100100: agent-memory save / clear work after it, fail without it', { skip: !url }, async () => {
  const sql = postgres(url, { max: 2, prepare: false, onnotice: () => {} });
  try {
    const u = crypto.randomUUID(); await sql`insert into auth.users(id) values(${u})`;
    const row = () => ({ id: crypto.randomUUID(), kind: 'fact', content: '喜欢猫', embedding: null, pinned: false, expires_at: null, source_conversation_id: null, source_turn_id: null,
      operation_id: crypto.randomUUID(), created_by: 'user', undo_token_hash: null, undo_expires_at: null, created_at: new Date().toISOString(), updated_at: new Date().toISOString() });
    const s = createPgAgentMemoryStore(sql);
    assert.ok((await s.insert(u, row())).row, 'save works with 100100 applied');
    await s.removeAll(u); assert.equal(await s.clearGeneration(u), 1, 'clear works with 100100 applied');
    // simulate the pre-100100 schema inside a rolled-back transaction
    for (const [undo, act, what] of [
      ['alter table agent_memory.memory_tombstones drop column operation_id cascade', st => st.insert(u, row()), 'save (tombstone operation_id check)'],
      ['drop table agent_memory.clear_generations', st => st.removeAll(u), 'clear memory (clear_generations)']]) {
      let err = null;
      await sql.begin(async tx => { await tx.unsafe(undo); try { await act(createPgAgentMemoryStore(tx)); } catch (e) { err = e; } throw ROLLBACK; }).catch(e => { if (e !== ROLLBACK) throw e; });
      assert.ok(err, `${what} fails without 20261023100100`);
    }
  } finally { await sql.end(); }
});
