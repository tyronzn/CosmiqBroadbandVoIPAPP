'use strict';

/**
 * APNs VoIP push client — Node built-ins only.
 *
 * A CallKit call cannot be raised by an ordinary alert push, and it cannot be
 * sent through FCM at all: iOS delivers VoIP wake-ups to a *PushKit* token over
 * APNs with `apns-push-type: voip`, which FCM does not send. So this speaks to
 * APNs directly over HTTP/2.
 *
 * Deliberately dependency-free. Node signs the ES256 JWT APNs requires natively
 * — `dsaEncoding: 'ieee-p1363'` produces exactly the raw r||s form JWS wants,
 * which is the one genuinely fiddly part of hand-rolling this — and `node:http2`
 * covers the transport. That is one less package to vet in a proprietary
 * product, and nothing to go stale inside a Cloud Function.
 */

const crypto = require('node:crypto');
const http2 = require('node:http2');

const HOST_PRODUCTION = 'api.push.apple.com';
const HOST_SANDBOX = 'api.sandbox.push.apple.com';

/**
 * APNs rejects a provider token older than one hour, and throttles providers
 * that mint a new one more than once every 20 minutes. 40 minutes sits
 * comfortably inside both bounds.
 */
const TOKEN_TTL_MS = 40 * 60 * 1000;

const DEFAULT_TIMEOUT_MS = 10000;

/**
 * Reasons that mean the token is dead rather than the request being wrong.
 * These should cause the stored token to be forgotten, or the gateway keeps
 * pushing to handsets that uninstalled the app months ago.
 */
const DEAD_TOKEN_REASONS = new Set([
  'BadDeviceToken',
  'Unregistered',
  'DeviceTokenNotForTopic',
  'ExpiredToken',
]);

function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/**
 * Read APNs settings from the environment.
 *
 * APNS_KEY holds the contents of the .p8 auth key. Secret managers and shell
 * env vars routinely flatten newlines to a literal backslash-n, which makes the
 * PEM unparseable, so those are restored here.
 */
function apnsConfigFromEnv(env = process.env) {
  return {
    key: String(env.APNS_KEY || '').replace(/\\n/g, '\n').trim(),
    keyId: String(env.APNS_KEY_ID || '').trim(),
    teamId: String(env.APNS_TEAM_ID || '').trim(),
    bundleId: String(env.APNS_BUNDLE_ID || 'za.co.cosmiq.voip').trim(),
    production: String(env.APNS_PRODUCTION || '').toLowerCase() === 'true',
  };
}

function isApnsConfigured(config) {
  return Boolean(config && config.key && config.keyId && config.teamId);
}

/** VoIP pushes go to the bundle id with `.voip` appended, never the bare one. */
function voipTopic(config) {
  return `${config.bundleId}.voip`;
}

function apnsHost(config) {
  return config.production ? HOST_PRODUCTION : HOST_SANDBOX;
}

/** Sign the short-lived ES256 provider token APNs authenticates with. */
function createAuthToken(config, now = Date.now()) {
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: config.keyId }));
  const claims = base64url(
    JSON.stringify({ iss: config.teamId, iat: Math.floor(now / 1000) })
  );
  const signingInput = `${header}.${claims}`;
  const signature = crypto.sign('sha256', Buffer.from(signingInput), {
    key: config.key,
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${base64url(signature)}`;
}

let cachedToken = null;

function authTokenFor(config, now = Date.now()) {
  if (
    cachedToken &&
    cachedToken.keyId === config.keyId &&
    now - cachedToken.issuedAt < TOKEN_TTL_MS
  ) {
    return cachedToken.value;
  }
  const value = createAuthToken(config, now);
  cachedToken = { value, issuedAt: now, keyId: config.keyId };
  return value;
}

/** Test seam — the module-level token cache would otherwise leak across tests. */
function _resetAuthTokenCache() {
  cachedToken = null;
}

function postNotification({
  host,
  deviceToken,
  authToken,
  topic,
  payload,
  collapseId,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  connect = http2.connect,
}) {
  return new Promise((resolve, reject) => {
    const client = connect(`https://${host}`);
    let settled = false;

    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      try {
        client.close();
      } catch (_) {
        /* already gone */
      }
      fn(value);
    };

    client.on('error', (err) => finish(reject, err));

    const body = Buffer.from(JSON.stringify(payload));
    const headers = {
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${authToken}`,
      'apns-topic': topic,
      'apns-push-type': 'voip',
      'apns-priority': '10',
      // A ringing call is worthless once it stops ringing: deliver now or drop.
      'apns-expiration': '0',
      'content-type': 'application/json',
      'content-length': String(body.length),
    };
    if (collapseId) headers['apns-collapse-id'] = collapseId;

    const req = client.request(headers);
    req.setTimeout(timeoutMs, () =>
      finish(reject, new Error('APNs request timed out'))
    );

    let status = 0;
    let raw = '';
    req.on('response', (resHeaders) => {
      status = Number(resHeaders[':status']) || 0;
    });
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      raw += chunk;
    });
    req.on('error', (err) => finish(reject, err));
    req.on('end', () => {
      let reason = '';
      if (raw) {
        try {
          reason = JSON.parse(raw).reason || '';
        } catch (_) {
          /* APNs returns a body only on failure, and not always JSON */
        }
      }
      finish(resolve, { status, reason });
    });

    req.end(body);
  });
}

/**
 * Deliver one VoIP push.
 *
 * Never throws: a push failure must not take down the call-notify request, and
 * the caller needs the outcome to decide whether to drop a dead token.
 */
async function sendVoipPush({
  config,
  deviceToken,
  payload,
  collapseId,
  now = Date.now(),
  timeoutMs,
  connect,
}) {
  if (!isApnsConfigured(config)) {
    return {
      ok: false,
      status: 0,
      reason: 'ApnsNotConfigured',
      shouldForgetToken: false,
    };
  }
  if (!deviceToken) {
    return {
      ok: false,
      status: 0,
      reason: 'MissingDeviceToken',
      shouldForgetToken: false,
    };
  }

  try {
    const result = await postNotification({
      host: apnsHost(config),
      deviceToken,
      authToken: authTokenFor(config, now),
      topic: voipTopic(config),
      payload,
      collapseId,
      timeoutMs,
      connect,
    });
    return {
      ok: result.status === 200,
      status: result.status,
      reason: result.reason,
      shouldForgetToken: DEAD_TOKEN_REASONS.has(result.reason),
    };
  } catch (err) {
    return {
      ok: false,
      status: 0,
      reason: err.message || 'ApnsRequestFailed',
      shouldForgetToken: false,
    };
  }
}

module.exports = {
  DEAD_TOKEN_REASONS,
  HOST_PRODUCTION,
  HOST_SANDBOX,
  TOKEN_TTL_MS,
  apnsConfigFromEnv,
  apnsHost,
  authTokenFor,
  createAuthToken,
  isApnsConfigured,
  sendVoipPush,
  voipTopic,
  _resetAuthTokenCache,
};
