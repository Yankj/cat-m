import postgres from 'npm:postgres@3.4.7';
import { createSupabaseTokenVerifier } from '../_shared/core/src/supabase-auth.mjs';
import { readConfig } from '../_shared/config.mjs';
import { createProactiveService } from '../_shared/proactive/service.mjs';
import { createPgStore } from '../_shared/proactive/pg-store.mjs';
import { createReminderModel } from '../_shared/proactive/model.mjs';
import { createApnsSender } from '../_shared/proactive/apns.mjs';

const env = (n: string) => Deno.env.get(n) ?? undefined;
const cfg: any = readConfig(env);
const dbUrl = env('CATPAW_PROACTIVE_DATABASE_URL') ?? env('SUPABASE_DB_URL');
const sql = postgres(dbUrl!, { max: 3, prepare: false, idle_timeout: 20 });
const service = createProactiveService({
  store: createPgStore(sql),
  verifyUser: createSupabaseTokenVerifier({ projectUrl: env('SUPABASE_URL') ?? cfg.projectUrl }),
  schedulerSecret: env('CATPAW_SCHEDULER_SECRET'),
  model: createReminderModel({ apiKey: cfg.modelKey ?? env('OPENROUTER_API_KEY'), route: cfg.route }),
  apns: createApnsSender({ keyId: env('APNS_KEY_ID'), teamId: env('APNS_TEAM_ID'), privateKeyPem: env('APNS_PRIVATE_KEY'), topic: env('APNS_BUNDLE_ID') }),
  log: (...a: unknown[]) => console.log('[catpaw-proactive]', ...a),
});
Deno.serve(req => service.handle(req));
