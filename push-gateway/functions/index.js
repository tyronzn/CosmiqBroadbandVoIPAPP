'use strict';

/**
 * Cosmiq VoIP — push notification gateway (Firebase Cloud Functions).
 *
 * Architecture, as confirmed by Backspace: PortaSIP is the SIP platform and
 * call controller; it does not talk to Apple or Google itself. This gateway is
 * that bridge. On an incoming call PortaSIP calls notifyIncomingCall, which
 * delivers the push that wakes the handset so it can register and answer.
 *
 *   Caller -> PortaSIP -> [notifyIncomingCall] -> APNs (iOS) / FCM (Android)
 *
 * The two platforms take deliberately different routes:
 *   - Android: a high-priority FCM data message.
 *   - iOS: a VoIP push sent straight to APNs against a PushKit token. This
 *     cannot go through FCM, which does not send apns-push-type voip, and
 *     without that header iOS will not wake the app for CallKit.
 */

const { onRequest } = require('firebase-functions/v2/https');
const { logger } = require('firebase-functions');
const admin = require('firebase-admin');

const {
  deviceDocId,
  fcmData,
  normalisePlatform,
  parsePortaRequest,
  tokenTail,
  voipPayload,
} = require('./lib/parse');

const {
  apnsConfigFromEnv,
  isApnsConfigured,
  sendVoipPush,
  voipTopic,
} = require('./lib/apns');

admin.initializeApp();
const db = admin.firestore();

const DEVICE_TOKENS = 'deviceTokens';

/**
 * Shared secret PortaSIP must present, as header x-gateway-secret or ?secret=.
 * Set with: firebase functions:secrets:set GATEWAY_SECRET
 * Left empty the gateway is open, which is only acceptable on an emulator.
 */
const GATEWAY_SECRET = process.env.GATEWAY_SECRET || '';

function isAuthorised(req) {
  if (!GATEWAY_SECRET) return true;
  const provided = req.get('x-gateway-secret') || req.query.secret;
  return provided === GATEWAY_SECRET;
}

/** Called by PortaSIP when a call arrives for one of our accounts. */
exports.notifyIncomingCall = onRequest(async (req, res) => {
  if (!isAuthorised(req)) {
    return res.status(401).json({ error: 'unauthorized' });
  }

  const info = parsePortaRequest(req);
  logger.info('incoming-call notify', {
    account: info.account,
    caller: info.caller,
    callId: info.callId,
    platform: info.platform,
    tokenTail: tokenTail(info.token),
  });

  if (!info.token && !info.account) {
    return res.status(400).json({ error: 'missing token/account' });
  }

  const targets = await resolveTargets(info);
  if (targets.length === 0) {
    return res
      .status(404)
      .json({ error: 'no device token', account: info.account });
  }

  const results = await Promise.all(targets.map((t) => sendPush(t, info)));
  const sent = results.filter((r) => r.ok).length;

  // 200 even when every push failed: PortaSIP should not retry a call
  // notification, and the body carries the detail for debugging.
  return res.json({
    ok: sent > 0,
    sent,
    targets: targets.length,
    results: results.map((r) => ({
      platform: r.platform,
      ok: r.ok,
      reason: r.reason,
    })),
  });
});

/**
 * Prefer a token relayed by PortaSIP (RFC 8599 pn-prm); otherwise look the
 * account up in Firestore, where registerDeviceToken keeps it.
 */
async function resolveTargets(info) {
  if (info.token) {
    return [
      {
        token: info.token,
        platform: normalisePlatform(info.platform),
        docId: null,
      },
    ];
  }
  const snap = await db
    .collection(DEVICE_TOKENS)
    .where('account', '==', info.account)
    .get();
  return snap.docs.map((doc) => ({
    token: doc.get('token'),
    platform: normalisePlatform(doc.get('platform')),
    docId: doc.id,
  }));
}

function sendPush(target, info) {
  return target.platform === 'ios'
    ? sendIosVoipPush(target, info)
    : sendAndroidPush(target, info);
}

