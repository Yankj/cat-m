import test from 'node:test';
import assert from 'node:assert/strict';
import {edgeHandler} from '../../../services/edge/supabase/functions/_shared/bootstrap.ts';
import {driver} from './postgres-boundary.mjs';
import {check, latch} from './helpers.mjs';

const values = {
  SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co',
  CATPAW_PUBLISHABLE_KEY: 'synthetic-public-fixture',
  CATPAW_DATABASE_URL: 'postgres://synthetic-fixture.invalid/unused',
  CATPAW_PRIVATE_MODEL_KEY: 'synthetic-model-disabled',
  CATPAW_TICK_HMAC_KEY: 'synthetic-tick-disabled',
  CATPAW_MEMORY_GUARD_KEY: 'synthetic-guard-disabled',
  CATPAW_VISION_LIVE_ENABLED: 'false',
};
const make = (get = name => values[name]) => edgeHandler('api', get, () => { throw Error('family_qa_unexpected_retained_job'); });
const health = handler => handler(new Request('https://family-fixture.invalid/healthz'));
const statuses = async requests => Promise.all((await Promise.all(requests)).map(async r => ({status: r.status, body: await r.json()})));

test('BOOT-01 healthy initialization: 100 concurrent requests share one real bootstrap initialization', {timeout: 10000}, async t => {
  driver.reset();
  const barrier = latch(); driver.barrier = barrier.promise;
  const handler = make(), pending = Array.from({length: 100}, () => health(handler));
  barrier.resolve();
  const rows = await statuses(pending);
  check(t, 'BOOT-01', {ok: rows.filter(r => r.status === 200 && r.body.status === 'alive').length, driverCreated: driver.created, roleQueries: driver.roleQueries, reserved: driver.reserved, released: driver.released}, {ok: 100, driverCreated: 1, roleQueries: 1, reserved: 1, released: 1}, {ok: 100, driverCreated: 1, roleQueries: 1, reserved: 1, released: 1}, 'Driver boundary only; no real PostgreSQL connections.');
});

test('BOOT-02 one rejected initialization must recover on the same handler for 100 subsequent concurrent retries', {timeout: 10000}, async t => {
  driver.reset(); driver.failRole = true;
  const handler = make(), first = await health(handler);
  assert.equal(first.status, 503);
  assert.equal(driver.released, 1, 'failed reserved connection is released');
  driver.failRole = false;
  const rows = await statuses(Array.from({length: 100}, () => health(handler)));
  t.diagnostic('FAMILY_BOOTSTRAP_DRIVER ' + JSON.stringify({id: 'BOOT-02', driverCreated: driver.created}));
  check(t, 'BOOT-02', {recovered: rows.filter(r => r.status === 200).length, unavailable: rows.filter(r => r.status === 503).length, boundedConstructors: driver.created <= 2, roleQueries: driver.roleQueries, released: driver.released, balancedReservations: driver.reserved === driver.released}, {recovered: 0, unavailable: 100, boundedConstructors: true, roleQueries: 1, released: 1, balancedReservations: true}, {recovered: 100, unavailable: 0, boundedConstructors: true, roleQueries: 2, released: 2, balancedReservations: true}, 'One initial failure plus 100 concurrent retries. Reusing a pool is allowed; immediate retry target and bounded-backoff timing still need M0 freeze.');
});

test('BOOT-03 missing configuration fails closed before a driver is constructed', async t => {
  driver.reset();
  const response = await health(make(() => undefined));
  check(t, 'BOOT-03', {status: response.status, code: (await response.json()).error.code, driverCreated: driver.created}, {status: 503, code: 'configuration_missing', driverCreated: 0}, {status: 503, code: 'configuration_missing', driverCreated: 0});
});
