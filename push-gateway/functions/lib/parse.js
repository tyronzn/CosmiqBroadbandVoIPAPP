'use strict';

/**
 * Pure request shaping for the push gateway.
 *
 * No Firebase, network or environment imports, so all of it can be unit tested
 * directly. This is where the guesswork about PortaSIP's request format lives,
 * which is exactly the part worth pinning down with tests.
 */

const crypto = require('node:crypto');

const IOS_PLATFORMS = new Set([
  'ios',
  'apns',
  'apns.voip',
  'voip',
  'iphone',
  'ipad',
]);

const ANDROID_PLATFORMS = new Set(['android', 'fcm', 'gcm', 'firebase']);

/**
 * Collapse the many spellings of a platform into 'ios' or 'android'.
 *
 * RFC 8599 calls these 'apns' and 'fcm' in the SIP Contact, but PortaSIP, the
 * app and a human filling in a form all spell them differently, so anything
 * recognisable is accepted. Unknown values fall back rather than throwing — a
 * mislabelled platform should still get *a* push attempt.
 */
function normalisePlatform(raw, fallback = 'android') {
  const value = String(raw || '').trim().toLowerCase();
  if (IOS_PLATFORMS.has(value)) return 'ios';
  if (ANDROID_PLATFORMS.has(value)) return 'android';
  return fallback;
}

/**
 * Map PortaSIP's request onto our fields.
 *
 * Backspace has not yet supplied the exact field names, so each value reads the
 * plausible candidates. Tighten this once the spec lands — the tests describe
 * the current contract.
 */
function parsePortaRequest(req) {
  const body = req.method === 'POST' ? req.body || {} : req.query || {};
  const caller =
    body.caller || body.from || body.cli || body['x-caller'] || 'Unknown caller';
  return {
    caller: String(caller),
    handle: String(body.handle || caller),
    account: String(body.account || body.callee || body.to || body.aor || ''),
    token: String(
      body.token || body.pn_prm || body['pn-prm'] || body.device_token || ''
    ),
    platform: normalisePlatform(
      body.platform || body.pn_provider || body['pn-provider'],
      ''
    ),
    callId: String(body.call_id || body.callid || body['call-id'] || ''),
  };
}

/**
 * The VoIP push payload.
 *
 * These three keys are read by name in ios/Runner/AppDelegate.swift. Changing
 * them here silently breaks the iOS call screen, so they are covered by tests.
 */
function voipPayload(info, { uuid = () => crypto.randomUUID() } = {}) {
  const caller = info.caller || 'Unknown caller';
  return {
    id: info.callId || uuid(),
    nameCaller: caller,
    handle: info.handle || caller,
  };
}

/** The data payload for Android's FCM wake-up. */
function fcmData(info) {
  return {
    type: 'incoming_call',
    caller: String(info.caller || 'Unknown caller'),
    callId: String(info.callId || ''),
  };
}

/**
 * Last few characters of a token, for logs.
 *
 * A device token is the address a push is delivered to, so the whole value is
 * never written to a log line; this is enough to correlate one.
 */
function tokenTail(token) {
  return String(token || '').slice(-8);
}

/**
 * Stable Firestore document id for an (account, token) pair.
 *
 * The token is hashed rather than embedded: document ids show up in logs and
 * console URLs, and a push token is a delivery address. Hashing also sidesteps
 * the characters Firestore forbids in an id, which raw FCM tokens can contain.
 */
function deviceDocId(account, token) {
  const safeAccount = String(account || "unknown").replace(/[^A-Za-z0-9._@+-]/g, "_");
  const digest = crypto
    .createHash("sha256")
    .update(String(token || ""))
    .digest("hex")
    .slice(0, 16);
  return safeAccount + "__" + digest;
}

module.exports = {
  deviceDocId,
  fcmData,
  normalisePlatform,
  parsePortaRequest,
  tokenTail,
  voipPayload,
};
