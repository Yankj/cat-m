// Log-safe error summary: stable code/name only. Never message, stack, SQL, titles or user text (api-v1 §6, §11).
export function errCode(e) {
  const c = e && typeof e === 'object' ? e.code : undefined;
  if (typeof c === 'string' && /^[A-Za-z0-9_.-]{1,64}$/.test(c)) return c;
  const n = e && typeof e === 'object' ? e.name : undefined;
  return typeof n === 'string' && /^[A-Za-z0-9_]{1,40}$/.test(n) ? n : 'error';
}
