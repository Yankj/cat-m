// APNs sender skeleton (R7 §8.4). Disabled unless every CATPAW_APNS_* value is present.
// No network in tests: fetchImpl is injected. Keys stay in Edge secrets only.
import { Buffer } from 'node:buffer';
import { ApiError, check } from '../facade-r2/src/common.mjs';

export const APNS_ENV_NAMES = Object.freeze(['CATPAW_APNS_KEY_ID', 'CATPAW_APNS_TEAM_ID', 'CATPAW_APNS_P8', 'CATPAW_APNS_BUNDLE_ID']);
export const APNS_HOSTS = Object.freeze({ production: 'https://api.push.apple.com', sandbox: 'https://api.sandbox.push.apple.com' });
export const PUSH_TYPES = Object.freeze(['alert', 'liveactivity', 'background']);
export const RELEVANCE = Object.freeze({ waiting_approval: 100, failed: 80, running: 50, succeeded: 30 });

/** Returns null (disabled) unless all env values exist. CATPAW_APNS_ENV = production|sandbox (default sandbox). */
export function readApnsConfig(get) {
  const values = Object.fromEntries(APNS_ENV_NAMES.map(n => [n, get(n)]));
  if (APNS_ENV_NAMES.some(n => !values[n])) return null;
  const env = get('CATPAW_APNS_ENV') || 'sandbox';
  check(Object.hasOwn(APNS_HOSTS, env), 422, 'apns_env_invalid');
  check(/^[A-Z0-9]{10}$/.test(values.CATPAW_APNS_KEY_ID) && /^[A-Z0-9]{10}$/.test(values.CATPAW_APNS_TEAM_ID), 422, 'apns_identity_invalid');
  check(/^[A-Za-z0-9.-]{1,155}$/.test(values.CATPAW_APNS_BUNDLE_ID), 422, 'apns_bundle_invalid');
  return { keyId: values.CATPAW_APNS_KEY_ID, teamId: values.CATPAW_APNS_TEAM_ID, p8: values.CATPAW_APNS_P8, bundleId: values.CATPAW_APNS_BUNDLE_ID, env, host: APNS_HOSTS[env] };
}

const b64url = data => Buffer.from(data).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function pemToPkcs8(pem) {
  const body = String(pem).replace(/\\n/g, '\n').replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '');
  check(body.length > 0 && /^[A-Za-z0-9+/=]+$/.test(body), 422, 'apns_key_invalid');
  return Buffer.from(body, 'base64');
}

