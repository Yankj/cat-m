import test from 'node:test';
import assert from 'node:assert/strict';
import { devicePromptFor, DEVICE_TOOLS } from '../supabase/functions/_shared/core/src/device-call.mjs';
import { chatPrompt } from '../supabase/functions/_shared/core/src/tools.mjs';
import { readConfig, readDailyCallLimit } from '../supabase/functions/_shared/config.mjs';

const defs = DEVICE_TOOLS.map(t => t.definition);
test('device tools offered: calendar denial removed and tool guidance added', () => {
  assert.match(chatPrompt, /No email\/calendar/);
  const p = devicePromptFor(chatPrompt, defs);
  assert.doesNotMatch(p, /email\/calendar/);
  assert.match(p, /calendar_create/);
  assert.match(p, /call the matching tool/);
});
test('no device tools: prompt unchanged', () => {
  assert.equal(devicePromptFor(chatPrompt, []), chatPrompt);
  assert.equal(devicePromptFor(chatPrompt, [{ type: 'function', function: { name: 'agent_status' } }]), chatPrompt);
});
test('calendar_create description mentions Chinese calendar words', () => {
  assert.match(defs.find(d => d.function.name === 'calendar_create').function.description, /日历/);
});
test('daily limit env', () => {
  assert.equal(readDailyCallLimit(undefined), 300);
  assert.equal(readDailyCallLimit('200'), 200);
  assert.equal(readDailyCallLimit('abc'), 300);
  assert.equal(readDailyCallLimit('0'), 300);
  assert.equal(readDailyCallLimit('-5'), 300);
  assert.equal(readDailyCallLimit('1.5'), 300);
  assert.equal(readDailyCallLimit(' 50 '), 50);
  try {
    const c = readConfig(k => ({ CATPAW_DAILY_CALL_LIMIT: '150', CATPAW_DAILY_MODEL_CALL_EXEMPT_SUBJECTS: '4AFDA38B-D35D-4CD7-A786-2F80A1910740,bad' })[k]);
    assert.equal(c.dailyCallLimit, 150); assert.ok(c.dailyCallExempt.has('4afda38b-d35d-4cd7-a786-2f80a1910740')); assert.equal(c.dailyCallExempt.size, 1);
  } catch (e) { if (!/not_configured|missing|required/i.test(String(e?.message ?? e))) throw e; }
});
