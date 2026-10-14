# iOS support (portable SIP engine)

This branch (`ios-webrtc`) replaces the Android-only native UDP SIP stack with a
**portable Dart engine** — `dart-sip-ua` for signalling plus `flutter_webrtc`
for media — so **Android and iOS run the same call code**.

## Transport: plain SIP over TCP, not WebRTC

An earlier version of this branch registered over **WSS** (SIP-over-WebSocket)
and needed PortaSIP's WebRTC gateway. **That gateway does not exist on this
platform**, which was established directly rather than taken on trust:

- `webrtc.cosmiqbroadband.co.za` only resolved because of a **wildcard** DNS
  record (`*.cosmiqbroadband.co.za`) pointing at Cloudflare. There is no
  `webrtc` record and no gateway behind it — a WebSocket upgrade on `/`, `/ws`
  and `/sip` returns a Cloudflare **404**.
- The SIP host `voice.cosmiqbroadband.co.za` has **no TLS ports open at all**
  (443, 8443 and 5061 are closed).

What the platform does answer, verified with a live SIP OPTIONS probe:

```
SIP/2.0 200 OK
Server: PortaSIP
Allow: INVITE, ACK, BYE, CANCEL, INFO, SUBSCRIBE, NOTIFY, REFER, MESSAGE, OPTIONS
```

...over **both UDP and TCP on 5060**. So the engine now uses
`TransportType.TCP` straight to `voice.cosmiqbroadband.co.za:5060`. WebRTC was
only ever a client-side convenience, never a platform requirement, and dropping
it removes every external dependency: no gateway, no new infrastructure, and
nothing needed from the carrier.

`sip_ua` is **MIT licensed**, so this changes nothing about the app's own
proprietary licence.

## Sign-in is unchanged

Users enter **only an extension and a password**, and always authenticate
against `voice.cosmiqbroadband.co.za`. The server is a compiled-in default in
`lib/models/server_config.dart`.

**Settings → Connection** can override the server, port and SIP domain, but it
is a support/diagnostic tool, not part of the sign-in flow. A banner appears
whenever the values differ from the defaults, with a Reset.

## Build and run on your Mac

```bash
git checkout ios-webrtc
flutter pub get
cd ios && pod install && cd ..
flutter run -d <your-iphone>
```

In **Xcode** (`ios/Runner.xcworkspace`), set:

1. **Bundle Identifier** to `za.co.cosmiq.voip` (Runner target, Signing &
   Capabilities). The generator produced `za.co.cosmiq.cosmiqVoip`.
2. **Team** to your Apple Developer team, for signing.
3. **iOS Deployment Target to 13.0**, required by `flutter_webrtc`. Also set
   `platform :ios, '13.0'` at the top of `ios/Podfile`, then re-run
   `pod install`.

Microphone permission and the VoIP background modes are already in
`ios/Runner/Info.plist`.

## Validate on Android first

The engine is shared, so the whole approach can be proven on an Android handset
or emulator on Windows, before a Mac is involved:

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb logcat -s flutter
```

If registration succeeds there, the remaining iOS work is a build and signing
exercise rather than an engineering unknown.

## What changed, and what did not

| Area | Status |
|------|--------|
| UI, AppState, dialer, in-call, settings | unchanged — same `SipService` interface |
| Signalling | `dart-sip-ua` over **TCP/5060** (`lib/services/sip_service.dart`) |
| Media | `flutter_webrtc` |
| Android native UDP stack (`CosmiqSipManager.kt`) | unused on this branch, kept and harmless |
| Codec selection | WebRTC negotiates automatically; Settings shows "Opus (automatic)". **G.729 is not available** on this engine |
| Push (incoming calls) | Android FCM is wired. **iOS needs CallKit and PushKit** — see the `ios-callkit` branch and SETUP_CALLKIT.md |

## The known risk: media

Signalling over TCP is settled. **Media is the open question.** `flutter_webrtc`
negotiates DTLS-SRTP with ICE, while a plain SIP platform may expect
unencrypted RTP over AVP. If registration and call setup succeed but there is no
audio, that mismatch is the first thing to suspect, and the fix is on the
platform side (enabling SRTP/ICE) or by swapping the media layer.

Settings → Diagnostics shows the signalling, which is enough to tell the two
apart: a call that reaches `CONFIRMED` with silent audio is a media problem, not
a signalling one.
