import test from 'node:test';
import assert from 'node:assert/strict';
import { extractScheduleItems, parseICS, dedupeAgainst, dedupeKey } from '../supabase/functions/_shared/connectors/gmail-extract.mjs';
import { readConnectorConfig, connectorStatus, handleLink, handleUnlink, tokenUsable, GMAIL_SCOPE, DISCLOSURE_VERSION } from '../supabase/functions/_shared/connectors/gmail-connector.mjs';

const U1 = '11111111-1111-4111-8111-111111111111', U2 = '22222222-2222-4222-8222-222222222222';
const KEY = 'A'.repeat(43) + '=';
const msg = (id, subject, bodyText, calendarText) => ({ id, threadId: 't' + id, payload: { headers: [{ name: 'Subject', value: subject }, { name: 'From', value: 'a@example.com' }] }, bodyText, calendarText });
const ICS = 'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:abc@google.com\r\nSEQUENCE:1\r\nSUMMARY:Design re\r\n view\r\nDTSTART:20261020T020000Z\r\nDTEND:20261020T030000Z\r\nLOCATION:Room 3\\, F2\r\nEND:VEVENT\r\nEND:VCALENDAR';

test('ICS invite → meeting with UID dedupe key, folded lines and escapes handled', () => {
  const [it] = extractScheduleItems(msg('m1', 'Invitation: Design review', '', ICS));
  assert.equal(it.kind, 'meeting'); assert.equal(it.title, 'Design review'); assert.equal(it.location, 'Room 3, F2');
  assert.equal(it.start.iso, '2026-10-20T02:00:00Z'); assert.equal(it.dedupe_key, 'uid:abc@google.com'); assert.equal(it.action, 'create');
});
test('ICS cancel → action cancel', () => {
  const [it] = extractScheduleItems(msg('m2', 'Canceled', '', ICS.replace('METHOD:REQUEST', 'METHOD:CANCEL')));
  assert.equal(it.action, 'cancel');
});
test('flight confirmation (en + zh)', () => {
  assert.equal(extractScheduleItems(msg('m3', 'Your trip', 'Flight number: CA 1234 departs 2026-11-02 08:35 from PEK'))[0].title, 'Flight CA1234');
  const zh = extractScheduleItems(msg('m4', '行程确认', '航班号：MU5101，2026年11月3日 14:20 起飞'))[0];
  assert.equal(zh.kind, 'flight'); assert.equal(zh.start.iso, '2026-11-03T14:20:00');
});
test('deadline and appointment', () => {
  assert.equal(extractScheduleItems(msg('m5', '报销提交', '请于 2026-10-25 前提交，截止后不受理'))[0].kind, 'deadline');
  const a = extractScheduleItems(msg('m6', '预约成功', '您已预约 2026/10/22 09:30 牙科就诊'))[0];
  assert.equal(a.kind, 'appointment'); assert.equal(a.start.allDay, false);
});
test('newsletter / no date / invalid → nothing', () => {
  assert.deepEqual(extractScheduleItems(msg('m7', 'Weekly digest', 'Top stories this week')), []);
  assert.deepEqual(extractScheduleItems(msg('m8', 'x', 'deadline 2026-13-40')), []);
  assert.deepEqual(extractScheduleItems(null), []);
  assert.equal(parseICS('nope'), null);
});
test('dedupe: Re:/Fwd: collapse, newest SEQUENCE wins, existing keys dropped, cancels kept', () => {
  const a = extractScheduleItems(msg('a', 'Deadline: report', 'due by 2026-10-30'))[0];
  const b = extractScheduleItems(msg('b', 'Re: Deadline: report', 'due by 2026-10-30'))[0];
  assert.equal(a.dedupe_key, b.dedupe_key);
  const v1 = extractScheduleItems(msg('c', 'i', '', ICS))[0], v2 = { ...v1, sequence: 2, title: 'moved' };
  assert.equal(dedupeAgainst([v1, v2])[0].title, 'moved');
  assert.deepEqual(dedupeAgainst([a], new Set([a.dedupe_key])), []);
  const cancel = { ...v1, action: 'cancel' }; assert.equal(dedupeAgainst([cancel], new Set([cancel.dedupe_key])).length, 1);
  assert.equal(dedupeKey({ kind: 'deadline', title: 'X', start: null }), 'k:deadline:x:');
});

