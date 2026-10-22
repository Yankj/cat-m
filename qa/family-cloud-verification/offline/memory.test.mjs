import test from 'node:test';
import assert from 'node:assert/strict';
import {createAgentMemoryService} from '../../../services/edge/supabase/functions/_shared/agent-memory/service.mjs';
import {createAgentMemoryStore} from '../../../services/edge/supabase/functions/_shared/agent-memory/memory-store.mjs';
import {UID, T0, latch, check} from './helpers.mjs';

async function fixture(options = {}) {
  const store = createAgentMemoryStore(), clock = {t: T0};
  const service = createAgentMemoryService({store, allow: () => true, verifyUser: async () => ({sub: UID}), now: () => clock.t, ...options});
  await service.patchSettings(UID, {consent: true, use_memory: true, auto_save: true});
  const call = async (method, path, body) => {
    const response = await service.handle(new Request('https://family-fixture.invalid/catpaw/agent-memory/v1' + path, {method, headers: {'authorization': 'Bearer synthetic-fixture', 'content-type': 'application/json'}, body: body === undefined ? undefined : JSON.stringify(body)}));
    return {status: response.status, body: await response.json()};
  };
  return {store, service, clock, call};
}

test('MEM-01 a stale in-flight HTTP edit must conflict instead of overwriting a newer correction', async t => {
  const reached = latch(), resume = latch();
  const f = await fixture({embed: async text => { if (text === 'synthetic-stale-content') { reached.resolve(); await resume.promise; } return [1, 0]; }});
  const saved = await f.call('POST', '/items', {kind: 'fact', content: 'synthetic-original-content'}), id = saved.body.memory.id;
  const stale = f.call('PATCH', '/items/' + id, {content: 'synthetic-stale-content'});
  await reached.promise; f.clock.t++;
  const fresh = await f.call('PATCH', '/items/' + id, {content: 'synthetic-new-correction'}); assert.equal(fresh.status, 200);
  resume.resolve(); const late = await stale;
  check(t, 'MEM-01', {lateStatus: late.status, content: (await f.store.get(UID, id)).content}, {lateStatus: 200, content: 'synthetic-stale-content'}, {lateStatus: 409, content: 'synthetic-new-correction'}, 'Current v1 PATCH has no content-CAS field. 409 is the proposed target; its versioned wire extension is still an M0 contract decision.');
});

test('MEM-02 a delayed update cannot resurrect a hard-deleted row or enter the next recall', async t => {
  const reached = latch(), resume = latch();
  const f = await fixture({embed: async text => { if (text === 'synthetic-delayed-edit') { reached.resolve(); await resume.promise; } return [1, 0]; }});
  const saved = await f.call('POST', '/items', {kind: 'fact', content: 'synthetic-original-content'}), id = saved.body.memory.id;
  const pending = f.call('PATCH', '/items/' + id, {content: 'synthetic-delayed-edit'});
  await reached.promise;
  assert.equal((await f.call('DELETE', '/items/' + id)).status, 200);
  resume.resolve(); const late = await pending;
  const recalled = await f.service.recallForTurn({subjectID: UID, query: 'synthetic delayed edit'});
  t.diagnostic('FAMILY_LIMITATION ' + JSON.stringify({id: 'MEM-02', lateHTTPStatus: late.status, lateCode: late.body.error, detail: 'No resurrection passes, but the stale HTTP update returns internal_error (500), not a typed conflict/not-found response.'}));
  check(t, 'MEM-02', {rows: f.store._dump().rows.length, recalled: recalled.ids.length, syncDeleted: (await f.store.changedSince(UID, '1970-01-01T00:00:00Z')).deleted.length}, {rows: 0, recalled: 0, syncDeleted: 1}, {rows: 0, recalled: 0, syncDeleted: 1}, 'Only same-store deletion/recall/tombstone is checked. The 500 response remains a separate API correctness gap.');
});

test('MEM-03 clear must fence an already-running journal summary and prevent deleted content from reappearing', async t => {
  const reached = latch(), resume = latch();
  const f = await fixture({summarize: async () => { reached.resolve(); await resume.promise; return 'synthetic-cleared-journal-content'; }});
  await f.service.recallForTurn({subjectID: UID, query: 'synthetic-cleared-journal-content', turnID: crypto.randomUUID(), conversationID: crypto.randomUUID()});
  assert.equal(f.store._dump().fragments.length, 1);
  const pending = f.service.journalTick('2026-10-22');
  await reached.promise;
  const cleared = await f.call('POST', '/clear', {confirm: 'delete_all'}); assert.equal(cleared.status, 200);
  assert.equal(f.store._dump().rows.length, 0);
  resume.resolve(); await pending;
  const recalled = await f.service.recallForTurn({subjectID: UID, query: 'synthetic-cleared-journal-content'});
  check(t, 'MEM-03', {rowsAfterClear: f.store._dump().rows.length, recalledAfterClear: recalled.ids.length}, {rowsAfterClear: 1, recalledAfterClear: 1}, {rowsAfterClear: 0, recalledAfterClear: 0}, 'Real journal service and memory store; summary is an inert delayed function. No actual summarization model/cache/index/native client.');
});

test('MEM-04 retrying a deleted original save operation must not recreate the deleted memory', async t => {
  const f = await fixture(), operation_id = crypto.randomUUID(), args = {kind: 'fact', content: 'synthetic-deleted-save'};
  const first = await f.service.executeTool(UID, 'memory_save', args, {operation_id});
  assert.equal((await f.call('DELETE', '/items/' + first.result.id)).status, 200);
  await f.service.executeTool(UID, 'memory_save', args, {operation_id});
  const recalled = await f.service.recallForTurn({subjectID: UID, query: 'synthetic-deleted-save'});
  check(t, 'MEM-04', {rowsAfterOriginalOperationReplay: f.store._dump().rows.length, recalled: recalled.ids.length}, {rowsAfterOriginalOperationReplay: 1, recalled: 1}, {rowsAfterOriginalOperationReplay: 0, recalled: 0}, 'Reuses the original operation_id without new consent or allow_relearn. Original save idempotency currently lives only on the deleted row.');
});

test('MEM-05 an interrupted journal save must retain fragments for a later retry', async t => {
  const f = await fixture();
  await f.service.recallForTurn({subjectID: UID, query: 'synthetic-retryable-fragment', turnID: crypto.randomUUID(), conversationID: crypto.randomUUID()});
  const insert = f.store.insert.bind(f.store); let faults = 1;
  f.store.insert = async (...args) => { if (faults-- > 0) throw Error('synthetic_journal_write_failure'); return insert(...args); };
  await assert.rejects(f.service.journalTick('2026-10-22'), /synthetic_journal_write_failure/);
  const retry = await f.service.journalTick('2026-10-22');
  check(t, 'MEM-05', {journalRows: f.store._dump().rows.filter(r => r.kind === 'journal').length, fragments: f.store._dump().fragments.length, writtenOnRetry: retry.written}, {journalRows: 0, fragments: 0, writtenOnRetry: 0}, {journalRows: 1, fragments: 0, writtenOnRetry: 1}, 'Failure at the real store insert port after takeFragments; real transaction/process recovery is unverified.');
});
