import test from 'node:test'; import assert from 'node:assert/strict';
import { parseStrict, canonical, requestHash, validateCommand } from '../supabase/functions/_shared/family/contract.mjs';
import { extractItemsFromText } from '../supabase/functions/_shared/family/extract-text.mjs';
import { derivedId } from '../supabase/functions/_shared/family/captures.mjs';
test('strict JSON: duplicate keys, floats, exponents, unsafe ints rejected', () => {
  for (const t of ['{"a":1,"a":2}', '{"a":1.5}', '{"a":1e3}', '{"a":9007199254740993}', '{"a":1}x']) assert.throws(() => parseStrict(t), /json_invalid/);
  assert.deepEqual(parseStrict('{"b":[1,"x",null,true],"a":{"c":-2}}'), { b: [1, 'x', null, true], a: { c: -2 } });
});
test('canonical hash: key order independent, missing keys = null, actor ignored', async () => {
  const id = '6f1c2c2e-7b1a-4c0a-9d2e-1a2b3c4d5e6f', hh = '3c1a9b2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d';
  assert.equal(canonical({ b: 1, a: [2, { d: null, c: '中' }] }), '{"a":[2,{"c":"中","d":null}],"b":1}');
  const a = await requestHash({ command_id: id, type: 'x.y', household_id: hh, payload: { z: 1, a: 2 } });
  const b = await requestHash({ payload: { a: 2, z: 1 }, household_id: hh, type: 'x.y', command_id: id, actor_user_id: 'u' });
  assert.equal(a, b); assert.match(a, /^[0-9a-f]{64}$/);
  assert.throws(() => validateCommand({ command_id: id, household_id: hh, type: 'household.ensure' }, { householdFromPath: hh }), /command_invalid/);
  assert.throws(() => validateCommand({ command_id: id, household_id: hh, type: 'child.upsert' }, { householdFromPath: '00000000-0000-4000-8000-000000000000' }), /command_invalid/);
});
test('text extractor keeps unknowns null', () => {
  const [c] = extractItemsFromText('周五3点接孩子', { today: '2026-10-23', children: [] });
  assert.equal(c.local_time, null); assert.equal(c.local_date, '2026-10-23');
  const [d] = extractItemsFromText('下周三下午4点半游泳课，带泳镜和毛巾', { today: '2026-10-23', children: [] });
  assert.deepEqual([d.local_date, d.local_time, d.bring], ['2026-10-28', '16:30', ['泳镜', '毛巾']]);
});
test('derived capture ids are stable UUIDs', async () => {
  const x = await derivedId('6f1c2c2e-7b1a-4c0a-9d2e-1a2b3c4d5e6f', 0);
  assert.equal(x, await derivedId('6f1c2c2e-7b1a-4c0a-9d2e-1a2b3c4d5e6f', 0)); assert.match(x, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
