import { createHash, randomUUID } from 'node:crypto';

export const id = () => randomUUID();
export const clone = value => structuredClone(value);
export function canonical(value) {
  if (value === null || ['string', 'boolean'].includes(typeof value)) return JSON.stringify(value);
  if (typeof value === 'number' && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (!value || Object.getPrototypeOf(value) !== Object.prototype) throw new FoundationError('schema_invalid', 422);
  return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
export const hash = value => createHash('sha256').update(typeof value === 'string' ? value : canonical(value)).digest('hex');
export class FoundationError extends Error {
  constructor(code, status = 409) { super(code); this.code = code; this.status = status; }
}
export function ensure(ok, code = 'schema_invalid', status = 422) { if (!ok) throw new FoundationError(code, status); }
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function uuid(value) { ensure(typeof value === 'string' && UUID.test(value)); return value; }
export function text(value, max = 8000) { ensure(typeof value === 'string' && value.trim().length > 0 && value.length <= max); return value; }
export function exact(value, required, optional = []) {
  ensure(value && Object.getPrototypeOf(value) === Object.prototype);
  ensure(required.every(k => Object.hasOwn(value, k)) && Object.keys(value).every(k => required.includes(k) || optional.includes(k)));
}
export function integer(value, min = 0, max = Number.MAX_SAFE_INTEGER) { ensure(Number.isSafeInteger(value) && value >= min && value <= max); return value; }
export function instant(value) { ensure(typeof value === 'string' && /^\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)$/.test(value) && Number.isFinite(Date.parse(value))); return new Date(value).toISOString(); }
export function json(value, max = 8000) { ensure(canonical(value).length <= max); return clone(value); }
export const TABLES = Object.freeze({
  conversations: 'conversation_refs', sources: 'source_records', goals: 'goals', bindings: 'execution_bindings',
  artifacts: 'artifact_versions', approvals: 'approval_bindings', jobs: 'memory_jobs', candidates: 'memory_candidates',
  facts: 'memory_claims', summaries: 'episode_summaries', guards: 'memory_guards', commands: 'memory_commands', events: 'events'
});
export const immutableKinds = new Set(['artifacts', 'bindings', 'approvals', 'commands', 'guards', 'events']);

// Chinese bigrams + words; no claim of semantic synonym recall or built-in Chinese PG segmentation.
export function tokens(input) {
  const normalized = input.normalize('NFKC').toLowerCase();
  const result = normalized.match(/[a-z0-9_]+/g) ?? [];
  for (const run of normalized.match(/[\p{Script=Han}]+/gu) ?? []) {
    if (run.length === 1) result.push(run);
    else for (let n = 0; n < run.length - 1; n++) result.push(run.slice(n, n + 2));
  }
  return [...new Set(result)].slice(0, 256);
}
export function searchText(claim) { return tokens(`${claim.predicate} ${canonical(claim.value)} ${canonical(claim.conditions)}`).join(' '); }
