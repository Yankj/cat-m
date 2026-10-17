// Codex p91w B1/B2: the 使用记忆 switch is written last-writer-by-sequence; writes without a sequence never rewrite it.
// Memory store always; the same scenario on real Postgres when CATPAW_TEST_PG_HOST (socket dir or host) is set.
import test from 'node:test';
import assert from 'node:assert/strict';
import process from 'node:process';
import { createAgentMemoryStore } from '../supabase/functions/_shared/agent-memory/memory-store.mjs';
import { createAgentMemoryService } from '../supabase/functions/_shared/agent-memory/service.mjs';

const U = '11111111-1111-4111-8111-111111111111';
async function scenario(store, peek) {
  const svc = createAgentMemoryService({ store, allow: () => true });
  let r = await svc.patchSettings(U, { consent: true, use_memory: true, use_memory_seq: 5 });
  assert.equal((await peek()).use_memory, true);
  r = await svc.patchSettings(U, { use_memory: false, use_memory_seq: 4 }); assert.equal(r.stale, true, 'older seq ignored');
  r = await svc.patchSettings(U, { use_memory: false, use_memory_seq: 5 }); assert.equal(r.stale, true, 'equal seq ignored');
  assert.equal((await peek()).use_memory, true);
  const staleSnapshot = await svc.settings(U); assert.equal(staleSnapshot.use_memory, true);
  await svc.patchSettings(U, { use_memory: false, use_memory_seq: 6 });
  // B1: autosave PATCH (no seq) sent from the stale "on" page must not turn use_memory back on
  await svc.patchSettings(U, { consent: true, auto_save: true });
  let s = await peek(); assert.equal(s.use_memory, false); assert.equal(s.auto_save, true); assert.equal(Number(s.use_memory_seq), 6);
  // once a sequenced choice exists, an old client's seq-less ON is refused
  await assert.rejects(svc.patchSettings(U, { consent: true, use_memory: true }), e => e.code === 'use_memory_seq_required' && e.status === 400);
  s = await peek(); assert.equal(s.use_memory, false);
  await svc.patchSettings(U, { consent: true, use_memory: true, use_memory_seq: 7 });
  await svc.patchSettings(U, { use_memory: false });   // old client without seq can still turn it off
  s = await peek(); assert.equal(s.use_memory, false); assert.equal(Number(s.use_memory_seq), 7);
}

test('B1 memory store: stale autosave PATCH keeps use_memory off; seq-less on rejected, seq-less off accepted', async () => {
  const store = createAgentMemoryStore();
  await scenario(store, async () => store._dump().settings[U]);
});

test('compat: an old client (no seq ever) can still turn memory on and off', async () => {
  const store = createAgentMemoryStore(), svc = createAgentMemoryService({ store, allow: () => true });
  await svc.patchSettings(U, { consent: true, use_memory: true }); assert.equal(store._dump().settings[U].use_memory, true);
  await svc.patchSettings(U, { use_memory: false }); assert.equal(store._dump().settings[U].use_memory, false);
});

test('B2 memory store: missing use_memory_seq column → 503 memory_schema_pending (not a generic 500)', async () => {
  const store = { ...createAgentMemoryStore(), putSettingsIfNewer: async () => { throw Object.assign(new Error('column'), { code: '42703' }); } };
  const svc = createAgentMemoryService({ store, allow: () => true });
  await assert.rejects(svc.patchSettings(U, { consent: true, use_memory: true, use_memory_seq: 1 }), e => e.code === 'memory_schema_pending' && e.status === 503);
});

test('B1/B2 real Postgres (CATPAW_TEST_PG_HOST)', { skip: process.env.CATPAW_TEST_PG_HOST ? false : 'CATPAW_TEST_PG_HOST not set' }, async () => {
  const { default: postgres } = await import(process.env.CATPAW_TEST_PG_DRIVER ?? 'postgres');   // e.g. file:///…/node_modules/postgres/src/index.js
  const { createPgAgentMemoryStore } = await import('../supabase/functions/_shared/agent-memory/pg-store.mjs');
  const { readFileSync } = await import('node:fs');
  const sql = postgres({ host: process.env.CATPAW_TEST_PG_HOST, port: Number(process.env.CATPAW_TEST_PG_PORT ?? 5432), user: process.env.CATPAW_TEST_PG_USER ?? 'postgres', database: 'postgres', max: 1, onnotice: () => {} });
  try {
    await sql.unsafe(`drop schema if exists agent_memory cascade; drop schema if exists auth cascade; create schema auth; create table auth.users(id uuid primary key); create schema agent_memory;
      create table agent_memory.memory_settings (user_id uuid primary key references auth.users(id) on delete cascade, use_memory boolean not null default false, auto_save boolean not null default false, consented_at timestamptz, updated_at timestamptz not null default now(), check ((not use_memory and not auto_save) or consented_at is not null));`);
    await sql.unsafe('insert into auth.users values($1)', [U]);
    const store = createPgAgentMemoryStore(sql), svc = createAgentMemoryService({ store, allow: () => true });
    await assert.rejects(svc.patchSettings(U, { consent: true, use_memory: true, use_memory_seq: 1 }), e => e.code === 'memory_schema_pending');
    await sql.unsafe(readFileSync(new URL('../supabase/migrations/20261017040000_agent_memory_choice_seq.sql', import.meta.url), 'utf8'));
    await scenario(store, async () => (await sql.unsafe('select use_memory,auto_save,use_memory_seq from agent_memory.memory_settings where user_id=$1', [U]))[0]);
  } finally { await sql.end(); }
});
