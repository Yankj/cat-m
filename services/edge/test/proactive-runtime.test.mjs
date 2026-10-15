import test from 'node:test'; import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { memoryHTTPFixture as fixture } from './fixtures/memory-http-fixture.mjs';
import { APPROVAL_CONTRACT } from '../supabase/functions/_shared/core/src/approval.mjs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';
import { createAgentMemoryRecall } from '../supabase/functions/_shared/proactive/memory-recall.mjs';
import { createSuggestionFeed } from '../supabase/functions/_shared/proactive/suggestion-feed.mjs';
import { createAgentMemoryService } from '../supabase/functions/_shared/agent-memory/service.mjs';
import { createAgentMemoryStore } from '../supabase/functions/_shared/agent-memory/memory-store.mjs';
import { createAgentMemoryChatTools } from '../supabase/functions/_shared/agent-memory/chat-tools.mjs';
import { readConfig } from '../supabase/functions/_shared/config.mjs';

const FX = JSON.parse(readFileSync(new URL('./fixtures/proactive/meeting-travel-signals.json', import.meta.url)));
const sc = n => structuredClone(FX.scenarios.find(s => s.name === n).request);
const U = randomUUID(), BASE = '/catpaw/proactive/v1';
function setup({ memory = null, t = '2026-10-15T02:00:00Z' } = {}) {
  const clock = { t: Date.parse(t) }, store = createMemoryStore();
  const decision = createDecisionService({ store, memory, now: () => clock.t });
  const svc = createProactiveService({ store, decision, schedulerSecret: 's', now: () => clock.t, verifyUser: async () => ({ sub: U }) });
  const call = async (method, path, body, headers = {}) => { const r = await svc.handle(new Request('https://x/functions/v1/catpaw-proactive' + path, { method, headers: { authorization: 'Bearer u', ...headers }, body: body ? JSON.stringify(body) : undefined })); return { status: r.status, headers: r.headers, body: await r.json() }; };
  return { clock, store, svc, call, tick: () => svc.tick() };
}

test('agent-memory adapter: used_memories come from real B1 memories; gate/consent off → none', async () => {
  const mstore = createAgentMemoryStore(); let allowed = true;
  const mem = createAgentMemoryService({ store: mstore, allow: () => allowed });
  const { call } = setup({ memory: createAgentMemoryRecall(mem) });
  assert.deepEqual((await call('POST', BASE + '/evaluate', sc('meeting_soon_far'))).body.used_memories, [], 'no consent yet');
  await mem.patchSettings(U, { consent: true, use_memory: true, auto_save: true });
  const { row } = await mem.save(U, { kind: 'preference', content: '去静安嘉里中心一般打车' });
  const s2 = sc('meeting_soon_far'); s2.signals[0].dedupe_key = 'x2';
  const r = await call('POST', BASE + '/evaluate', s2);
  assert.deepEqual(r.body.used_memories.map(m => m.id), [row.id]); assert.equal(r.body.suggestion.memories[0].content, '去静安嘉里中心一般打车');
  const f = await call('POST', `${BASE}/suggestions/${r.body.event_id}/feedback`, { value: 'intrusive' });
  assert.ok(f.body.memory_id); assert.equal((await mstore.get(U, f.body.memory_id)).kind, 'preference');
  allowed = false; const s3 = sc('meeting_soon_far'); s3.signals[0].dedupe_key = 'x3';
  assert.deepEqual((await call('POST', BASE + '/evaluate', s3)).body.used_memories, []);
});