const cfg = env => readConnectorConfig(n => env[n]);
test('inert until OAuth client id and token key are configured; gate default on; blocklist wins', async () => {
  assert.equal(connectorStatus(cfg({}), U1).enabled, true);
  assert.equal(connectorStatus(cfg({}), U1).available, false);
  assert.equal((await handleLink(cfg({}), { subjectID: U1 }, {}, {})).status, 503);
  assert.equal((await handleLink(cfg({ CATPAW_GOOGLE_OAUTH_CLIENT_ID: 'x', CATPAW_CONNECTOR_TOKEN_KEY: 'short' }), { subjectID: U1 }, {}, {})).status, 503);
  const c = cfg({ CATPAW_GOOGLE_OAUTH_CLIENT_ID: 'x', CATPAW_CONNECTOR_TOKEN_KEY: KEY, CATPAW_FEATURE_BLOCKLIST_SUBJECTS: U2 });
  assert.equal(connectorStatus(c, U1).available, true);
  assert.equal(connectorStatus(c, U2).enabled, false);
  assert.equal((await handleLink(c, { subjectID: U2 }, {}, {})).status, 404);
  assert.equal(connectorStatus(cfg({ CATPAW_GMAIL_CONNECTOR_ENABLED: 'false' }), U1).enabled, false);
  assert.ok(!JSON.stringify(connectorStatus(c, U1)).includes(KEY));
});
const LINK = { code: '4/0AbCdEfGhIjKlMnOpQrStUv', code_verifier: 'v'.repeat(43), disclosure_version: DISCLOSURE_VERSION, consent: 'allow', account_epoch: 3 };
const C = () => cfg({ CATPAW_GOOGLE_OAUTH_CLIENT_ID: 'x', CATPAW_CONNECTOR_TOKEN_KEY: KEY });
test('link requires consent + current disclosure + PKCE; stores epoch-bound row', async () => {
  const stored = [];
  const ports = { exchangeCode: async () => ({ scope: `${GMAIL_SCOPE} openid`, refresh_token: 'rt' }), store: async r => stored.push(r), revoke: async () => {} };
  assert.equal((await handleLink(C(), { subjectID: U1 }, { ...LINK, consent: 'deny' }, ports)).status, 422);
  assert.equal((await handleLink(C(), { subjectID: U1 }, { ...LINK, disclosure_version: 'old' }, ports)).status, 422);
  assert.equal((await handleLink(C(), { subjectID: U1 }, { ...LINK, code_verifier: 'short' }, ports)).status, 422);
  assert.equal(stored.length, 0);
  assert.equal((await handleLink(C(), { subjectID: U1 }, LINK, ports)).status, 200);
  assert.deepEqual([stored[0].owner, stored[0].accountEpoch], [U1, 3]);
});
test('broader-than-readonly scope is rejected and the grant revoked', async () => {
  const revoked = [], stored = [];
  const ports = { exchangeCode: async () => ({ scope: `${GMAIL_SCOPE} https://www.googleapis.com/auth/gmail.modify`, refresh_token: 'rt' }), store: async r => stored.push(r), revoke: async t => revoked.push(t) };
  assert.equal((await handleLink(C(), { subjectID: U1 }, LINK, ports)).body.error, 'scope_not_allowed');
  assert.deepEqual(revoked, ['rt']); assert.equal(stored.length, 0);
});
test('unlink deletes row then revokes; revoke failure does not fail unlink', async () => {
  const r = await handleUnlink(C(), { subjectID: U1 }, { remove: async () => ({ refreshToken: 'rt' }), revoke: async () => { throw new Error('net'); } });
  assert.equal(r.body.linked, false);
});
test('token never usable under another account or epoch, or when parked', () => {
  const row = { owner: U1, accountEpoch: 3, state: 'active' };
  assert.ok(tokenUsable(row, { subjectID: U1, accountEpoch: 3 }));
  assert.ok(!tokenUsable(row, { subjectID: U2, accountEpoch: 3 }));
  assert.ok(!tokenUsable(row, { subjectID: U1, accountEpoch: 4 }));
  assert.ok(!tokenUsable({ ...row, state: 'parked' }, { subjectID: U1, accountEpoch: 3 }));
});
