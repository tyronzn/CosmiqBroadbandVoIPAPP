'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  deviceDocId,
  fcmData,
  normalisePlatform,
  parsePortaRequest,
  tokenTail,
  voipPayload,
} = require('../lib/parse');

const post = (body) => ({ method: 'POST', body, query: {} });
const get = (query) => ({ method: 'GET', body: {}, query });

test('normalisePlatform collapses the spellings of iOS', () => {
  for (const value of ['ios', 'APNS', 'apns.voip', 'voip', 'iPhone']) {
    assert.equal(normalisePlatform(value), 'ios');
  }
});

test('normalisePlatform collapses the spellings of Android', () => {
  for (const value of ['android', 'FCM', 'gcm', 'firebase']) {
    assert.equal(normalisePlatform(value), 'android');
  }
});

test('normalisePlatform falls back rather than throwing on junk', () => {
  // A mislabelled platform should still get some push attempt.
  assert.equal(normalisePlatform('symbian'), 'android');
  assert.equal(normalisePlatform(undefined, ''), '');
});

test('parsePortaRequest reads the primary field names', () => {
  const info = parsePortaRequest(
    post({
      caller: '0827644298',
      account: '27877299809',
      token: 'abc123',
      platform: 'apns',
      call_id: 'call-1',
    })
  );
  assert.equal(info.caller, '0827644298');
  assert.equal(info.account, '27877299809');
  assert.equal(info.token, 'abc123');
  assert.equal(info.platform, 'ios');
  assert.equal(info.callId, 'call-1');
});

test('parsePortaRequest accepts the RFC 8599 spellings', () => {
  const info = parsePortaRequest(
    post({ from: '0821112222', aor: '2000', 'pn-prm': 'tok', 'pn-provider': 'fcm' })
  );
  assert.equal(info.caller, '0821112222');
  assert.equal(info.account, '2000');
  assert.equal(info.token, 'tok');
  assert.equal(info.platform, 'android');
});

test('parsePortaRequest reads the query string on GET', () => {
  const info = parsePortaRequest(get({ cli: '0123', callee: '2001' }));
  assert.equal(info.caller, '0123');
  assert.equal(info.account, '2001');
});

test('parsePortaRequest defaults a missing caller instead of blanking it', () => {
  assert.equal(parsePortaRequest(post({})).caller, 'Unknown caller');
});

test('parsePortaRequest leaves platform empty when unstated', () => {
  // So resolveTargets can fall back to the stored platform rather than
  // assuming Android for an iPhone.
  assert.equal(parsePortaRequest(post({ account: '2000' })).platform, '');
});

test('voipPayload matches the keys AppDelegate.swift reads', () => {
  // id / nameCaller / handle are read by name in the Swift. Renaming any of
  // them silently breaks the iOS call screen.
  const payload = voipPayload({ caller: '0827644298', callId: 'c-1' });
  assert.deepEqual(Object.keys(payload).sort(), ['handle', 'id', 'nameCaller']);
  assert.equal(payload.id, 'c-1');
  assert.equal(payload.nameCaller, '0827644298');
  assert.equal(payload.handle, '0827644298');
});

test('voipPayload generates an id when the call has none', () => {
  const payload = voipPayload({ caller: 'x' }, { uuid: () => 'generated' });
  assert.equal(payload.id, 'generated');
});

test('fcmData carries the fields the Android client expects', () => {
  const data = fcmData({ caller: '0827644298', callId: 'c-9' });
  assert.equal(data.type, 'incoming_call');
  assert.equal(data.caller, '0827644298');
  assert.equal(data.callId, 'c-9');
});

test('tokenTail never returns the whole token', () => {
  const token = 'a'.repeat(64) + 'ZZZZZZZZ';
  assert.equal(tokenTail(token), 'ZZZZZZZZ');
  assert.equal(tokenTail(''), '');
  assert.equal(tokenTail(undefined), '');
});

test('deviceDocId is stable and never embeds the raw token', () => {
  const id = deviceDocId('27877299809', 'secret-token-value');
  assert.equal(id, deviceDocId('27877299809', 'secret-token-value'));
  assert.ok(!id.includes('secret-token-value'));
  assert.ok(id.startsWith('27877299809__'));
});

test('deviceDocId strips characters Firestore rejects in an id', () => {
  const id = deviceDocId('user/name', 'tok');
  assert.ok(!id.includes('/'));
});

test('deviceDocId separates different tokens for one account', () => {
  assert.notEqual(deviceDocId('2000', 'token-a'), deviceDocId('2000', 'token-b'));
});
