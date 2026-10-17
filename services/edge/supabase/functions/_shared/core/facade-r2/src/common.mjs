import { createHash } from 'node:crypto';
export const COMMIT = '1ac68f3909f2478ab6280883f1ab5ea65eb5719d';
export const clone = v => structuredClone(v);
export const canonical = v => {
  if (v === null || ['string','boolean'].includes(typeof v)) return JSON.stringify(v);
  if (typeof v==='number') { if(!Number.isFinite(v))throw new ApiError(422,'schema_invalid');return JSON.stringify(v); }
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (!v || Object.getPrototypeOf(v) !== Object.prototype) throw new ApiError(422,'schema_invalid');
  return `{${Object.keys(v).sort().map(k=>`${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`;
};
export const hash = v => createHash('sha256').update(typeof v==='string'?v:canonical(v)).digest('hex');
export class ApiError extends Error {
  constructor(status,code,{reconciliation=false,retryable=false,retryAfterSec=null}={}) { super(code); this.status=status;this.code=code;this.reconciliation=reconciliation;this.retryable=retryable===true;if(Number.isInteger(retryAfterSec)&&retryAfterSec>0)this.retryAfterSec=retryAfterSec; }
}
export const check = (ok,status,code,details) => { if (!ok) throw new ApiError(status,code,details); };
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function shape(value,fields) {
  check(value && !Array.isArray(value) && Object.getPrototypeOf(value)===Object.prototype,422,'schema_invalid');
  check(Object.keys(value).every(k=>fields.includes(k)) && fields.every(k=>k in value),422,'schema_invalid');
}
export const iso = () => new Date().toISOString();
export function immutableBody(artifact) { return canonical({kind:artifact.kind,title:artifact.title,summary:artifact.summary,data:artifact.data}); }
export const SYNTHETIC_SCOPE = Object.freeze({scope_id:'11111111-2222-4222-8222-111111111111',profile_id:'11111111-1111-4111-8111-111111111111',workspace_id:'11111111-2222-4222-8222-111111111111'});
export function syntheticAuth(authorization) {
  check(authorization==='Bearer synthetic-only',401,'session_required');
  return {subject_id:'synthetic-principal',scopes:[SYNTHETIC_SCOPE]};
}
