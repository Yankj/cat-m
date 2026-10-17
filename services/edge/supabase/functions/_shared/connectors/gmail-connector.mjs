// catpaw.connectors.gmail.v1 — inert-by-default request handling for the Gmail connector (v1.1). No network I/O here:
// Google token exchange / Gmail fetch are injected ports so tests run offline and nothing runs until credentials exist.
import { readFeatureGate, readAllowlist, withBlocklist, featureAllows } from '../config.mjs';
export const GMAIL_SCOPE = 'https://www.googleapis.com/auth/gmail.readonly';
export const ALLOWED_SCOPES = new Set([GMAIL_SCOPE]);
export const DISCLOSURE_VERSION = 'gmail-connector-disclosure.v1';
export const DATA_FIELDS = ['message_id', 'thread_id', 'subject', 'from', 'date', 'body_text_excerpt', 'calendar_attachment'];

export function readConnectorConfig(get) {
  const gate = readFeatureGate(get('CATPAW_GMAIL_CONNECTOR_ENABLED'), 'on');
  const allow = withBlocklist(readAllowlist(get('CATPAW_FEATURE_ALLOWLIST_SUBJECTS')), readAllowlist(get('CATPAW_FEATURE_BLOCKLIST_SUBJECTS')));
  const clientId = get('CATPAW_GOOGLE_OAUTH_CLIENT_ID') || null;
  const encKey = get('CATPAW_CONNECTOR_TOKEN_KEY') || null; // 32-byte base64 AES-GCM key; value never logged
  const encKeyOk = typeof encKey === 'string' && /^[A-Za-z0-9+/]{43}=$/.test(encKey);
  return { gate, allow, clientId, encKeyOk, configured: !!clientId && encKeyOk };
}

/** Status shape safe for clients: never contains key material. */
export function connectorStatus(cfg, subjectID) {
  const enabled = featureAllows(cfg.gate, cfg.allow, subjectID);
  return { connector: 'gmail', enabled, configured: cfg.configured, available: enabled && cfg.configured,
    scopes: [...ALLOWED_SCOPES], disclosure_version: DISCLOSURE_VERSION, data_fields: DATA_FIELDS };
}

/** Validate a link request (authorization-code + PKCE verifier from iOS). Returns {status, body}. */
export async function handleLink(cfg, ctx, input, ports) {
  const st = connectorStatus(cfg, ctx.subjectID);
  if (!st.enabled) return { status: 404, body: { error: 'feature_disabled' } };
  if (!st.configured) return { status: 503, body: { error: 'connector_not_configured' } };
  const ok = input && typeof input.code === 'string' && /^[A-Za-z0-9+/=_.\-]{20,512}$/.test(input.code)
    && typeof input.code_verifier === 'string' && /^[A-Za-z0-9\-._~]{43,128}$/.test(input.code_verifier)
    && input.disclosure_version === DISCLOSURE_VERSION && input.consent === 'allow'
    && Number.isInteger(input.account_epoch) && input.account_epoch >= 0;
  if (!ok) return { status: 422, body: { error: 'invalid_link_request' } };
  const grant = await ports.exchangeCode({ code: input.code, codeVerifier: input.code_verifier, clientId: cfg.clientId });
  const scopes = String(grant?.scope ?? '').split(/\s+/).filter(Boolean);
  if (!scopes.length || scopes.some(s => !ALLOWED_SCOPES.has(s) && !['openid', 'email'].includes(s)) || !scopes.includes(GMAIL_SCOPE)) {
    if (grant?.refresh_token) await ports.revoke(grant.refresh_token);
    return { status: 422, body: { error: 'scope_not_allowed' } };
  }
  await ports.store({ owner: ctx.subjectID, accountEpoch: input.account_epoch, refreshToken: grant.refresh_token, scopes, disclosureVersion: DISCLOSURE_VERSION });
  return { status: 200, body: { linked: true, scopes } };
}

/** Revoke: delete server row first (authoritative), then best-effort Google revoke. */
export async function handleUnlink(cfg, ctx, ports) {
  const row = await ports.remove({ owner: ctx.subjectID });
  if (row?.refreshToken) { try { await ports.revoke(row.refreshToken); } catch { /* row already gone; token unusable by us */ } }
  return { status: 200, body: { linked: false } };
}

/** Polling guard: a token may only be used for the owner + epoch it was linked under. */
export function tokenUsable(row, ctx) {
  return !!row && row.owner === ctx.subjectID && row.accountEpoch === ctx.accountEpoch && row.state === 'active';
}
