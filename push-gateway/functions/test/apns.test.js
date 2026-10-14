'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');

const {
  apnsConfigFromEnv,
  apnsHost,
  authTokenFor,
  createAuthToken,
  isApnsConfigured,
  sendVoipPush,
  voipTopic,
  _resetAuthTokenCache,
} = require('../lib/apns');

const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', {
  namedCurve: 'P-256',
});
const KEY_PEM = privateKey.export({ type: 'pkcs8', format: 'pem' });

const config = (over) =>
  Object.assign(
    {
      key: KEY_PEM,
      keyId: 'KEY123',
      teamId: 'TEAM456',
      bundleId: 'za.co.cosmiq.voip',
      production: false,
    },
    over
  );

function b64urlToBuf(value) {
  return Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

/**
 * Stand-in for node:http2 connect. Records the headers and body the client
 * sends, which is the part that actually has to be right.
 */
function mockConnect(capture, options) {
  const settings = Object.assign({ status: 200, body: '' }, options);
  return () => {
    const client = new EventEmitter();
    client.close = () => {
      capture.closed = true;
    };
    client.request = (headers) => {
      capture.headers = headers;
      const req = new EventEmitter();
      req.setTimeout = () => {};
      req.setEncoding = () => {};
      req.end = (payload) => {
        capture.body = payload ? payload.toString() : '';
        process.nextTick(() => {
          req.emit('response', { ':status': settings.status });
          if (settings.body) req.emit('data', settings.body);
          req.emit('end');
        });
      };
      return req;
    };
    return client;
  };
}

test('apnsConfigFromEnv restores newlines flattened by a secret store', () => {
  // Secret managers and shell env vars routinely turn the .p8 newlines into a
  // literal backslash-n, which leaves the PEM unparseable. Built by char code
  // so the expectation cannot be lost to escaping.
  const backslashN = String.fromCharCode(92) + 'n';
  const realNewline = String.fromCharCode(10);
  const flattened =
    '-----BEGIN PRIVATE KEY-----' +
    backslashN +
    'abc' +
    backslashN +
    '-----END PRIVATE KEY-----';

  const cfg = apnsConfigFromEnv({
    APNS_KEY: flattened,
    APNS_KEY_ID: 'K',
    APNS_TEAM_ID: 'T',
  });

  assert.ok(cfg.key.includes(realNewline), 'real newlines restored');
  assert.ok(!cfg.key.includes(backslashN), 'literal backslash-n removed');
});

test('apnsConfigFromEnv defaults the bundle id and sandbox environment', () => {
  const cfg = apnsConfigFromEnv({});
  assert.equal(cfg.bundleId, 'za.co.cosmiq.voip');
  assert.equal(cfg.production, false);
});

test('apnsConfigFromEnv only treats the exact string true as production', () => {
  assert.equal(apnsConfigFromEnv({ APNS_PRODUCTION: 'TRUE' }).production, true);
  assert.equal(apnsConfigFromEnv({ APNS_PRODUCTION: '1' }).production, false);
});

test('isApnsConfigured requires key, key id and team id', () => {
  assert.equal(isApnsConfigured(config()), true);
  assert.equal(isApnsConfigured(config({ key: '' })), false);
  assert.equal(isApnsConfigured(config({ keyId: '' })), false);
  assert.equal(isApnsConfigured(config({ teamId: '' })), false);
});

test('voipTopic appends dot voip to the bundle id', () => {
  // Sending to the bare bundle id will not wake the app.
  assert.equal(voipTopic(config()), 'za.co.cosmiq.voip.voip');
});

test('apnsHost switches between sandbox and production', () => {
  assert.equal(apnsHost(config({ production: false })), 'api.sandbox.push.apple.com');
  assert.equal(apnsHost(config({ production: true })), 'api.push.apple.com');
});

test('createAuthToken produces a verifiable ES256 JWT', () => {
  const token = createAuthToken(config(), 1700000000000);
  const parts = token.split('.');
  assert.equal(parts.length, 3);

  const header = JSON.parse(b64urlToBuf(parts[0]).toString());
  assert.equal(header.alg, 'ES256');
  assert.equal(header.kid, 'KEY123');

  const claims = JSON.parse(b64urlToBuf(parts[1]).toString());
  assert.equal(claims.iss, 'TEAM456');
  assert.equal(claims.iat, 1700000000);

  // JWS requires the raw r-then-s form, not the DER encoding OpenSSL defaults
  // to. Getting this wrong is the classic hand-rolled-APNs bug.
  const signature = b64urlToBuf(parts[2]);
  assert.equal(signature.length, 64, 'ES256 signature must be raw r then s');

  const verified = crypto.verify(
    'sha256',
    Buffer.from(parts[0] + '.' + parts[1]),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    signature
  );
  assert.ok(verified, 'APNs must be able to verify the signature');
});

test('authTokenFor reuses a token inside the refresh window', () => {
  // APNs throttles providers that mint tokens more often than every 20 minutes.
  _resetAuthTokenCache();
  const cfg = config();
  const first = authTokenFor(cfg, 1700000000000);
  const second = authTokenFor(cfg, 1700000000000 + 10 * 60 * 1000);
  assert.equal(first, second);
});

test('authTokenFor mints a new token once the window passes', () => {
  // And APNs rejects any token older than an hour.
  _resetAuthTokenCache();
  const cfg = config();
  const first = authTokenFor(cfg, 1700000000000);
  const later = authTokenFor(cfg, 1700000000000 + 41 * 60 * 1000);
  assert.notEqual(first, later);
});

test('sendVoipPush sends the headers that make iOS wake for CallKit', async () => {
  _resetAuthTokenCache();
  const capture = {};
  const result = await sendVoipPush({
    config: config(),
    deviceToken: 'DEVICETOKEN',
    payload: { id: 'c-1', nameCaller: '0827644298', handle: '0827644298' },
    connect: mockConnect(capture),
  });

  assert.equal(result.ok, true);
  assert.equal(capture.headers['apns-push-type'], 'voip');
  assert.equal(capture.headers['apns-topic'], 'za.co.cosmiq.voip.voip');
  assert.equal(capture.headers['apns-priority'], '10');
  assert.equal(capture.headers['apns-expiration'], '0');
  assert.equal(capture.headers[':path'], '/3/device/DEVICETOKEN');
  assert.ok(capture.headers.authorization.startsWith('bearer '));
  assert.deepEqual(JSON.parse(capture.body), {
    id: 'c-1',
    nameCaller: '0827644298',
    handle: '0827644298',
  });
  assert.ok(capture.closed, 'the http2 session must be closed');
});

test('sendVoipPush flags a dead token so the caller can forget it', async () => {
  _resetAuthTokenCache();
  const result = await sendVoipPush({
    config: config(),
    deviceToken: 'GONE',
    payload: {},
    connect: mockConnect({}, {
      status: 410,
      body: JSON.stringify({ reason: 'Unregistered' }),
    }),
  });
  assert.equal(result.ok, false);
  assert.equal(result.status, 410);
  assert.equal(result.reason, 'Unregistered');
  assert.equal(result.shouldForgetToken, true);
});

test('sendVoipPush keeps the token on a transient failure', async () => {
  _resetAuthTokenCache();
  const result = await sendVoipPush({
    config: config(),
    deviceToken: 'STILLGOOD',
    payload: {},
    connect: mockConnect({}, {
      status: 503,
      body: JSON.stringify({ reason: 'ServiceUnavailable' }),
    }),
  });
  assert.equal(result.ok, false);
  assert.equal(result.shouldForgetToken, false);
});

test('sendVoipPush reports rather than throws when APNs is unconfigured', async () => {
  // A push failure must never take down the call-notify request.
  const result = await sendVoipPush({
    config: config({ key: '' }),
    deviceToken: 'X',
    payload: {},
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'ApnsNotConfigured');
});

test('sendVoipPush survives a connection error', async () => {
  _resetAuthTokenCache();
  const result = await sendVoipPush({
    config: config(),
    deviceToken: 'X',
    payload: {},
    connect: () => {
      const client = new EventEmitter();
      client.close = () => {};
      client.request = () => {
        throw new Error('socket exploded');
      };
      return client;
    },
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'socket exploded');
});
