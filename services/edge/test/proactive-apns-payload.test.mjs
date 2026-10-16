import test from 'node:test'; import assert from 'node:assert/strict';
import { apnsPayload } from '../supabase/functions/_shared/proactive/apns-payload.mjs';

test('PR90 #2: APNs payload follows the level — notify is a normal alert, only interrupt is time-sensitive', () => {
  const raw = d => apnsPayload({ kind: 'apns' }, { id: 'e', title: 't', body: 'b', kind: 'proactive_decision', payload: { decision: d } }, 'app.catpaw', 0);
  const p = d => raw(d).body.aps;
  assert.equal(p('notify')['interruption-level'], 'active'); assert.equal(p('notify').sound, 'default');
  assert.equal(p('interrupt')['interruption-level'], 'time-sensitive');
  assert.equal(raw('card'), null, 'card/silent are never pushed');
});
