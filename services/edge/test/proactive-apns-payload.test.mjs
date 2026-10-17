import test from 'node:test'; import assert from 'node:assert/strict';
import { apnsPayload } from '../supabase/functions/_shared/proactive/apns-payload.mjs';

test('PR90 #2: APNs payload follows the level — notify is a normal alert, only interrupt is time-sensitive', () => {
  const raw = d => apnsPayload({ kind: 'apns' }, { id: 'e', title: 't', body: 'b', kind: 'proactive_decision', payload: { decision: d } }, 'app.catpaw', 0);
  const p = d => raw(d).body.aps;
  assert.equal(p('notify')['interruption-level'], 'active'); assert.equal(p('notify').sound, 'default');
  assert.equal(p('interrupt')['interruption-level'], 'time-sensitive');
  assert.equal(raw('card'), null, 'card/silent are never pushed');
});

test('AccountEpoch: APNs payload carries the account and the decision; event_id is the shared delivery id', () => {
  const p = apnsPayload({ kind: 'apns' }, { id: 'E1', user_id: 'U-1', title: 't', body: 'b', kind: 'proactive_decision', payload: { decision: 'notify' } }, 'app.catpaw', 0).body.catpaw;
  assert.equal(p.account, 'U-1'); assert.equal(p.decision, 'notify'); assert.equal(p.event_id, 'E1');
});
