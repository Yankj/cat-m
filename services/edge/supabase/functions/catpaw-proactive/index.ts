import postgres from 'npm:postgres@3.4.7';
import { createSupabaseTokenVerifier } from '../_shared/core/src/supabase-auth.mjs';
import { readConfig, featureAllows } from '../_shared/config.mjs';
import { createAgentMemoryService } from '../_shared/agent-memory/service.mjs';
import { createPgAgentMemoryStore } from '../_shared/agent-memory/pg-store.mjs';
import { createAgentMemoryRecall } from '../_shared/proactive/memory-recall.mjs';
import { createProactiveService } from '../_shared/proactive/service.mjs';
import { createPgStore } from '../_shared/proactive/pg-store.mjs';
import { createReminderModel } from '../_shared/proactive/model.mjs';
import { createApnsSender } from '../_shared/proactive/apns.mjs';
import { createDecisionService } from '../_shared/proactive/decision.mjs';
import { createDecisionModel } from '../_shared/proactive/decision-model.mjs';
import { parseQuietHours } from '../_shared/proactive/throttle.mjs';

const env = (n: string) => Deno.env.get(n) ?? undefined;
const cfg: any = readConfig(env);
const dbUrl = env('CATPAW_PROACTIVE_DATABASE_URL') ?? env('SUPABASE_DB_URL');
const sql = postgres(dbUrl!, { max: 3, prepare: false, idle_timeout: 20 });
const store = createPgStore(sql);
const quietHours = parseQuietHours(env('CATPAW_PROACTIVE_QUIET_HOURS'));
const dailyPushCap = Number(env('CATPAW_PROACTIVE_DAILY_PUSH_CAP') ?? 5) || 5;
const log = (...a: unknown[]) => console.log('[catpaw-proactive]', ...a);
// Memory: B1 catpaw.agent-memory.v1 (same gate CATPAW_AGENT_MEMORY_ENABLED + allowlist, same consent) via the adapter.
const memoryGate = cfg.agentMemory ?? 'off';
const memory = memoryGate === 'off' ? null : createAgentMemoryRecall(createAgentMemoryService({ store: createPgAgentMemoryStore(sql), allow: (uid: string) => featureAllows(memoryGate, cfg.featureAllowlist, uid) }));
const decision = createDecisionService({ store, model: createDecisionModel({ get: env, log }), memory, log,
  config: { threshold: Number(env('CATPAW_PROACTIVE_CONFIDENCE_THRESHOLD') ?? 0.6), dedupeWindowSec: Number(env('CATPAW_PROACTIVE_DEDUPE_WINDOW_SEC') ?? 1800), quietHours, dailyCap: dailyPushCap } });
const service = createProactiveService({
  store, decision,
  verifyUser: createSupabaseTokenVerifier({ projectUrl: env('SUPABASE_URL') ?? cfg.projectUrl }),
  schedulerSecret: env('CATPAW_SCHEDULER_SECRET'),
  model: createReminderModel({ apiKey: cfg.modelKey ?? env('OPENROUTER_API_KEY'), route: cfg.route }),
  apns: createApnsSender({ keyId: env('APNS_KEY_ID'), teamId: env('APNS_TEAM_ID'), privateKeyPem: env('APNS_PRIVATE_KEY'), topic: env('APNS_BUNDLE_ID') }),
  quietHours, dailyPushCap,
  log: (...a: unknown[]) => console.log('[catpaw-proactive]', ...a),
});
Deno.serve(req => service.handle(req));
