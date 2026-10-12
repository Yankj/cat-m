// No driver/config/provider import. Caller injects a pg-compatible Pool, using one connection per transaction.
import { TABLES, immutableKinds, ensure, hash, canonical, FoundationError } from './common.mjs';

export class PostgresRepository {
  constructor(pool) { ensure(pool && typeof pool.connect === 'function'); this.pool = pool; this.execution_layer = 'postgres_unverified'; }
  async connection(scopeId, fn) {
    const metric=this.metrics,connectAt=metric?.now();
    const c = await this.pool.connect();
    metric?.record('database_connect',connectAt);
    const started=metric?.now();let count=0,db_ms=0;
    const query=async(...args)=>{const at=metric?.now();try{return await c.query(...args);}finally{count++;if(metric)db_ms+=Math.max(0,metric.now()-at);}};
    const connection=metric?{query}:c;
    try {
      await connection.query('BEGIN');
      await connection.query("SELECT set_config('catpaw.scope_id',$1,true)", [scopeId]);
      const result = await fn(connection); await connection.query('COMMIT'); return result;
    } catch (error) { try { await connection.query('ROLLBACK'); } catch {} throw error; }
    finally { c.release();metric?.record('database_transaction',started,{count,db_ms}); }
  }
  async bootstrapScope(identity) {
    return this.connection(identity.scope_id, async c => {
      const data = { identity, generation: 1, enabled: true, last_sequence: 0 };
      await c.query('INSERT INTO catpaw.scopes(scope_id,data) VALUES($1,$2::jsonb) ON CONFLICT DO NOTHING', [identity.scope_id, JSON.stringify(data)]);
      const r = await c.query('SELECT data FROM catpaw.scopes WHERE scope_id=$1 FOR UPDATE', [identity.scope_id]);
      ensure(r.rows[0] && hash(r.rows[0].data.identity) === hash(identity), 'scope_conflict', 409);
    });
  }
  async transaction(scopeId, fn) {
    if (typeof scopeId === 'function') {
      const callback = scopeId;
      return this.connection('', c => callback(new RecordTransaction(c)));
    }
    return this.connection(scopeId, async c => {
      // Serializes every writer and cursor allocation IN THE SAME transaction; not BIGSERIAL order.
      const r = await c.query('SELECT data FROM catpaw.scopes WHERE scope_id=$1 FOR UPDATE', [scopeId]);
      ensure(r.rows.length === 1, 'scope_forbidden', 403);
      return fn(new PostgresTransaction(c, scopeId));
    });
  }
}
export class PostgresTransaction {
  constructor(connection, scopeId) { this.connection = connection; this.scopeId = scopeId; this.records = new RecordTransaction(connection); }
  table(kind) { ensure(Object.hasOwn(TABLES, kind)); return `catpaw.${TABLES[kind]}`; }
  async scope() { const r = await this.connection.query('SELECT data FROM catpaw.scopes WHERE scope_id=$1', [this.scopeId]); return r.rows[0].data; }
  async saveScope(data) { await this.connection.query('UPDATE catpaw.scopes SET data=$2::jsonb WHERE scope_id=$1', [this.scopeId, JSON.stringify(data)]); }
  async get(kind, id) { const r = await this.connection.query(`SELECT data FROM ${this.table(kind)} WHERE scope_id=$1 AND id=$2`, [this.scopeId, id]); return r.rows[0]?.data ?? null; }
  async list(kind) { const r = await this.connection.query(`SELECT data FROM ${this.table(kind)} WHERE scope_id=$1 ORDER BY id`, [this.scopeId]); return r.rows.map(r => r.data); }
  async put(kind, value, { insert = false } = {}) {
    ensure(value.scope_id === this.scopeId, 'scope_forbidden', 403);
    const sql = `INSERT INTO ${this.table(kind)}(scope_id,id,data) VALUES($1,$2,$3::jsonb)` +
      (insert || immutableKinds.has(kind) ? '' : ' ON CONFLICT(scope_id,id) DO UPDATE SET data=excluded.data');
    try { await this.connection.query(sql, [this.scopeId, value.id, JSON.stringify(value)]); }
    catch (e) { if (e.code === '23505') throw new FoundationError('immutable_or_duplicate'); throw e; }
    return value;
  }
  async remove(kind, id) { ensure(!immutableKinds.has(kind), 'immutable_or_duplicate', 409); await this.connection.query(`DELETE FROM ${this.table(kind)} WHERE scope_id=$1 AND id=$2`, [this.scopeId, id]); }
  async compareAndSwap(kind, id, expected, patch) {
    ensure(!immutableKinds.has(kind), 'immutable_or_duplicate', 409);
    ensure(!Object.hasOwn(patch, 'id') && !Object.hasOwn(patch, 'scope_id'), 'identity_patch_forbidden', 409);
    const r = await this.connection.query(`UPDATE ${this.table(kind)} SET data=data || $4::jsonb WHERE scope_id=$1 AND id=$2 AND NOT EXISTS(SELECT 1 FROM jsonb_each($3::jsonb) AS e WHERE data->e.key IS DISTINCT FROM e.value) RETURNING data`, [this.scopeId, id, JSON.stringify(expected), JSON.stringify(patch)]);
    return r.rows[0]?.data ?? null;
  }
  async search(queryTokens) {
    if (!queryTokens.length) return [];
    // queryTokens come from the deterministic tokenizer, NEVER raw tsquery/SQL supplied by a model.
    const q = queryTokens.map(t => `'${t.replaceAll("'", "''")}'`).join(' | ');
    const r = await this.connection.query('SELECT data FROM catpaw.memory_claims WHERE scope_id=$1 AND search_vector @@ to_tsquery(\'simple\',$2)', [this.scopeId, q]);
    return r.rows.map(r => r.data);
  }
}

