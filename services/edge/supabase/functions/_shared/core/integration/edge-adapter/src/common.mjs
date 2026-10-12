import { createHash, randomUUID } from 'node:crypto';
export const clone = value => structuredClone(value);
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]));
  return value;
}
export const hash = value => createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
export const id = () => randomUUID();
export const iso = ms => new Date(ms).toISOString();
export class AdapterError extends Error {
  constructor(code) { super(code); this.name = 'AdapterError'; this.code = code; }
}
export const ensure = (condition, code) => { if (!condition) throw new AdapterError(code); };
// Only callers that can prove no external dispatch occurred may request a retry.
export class SafeRetry extends AdapterError { constructor() { super('pre_dispatch_transient'); } }
export const dispatched = task => task.state?.local_model?.round?.state === 'dispatched';
export const checkpointHash = task => hash(task.state ?? {});
