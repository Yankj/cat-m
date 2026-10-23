// catpaw.family.v1 wire contract helpers (api-v1 §1, §5): strict JSON parse, canonical request hash.
export const PROTOCOL = 'catpaw.family.v1';
export const PREFIX = '/catpaw/family/v1';
export const MAX_BODY = 32 * 1024;
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const HASH_KEYS = ['command_id', 'type', 'household_id', 'target_id', 'expected_revision', 'proposal_id', 'payload', 'consent'];

export class FamilyError extends Error {
  constructor(status, code, extra = {}) { super(code); this.status = status; this.code = code; this.extra = extra; }
}

// Strict parser: rejects duplicate keys and any number that is not a safe integer (api-v1 §1, §5.4).
export function parseStrict(text) {
  let i = 0;
  const fail = () => { throw new FamilyError(422, 'json_invalid'); };
  const ws = () => { while (i < text.length && ' \t\n\r'.includes(text[i])) i++; };
  const str = () => {
    if (text[i] !== '"') fail();
    let j = i + 1;
    for (; j < text.length; j++) { const ch = text[j]; if (ch === '\\') { j++; continue; } if (ch === '"') break; if (ch < ' ') fail(); }
    if (j >= text.length) fail();
    let v; try { v = JSON.parse(text.slice(i, j + 1)); } catch { fail(); }
    i = j + 1; return v;
  };
  const val = (depth) => {
    if (depth > 32) fail();
    ws(); const ch = text[i];
    if (ch === '{') {
      i++; const o = {}; const seen = new Set(); ws();
      if (text[i] === '}') { i++; return o; }
      for (;;) { ws(); const k = str(); if (seen.has(k)) fail(); seen.add(k); ws(); if (text[i++] !== ':') fail(); o[k] = val(depth + 1); ws();
        if (text[i] === ',') { i++; continue; } if (text[i] === '}') { i++; return o; } fail(); }
    }
    if (ch === '[') {
      i++; const a = []; ws(); if (text[i] === ']') { i++; return a; }
      for (;;) { a.push(val(depth + 1)); ws(); if (text[i] === ',') { i++; continue; } if (text[i] === ']') { i++; return a; } fail(); }
    }
    if (ch === '"') return str();
    for (const [lit, v] of [['true', true], ['false', false], ['null', null]]) if (text.startsWith(lit, i)) { i += lit.length; return v; }
    const m = /^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?/.exec(text.slice(i));
    if (!m || m[2] || m[3]) fail();
    const n = Number(m[0]); if (!Number.isSafeInteger(n)) fail(); i += m[0].length; return n;
  };
  const v = val(0); ws(); if (i !== text.length) fail(); return v;
}

// Canonical JSON: keys sorted by UTF-16 code units (JS default sort), no whitespace, safe integers only.
export function canonical(v) {
  if (v === null || typeof v === 'boolean') return JSON.stringify(v);
  if (typeof v === 'number') { if (!Number.isSafeInteger(v)) throw new FamilyError(422, 'json_invalid'); return String(v); }
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (typeof v === 'object') return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}';
  throw new FamilyError(422, 'json_invalid');
}

export function hashable(cmd) { const o = {}; for (const k of HASH_KEYS) o[k] = cmd[k] === undefined ? null : cmd[k]; return o; }

export async function requestHash(cmd) {
  const bytes = new TextEncoder().encode(canonical(hashable(cmd)));
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...d].map(b => b.toString(16).padStart(2, '0')).join('');
}

export function validateCommand(cmd, { householdFromPath = null } = {}) {
  if (!cmd || typeof cmd !== 'object' || Array.isArray(cmd)) throw new FamilyError(422, 'command_invalid');
  for (const k of ['command_id', 'household_id']) if (typeof cmd[k] !== 'string' || !UUID_RE.test(cmd[k])) throw new FamilyError(422, 'command_invalid');
  if (typeof cmd.type !== 'string' || !/^[a-z]+\.[a-z_]+$/.test(cmd.type)) throw new FamilyError(422, 'command_invalid');
  // v0.4 deploy review: shared read-only access (household grants) is out of scope; refuse before dispatch.
  if (cmd.type.startsWith('grant.')) throw new FamilyError(422, 'command_invalid');
  for (const k of ['target_id', 'proposal_id']) if (cmd[k] != null && (typeof cmd[k] !== 'string' || !UUID_RE.test(cmd[k]))) throw new FamilyError(422, 'command_invalid');
  if (cmd.expected_revision != null && (!Number.isSafeInteger(cmd.expected_revision) || cmd.expected_revision < 1)) throw new FamilyError(422, 'command_invalid');
  if (cmd.payload != null && (typeof cmd.payload !== 'object' || Array.isArray(cmd.payload))) throw new FamilyError(422, 'command_invalid');
  if (householdFromPath === null && cmd.type !== 'household.ensure') throw new FamilyError(422, 'command_invalid');
  if (householdFromPath !== null && (cmd.type === 'household.ensure' || cmd.household_id !== householdFromPath)) throw new FamilyError(422, 'command_invalid');
  // actor / user / owner fields in the body are ignored (api-v1 §1): never forwarded.
  const out = {}; for (const k of HASH_KEYS) if (cmd[k] !== undefined) out[k] = cmd[k]; return out;
}