/** Existing facade Store port. Internal-only; scope/auth and grant/lease fencing remain in facade/FencedWorkerStore. */
export class RecordTransaction {
  constructor(connection) { this.connection = connection; this.lockedScope = null; }
  async withScope(scopeId, fn, {reuseLockedScope=false}={}) {
    ensure(!this.lockedScope || this.lockedScope === scopeId, 'one_scope_per_transaction', 409);
    // Explicit chat-only reuse; the same row lock remains held until COMMIT.
    // No cross-request or cross-transaction authorization cache.
    if(reuseLockedScope&&this.scopedTransaction)return fn(this.scopedTransaction);
    this.lockedScope = scopeId;
    await this.connection.query("SELECT set_config('catpaw.scope_id',$1,true)", [scopeId]);
    const r = await this.connection.query('SELECT data FROM catpaw.scopes WHERE scope_id=$1 FOR UPDATE', [scopeId]);
    ensure(r.rows.length === 1, 'scope_forbidden', 403);
    this.scopedTransaction=new PostgresTransaction(this.connection, scopeId);
    return fn(this.scopedTransaction);
  }
  async chatConversationHead(owner,id){
    const r=await this.connection.query(`SELECT jsonb_build_object('id',data->'id','subject_id',data->'subject_id','scope_id',data->'scope_id','state',data->'state','grant_epoch',data->'grant_epoch','revision',data->'revision') AS data FROM public.records WHERE owner=$1 AND kind='native-chat-conversations' AND id=$2`,[owner,id]);
    return r.rows[0]?.data??null;
  }
  async chatTurnTail(owner,id,afterSequence){
    const r=await this.connection.query(`SELECT (data-ARRAY['input','history','model_history','subject_id','source_auth','dispatch_checkpoint','events']) || jsonb_build_object('events',COALESCE((SELECT jsonb_agg(e ORDER BY (e->>'sequence')::integer) FROM jsonb_array_elements(data->'events') e WHERE (e->>'sequence')::integer>$3),'[]'::jsonb)) AS data, jsonb_array_length(data->'events') AS event_count, data->>'subject_id' AS subject_id FROM public.records WHERE owner=$1 AND kind='native-chat-turns' AND id=$2`,[owner,id,afterSequence]);
    return r.rows[0]??null;
  }
  async lock(owner, kind, id) {
    // Advisory lock covers missing record rows too. Parameters are never SQL identifiers.
    await this.connection.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [canonical([owner, kind, id])]);
    await this.connection.query('SELECT id FROM public.records WHERE owner=$1 AND kind=$2 AND id=$3 FOR UPDATE', [owner, kind, id]);
  }
  async get(owner, kind, id) { const r = await this.connection.query('SELECT data FROM public.records WHERE owner=$1 AND kind=$2 AND id=$3', [owner, kind, id]); return r.rows[0]?.data ?? null; }
  async list(owner, kind) { const r = await this.connection.query('SELECT data FROM public.records WHERE owner=$1 AND kind=$2 ORDER BY updated_at,id', [owner, kind]); return r.rows.map(r => r.data); }
  async scan(kind) { const r = await this.connection.query('SELECT owner,data FROM public.records WHERE kind=$1 ORDER BY updated_at,id', [kind]); return r.rows.map(r => ({ owner: r.owner, value: r.data })); }
  async put(owner, kind, value) { await this.connection.query('INSERT INTO public.records(owner,kind,id,data) VALUES($1,$2,$3,$4::jsonb) ON CONFLICT(owner,kind,id) DO UPDATE SET data=excluded.data,updated_at=now()', [owner, kind, value.id, JSON.stringify(value)]); return value; }
  async insertIfAbsent(owner, kind, value) { const r = await this.connection.query('INSERT INTO public.records(owner,kind,id,data) VALUES($1,$2,$3,$4::jsonb) ON CONFLICT DO NOTHING RETURNING data', [owner, kind, value.id, JSON.stringify(value)]); return r.rows[0]?.data ?? null; }
  async compareAndSwap(owner, kind, id, expected, patch) { const r = await this.connection.query('UPDATE public.records SET data=data || $5::jsonb,updated_at=now() WHERE owner=$1 AND kind=$2 AND id=$3 AND NOT EXISTS(SELECT 1 FROM jsonb_each($4::jsonb) AS e WHERE data->e.key IS DISTINCT FROM e.value) RETURNING data', [owner, kind, id, JSON.stringify(expected), JSON.stringify(patch)]); return r.rows[0]?.data ?? null; }
  async claim(owner, id, status, now) {
    const r = await this.connection.query(`UPDATE public.records AS action SET data=jsonb_set(data,'{status}',$4::jsonb),updated_at=now()
      WHERE owner=$1 AND kind='actions' AND id=$2 AND data->>'status'='awaiting_review' AND (data->>'expiresAt')::timestamptz>$3::timestamptz
      AND ($4::jsonb <> '"executing"'::jsonb OR data->>'taskId' IS NULL OR EXISTS(SELECT 1 FROM public.records task
        WHERE task.owner=action.owner AND task.kind='tasks' AND task.id=action.data->>'taskId' AND task.data->>'status' IN ('running','waiting_approval'))) RETURNING data`, [owner, id, now, JSON.stringify(status)]);
    return r.rows[0]?.data ?? null;
  }
}