test('snooze re-surfaces after snooze_until on scheduler tick (pg_cron) and re-queues push for notify/interrupt', async () => {
  const { call, tick, clock, store } = setup();
  const id = (await call('POST', BASE + '/evaluate', sc('meeting_soon_far'))).body.event_id;
  assert.equal((await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze', minutes: 15 })).body.suggestion.status, 'snoozed');
  clock.t += 10 * 60000; assert.equal((await tick()).resurfaced, 0);
  clock.t += 6 * 60000; const t = await tick(); assert.equal(t.resurfaced, 1);
  const s = (await call('GET', `${BASE}/suggestions/${id}`)).body.suggestion; assert.equal(s.status, 'pending'); assert.equal(s.taken.length, 1);
  assert.ok((await store.getEvent(U, id)).payload.suggestion.resurfaced_at);
});

test('suggestion feed for chat SSE: gate off → nothing; on → each pending suggestion once, toSuggestion payload', async () => {
  const { call, store } = setup();
  const id = (await call('POST', BASE + '/evaluate', sc('flight_delayed_affects_meeting'))).body.event_id;
  await call('POST', BASE + '/evaluate', sc('nothing_to_do'));
  assert.deepEqual(await createSuggestionFeed({ store }).claimForTurn({ subjectID: U }), []);
  const feed = createSuggestionFeed({ store, allow: () => true });
  const a = await feed.claimForTurn({ subjectID: U, turnID: 't1' }); assert.equal(a.length, 1); assert.equal(a[0].id, id);
  for (const k of ['id', 'title', 'reason', 'memories', 'actions', 'signals', 'status', 'createdAt', 'taken']) assert.ok(k in a[0], k);
  assert.deepEqual(await feed.claimForTurn({ subjectID: U, turnID: 't2' }), []);
  assert.equal(readConfig(() => undefined).proactiveSuggestionsSSE, 'off');
  assert.equal(readConfig(n => n === 'CATPAW_PROACTIVE_SUGGESTIONS_SSE_ENABLED' ? 'allowlist' : undefined).proactiveSuggestionsSSE, 'allowlist');
});

test('S1 Idempotency-Key on decision routes: replay identical response, reject reuse with a different body', async () => {
  const { call } = setup();
  const h = { 'Idempotency-Key': 'eval-key-0001' };
  const a = await call('POST', BASE + '/evaluate', sc('meeting_soon_far'), h);
  const b = await call('POST', BASE + '/evaluate', sc('meeting_soon_far'), h);
  assert.equal(b.body.event_id, a.body.event_id); assert.equal(b.headers.get('idempotent-replayed'), 'true'); assert.equal(b.body.decision, 'interrupt', 'not deduped to silent');
  assert.equal((await call('POST', BASE + '/evaluate', sc('meeting_conflict'), h)).body.error, 'idempotency_key_reused');
  assert.equal((await call('POST', BASE + '/evaluate', sc('meeting_conflict'), { 'Idempotency-Key': 'x' })).body.error, 'idempotency_key_invalid');
  const id = a.body.event_id, k = { 'Idempotency-Key': 'act-key-0001' };
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze' }, k);
  await call('POST', `${BASE}/suggestions/${id}/action`, { action: 'snooze' }, k);
  assert.equal((await call('GET', `${BASE}/suggestions/${id}`)).body.suggestion.taken.length, 1);
  assert.equal((await call('POST', `${BASE}/suggestions/${id}/undo`, {}, { 'Idempotency-Key': 'undo-key-01' })).body.suggestion.status, 'pending');
});

test('S2 memory: memory.update events from tools, /memories?since= incremental with tombstones', async () => {
  const store = createAgentMemoryStore(), svc = createAgentMemoryService({ store, allow: () => true, verifyUser: async () => ({ sub: U }) });
  await svc.patchSettings(U, { consent: true, use_memory: true, auto_save: true });
  const saved = await svc.executeTool(U, 'memory_save', { kind: 'preference', content: '靠窗座位' });
  const up = saved.events.find(e => e.type === 'memory.update'); assert.equal(up.data.op, 'saved'); assert.equal(up.data.memories[0].content, '靠窗座位');
  const id = saved.result.id;
  const call = async q => (await svc.handle(new Request('https://x/catpaw/agent-memory/v1/memories' + q, { headers: { authorization: 'Bearer u' } }))).json();
  const all = await call(''); assert.equal(all.memories.length, 1); assert.ok(all.cursor);
  const cursor = new Date(Date.now() - 1000).toISOString();
  assert.equal((await svc.executeTool(U, 'memory_update', { id, content: '过道座位' })).events[0].data.op, 'updated');
  await svc.save(U, { kind: 'fact', content: '住在静安' });
  const del = await svc.executeTool(U, 'memory_forget', { ids: [id] }); assert.equal(del.events[0].data.op, 'forgotten');
  const inc = await call('?since=' + encodeURIComponent(cursor));
  assert.deepEqual(inc.memories.map(m => m.content), ['住在静安']); assert.deepEqual(inc.deleted.map(d => d.id), [id]);
  const r = await svc.recallForTurn({ subjectID: U, query: '静安' }); assert.deepEqual(r.items.map(i => i.content), ['住在静安']);
});

// chat SSE integration (catpaw-api): memory.used + proactive_suggestion on the next turn; Idempotency-Key must match turn_id.
const sse = async r => (await r.text()).split('\n\n').filter(b => b.startsWith('data: ')).map(b => JSON.parse(b.slice(6)));
test('chat SSE: memory.used + proactive_suggestion events (gated) and Idempotency-Key alias on send', async () => {
  const f = await fixture({ stream: async function* () { yield { type: 'text_delta', text: '好' }; yield { type: 'done', finish_reason: 'stop' }; } });
  const mstore = createAgentMemoryStore(), mem = createAgentMemoryService({ store: mstore, allow: () => true });
  f.runtime.chat.facade.agentMemory = mem; f.runtime.chat.facade.gatedChatTools = new Map([...(f.runtime.chat.facade.gatedChatTools ?? []), ...createAgentMemoryChatTools({ service: mem })]);
  const owner = f.principal.subject_id;
  await mem.patchSettings(owner, { consent: true, use_memory: true, auto_save: false }); const { row } = await mem.save(owner, { kind: 'preference', content: '出差坐靠窗' });
  const pstore = createMemoryStore(), dec = createDecisionService({ store: pstore });
  const ev = await dec.evaluate(owner, sc('flight_delayed_affects_meeting'));
  f.runtime.chat.facade.proactiveSuggestions = createSuggestionFeed({ store: pstore, allow: () => true });
  const cid = await f.newConversation(); await f.json(await f.req(`/catpaw/privacy/v1/scopes/${f.scope.scope_id}/conversations/${cid}/model-consent`, { decision: 'allow', expected_revision: 0, route_hash: f.config.routeHash }));
  const path = `/catpaw/chat/v1/scopes/${f.scope.scope_id}/conversations/${cid}`;
  const send = async (text, headers = {}, tid = randomUUID()) => { const c = (await f.json(await f.req(path))).conversation; const r = await f.runtime.api(new Request('https://memory-test.example.invalid' + path + '/turns', { method: 'POST', headers: { Authorization: 'Bearer memory-fixture', 'Content-Type': 'application/json', 'X-Catpaw-Approval-Contract': APPROVAL_CONTRACT, ...headers }, body: JSON.stringify({ turn_id: tid, expected_revision: c.revision, expected_grant_epoch: c.grant_epoch, message: { id: randomUUID(), text }, context: [] }) })); return r; };
  const bad = await send('靠窗', { 'Idempotency-Key': randomUUID() }); assert.equal(bad.status, 422); assert.equal((await bad.json()).error.code, 'idempotency_key_mismatch');
  const tid = randomUUID(); const r = await send('出差靠窗', { 'Idempotency-Key': tid.toUpperCase() }, tid); assert.equal(r.status, 200);
  const events = await sse(r); await f.runtime.chat.waitIdle();
  const used = events.find(e => e.type === 'memory.used'); assert.deepEqual(used.data.memories, [{ id: row.id, kind: 'preference', content: '出差坐靠窗' }]);
  const ps = events.find(e => e.type === 'proactive_suggestion'); assert.equal(ps.data.id, ev.event_id); assert.equal(ps.data.status, 'pending');
  const r2 = await send('再来'); const e2 = await sse(r2); await f.runtime.chat.waitIdle();
  assert.equal(e2.some(e => e.type === 'proactive_suggestion'), false, 'delivered once');
});
