# iOS incoming calls — CallKit + PushKit

Branch: `ios-callkit` (off `ios-webrtc`).

On iOS an app cannot simply "listen" for a SIP call in the background: once
suspended, the WebSocket dies and nothing arrives. The platform-sanctioned route
is a **VoIP push (PushKit)** that wakes the app, which must then **immediately
report the call to CallKit** — if it doesn't, iOS terminates the process.

This branch wires up the client half of that.

## What works without any Apple setup

The native call screen is used for calls that arrive **while the app is
running** — the phone rings through iOS, the call appears in Recents, and the
lock screen and CarPlay controls work. Answer / decline / mute / hold / DTMF on
the native UI drive the SIP session.

That needs no certificate and no gateway. It does still need the WSS gateway
from [SETUP_IOS.md](SETUP_IOS.md) — without registration there are no calls at all.

## What needs the full chain (app closed)

Incoming calls while the app is **closed or suspended** need all of:

1. An Apple **VoIP Services certificate** (below).
2. The **push gateway** sending APNs VoIP pushes — the `push-gateway` branch
   currently only sends **FCM**, so it needs APNs support added.
3. **Backspace/PortaSIP** calling that gateway when a call arrives.

None of those exist yet, so closed-app calls will not work until they do.

## Xcode setup (on the Mac)

In `ios/Runner.xcworkspace`, Runner target → **Signing & Capabilities**:

1. **+ Capability → Push Notifications**
2. **+ Capability → Background Modes**, then tick:
   - **Voice over IP**
   - **Audio, AirPlay, and Picture in Picture**
   *(`UIBackgroundModes` already lists `voip` and `audio` in `Info.plist`; the
   capability is what makes the entitlement real.)*
3. Confirm **Bundle Identifier** is `za.co.cosmiq.voip` and a **Team** is set.

Enabling Push Notifications creates `Runner.entitlements` with `aps-environment`.
Let Xcode generate it — a hand-written entitlements file that disagrees with the
provisioning profile fails to sign.

## Apple Developer setup

1. developer.apple.com → Certificates → **+** → **VoIP Services Certificate**.
2. Pick App ID `za.co.cosmiq.voip`, upload a CSR, download the `.cer`.
3. Import to Keychain, export as `.p12` — that's what the push gateway uses to
   authenticate to APNs. (A `.p8` **APNs Auth Key** works too and doesn't expire;
   prefer it if you're setting this up fresh.)

VoIP pushes go to the APNs topic **`za.co.cosmiq.voip.voip`** — the bundle ID
with `.voip` appended. Sending to the plain bundle ID will not wake the app.

## Push payload contract

`AppDelegate.swift` reads these keys from the VoIP push and shows the call:

```json
{
  "id": "<unique call id>",
  "nameCaller": "0827644298",
  "handle": "0827644298"
}
```

Anything else in the payload is ignored. `id` should be unique per call so
CallKit can match a later "call ended" to the right call.

## Gateway work still to do

`push-gateway/functions/index.js` sends FCM only. For iOS it needs to:

- store the **PushKit** token separately from the FCM token (they are different
  tokens for the same device),
- send to APNs with topic `za.co.cosmiq.voip.voip`, `apns-push-type: voip`,
  `apns-priority: 10`,
- send the payload above.

The Dart side already exposes the token: `CallKitService.voipPushToken`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Call connects but **no audio** | The CallKit / WebRTC audio-session conflict. `IOSParams.configureAudioSession` is set to **`false`** in `callkit_service.dart` so flutter_webrtc owns the session — try flipping it to `true`. This is the first thing to try. |
| No native call screen, app open | `CallKitService.isSupported` is iOS-only by design; on Android the full-screen notification is used instead |
| Nothing happens on a VoIP push | Certificate/topic wrong, or the payload is missing `id` |
| App crashes right after a VoIP push | iOS killing it for not reporting a call — means `showCallkitIncoming` didn't run |
| Call screen stays after hangup | A `CallKitService.endCall` was missed — check the Diagnostics log |

## Caveat — the Swift is unverified

`ios/Runner/AppDelegate.swift` was written against the plugin's actual Swift
signatures (`setDevicePushTokenVoIP`, `showCallkitIncoming(_:fromPushKit:completion:)`,
`Data(id:nameCaller:handle:type:)`) but **has not been compiled** — there is no
Mac in the loop yet. Expect to fix small things on the first build.

Note the AppDelegate deliberately does **not** adopt the plugin's
`CallkitIncomingAppDelegate` protocol. That protocol requires seven members
(including `providerDidReset()`, which the plugin's own README example omits) and
is only needed when the app answers calls via a server API rather than in Dart.
Accept/decline is handled through the Dart event stream instead.

If the iOS build breaks and you need to get back to a known-good state for
testing, `ios-webrtc` has none of this.
