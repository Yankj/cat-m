// catpaw.feature-enrollment.v1: DB-backed feature enrollment (replaces hand-typed allowlist UUIDs in env).
// An enrolled subject counts as being on CATPAW_FEATURE_ALLOWLIST_SUBJECTS for the features it is enrolled in.
export const ENROLLMENT_CONTRACT = 'catpaw.feature-enrollment.v1';
export const FEATURES = Object.freeze(['agent_memory', 'task_tools', 'generative_ui', 'device_tools', 'proactive']);
// Invite codes: 'CP-' + 12 chars from this alphabet (no 0/O/1/I/L), shown grouped as CP-XXXX-XXXX-XXXX.
export const INVITE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
/** Uppercase, drop spaces/dashes, drop an optional CP prefix. Returns null when it cannot be a code. */
export function normalizeInviteCode(input) {
  if (typeof input !== 'string' || input.length > 64) return null;
  let s = input.toUpperCase().replace(/[\s\-_]/g, '');
  if (s.startsWith('CP')) s = s.slice(2);
  return /^[A-HJ-KM-NP-Z2-9]{12}$/.test(s) ? s : null;
}
/** Hex SHA-256 of the normalized code; must equal feature_access.invite_code_hash() in the migration. */
export async function hashInviteCode(normalized) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('catpaw-invite-v1:' + normalized));
  return [...new Uint8Array(d)].map(b => b.toString(16).padStart(2, '0')).join('');
}