/** ES256 provider token. Apple accepts a token for up to 60 min; we refresh every 50 min. */
export class ApnsTokenSigner {
  #key = null; #cached = null;
  constructor(config, { now = () => Date.now(), subtle = globalThis.crypto.subtle } = {}) { this.config = config; this.now = now; this.subtle = subtle; }
  async token() {
    const issuedAt = Math.floor(this.now() / 1000);
    if (this.#cached && issuedAt - this.#cached.iat < 3000) return this.#cached.jwt;
    this.#key ??= await this.subtle.importKey('pkcs8', pemToPkcs8(this.config.p8), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    const header = b64url(JSON.stringify({ alg: 'ES256', kid: this.config.keyId }));
    const claims = b64url(JSON.stringify({ iss: this.config.teamId, iat: issuedAt }));
    const signature = await this.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, this.#key, new TextEncoder().encode(`${header}.${claims}`));
    const jwt = `${header}.${claims}.${b64url(new Uint8Array(signature))}`; // WebCrypto ECDSA output is raw r||s (JOSE form)
    this.#cached = { jwt, iat: issuedAt };
    return jwt;
  }
}

/** Build a Live Activity payload (ActivityKit content-state from design §8.2). */
export function liveActivityPayload({ event = 'update', contentState, staleAfterSeconds = 1800, now = Date.now(), dismissalDate = null }) {
  check(['update', 'end', 'start'].includes(event), 422, 'apns_event_invalid');
  check(contentState && typeof contentState.status === 'string', 422, 'apns_content_state_invalid');
  const ts = Math.floor(now / 1000);
  const aps = { timestamp: ts, event, 'content-state': contentState, 'stale-date': ts + staleAfterSeconds, 'relevance-score': RELEVANCE[contentState.status] ?? 50 };
  if (event === 'end' && dismissalDate) aps['dismissal-date'] = dismissalDate;
  return { aps };
}

export class ApnsSender {
  constructor(config, { fetchImpl = globalThis.fetch, signer = new ApnsTokenSigner(config) } = {}) { this.config = config; this.fetchImpl = fetchImpl; this.signer = signer; }
  topic(pushType) { return pushType === 'liveactivity' ? `${this.config.bundleId}.push-type.liveactivity` : this.config.bundleId; }
  /** Returns {ok, status, reason, unregistered}. 410 → caller deletes the token; 429 → caller backs off. */
  async send({ deviceToken, pushType, payload, priority, collapseId = null, expiration = 0 }) {
    check(typeof deviceToken === 'string' && /^[0-9a-f]{64,200}$/i.test(deviceToken), 422, 'apns_token_invalid');
    check(PUSH_TYPES.includes(pushType), 422, 'apns_push_type_invalid');
    const prio = priority ?? (pushType === 'background' ? 5 : 10);
    check([5, 10].includes(prio), 422, 'apns_priority_invalid');
    const body = JSON.stringify(payload); check(Buffer.byteLength(body) <= 4096, 413, 'apns_payload_too_large');
    const headers = { authorization: `bearer ${await this.signer.token()}`, 'apns-push-type': pushType, 'apns-topic': this.topic(pushType), 'apns-priority': String(prio), 'apns-expiration': String(expiration), 'content-type': 'application/json' };
    if (collapseId) { check(Buffer.byteLength(collapseId) <= 64, 422, 'apns_collapse_invalid'); headers['apns-collapse-id'] = collapseId; }
    const response = await this.fetchImpl(`${this.config.host}/3/device/${deviceToken}`, { method: 'POST', redirect: 'error', headers, body });
    let reason = null; if (response.status !== 200) { try { reason = (await response.json())?.reason ?? null; } catch { reason = null; } }
    return { ok: response.status === 200, status: response.status, reason, unregistered: response.status === 410, retryLater: response.status === 429 || response.status >= 500 };
  }
}

/** Token registry routes (placeholder storage keyed by authenticated subject). */
export function validateDeviceTokenInput(input) {
  check(input && typeof input === 'object' && !Array.isArray(input), 422, 'push_token_invalid');
  check(Object.keys(input).every(k => ['device_id', 'apns_token', 'env', 'task_id', 'activity_token', 'push_to_start_token'].includes(k)), 422, 'push_token_invalid');
  check(typeof input.device_id === 'string' && /^[0-9a-f-]{36}$/i.test(input.device_id), 422, 'push_device_invalid');
  for (const k of ['apns_token', 'activity_token', 'push_to_start_token']) if (input[k] !== undefined) check(typeof input[k] === 'string' && /^[0-9a-f]{64,200}$/i.test(input[k]), 422, 'push_token_invalid');
  if (input.env !== undefined) check(Object.hasOwn(APNS_HOSTS, input.env), 422, 'push_env_invalid');
  return input;
}
export async function handlePushTokenRoute({ path, method, apns, authenticate, auth, repository, body, now = () => new Date().toISOString() }) {
  const kind = path === '/catpaw/devices/v1/push-token' ? 'device_push_tokens' : path === '/catpaw/devices/v1/live-activity-tokens' ? 'live_activity_tokens' : null;
  if (!kind) return null;
  if (!apns) throw new ApiError(503, 'apns_not_configured');
  check(['POST', 'DELETE'].includes(method), 405, 'method_not_allowed');
  const principal = await authenticate(auth);
  const input = validateDeviceTokenInput(await body());
  const owner = `push:${principal.subject_id}`, id = kind === 'live_activity_tokens' ? `${input.device_id}:${input.task_id ?? 'push-to-start'}` : input.device_id;
  if (kind === 'live_activity_tokens' && input.task_id !== undefined) check(typeof input.task_id === 'string' && /^[A-Za-z0-9._:-]{1,160}$/.test(input.task_id), 422, 'push_task_invalid');
  await repository.transaction(async tx => {
    await tx.lock(owner, kind, id);
    if (method === 'DELETE') { const old = await tx.get(owner, kind, id); if (old) await tx.put(owner, kind, { ...old, id, state: 'deleted', updated_at: now() }); return; }
    await tx.put(owner, kind, { id, ...input, subject_id: principal.subject_id, state: 'active', updated_at: now() });
  });
  return { registered: method === 'POST', kind };
}
