// Postgres store (npm:postgres tagged-template client). Runs as the DB role in SUPABASE_DB_URL / CATPAW_DATABASE_URL;
// every user-facing query is explicitly filtered by user_id (RLS is the second layer for direct PostgREST access).
const TASK_COLS = 'id,user_id,conversation_id,source_turn_id,operation_id,title,notes,due_at,time_zone,recurrence,status,remind_lead_seconds,snooze_until,next_fire_at,fire_count,created_by,revision,created_at,updated_at';
const iso = r => { if (!r) return r; for (const k of ['due_at', 'snooze_until', 'next_fire_at', 'created_at', 'updated_at', 'scheduled_at', 'read_at', 'claimed_at']) if (r[k] instanceof Date) r[k] = r[k].toISOString(); return r; };
const PATCHABLE = ['title', 'notes', 'due_at', 'time_zone', 'recurrence', 'status', 'remind_lead_seconds', 'snooze_until', 'next_fire_at'];
export function createPgStore(sql) {
  return {
    async createTask(uid, t) {
      const ins = await sql.unsafe(`insert into proactive.tasks(user_id,conversation_id,source_turn_id,operation_id,title,notes,due_at,time_zone,recurrence,status,remind_lead_seconds,next_fire_at,fire_count,created_by)
        values($1,$2,$3,$4,$5,$6,$7,$8,$9::text::jsonb,$10,$11,$12,$13,$14) on conflict(user_id,operation_id) do nothing returning ${TASK_COLS}`,
        [uid, t.conversation_id, t.source_turn_id, t.operation_id, t.title, t.notes, t.due_at, t.time_zone, t.recurrence == null ? null : JSON.stringify(t.recurrence), t.status, t.remind_lead_seconds, t.next_fire_at, t.fire_count, t.created_by]);
      if (ins.length) return { row: iso(ins[0]), created: true };
      const ex = await sql.unsafe(`select ${TASK_COLS} from proactive.tasks where user_id=$1 and operation_id=$2`, [uid, t.operation_id]);
      return { row: iso(ex[0]), created: false };
    },
    async getTask(uid, id) { const r = await sql.unsafe(`select ${TASK_COLS} from proactive.tasks where user_id=$1 and id=$2`, [uid, id]); return iso(r[0]) ?? null; },
    async listTasks(uid, { status, limit }) { const r = await sql.unsafe(`select ${TASK_COLS} from proactive.tasks where user_id=$1 and ($2='all' or status=$2) order by due_at nulls last, created_at limit $3`, [uid, status, limit]); return r.map(iso); },
    async updateTask(uid, id, f, rev) {
      const keys = Object.keys(f).filter(k => PATCHABLE.includes(k)); const args = [uid, id, rev];
      const set = keys.map(k => { args.push(k === 'recurrence' ? (f[k] == null ? null : JSON.stringify(f[k])) : f[k]); return `${k}=$${args.length}${k === 'recurrence' ? '::text::jsonb' : ''}`; });
      const r = await sql.unsafe(`update proactive.tasks set ${set.join(',')} where user_id=$1 and id=$2 and revision=$3 returning ${TASK_COLS}`, args); return iso(r[0]) ?? null;
    },
    async claimDue(nowIso, limit) { const r = await sql.unsafe('select * from proactive.claim_due_reminders($1::timestamptz,$2)', [nowIso, limit]); return r.map(iso); },
    async finishOccurrence(c, f) {
      await sql.begin(async tx => {
        await tx.unsafe(`update proactive.tasks set next_fire_at=$3, fire_count=$4, status=case when status='snoozed' then 'open' else $5 end, snooze_until=null where id=$1 and next_fire_at=$2`, [c.task_id, c.scheduled_at, f.next_fire_at, f.fire_count, f.status]);
        await tx.unsafe(`update proactive.reminder_occurrences set state='generated' where task_id=$1 and scheduled_at=$2`, [c.task_id, c.scheduled_at]);
      });
    },
    async insertEvent(ev) { const r = await sql.unsafe(`insert into proactive.events(user_id,task_id,conversation_id,kind,title,body,payload,dedupe_key,push_state) values($1,$2,$3,$4,$5,$6,$7::text::jsonb,$8,$9) on conflict(user_id,dedupe_key) do nothing returning *`, [ev.user_id, ev.task_id, ev.conversation_id, ev.kind, ev.title, ev.body, JSON.stringify(ev.payload ?? {}), ev.dedupe_key, ev.push_state ?? 'pending']); return iso(r[0]) ?? null; },
    async listEvents(uid, after, limit) { const r = await sql.unsafe(`select * from (select * from proactive.events where user_id=$1 and ($2::timestamptz is null or created_at>$2::timestamptz) order by created_at desc limit $3) e order by created_at`, [uid, after, limit]); return r.map(iso); },
    async getEvent(uid, id) { const r = await sql.unsafe('select * from proactive.events where user_id=$1 and id=$2', [uid, id]); return iso(r[0]) ?? null; },
    async recordPushAction(uid, id, action, at) { const r = await sql.unsafe(`update proactive.events set action=$3, opened_at=coalesce(opened_at,$4::timestamptz), read_at=coalesce(read_at,$4::timestamptz) where user_id=$1 and id=$2 and action is null returning id`, [uid, id, action, at]); return r.length > 0; },
    async seenSignalHashes(uid, hashes, sinceIso) { const r = await sql.unsafe('select signal_hash from proactive.signal_seen where user_id=$1 and signal_hash = any($2::text[]) and seen_at > $3::timestamptz', [uid, hashes, sinceIso]); return r.map(x => x.signal_hash); },
    async markSignalHashes(uid, hashes, atIso) { await sql.unsafe('insert into proactive.signal_seen(user_id,signal_hash,seen_at) select $1, unnest($2::text[]), $3::timestamptz on conflict (user_id,signal_hash) do update set seen_at=excluded.seen_at', [uid, hashes, atIso]); },
    async getTriggerWeights(uid) { const r = await sql.unsafe('select trigger, weight::float8 weight, threshold_bump::float8 threshold_bump from proactive.trigger_weights where user_id=$1', [uid]); return Object.fromEntries(r.map(x => [x.trigger, { weight: x.weight, threshold_bump: x.threshold_bump }])); },
    async setTriggerWeight(uid, t, w) { await sql.unsafe('insert into proactive.trigger_weights(user_id,trigger,weight,threshold_bump) values($1,$2,$3,$4) on conflict(user_id,trigger) do update set weight=excluded.weight, threshold_bump=excluded.threshold_bump, updated_at=now()', [uid, t, w.weight, w.threshold_bump]); },
    async countDecisionsSince(uid, sinceIso, levels) { const r = await sql.unsafe(`select count(*)::int n from proactive.events where user_id=$1 and kind='proactive_decision' and created_at >= $2::timestamptz and payload->>'decision' = any($3::text[])`, [uid, sinceIso, levels]); return r[0]?.n ?? 0; },
    async getFeedback(uid, eid) { const r = await sql.unsafe('select kind, created_at from proactive.feedback where user_id=$1 and event_id=$2', [uid, eid]); return iso(r[0]) ?? null; },
    async insertFeedback(uid, eid, kind, at) { const r = await sql.unsafe('insert into proactive.feedback(user_id,event_id,kind,created_at) values($1,$2,$3,$4) on conflict(event_id) do nothing returning event_id', [uid, eid, kind, at]); return r.length > 0; },
    async updateEventPayload(uid, id, payload) { const r = await sql.unsafe('update proactive.events set payload=$3::text::jsonb where user_id=$1 and id=$2 returning *', [uid, id, JSON.stringify(payload)]); return iso(r[0]) ?? null; },
    async markRead(uid, id, at) { const r = await sql.unsafe(`update proactive.events set read_at=coalesce(read_at,$3) where user_id=$1 and id=$2 returning id`, [uid, id, at]); return r.length > 0; },
    async pendingPushEvents(limit, nowIso = null) { const r = await sql.unsafe(`update proactive.events set push_attempts=push_attempts+1 where id in (select id from proactive.events where push_state='pending' and push_attempts<5 and (push_after is null or push_after <= coalesce($2::timestamptz, now())) order by created_at limit $1 for update skip locked) returning *`, [limit, nowIso]); return r.map(iso); },
    async deferPush(id, until) { await sql.unsafe('update proactive.events set push_after=$2, push_attempts=greatest(push_attempts-1,0) where id=$1', [id, until]); },
    async countPushedSince(uid, sinceIso) { const r = await sql.unsafe(`select count(*)::int n from proactive.events where user_id=$1 and push_state='sent' and pushed_at >= $2::timestamptz`, [uid, sinceIso]); return r[0]?.n ?? 0; },
    async setPush(id, state, err) { await sql.unsafe(`update proactive.events set push_state=$2, push_error=$3, pushed_at=case when $2='sent' then now() else pushed_at end where id=$1`, [id, state, err]); },
    async tokensFor(uid) { return sql.unsafe('select * from proactive.device_push_tokens where user_id=$1 and enabled', [uid]); },
    async upsertToken(uid, t) { const r = await sql.unsafe(`insert into proactive.device_push_tokens(user_id,device_id,kind,token,environment,bundle_id,activity_id) values($1,$2,$3,$4,$5,$6,$7)
       on conflict(user_id,device_id,kind,coalesce(activity_id,'')) do update set token=excluded.token,environment=excluded.environment,bundle_id=excluded.bundle_id,enabled=true,last_error=null returning id,device_id,kind,environment,bundle_id,activity_id,enabled`, [uid, t.device_id, t.kind, t.token, t.environment, t.bundle_id, t.activity_id]); return r[0]; },
    async deleteToken(uid, dev, kind) { const r = await sql.unsafe('delete from proactive.device_push_tokens where user_id=$1 and device_id=$2 and ($3::text is null or kind=$3) returning id', [uid, dev, kind]); return r.length; },
    async disableToken(id, reason) { await sql.unsafe('update proactive.device_push_tokens set enabled=false,last_error=$2 where id=$1', [id, reason]); },
  };
}
