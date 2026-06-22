# Cosmiq VoIP — Push Notification Gateway

A Firebase Cloud Functions service that bridges **PortaSIP → FCM/APNs**, so the
app gets incoming-call notifications while it's closed.

```
Caller → PortaSIP (call control) → [this gateway] → FCM (Android) / APNs (iOS)
       → phone wakes → app re-registers → PortaSIP delivers the INVITE
```

Per Backspace: Porta is only the SIP platform/call controller; the app vendor
(us) operates this push gateway. Porta calls our `notifyIncomingCall` endpoint
when a call arrives for one of our accounts.

## Endpoints

| Function | Purpose |
|----------|---------|
| `notifyIncomingCall` | **Called by PortaSIP** on an incoming call → sends the push. |
| `registerDeviceToken` | Called by the app to store its SIP-account → FCM-token map (only needed if Porta does **not** relay the token via `pn-prm`). |

## Deploy

Prereqs: Node 20, the [Firebase CLI](https://firebase.google.com/docs/cli)
(`npm i -g firebase-tools`), and a Firebase project with **Cloud Functions** +
**Firestore** enabled (same project as the app's `google-services.json`).

```bash
cd push-gateway
# put your real project id in .firebaserc (replace the placeholder)
firebase login
cd functions && npm install && cd ..

# optional but recommended: a shared secret Porta must present
firebase functions:secrets:set GATEWAY_SECRET

firebase deploy --only functions
```

After deploy you'll get URLs like:
```
https://<region>-<project>.cloudfunctions.net/notifyIncomingCall
https://<region>-<project>.cloudfunctions.net/registerDeviceToken
```

## Wire it to PortaSIP (give Backspace)

- **Gateway URL** for incoming-call notifications: the `notifyIncomingCall` URL above.
- The shared secret (if set) — they must send it as header `x-gateway-secret` or `?secret=`.
- The `pn-provider` / `pn-param` / `pn-prm` values the app should register with —
  these come **from Backspace** and must match how they configure our provider.

## ⚠️ One thing to finalize once Backspace replies

`parsePortaRequest()` in `functions/index.js` currently reads the *common*
field names PortaSIP might use (`caller`/`from`, `account`/`callee`,
`token`/`pn_prm`, …). Once Backspace sends the **exact request format**, tighten
that function to match — that's the only code change needed to go live.

## Token flow — two models (Backspace's spec decides which)

1. **Porta relays the token** (RFC 8599 `pn-prm`): the app puts its FCM token in
   the SIP REGISTER, Porta includes it when calling us → `notifyIncomingCall`
   uses it directly. No `registerDeviceToken` needed.
2. **App registers the token with us:** the app POSTs `{account, token, platform}`
   to `registerDeviceToken` on login; `notifyIncomingCall` looks it up by account.

The gateway supports **both** — it uses a relayed token if present, else looks
it up in Firestore.

## iOS / CallKit note

Android works fully with FCM. For a proper iOS **CallKit** incoming-call screen,
iOS needs a **VoIP push** (`apns-push-type: voip`) to a **PushKit** token over a
dedicated APNs channel — that's built alongside the iOS CallKit work, not here.
This gateway gives iOS a standard alert notification in the meantime.
