// Deterministic SERIALIZED TEST DOUBLE. Snapshot restore tests are not PostgreSQL/process durability evidence.
import { clone, ensure, hash, TABLES, immutableKinds, FoundationError } from './common.mjs';

export class TestRepository {
  constructor(snapshot = { scopes: [], rows: [], records: [] }) {
    this.scopes = new Map(clone(snapshot.scopes)); this.rows = new Map(clone(snapshot.rows)); this.records = new Map(clone(snapshot.records ?? [])); this.tail = Promise.resolve();
    this.execution_layer = 'synthetic_test_double';
  }
  async bootstrapScope(scope) {
    const old = this.scopes.get(scope.scope_id);
    if (old) ensure(hash(old.identity) === hash(scope), 'scope_conflict', 409);
    else this.scopes.set(scope.scope_id, { identity: clone(scope), generation: 1, enabled: true, last_sequence: 0 });
  }
  async transaction(scopeId, fn) {
    const recordsOnly = typeof scopeId === 'function'; if (recordsOnly) { fn = scopeId; scopeId = null; }
    let release; const gate = new Promise(r => { release = r; }); const previous = this.tail; this.tail = previous.then(() => gate);
    await previous;
    const scopes = new Map(clone([...this.scopes])); const rows = new Map(clone([...this.rows])); const records = new Map(clone([...this.records]));
    try {
      if (!recordsOnly) ensure(scopes.has(scopeId), 'scope_forbidden', 403);
      const recordTx = new TestRecordTransaction(records, scopes, rows);
      const tx = recordsOnly ? recordTx : new TestTransaction(scopeId, scopes, rows, recordTx); const result = await fn(tx);
      this.scopes = scopes; this.rows = rows; this.records = records; return clone(result);
    } finally { release(); }
  }
  snapshot() { return clone({ scopes: [...this.scopes], rows: [...this.rows], records: [...this.records] }); }
}
class TestTransaction {
  constructor(scopeId, scopes, rows, records) { this.scopeId = scopeId; this.scopes = scopes; this.rows = rows; this.records = records; }
  key(kind, id) { ensure(Object.hasOwn(TABLES, kind)); return JSON.stringify([this.scopeId, kind, id]); }
  async scope() { return clone(this.scopes.get(this.scopeId)); }
  async saveScope(value) { this.scopes.set(this.scopeId, clone(value)); }
  async get(kind, id) { return clone(this.rows.get(this.key(kind, id)) ?? null); }
  async list(kind) { this.key(kind, ''); return [...this.rows].filter(([k]) => { const [s, t] = JSON.parse(k); return s === this.scopeId && t === kind; }).map(([, v]) => clone(v)); }
  async put(kind, value, { insert = false } = {}) {
    ensure(value.scope_id === this.scopeId, 'scope_forbidden', 403);
    const old = await this.get(kind, value.id);
    if (old && (insert || immutableKinds.has(kind))) throw new FoundationError('immutable_or_duplicate');
    this.rows.set(this.key(kind, value.id), clone(value)); return clone(value);
  }
  async remove(kind, id) { ensure(!immutableKinds.has(kind), 'immutable_or_duplicate', 409); this.rows.delete(this.key(kind, id)); }
  async compareAndSwap(kind, id, expected, patch) {
    ensure(!immutableKinds.has(kind), 'immutable_or_duplicate', 409);
    const old = await this.get(kind, id);
    if (!old || !Object.entries(expected).every(([k, v]) => Object.hasOwn(old, k) && hash(old[k]) === hash(v))) return null;
    ensure(!Object.hasOwn(patch, 'id') && !Object.hasOwn(patch, 'scope_id'), 'identity_patch_forbidden', 409);
    return this.put(kind, { ...old, ...clone(patch) });
  }
  async search(queryTokens) {
    return (await this.list('facts')).filter(v => queryTokens.some(t => v.search_text.split(' ').includes(t)));
  }
}

class TestRecordTransaction {
  constructor(records, scopes, rows) { this.records = records; this.scopes = scopes; this.rows = rows; this.lockedScope = null; }
  key(owner, kind, id) { return JSON.stringify([owner, kind, id]); }
  async withScope(scopeId, fn) { ensure(!this.lockedScope || this.lockedScope === scopeId, 'one_scope_per_transaction', 409); this.lockedScope = scopeId; ensure(this.scopes.has(scopeId), 'scope_forbidden', 403); return fn(new TestTransaction(scopeId, this.scopes, this.rows, this)); }
  async lock() {} // test serialization only
  async get(owner, kind, id) { return clone(this.records.get(this.key(owner, kind, id)) ?? null); }
  async list(owner, kind) { return [...this.records].filter(([k]) => { const [o, t] = JSON.parse(k); return o === owner && t === kind; }).map(([, v]) => clone(v)); }
  async scan(kind) { return [...this.records].filter(([k]) => JSON.parse(k)[1] === kind).map(([k, value]) => ({ owner: JSON.parse(k)[0], value: clone(value) })); }
  async put(owner, kind, value) { this.records.set(this.key(owner, kind, value.id), clone(value)); return clone(value); }
  async insertIfAbsent(owner, kind, value) { if (await this.get(owner, kind, value.id)) return null; return this.put(owner, kind, value); }
  async compareAndSwap(owner, kind, id, expected, patch) { const v = await this.get(owner, kind, id); if (!v || !Object.entries(expected).every(([k, e]) => Object.hasOwn(v, k) && hash(v[k]) === hash(e))) return null; return this.put(owner, kind, { ...v, ...clone(patch) }); }
  async claim(owner, id, status, now) { const a = await this.get(owner, 'actions', id); if (!a || a.status !== 'awaiting_review' || Date.parse(a.expiresAt) <= Date.parse(now)) return null; if (status === 'executing' && a.taskId) { const t = await this.get(owner, 'tasks', a.taskId); if (!t || !['running', 'waiting_approval'].includes(t.status)) return null; } return this.compareAndSwap(owner, 'actions', id, { status: 'awaiting_review' }, { status }); }
}
