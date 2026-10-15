// Demo: meeting & travel proactive assistant, fully local (in-memory store + memory stand-in).
// Run: deno run -A services/edge/scripts/demo-proactive.mjs
// With CATPAW_PRIVATE_MODEL_KEY and/or CATPAW_AGNES_API_KEY in env the real LLM decides (OpenRouter → Agnes);
// without keys the deterministic rules decide. Keys are read from env only and never printed.
import { readFileSync } from 'node:fs';
import { createProactiveService } from '../supabase/functions/_shared/proactive/service.mjs';
import { createMemoryStore } from '../supabase/functions/_shared/proactive/memory-store.mjs';
import { createDecisionService } from '../supabase/functions/_shared/proactive/decision.mjs';
import { createDecisionModel } from '../supabase/functions/_shared/proactive/decision-model.mjs';
import { createInMemoryRecall } from '../supabase/functions/_shared/proactive/memory-recall.mjs';

const FX = JSON.parse(readFileSync(new URL('../test/fixtures/proactive/meeting-travel-signals.json', import.meta.url)));
const U = '00000000-0000-4000-8000-000000000001', store = createMemoryStore();
const model = createDecisionModel({ get: n => Deno.env.get(n) ?? undefined, log: (...a) => console.log('  [model]', ...a) });
const decision = createDecisionService({ store, model, memory: createInMemoryRecall({ [U]: FX.memories }), config: { quietHours: null } });
const svc = createProactiveService({ store, decision, verifyUser: async () => ({ sub: U }) });
const call = async (m, p, b) => (await svc.handle(new Request('https://local/functions/v1/catpaw-proactive/catpaw/proactive/v1' + p, { method: m, headers: { authorization: 'Bearer demo' }, body: b ? JSON.stringify(b) : undefined }))).json();
console.log(`decider: ${model ? 'LLM ' + model.routes.join(' → ') + ' (fallback: rules)' : 'rules (no model key in env)'}\n`);
const ids = {};
for (const s of FX.scenarios) {
  const r = await call('POST', '/evaluate', s.request); ids[s.name] = r.event_id;
  console.log(`▶ ${s.name}\n  decision=${r.decision} confidence=${r.confidence} source=${r.source}\n  ${r.suggestion.title}：${r.reason}\n  memories=${r.used_memories.map(m => m.content).join(' | ') || '-'}  actions=${r.suggested_actions.join(',')}${r.trace.length ? '\n  trace: ' + r.trace.join('; ') : ''}\n`);
}
console.log('▶ repeat meeting_soon_far (dedupe):', (await call('POST', '/evaluate', FX.scenarios[0].request)).decision);
const id = ids.meeting_soon_far;
console.log('▶ action notify_attendees →', (await call('POST', `/suggestions/${id}/action`, { action: 'notify_attendees', operation_id: 'demo-op-1' })).suggestion.status);
console.log('▶ undo →', (await call('POST', `/suggestions/${id}/undo`, {})).suggestion.status);
console.log('▶ feedback intrusive on conflict →', JSON.stringify((await call('POST', `/suggestions/${ids.meeting_conflict}/feedback`, { value: 'intrusive' })).weights));
const again = structuredClone(FX.scenarios.find(s => s.name === 'meeting_conflict').request); again.signals[0].dedupe_key += '-2'; again.signals[0].data.minutes_until = 30;
const r2 = await call('POST', '/evaluate', again);
console.log(`▶ conflict again (30 min out) after feedback → ${r2.decision} (${r2.trace.join('; ') || 'no downgrade'})`);
console.log('\n▶ GET /suggestions →', (await call('GET', '/suggestions')).suggestions.map(s => `${s.status}:${s.title}`).join(' | '));
