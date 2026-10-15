// catpaw.agent-memory.v1 — the agent-facing memory of Wave 2 §1 (plan.md).
// Separate from the source-backed catpaw.memory.v1 (core/src/memory-*.mjs); see docs/agent-memory-contract.md
// for why both exist and how they should converge before the gate is flipped to `true`.
export const AGENT_MEMORY_CONTRACT = 'catpaw.agent-memory.v1';
export const MEMORY_MODE_HEADER = 'X-Catpaw-Memory-Mode'; // 'ephemeral' = temporary conversation: no recall, no tools, no journal
export const MEMORY_KINDS = Object.freeze(['profile', 'preference', 'person', 'fact', 'journal']);
export const LIMITS = Object.freeze({ content_chars: 500, rows_per_user: 1000, search_k_max: 20, recall_k: 6, pinned_tokens: 1500, forget_max: 20, undo_ttl_ms: 24 * 3600 * 1000, decay_half_life_days: 30, journal_fragment_chars: 400 });
// Privacy default: nothing is read or written until the user consents (plan §1.2 defaults to true; see objections).
export const DEFAULT_SETTINGS = Object.freeze({ use_memory: false, auto_save: false, consented_at: null });
const str = (v, max) => typeof v === 'string' && v.trim().length > 0 && v.length <= max;
const UUIDRE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUUID = v => typeof v === 'string' && UUIDRE.test(v);
export class MemoryError extends Error { constructor(status, code) { super(code); this.status = status; this.code = code; } }
const bad = (code, status = 422) => new MemoryError(status, code);
const exact = (v, allowed) => { if (!v || typeof v !== 'object' || Array.isArray(v) || Object.keys(v).some(k => !allowed.includes(k))) throw bad('memory_schema_invalid'); };
const fn = (name, description, properties, required) => ({ type: 'function', function: { name, description, parameters: { type: 'object', properties, required, additionalProperties: false } } });
export const MEMORY_TOOLS = Object.freeze([
  fn('memory_save', 'Remember a durable fact about the user for future conversations. Only for stable personal facts or preferences the user stated; never secrets, credentials, health or financial identifiers.', { kind: { type: 'string', enum: MEMORY_KINDS.filter(k => k !== 'journal') }, content: { type: 'string', maxLength: LIMITS.content_chars }, expires_at: { type: 'string', description: 'ISO 8601, optional' } }, ['kind', 'content']),
  fn('memory_search', 'Search the user\'s saved memories.', { query: { type: 'string', maxLength: 200 }, k: { type: 'integer', minimum: 1, maximum: LIMITS.search_k_max } }, ['query']),
  fn('memory_update', 'Correct the content of one saved memory (id from memory_search or recalled context).', { id: { type: 'string' }, content: { type: 'string', maxLength: LIMITS.content_chars } }, ['id', 'content']),
  fn('memory_forget', 'Delete saved memories. Prefer ids from memory_search; the user confirms on a card before anything is deleted.', { ids: { type: 'array', items: { type: 'string' }, maxItems: LIMITS.forget_max }, query: { type: 'string', maxLength: 200 } }, []),
]);
export const MEMORY_TOOL_NAMES = Object.freeze(MEMORY_TOOLS.map(t => t.function.name));
export function validateToolArgs(name, a) {
  if (name === 'memory_save') { exact(a, ['kind', 'content', 'expires_at']); if (!MEMORY_KINDS.includes(a.kind) || a.kind === 'journal' || !str(a.content, LIMITS.content_chars)) throw bad('memory_schema_invalid'); if (a.expires_at !== undefined && a.expires_at !== null && !Number.isFinite(Date.parse(a.expires_at))) throw bad('memory_schema_invalid'); return; }
  if (name === 'memory_search') { exact(a, ['query', 'k']); if (!str(a.query, 200) || (a.k !== undefined && !(Number.isInteger(a.k) && a.k >= 1 && a.k <= LIMITS.search_k_max))) throw bad('memory_schema_invalid'); return; }
  if (name === 'memory_update') { exact(a, ['id', 'content']); if (!isUUID(a.id) || !str(a.content, LIMITS.content_chars)) throw bad('memory_schema_invalid'); return; }
  if (name === 'memory_forget') { exact(a, ['ids', 'query']); const ids = a.ids !== undefined, q = a.query !== undefined; if (ids === q) throw bad('memory_schema_invalid'); if (ids && !(Array.isArray(a.ids) && a.ids.length >= 1 && a.ids.length <= LIMITS.forget_max && a.ids.every(isUUID))) throw bad('memory_schema_invalid'); if (q && !str(a.query, 200)) throw bad('memory_schema_invalid'); return; }
  throw bad('memory_schema_invalid');
}
export function validateSettingsPatch(a) { exact(a, ['use_memory', 'auto_save', 'consent']); if (Object.values(a).some(v => typeof v !== 'boolean') || !Object.keys(a).length) throw bad('memory_schema_invalid'); return a; }
/** Rough token estimate: CJK ≈ 1 token per char, other text ≈ 4 chars per token. */
export function estimateTokens(text) { let cjk = 0; for (const ch of text) if (/[\u3000-\u9fff\uac00-\ud7af\uff00-\uffef]/.test(ch)) cjk++; return cjk + Math.ceil((text.length - cjk) / 4); }
/** Lexical terms: lowercase words plus CJK bigrams (fallback when no embedding provider is configured). */
export function terms(text) {
  const out = new Set(), s = String(text).toLowerCase();
  for (const w of s.match(/[a-z0-9]+/g) ?? []) if (w.length > 1) out.add(w);
  for (const run of s.match(/[\u3400-\u9fff]+/g) ?? []) { if (run.length === 1) out.add(run); for (let i = 0; i + 1 < run.length; i++) out.add(run.slice(i, i + 2)); }
  return out;
}
export function lexicalScore(query, content) { const q = terms(query); if (!q.size) return 0; const c = terms(content); let hit = 0; for (const t of q) if (c.has(t)) hit++; return hit / q.size; }
export const cosine = (a, b) => { let d = 0, x = 0, y = 0; for (let i = 0; i < a.length; i++) { d += a[i] * b[i]; x += a[i] * a[i]; y += b[i] * b[i]; } return x && y ? d / Math.sqrt(x * y) : 0; };
export const decay = (updatedAt, now) => Math.pow(0.5, Math.max(0, now - Date.parse(updatedAt)) / (LIMITS.decay_half_life_days * 86400000));
export const publicMemory = r => ({ id: r.id, kind: r.kind, content: r.content, pinned: r.pinned === true, expires_at: r.expires_at ?? null, source_conversation_id: r.source_conversation_id ?? null, created_at: r.created_at, updated_at: r.updated_at });
