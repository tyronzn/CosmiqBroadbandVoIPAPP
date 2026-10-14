# Cosmiq VoIP — Push Notification Gateway

A Firebase Cloud Functions service that bridges **PortaSIP → APNs / FCM**, so the
app receives incoming calls while it is closed.

```
Caller → PortaSIP (call control) → [this gateway] → APNs (iOS) / FCM (Android)
       → handset wakes → app registers → PortaSIP delivers the INVITE
```

Per Backspace: Porta is only the SIP platform and call controller; the app
vendor (us) operates this push gateway. Porta calls `notifyIncomingCall` when a
call arrives for one of our accounts.

## The two platforms take different routes

This matters, and is the reason the gateway is not just an FCM wrapper.

| | Android | iOS |
|---|---|---|
| Transport | FCM | **APNs directly** |
| Token | FCM registration token | **PushKit (VoIP) token** |
| Message | high-priority data message | `apns-push-type: voip` |
| Raises | full-screen notification | **CallKit** native call screen |

iOS **cannot** go through FCM. FCM does not send `apns-push-type: voip`, and
without that header iOS will not wake a suspended app for CallKit — Apple
terminates an app that takes a VoIP push and fails to report a call. So the
gateway speaks HTTP/2 to APNs itself.

The VoIP topic is the bundle id with `.voip` appended —
`za.co.cosmiq.voip.voip`. Sending to the bare bundle id silently does nothing.

### No third-party APNs library

`lib/apns.js` uses Node built-ins only. Node signs the ES256 provider token APNs
requires natively (`dsaEncoding: 'ieee-p1363'` is exactly the raw r-then-s form
JWS needs, which is the one genuinely error-prone part), and `node:http2` covers
the transport. One less dependency to vet in a proprietary product.

## Endpoints

| Function | Called by | Purpose |
|---|---|---|
| `notifyIncomingCall` | **PortaSIP** | Sends the push for an incoming call. |
| `registerDeviceToken` | the app | Stores the SIP-account → device-token map. Needed only if Porta does not relay the token itself via `pn-prm`. |
| `unregisterDeviceToken` | the app | Drops the mapping on sign-out, so a handed-on handset stops ringing. |
| `health` | you | Reports whether APNs is configured, and for which environment. Leaks no secrets. |

iOS must register its **PushKit** token here, not its FCM token — they are
different tokens for the same device. The app exposes it as
`CallKitService.voipPushToken`.

Dead tokens are deleted automatically: APNs `Unregistered` / `BadDeviceToken`
(and FCM's `registration-token-not-registered`) remove the stored mapping, so
the gateway stops pushing to handsets that uninstalled the app. Transient
failures such as a 503 deliberately do **not** drop the token.

## Configuration

Set as Firebase secrets, never committed:

| Name | Required | Meaning |
|---|---|---|
| `APNS_KEY` | for iOS | Contents of the `.p8` APNs auth key. Literal `\n` is tolerated and converted back to real newlines. |
| `APNS_KEY_ID` | for iOS | The 10-character Key ID of that `.p8`. |
| `APNS_TEAM_ID` | for iOS | Apple Developer Team ID. |
| `APNS_BUNDLE_ID` | no | Defaults to `za.co.cosmiq.voip`. |
| `APNS_PRODUCTION` | no | `true` for release builds. Defaults to sandbox. |
| `GATEWAY_SECRET` | recommended | Shared secret PortaSIP must present. |

The sandbox/production split is a common trap: a **TestFlight or App Store**
build needs `APNS_PRODUCTION=true`, a build run from Xcode needs sandbox. The
wrong one fails with `BadDeviceToken`.

### Getting the APNs key

An **APNs Auth Key (.p8)** is preferred over a VoIP Services certificate — it
does not expire and one key covers every app in the team.

1. developer.apple.com → Certificates, Identifiers & Profiles → **Keys** → **+**
2. Enable **Apple Push Notifications service (APNs)**, create, download the `.p8`
   (downloadable **once**), and note the Key ID.
3. Team ID is in Membership details.

## Deploy

Prereqs: Node 20+, the Firebase CLI (`npm i -g firebase-tools`), and a Firebase
project with Cloud Functions and Firestore enabled — the same project as the
app's `google-services.json`.

```bash
cd push-gateway
# put your real project id in .firebaserc (it ships with a placeholder)
firebase login
cd functions && npm install && cd ..

firebase functions:secrets:set GATEWAY_SECRET
firebase functions:secrets:set APNS_KEY        # paste the .p8 contents
firebase functions:secrets:set APNS_KEY_ID
firebase functions:secrets:set APNS_TEAM_ID

firebase deploy --only functions
```

Then confirm the deploy:

```bash
curl https://<region>-<project>.cloudfunctions.net/health
```

`apnsConfigured: true` and the expected `apnsEnvironment` means iOS is wired up.

## Tests

```bash
cd push-gateway/functions && npm test
```

29 tests, no network and no Firebase emulator required. They cover the request
parsing (including the RFC 8599 field spellings), the payload contract shared
with `ios/Runner/AppDelegate.swift`, ES256 token signing and caching, and the
APNs headers — against a mocked HTTP/2 connection.

The payload keys `id`, `nameCaller` and `handle` are read **by name** in the
Swift. Renaming one silently breaks the iOS call screen, so a test pins them.

## Still outstanding

1. **Backspace must supply the request format** PortaSIP sends to
   `notifyIncomingCall`. `lib/parse.js` currently accepts every plausible field
   name; tighten it once the spec lands — the tests document the contract.
2. **Backspace must be pointed at the deployed URL**, with the shared secret.
3. The Apple **APNs key** above, and the iOS app built from the `ios-callkit`
   branch so it has a PushKit token to register.

Until all three are in place, iOS receives calls only while the app is running.
