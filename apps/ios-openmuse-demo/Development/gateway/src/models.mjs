import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

export const hash = text => createHash('sha256').update(text).digest('hex');
export function fail(code, message = code) { return Object.assign(new Error(message), {code}); }
export function immutable(value) {
  if (value && typeof value === 'object') { Object.values(value).forEach(immutable); Object.freeze(value); }
  return value;
}
export const clone = value => JSON.parse(JSON.stringify(value));
export function canonicalJSON(value) {
  const canonical = item => Array.isArray(item) ? item.map(canonical) : item && typeof item === 'object' ?
    Object.fromEntries(Object.keys(item).sort().map(key => [key, canonical(item[key])])) : item;
  return JSON.stringify(canonical(value));
}
export class ModelRegistry {
  constructor(config = JSON.parse(readFileSync(new URL('../config/models.json', import.meta.url)))) {
    this.config = immutable(clone(config));
  }
  select(id) {
    const value = this.config.candidates.find(m => m.id === id);
    if (!value) throw fail('model_not_allowlisted');
    return value;
  }
  list() { return this.config.candidates; }
}

// Operator-supplied nonsecret evidence, bound to the credential account and exact model.
// This is an admission contract, not a claimed balance API or an automatic console verifier.
export function verifyFreeProtection(model, evidence, now = Date.now()) {
  if (model.free.expires_at && Date.parse(model.free.expires_at) <= now) throw fail('model_expired');
  if (!evidence || evidence.provider !== model.provider || evidence.model !== model.model ||
      evidence.region !== model.region || !evidence.account_reference ||
      evidence.eligibility !== 'verified' || !Number.isFinite(Date.parse(evidence.valid_until)) ||
      Date.parse(evidence.valid_until) <= now || !Number.isFinite(Date.parse(evidence.verified_at)) ||
      Date.parse(evidence.verified_at) > now) throw fail('free_protection_unverified');
  if (model.provider === 'bailian') {
    if (model.region !== 'cn-beijing' || evidence.stop_when_free_exhausted !== 'effective' ||
        evidence.key_kind !== 'general_api_key' || !evidence.platform_evidence_reference ||
        !(Date.parse(evidence.quota_expires_at) > now)) throw fail('free_protection_unverified');
  } else if (model.price.input_per_million !== 0 || model.price.output_per_million !== 0 ||
             evidence.price_input !== 0 || evidence.price_output !== 0) throw fail('nonzero_price');
  if (model.documentation_status === 'candidate_requires_official_recheck' &&
      (!evidence.official_price_verified || !evidence.official_price_reference)) throw fail('price_documentation_unverified');
}

export function freezeRequest(model, input, {real = false, evidence, now = Date.now(), taskID = 'synthetic'} = {}) {
  const keys = new Set(['messages', 'tools', 'response_format', 'max_tokens']);
  if (Object.keys(input).some(k => !keys.has(k))) throw fail('unsupported_payload_option');
  if (real) verifyFreeProtection(model, evidence, now);
  if (model.provider === 'openrouter' && (!model.model.endsWith(':free') ||
      model.price.input_per_million !== 0 || model.price.output_per_million !== 0)) throw fail('nonzero_price');
  if (!Array.isArray(input.messages) || !input.messages.length || input.messages.length > 30) throw fail('invalid_messages');
  for (const m of input.messages) {
    if (!['system', 'user', 'assistant', 'tool'].includes(m.role)) throw fail('invalid_role');
    if (typeof m.content !== 'string') {
      if (!model.capabilities.images || m.role !== 'user' || !Array.isArray(m.content)) throw fail('unsupported_images');
      for (const p of m.content) {
        if (p.type === 'text' && typeof p.text === 'string') continue;
        // Only inline synthetic image data; arbitrary remote image URLs are not fetched.
        if (p.type !== 'image_url' || !/^data:image\/(png|jpeg);base64,[A-Za-z0-9+/=]+$/.test(p.image_url?.url ?? '')) throw fail('invalid_image');
      }
    }
  }
  if (input.tools?.length && !model.capabilities.tools) throw fail('unsupported_tools');
  if (input.tools?.some(t => t.type !== 'function' || !/^[a-zA-Z0-9_]{1,64}$/.test(t.function?.name ?? '') || !t.function?.parameters)) throw fail('invalid_tools');
  if (input.response_format && (input.response_format.type !== 'json_schema' || !model.capabilities.json_schema)) throw fail('unsupported_schema');
  const payload = {model: model.model, messages: clone(input.messages), stream: true, max_tokens: input.max_tokens ?? 1024};
  if (!Number.isInteger(payload.max_tokens) || payload.max_tokens < 1 || payload.max_tokens > 4096) throw fail('invalid_max_tokens');
  if (input.tools?.length) payload.tools = clone(input.tools);
  if (input.response_format) payload.response_format = clone(input.response_format);
  if (model.provider === 'openrouter') {
    // No auto route, models fallback array, paid plugins or provider fallback upgrades.
    payload.provider = {allow_fallbacks: false, require_parameters: true, max_price: {prompt: 0, completion: 0, request: 0}};
  }
  const payloadJSON = JSON.stringify(payload);
  if (Buffer.byteLength(payloadJSON) > 1024 * 1024) throw fail('payload_too_large');
  return immutable({model: clone(model), payloadJSON, payloadHash: hash(payloadJSON), taskID,
    real, protection: real ? clone(evidence) : null, frozenAt: new Date(now).toISOString()});
}

export class CredentialProvider {
  // No default environment/file/keychain lookup. Production implements this only on the server.
  async credentialFor(_request) { throw fail('credentials_unconfigured'); }
}
