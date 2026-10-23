import assert from 'node:assert/strict';
export const targetMode = process.env.FAMILY_QA_MODE === 'targets';
export const UID = '00000000-0000-4000-8000-000000000001';
export const OTHER_UID = '00000000-0000-4000-8000-000000000002';
export const T0 = Date.parse('2026-10-22T12:00:00Z');
export function latch() { let resolve; const promise = new Promise(r => { resolve = r; }); return {promise, resolve}; }
export function check(t, id, actual, current, target, limitation = null) {
  let targetPass = true;
  try { assert.deepEqual(actual, target); } catch { targetPass = false; }
  t.diagnostic('FAMILY_OBSERVATION ' + JSON.stringify({id, actual, target, product_status: targetPass ? 'PASS' : 'FAIL', limitation}));
  assert.deepEqual(actual, targetMode ? target : current, id + (targetMode ? ': target behavior' : ': pinned current behavior'));
  assert.equal(globalThis.__familyQANetwork.attempts.length, 0, 'maintenance source attempted external network');
}
