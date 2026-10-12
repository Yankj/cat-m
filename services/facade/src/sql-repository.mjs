// Real SQL implementation against OpenMuse's existing records table.
// Database adapter must pin ONE connection for an entire transaction, never BEGIN on pool.query.
export class SqlRepository {
  constructor(database) { this.database=database;this.layer='sql_unverified'; }
  transaction(fn) { return this.database.transaction(connection=>fn(new SqlTransaction(connection))); }
}
export class SqlTransaction {
  constructor(connection) { this.connection=connection; }
  async lock(owner,kind,id) { await this.connection.query('SELECT id FROM records WHERE owner=$1 AND kind=$2 AND id=$3 FOR UPDATE',[owner,kind,id]); }
  async get(owner,kind,id) { const r=await this.connection.query('SELECT data FROM records WHERE owner=$1 AND kind=$2 AND id=$3',[owner,kind,id]);return r.rows[0]?.data??null; }
  async list(owner,kind) { const r=await this.connection.query('SELECT data FROM records WHERE owner=$1 AND kind=$2 ORDER BY updated_at,id',[owner,kind]);return r.rows.map(x=>x.data); }
  async scan(kind) { const r=await this.connection.query('SELECT owner,data FROM records WHERE kind=$1 ORDER BY updated_at,id',[kind]);return r.rows.map(x=>({owner:x.owner,value:x.data})); }
  async put(owner,kind,value) { await this.connection.query('INSERT INTO records(owner,kind,id,data) VALUES($1,$2,$3,$4::jsonb) ON CONFLICT(owner,kind,id) DO UPDATE SET data=excluded.data,updated_at=now()',[owner,kind,value.id,JSON.stringify(value)]);return value; }
  async insertIfAbsent(owner,kind,value) { const r=await this.connection.query('INSERT INTO records(owner,kind,id,data) VALUES($1,$2,$3,$4::jsonb) ON CONFLICT DO NOTHING RETURNING data',[owner,kind,value.id,JSON.stringify(value)]);return r.rows[0]?.data??null; }
  async compareAndSwap(owner,kind,id,expected,patch) { const r=await this.connection.query('UPDATE records SET data=data || $5::jsonb,updated_at=now() WHERE owner=$1 AND kind=$2 AND id=$3 AND data @> $4::jsonb RETURNING data',[owner,kind,id,JSON.stringify(expected),JSON.stringify(patch)]);return r.rows[0]?.data??null; }
  async claim(owner,id,status,now) { const r=await this.connection.query(`UPDATE records AS action SET data=jsonb_set(data,'{status}',$4::jsonb),updated_at=now() WHERE owner=$1 AND kind='actions' AND id=$2 AND data->>'status'='awaiting_review' AND (data->>'expiresAt')::timestamptz>$3::timestamptz AND ($4::jsonb <> '"executing"'::jsonb OR data->>'taskId' IS NULL OR EXISTS(SELECT 1 FROM records task WHERE task.owner=action.owner AND task.kind='tasks' AND task.id=action.data->>'taskId' AND task.data->>'status' IN ('running','waiting_approval'))) RETURNING data`,[owner,id,now,JSON.stringify(status)]);return r.rows[0]?.data??null; }
}
export function postgresDatabase(pool) {
  return {transaction:async fn=>{const c=await pool.connect();try{await c.query('BEGIN');const result=await fn(c);await c.query('COMMIT');return result;}catch(e){await c.query('ROLLBACK');throw e;}finally{c.release();}}};
}
export function pgliteDatabase(embedded) { return {transaction:fn=>embedded.transaction(tx=>fn(tx))}; }
