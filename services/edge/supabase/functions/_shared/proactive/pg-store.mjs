// Postgres store (npm:postgres tagged-template client). Runs as the DB role in SUPABASE_DB_URL / CATPAW_DATABASE_URL;
// every user-facing query is explicitly filtered by user_id (RLS is the second layer for direct PostgREST access).
const TASK_COLS = 'id,user_id,conversation_id,source_turn_id,operation_id,title,notes,due_at,time_zone,recurrence,status,remind_lead_seconds,snooze_until,next_fire_at,fire_count,created_by,revision,created_at,updated_at';
const iso = r => { if (!r) return r; for (const k of ['due_at', 'snooze_until', 'next_fire_at', 'created_at', 'updated_at', 'scheduled_at', 'read_at', 'claimed_at']) if (r[k] instanceof Date) r[k] = r[k].toISOString(); return r; };
const PATCHABLE = ['title', 'notes', 'due_at', 'time_zone', 'recurrence', 'status', 'remind_lead_seconds', 'snooze_until', 'next_fire_at'];
// p90i: every push state write names the generation it acts on (no null bypass).
const need = g => { if (g == null) throw new Error('generation_required'); };
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
    async releaseOccurrence(c) { await sql.unsafe(`delete from proactive.reminder_occurrences where task_id=$1 and scheduled_at=$2 and state='claimed'`, [c.task_id, c.scheduled_at]); },
    async insertEvent(ev) { if (ev.kind === 'reminder_due' && ev.task_id) { const r = await sql.unsafe(`insert into proactive.events(user_id,task_id,conversation_id,kind,title,body,payload,dedupe_key,push_state) select $1,$2,$3,$4,$5,$6,$7::text::jsonb,$8,$9 where exists (select 1 from proactive.tasks t where t.id=$2 and t.user_id=$1 and t.status in ('open','snoozed') and t.next_fire_at=($7::text::jsonb->>'scheduled_at')::timestamptz) on conflict(user_id,dedupe_key) do nothing returning *`, [ev.user_id, ev.task_id, ev.conversation_id, ev.kind, ev.title, ev.body, JSON.stringify(ev.payload ?? {}), ev.dedupe_key, ev.push_state ?? 'pending']); return iso(r[0]) ?? null; }
      const r = await sql.unsafe(`insert into proactive.events(user_id,task_id,conversation_id,kind,title,body,payload,dedupe_key,push_state) values($1,$2,$3,$4,$5,$6,$7::text::jsonb,$8,$9) on conflict(user_id,dedupe_key) do nothing returning *`, [ev.user_id, ev.task_id, ev.conversation_id, ev.kind, ev.title, ev.body, JSON.stringify(ev.payload ?? {}), ev.dedupe_key, ev.push_state ?? 'pending']); return iso(r[0]) ?? null; },
    async listEvents(uid, after, limit) { const r = await sql.unsafe(`select * from (select * from proactive.events where user_id=$1 and ($2::timestamptz is null or created_at>$2::timestamptz) order by created_at desc limit $3) e order by created_at`, [uid, after, limit]); return r.map(iso); },
    async getEvent(uid, id) { const r = await sql.unsafe('select * from proactive.events where user_id=$1 and id=$2', [uid, id]); return iso(r[0]) ?? null; },
    async recordPushAction(uid, id, action, at) { const r = await sql.unsafe(`update proactive.events set action=$3, opened_at=coalesce(opened_at,$4::timestamptz), read_at=coalesce(read_at,$4::timestamptz) where user_id=$1 and id=$2 and action is null returning id`, [uid, id, action, at]); return r.length > 0; },
    async seenSignalHashes(uid, hashes, sinceIso) { const r = await sql.unsafe('select signal_hash from proactive.signal_seen where user_id=$1 and signal_hash = any($2::text[]) and seen_at > $3::timestamptz', [uid, hashes, sinceIso]); return r.map(x => x.signal_hash); },
    async markSignalHashes(uid, hashes, atIso) { await sql.unsafe('insert into proactive.signal_seen(user_id,signal_hash,seen_at) select $1, unnest($2::text[]), $3::timestamptz on conflict (user_id,signal_hash) do update set seen_at=excluded.seen_at', [uid, hashes, atIso]); },
    async getTriggerWeights(uid) { const r = await sql.unsafe('select trigger, weight::float8 weight, threshold_bump::float8 threshold_bump from proactive.trigger_weights where user_id=$1', [uid]); return Object.fromEntries(r.map(x => [x.trigger, { weight: x.weight, threshold_bump: x.threshold_bump }])); },
    async setTriggerWeight(uid, t, w) { await sql.unsafe('insert into proactive.trigger_weights(user_id,trigger,weight,threshold_bump) values($1,$2,$3,$4) on conflict(user_id,trigger) do update set weight=excluded.weight, threshold_bump=excluded.threshold_bump, updated_at=now()', [uid, t, w.weight, w.threshold_bump]); },
    // v10 P1-1: distinct meetings (first signal_hash, else the row id); the meeting being judged never counts against itself.
    async countDecisionsForDay(uid, startIso, endIso, levels, excludeHashes = []) { const r = await sql.unsafe(`select count(distinct coalesce(payload->'signals'->0->>'signal_hash', 'id:' || id::text))::int n from proactive.events where user_id=$1 and kind='proactive_decision' and payload->>'decision' = any($4::text[]) and coalesce((payload->>'deliver_at')::timestamptz, created_at) >= $2::timestamptz and coalesce((payload->>'deliver_at')::timestamptz, created_at) < $3::timestamptz and not coalesce(payload->'signals'->0->>'signal_hash' = any($5::text[]), false)`, [uid, startIso, endIso, levels, excludeHashes]); return r[0]?.n ?? 0; },
    // v10 P1-2: newest delivered (non-silent) decision since sinceIso that carried one of these signal hashes.
    async lastDecisionForHashes(uid, hashes, sinceIso) { const r = await sql.unsafe(`select * from proactive.events e where user_id=$1 and kind='proactive_decision' and payload->>'decision' <> 'silent' and coalesce((payload->>'evaluated_at')::timestamptz, created_at) > $3::timestamptz and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(payload->'signals')='array' then payload->'signals' else '[]'::jsonb end) s where s->>'signal_hash' = any($2::text[])) order by coalesce((payload->>'evaluated_at')::timestamptz, created_at) desc limit 1`, [uid, hashes, sinceIso]); return iso(r[0]) ?? null; },
    async countDecisionsSince(uid, sinceIso, levels) { const r = await sql.unsafe(`select count(*)::int n from proactive.events where user_id=$1 and kind='proactive_decision' and created_at >= $2::timestamptz and payload->>'decision' = any($3::text[])`, [uid, sinceIso, levels]); return r[0]?.n ?? 0; },
    async getFeedback(uid, eid) { const r = await sql.unsafe('select kind, created_at from proactive.feedback where user_id=$1 and event_id=$2', [uid, eid]); return iso(r[0]) ?? null; },
    async insertFeedback(uid, eid, kind, at) { const r = await sql.unsafe('insert into proactive.feedback(user_id,event_id,kind,created_at) values($1,$2,$3,$4) on conflict(event_id) do nothing returning event_id', [uid, eid, kind, at]); return r.length > 0; },
    async updateEventPayload(uid, id, payload, expectedRev) {
      // Codex PR90 #7: compare-and-set on suggestion.rev when the caller read a version (lost race → null).
      if (expectedRev === undefined) { const r = await sql.unsafe('update proactive.events set payload=$3::text::jsonb where user_id=$1 and id=$2 returning *', [uid, id, JSON.stringify(payload)]); return iso(r[0]) ?? null; }
      const r = await sql.unsafe(`update proactive.events set payload=$3::text::jsonb where user_id=$1 and id=$2 and coalesce((payload->'suggestion'->>'rev')::int, 0) = $4 returning *`, [uid, id, JSON.stringify(payload), expectedRev]);
      return iso(r[0]) ?? null;
    },
    async claimSuggestionsForChat(uid, { limit, at, turnID }) {
      const r = await sql.unsafe(`update proactive.events e set payload = jsonb_set(jsonb_set(jsonb_set(e.payload, '{suggestion,chat_delivered_at}', to_jsonb($3::text)), '{suggestion,chat_turn_id}', to_jsonb($4::text)), '{suggestion,rev}', to_jsonb(coalesce((e.payload->'suggestion'->>'rev')::int, 0) + 1))
        where e.id in (select id from proactive.events where user_id=$1 and kind='proactive_decision' and payload->>'decision' <> 'silent'
          and payload->'suggestion'->>'status' = 'pending' and payload->'suggestion'->>'chat_delivered_at' is null order by created_at limit $2 for update skip locked) returning e.*`, [uid, limit, at, turnID ?? '']);
      return r.map(iso);
    },
    async resurfaceSnoozed(nowIso) { const r = await sql.unsafe('select proactive.resurface_snoozed_suggestions($1::timestamptz) as id', [nowIso]); return r.map(x => x.id).filter(Boolean); },
    async idemGet(uid, key) { const r = await sql.unsafe('select route, request_hash, status, response from proactive.idempotency_keys where user_id=$1 and key=$2', [uid, key]); return r[0] ?? null; },
    async idemPut(uid, key, rec) { const r = await sql.unsafe('insert into proactive.idempotency_keys(user_id,key,route,request_hash,status,response) values($1,$2,$3,$4,$5,$6::text::jsonb) on conflict do nothing returning key', [uid, key, rec.route, rec.request_hash, rec.status, JSON.stringify(rec.response)]); return r.length > 0; },
    async markRead(uid, id, at) { const r = await sql.unsafe(`update proactive.events set read_at=coalesce(read_at,$3) where user_id=$1 and id=$2 returning id`, [uid, id, at]); return r.length > 0; },
    async pendingPushEvents(limit, nowIso = null) { const r = await sql.unsafe(`update proactive.events set push_attempts=push_attempts+1 where id in (select id from proactive.events where push_state='pending' and push_attempts<5 and (push_after is null or push_after <= coalesce($2::timestamptz, now())) order by created_at limit $1 for update skip locked) returning *`, [limit, nowIso]); return r.map(iso); },
    async deferPush(id, until, generation) { need(generation); await sql.unsafe(`update proactive.events set push_after=$2, push_attempts=greatest(push_attempts-1,0) where id=$1 and push_state='pending' and push_generation=$3::int`, [id, until, generation]); },
    async countPushedSince(uid, sinceIso) { const r = await sql.unsafe(`select count(*)::int n from proactive.events where user_id=$1 and push_state='sent' and pushed_at >= $2::timestamptz`, [uid, sinceIso]); return r[0]?.n ?? 0; },
    // PR90h #1: bound to the generation (and suggestion status) the action saw — a cancel arriving after a resurface is a no-op.
    async cancelPendingPush(uid, id, reason, generation, status = null) { need(generation); await sql.unsafe(`update proactive.events set push_state='skipped', push_error=$3 where id=$1 and user_id=$2 and push_state='pending' and push_generation=$4::int and ($5::text is null or payload->'suggestion'->>'status'=$5::text)`, [id, uid, reason, generation, status]); },
    // Codex PR90e #6: terminal states are final — only a pending / sending row moves (never overwrites skipped/sent/…).
    // Pre-claim dispositions only: never touches a claimed ('sending') or finished row.
    async setPush(id, state, err, generation) { need(generation); await sql.unsafe(`update proactive.events set push_state=$2, push_error=$3, pushed_at=case when $2='sent' then now() else pushed_at end where id=$1 and push_state='pending' and push_generation=$4::int`, [id, state, err, generation]); },
    // Codex PR90f #4: the send licence is a claim token bound to the row's current generation (single UPDATE, row lock).
    async claimPush(id, nowIso = null, generation) { need(generation); const r = await sql.unsafe(`update proactive.events set push_state='sending', push_claim=gen_random_uuid(), push_claimed_at=coalesce($2::timestamptz, now()), push_attempted_at=null where id=$1 and push_state='pending' and push_generation=$3::int and coalesce(payload->'suggestion'->>'status','pending')='pending' returning push_claim::text as claim, push_generation as generation`, [id, nowIso, generation]); return r[0] ? { claim: r[0].claim, generation: r[0].generation } : null; },
    // p90i P2: the licence also needs the card still pending — a dismiss / snooze mid-send stops the remaining devices.
    async markPushAttempt(id, claim, nowIso = null) { if (!claim) return false; const r = await sql.unsafe(`update proactive.events set push_attempted_at=coalesce($3::timestamptz, now()) where id=$1 and push_state='sending' and push_claim=$2::uuid and coalesce(payload->'suggestion'->>'status','pending')='pending' returning id`, [id, claim, nowIso]); return r.length === 1; },
    async finishPush(id, claim, state, err, nowIso = null) { if (!claim) return false; const r = await sql.unsafe(`update proactive.events set push_state=$3, push_error=$4, push_claim=null, pushed_at=case when $3='sent' then coalesce($5::timestamptz, now()) else pushed_at end where id=$1 and push_state='sending' and push_claim=$2::uuid returning id`, [id, claim, state, err, nowIso]); return r.length === 1; },
    // Codex PR90g #4: unsent (never attempted) → a new generation with its own retry budget; attempted (outcome unknown)
    // → NOT resent (at-most-once): failed / outcome_unknown, the card stays in the app inbox. A row without a lease start
    // (written before 20261017030000) counts as expired.
    async recoverStalePush(nowIso, leaseSeconds) { const r = await sql.unsafe(`update proactive.events set push_state=case when push_attempted_at is null then 'pending' else 'failed' end, push_error=case when push_attempted_at is null then push_error else 'outcome_unknown' end, push_generation=push_generation+1, push_attempts=0, push_recovered=case when push_attempted_at is null then 'unsent' else 'unknown' end, push_claim=null, push_claimed_at=null where push_state='sending' and coalesce(push_claimed_at, '-infinity'::timestamptz) < $1::timestamptz - make_interval(secs => $2::double precision) returning id`, [nowIso, leaseSeconds]); return r.length; },
    async getEventByDedupe(uid, key) { const r = await sql.unsafe('select * from proactive.events where user_id=$1 and dedupe_key=$2', [uid, key]); return r[0] ? iso(r[0]) : null; },
    async tokensFor(uid) { return sql.unsafe('select * from proactive.device_push_tokens where user_id=$1 and enabled', [uid]); },
    async upsertToken(uid, t) { const r = await sql.unsafe(`insert into proactive.device_push_tokens(user_id,device_id,kind,token,environment,bundle_id,activity_id) values($1,$2,$3,$4,$5,$6,$7)
       on conflict(user_id,device_id,kind,coalesce(activity_id,'')) do update set token=excluded.token,environment=excluded.environment,bundle_id=excluded.bundle_id,enabled=true,last_error=null returning id,device_id,kind,environment,bundle_id,activity_id,enabled`, [uid, t.device_id, t.kind, t.token, t.environment, t.bundle_id, t.activity_id]); return r[0]; },
    async deleteToken(uid, dev, kind) { const r = await sql.unsafe('delete from proactive.device_push_tokens where user_id=$1 and device_id=$2 and ($3::text is null or kind=$3) returning id', [uid, dev, kind]); return r.length; },
    async disableToken(id, reason) { await sql.unsafe('update proactive.device_push_tokens set enabled=false,last_error=$2 where id=$1', [id, reason]); },
  };
}
