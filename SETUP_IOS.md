# iOS support (portable SIP/WebRTC engine)

This branch (`ios-webrtc`) replaces the Android-only native UDP SIP stack with a
**portable Dart engine** — `dart-sip-ua` (SIP-over-WebSocket) + `flutter_webrtc`
(media) — so **Android and iOS run the same call code**.

## The gating dependency: PortaSIP WebRTC gateway

This engine connects over **WSS** (SIP-over-WebSocket) with **WebRTC media**, not
plain UDP SIP. It only works if Backspace/PortaSIP exposes a **WebRTC gateway**.

Ask Backspace for three things before testing:

1. Is the **PortaSIP WebRTC/WSS gateway enabled** for this account?
2. The **exact WSS URL** — host **plus port and path** (e.g. `wss://webrtc.cosmiqbroadband.co.za:8443/ws`).
3. The **SIP domain** to use over WebRTC (expected: `voice.cosmiqbroadband.co.za`).

Until the real endpoint is set, registration fails — there is nothing to connect
to. The app says so rather than looking broken: while it is still on the shipped
default, **Settings → Connection** shows a warning banner.

### Setting the endpoint

**On the device (preferred while testing):** Settings → Connection. Enter the WSS
URL and SIP domain, save, then sign out and back in. No rebuild — which matters
on iOS, where a rebuild means going back to the Mac. The override is stored on
the device and survives restarts; "Reset to defaults" clears it.

**In code (once the value is confirmed):** update the shipped defaults in
`lib/models/server_config.dart` so new installs get it without any setup:
```dart
static const String wssUrl = 'wss://webrtc.cosmiqbroadband.co.za';  // ← confirm path
static const String sipDomain = 'voice.cosmiqbroadband.co.za';      // ← confirm
```

The gateway needs a **valid TLS certificate** — the client sets
`allowBadCertificate = false`, so a self-signed cert fails the handshake.

## Build & run on your Mac

```bash
git checkout ios-webrtc
flutter pub get
cd ios && pod install && cd ..
flutter run -d <your-iphone>
```

In **Xcode** (`ios/Runner.xcworkspace`), set:
1. **Bundle Identifier** → `za.co.cosmiq.voip` (Runner target → Signing & Capabilities).
   *(The generator made `za.co.cosmiq.cosmiqVoip` — change it.)*
2. **Team** → your Apple Developer team (for signing).
3. **iOS Deployment Target → 13.0** (required by `flutter_webrtc`). Also set
   `platform :ios, '13.0'` at the top of `ios/Podfile` (uncomment/edit), then
   re-run `pod install`.

Microphone permission + VoIP background modes are already in `ios/Runner/Info.plist`.

## What changed (and what didn't)

| Area | Status |
|------|--------|
| UI, AppState, dialer/in-call/settings | unchanged — same `SipService` interface |
| Call engine | now `dart-sip-ua` + `flutter_webrtc` (`lib/services/sip_service.dart`) |
| Android native UDP stack (`CosmiqSipManager.kt`) | unused on this branch (kept, harmless) |
| Codec selection | WebRTC negotiates **Opus** automatically. The picker is gone — Settings now shows "Opus (automatic)". **G.729 is dropped** — WebRTC doesn't support it. |
| Push (incoming calls) | Android FCM still wired; **iOS needs APNs + PushKit + CallKit** (not yet built — Apple requires CallKit for VoIP push) |

## When something fails on the handset

There is no console attached to a phone in the field, and reading the iOS device
log needs a Mac — so the app keeps its own log.

**Settings → Diagnostics** shows every registration, WebSocket and call
transition, newest first, and the copy button puts the whole log (with the app
version and the endpoint in use) on the clipboard — paste that into a message to
support or to Backspace. Credentials are never logged.

Sign-in failures are reported with their cause rather than a generic error:

| What you see | What it means |
|---|---|
| Extension or password rejected | SIP 401/403 — credentials are wrong |
| That extension does not exist | SIP 404 — wrong extension, or not provisioned |
| Lost the connection to the WebRTC gateway | WebSocket dropped — wrong URL, TLS, or firewall |
| The gateway did not respond within 20 seconds | Nothing listening at that URL |
| WebRTC endpoint is not configured | The URL in Settings → Connection is malformed |

## Remaining iOS work (after calls work)

- **CallKit + PushKit + APNs** for incoming calls when the app is closed (the iOS
  equivalent of the Android FCM/full-screen-notification work). `flutter_callkit_incoming`
  covers both platforms if you want to unify.
- Decide whether to keep the native Android UDP stack as a fallback or remove it.
