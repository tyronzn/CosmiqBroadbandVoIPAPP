/**
 * Cosmiq VoIP — Push Notification Gateway (Firebase Cloud Functions).
 *
 * Architecture (per Backspace): PortaSIP is the SIP platform / call controller;
 * THIS gateway is the bridge to Apple (APNs) and Google (FCM). On an incoming
 * call, PortaSIP calls `notifyIncomingCall`, which delivers the push that wakes
 * the app so it can re-register and answer.
 *
 *   Caller -> PortaSIP -> [notifyIncomingCall] -> FCM / APNs -> phone wakes
 *
 * The exact request format PortaSIP sends is pending Backspace's spec — see the
 * TODO in parsePortaRequest(). Everything else is ready.
 */

const { onRequest } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

// Shared secret PortaSIP must present (header `x-gateway-secret` or `?secret=`).
// Set it with:  firebase functions:secrets:set GATEWAY_SECRET   (or env var).
// Coordinate the exact auth scheme with Backspace.
const GATEWAY_SECRET = process.env.GATEWAY_SECRET || "";

/**
 * Called by PortaSIP when there's an incoming call for one of our accounts.
 */
exports.notifyIncomingCall = onRequest(async (req, res) => {
  if (GATEWAY_SECRET) {
    const provided = req.get("x-gateway-secret") || req.query.secret;
    if (provided !== GATEWAY_SECRET) {
      return res.status(401).json({ error: "unauthorized" });
    }
  }

  const info = parsePortaRequest(req);
  logger.info("incoming-call notify", info);

  if (!info.token && !info.account) {
    return res.status(400).json({ error: "missing token/account" });
  }

  // Prefer a device token relayed by PortaSIP (RFC 8599 pn-prm); otherwise look
  // it up by SIP account in Firestore (populated by registerDeviceToken).
  let targets = [];
  if (info.token) {
    targets = [{ token: info.token, platform: info.platform || "android" }];
  } else {
    const snap = await db
      .collection("deviceTokens")
      .where("account", "==", info.account)
      .get();
    targets = snap.docs.map((d) => d.data());
  }

  if (targets.length === 0) {
    return res.status(404).json({ error: "no device token", account: info.account });
  }

  const results = await Promise.all(targets.map((t) => sendPush(t, info)));
  const sent = results.filter(Boolean).length;
  return res.json({ ok: sent > 0, sent, targets: targets.length });
});

/**
 * Called by the app (on login / FCM token refresh) to register the
 * SIP-account -> device-token mapping. Used only if PortaSIP does NOT relay the
 * token itself; harmless to call regardless.
 */
exports.registerDeviceToken = onRequest(async (req, res) => {
  const body = req.method === "POST" ? req.body || {} : req.query;
  const { account, token, platform } = body;
  if (!account || !token) {
    return res.status(400).json({ error: "account and token required" });
  }
  await db
    .collection("deviceTokens")
    .doc(`${account}__${String(token).slice(-20)}`)
    .set(
      {
        account,
        token,
        platform: platform || "android",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  return res.json({ ok: true });
});

/**
 * Map PortaSIP's request to our fields. PortaSIP's actual field names are
 * pending Backspace — this reads the common candidates so it works for most
 * formats; tighten it once we have the spec.
 */
function parsePortaRequest(req) {
  const b = req.method === "POST" ? req.body || {} : req.query;
  return {
    caller: b.caller || b.from || b.cli || b["x-caller"] || "Unknown",
    account: b.account || b.callee || b.to || b.aor || "",
    token: b.token || b.pn_prm || b["pn-prm"] || b.device_token || "",
    platform: (b.platform || b.pn_provider || b["pn-provider"] || "").toLowerCase(),
    callId: b.call_id || b.callid || b["call-id"] || "",
  };
}

/**
 * Send the wake-up push. Android: high-priority FCM data message. iOS: an APNs
 * alert via FCM. NOTE: a proper iOS CallKit experience needs a *VoIP* push
 * (apns-push-type: voip) to a PushKit token over a dedicated APNs channel —
 * that's a follow-on with the iOS CallKit work; this covers Android fully and
 * gives iOS a notification in the meantime.
 */
async function sendPush(target, info) {
  const message = {
    token: target.token,
    data: {
      type: "incoming_call",
      caller: String(info.caller || "Unknown"),
      callId: String(info.callId || ""),
    },
    android: { priority: "high" },
    apns: {
      headers: { "apns-priority": "10", "apns-push-type": "alert" },
      payload: {
        aps: {
          alert: { title: "Incoming call", body: String(info.caller || "Unknown") },
          sound: "default",
          "content-available": 1,
        },
      },
    },
  };
  try {
    await admin.messaging().send(message);
    return true;
  } catch (e) {
    logger.error("push send failed", { tail: String(target.token).slice(-8), err: e.message });
    return false;
  }
}
