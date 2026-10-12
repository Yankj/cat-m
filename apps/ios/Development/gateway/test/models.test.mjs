import test from 'node:test';
import assert from 'node:assert/strict';
import { ModelRegistry, freezeRequest } from '../src/models.mjs';

test('a Qwen request without effective free-tier protection is denied before credentials or transport', () => {
  const registry = new ModelRegistry();
  assert.throws(() => freezeRequest(registry.select('qwen-beijing'), {
    messages: [{role: 'user', content: 'synthetic task'}]
  }, {real: true}), {code: 'free_protection_unverified'});
});

test('free routes freeze exact payload bytes and do not change when the active model changes', () => {
  const registry = new ModelRegistry();
  const input = {messages: [{role: 'user', content: 'original synthetic message'}]};
  const original = freezeRequest(registry.select('dots-free'), input);
  input.messages[0].content = 'later edit';
  const next = freezeRequest(registry.select('nemotron-free'), input);
  assert.equal(JSON.parse(original.payloadJSON).messages[0].content, 'original synthetic message');
  assert.equal(JSON.parse(original.payloadJSON).model, 'dots-studio/dots-3-note-preview:free');
  assert.equal(JSON.parse(next.payloadJSON).model, 'nvidia/nemotron-3-ultra-550b-a55b:free');
  assert.deepEqual(JSON.parse(original.payloadJSON).provider, {
    allow_fallbacks: false, require_parameters: true, max_price: {prompt: 0, completion: 0, request: 0}
  });
  assert.throws(() => freezeRequest(registry.select('dots-free'), {...input, plugins: [{id: 'web'}]}), {code:'unsupported_payload_option'});
  assert.throws(() => registry.select('auto'), {code:'model_not_allowlisted'});
});

test('Qwen protection evidence must bind region, model, credential type, account and unexpired quota', () => {
  const model = new ModelRegistry().select('qwen-beijing');
  const now = Date.parse('2026-10-11T00:00:00Z');
  const evidence = {provider:'bailian', model:model.model, region:'cn-beijing', account_reference:'synthetic-account',
    eligibility:'verified', verified_at:'2026-10-10T23:00:00Z', valid_until:'2026-10-12T00:00:00Z',
    quota_expires_at:'2026-11-01T00:00:00Z', key_kind:'general_api_key', stop_when_free_exhausted:'effective',
    platform_evidence_reference:'synthetic-console-protection-check'};
  assert.equal(freezeRequest(model, {messages:[{role:'user',content:'synthetic'}]}, {real:true, evidence, now}).real, true);
  for (const override of [{stop_when_free_exhausted:'requested'}, {key_kind:'coding_plan'}, {region:'singapore'},
    {quota_expires_at:'2026-10-10T00:00:00Z'}, {model:'qwen3.8-max'}, {eligibility:'unverified'}]) {
    assert.throws(() => freezeRequest(model, {messages:[{role:'user',content:'synthetic'}]},
      {real:true,evidence:{...evidence,...override},now}), {code:'free_protection_unverified'});
  }
});

test('expiry and unsupported capabilities fail at admission', () => {
  const r = new ModelRegistry();
  assert.throws(() => freezeRequest(r.select('dots-free'), {messages:[{role:'user',content:'synthetic'}]},
    {real:true,now:Date.parse('2026-12-31T00:00:00Z')}), {code:'model_expired'});
  assert.throws(() => freezeRequest(r.select('nemotron-free'), {messages:[{role:'user',content:[{type:'image_url',image_url:{url:'data:image/png;base64,AA=='}}]}]}), {code:'unsupported_images'});
  assert.throws(() => freezeRequest(r.select('nemotron-free'), {messages:[{role:'user',content:'synthetic'}],response_format:{type:'json_schema'}}), {code:'unsupported_schema'});
});
