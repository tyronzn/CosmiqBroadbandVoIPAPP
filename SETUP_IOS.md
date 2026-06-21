# iOS support (portable SIP/WebRTC engine)

This branch (`ios-webrtc`) replaces the Android-only native UDP SIP stack with a
**portable Dart engine** — `dart-sip-ua` (SIP-over-WebSocket) + `flutter_webrtc`
(media) — so **Android and iOS run the same call code**.

## The gating dependency: PortaSIP WebRTC gateway

This engine connects over **WSS** (SIP-over-WebSocket) with **WebRTC media**, not
plain UDP SIP. It only works if Backspace/PortaSIP exposes a **WebRTC gateway**.

- A `webrtc.cosmiqbroadband.co.za` host already exists (good sign), but you must
  get the **exact WSS URL + SIP domain** from Backspace and set it in
  `lib/models/server_config.dart`:
  ```dart
  static const String wssUrl = 'wss://webrtc.cosmiqbroadband.co.za';  // ← confirm path
  static const String sipDomain = 'voice.cosmiqbroadband.co.za';      // ← confirm
  ```
- Until the real WSS endpoint is set, registration will fail (nothing to connect to).

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
| Codec selection | WebRTC negotiates **Opus** automatically; the Settings codec picker is now cosmetic (consider hiding it for this build). **G.729 is dropped** — WebRTC doesn't support it. |
| Push (incoming calls) | Android FCM still wired; **iOS needs APNs + PushKit + CallKit** (not yet built — Apple requires CallKit for VoIP push) |

## Remaining iOS work (after calls work)

- **CallKit + PushKit + APNs** for incoming calls when the app is closed (the iOS
  equivalent of the Android FCM/full-screen-notification work). `flutter_callkit_incoming`
  covers both platforms if you want to unify.
- Decide whether to keep the native Android UDP stack as a fallback or remove it.