async function sendIosVoipPush(target, info) {
  const config = apnsConfigFromEnv();
  if (!isApnsConfigured(config)) {
    logger.error('apns not configured - set APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID');
    return { ok: false, platform: 'ios', reason: 'ApnsNotConfigured' };
  }

  const result = await sendVoipPush({
    config,
    deviceToken: target.token,
    payload: voipPayload(info),
  });

  if (!result.ok) {
    logger.error('apns voip push failed', {
      status: result.status,
      reason: result.reason,
      tokenTail: tokenTail(target.token),
    });
    if (result.shouldForgetToken) await forgetToken(target, result.reason);
  }
  return { ok: result.ok, platform: 'ios', reason: result.reason };
}

async function sendAndroidPush(target, info) {
  try {
    await admin.messaging().send({
      token: target.token,
      data: fcmData(info),
      android: { priority: 'high' },
    });
    return { ok: true, platform: 'android' };
  } catch (err) {
    const info2 = err && err.errorInfo;
    const code = (info2 && info2.code) || (err && err.code) || '';
    logger.error('fcm push failed', {
      code,
      tokenTail: tokenTail(target.token),
      err: err.message,
    });
    // Only this code means the token is genuinely dead. Other failures may be
    // transient or a malformed message, and must not delete a working token.
    if (String(code).includes('registration-token-not-registered')) {
      await forgetToken(target, code);
    }
    return { ok: false, platform: 'android', reason: code || 'FcmSendFailed' };
  }
}

/**
 * Drop a token the platform reports as dead, so the gateway stops pushing to
 * handsets that uninstalled the app.
 */
async function forgetToken(target, reason) {
  if (!target.docId) return;
  try {
    await db.collection(DEVICE_TOKENS).doc(target.docId).delete();
    logger.info('forgot dead device token', { docId: target.docId, reason });
  } catch (err) {
    logger.error('could not delete dead token', { err: err.message });
  }
}

/**
 * Called by the app on login and whenever the token changes, recording the
 * SIP-account to device-token mapping. Needed only when PortaSIP does not relay
 * the token itself; harmless to call either way.
 *
 * iOS must register its PushKit (VoIP) token here, not its FCM token - they are
 * different tokens for the same device.
 */
exports.registerDeviceToken = onRequest(async (req, res) => {
  const body = req.method === 'POST' ? req.body || {} : req.query;
  const { account, token } = body;
  if (!account || !token) {
    return res.status(400).json({ error: 'account and token required' });
  }

  const platform = normalisePlatform(body.platform);
  await db
    .collection(DEVICE_TOKENS)
    .doc(deviceDocId(account, token))
    .set(
      {
        account: String(account),
        token: String(token),
        platform,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

  logger.info('registered device token', {
    account,
    platform,
    tokenTail: tokenTail(token),
  });
  return res.json({ ok: true, platform });
});

/** Called on sign-out, so a handed-on handset stops receiving the calls. */
exports.unregisterDeviceToken = onRequest(async (req, res) => {
  const body = req.method === 'POST' ? req.body || {} : req.query;
  const { account, token } = body;
  if (!account || !token) {
    return res.status(400).json({ error: 'account and token required' });
  }
  await db.collection(DEVICE_TOKENS).doc(deviceDocId(account, token)).delete();
  return res.json({ ok: true });
});

/**
 * Deployment check. Reports whether APNs is wired up and which environment it
 * targets, revealing no secret - useful for confirming a deploy and for
 * Backspace to verify reachability.
 */
exports.health = onRequest(async (req, res) => {
  const config = apnsConfigFromEnv();
  return res.json({
    ok: true,
    fcm: true,
    apnsConfigured: isApnsConfigured(config),
    apnsEnvironment: config.production ? 'production' : 'sandbox',
    voipTopic: voipTopic(config),
    authRequired: Boolean(GATEWAY_SECRET),
  });
});
