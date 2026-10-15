# Cosmiq Broadband VoIP

A mobile VoIP client for Cosmiq Broadband — an Android app built with Flutter,
with a hand-rolled native SIP/RTP stack and integration to a PortaBilling /
PortaSIP backend for registration, calling, call history, voicemail, and account
management.

> **License: All rights reserved.** This source is published for reference only.
> No permission is granted to use, run, modify, distribute, or resell it — see
> [LICENSE](LICENSE). In particular, you may not use it to provide or resell any
> communications service.

## Features

- SIP registration & calling over **UDP** (pure-Kotlin native stack, no Linphone/WebRTC dependency)
- Outbound & inbound calls with DIGEST auth, proper CANCEL/BYE handling, and periodic re-REGISTER
- Audio codecs: **G.711 µ-law (PCMU)**, **G.711 A-law (PCMA)**, and optional **G.729** (via bcg729 — see below)
- Call history (CDRs), voicemail list, and account info via the PortaBilling REST API
- Dialer, in-call, recents, voicemail, and settings UI; secure credential storage; auto-login

## Architecture

| Layer | Location |
|-------|----------|
| UI / state (Flutter, Provider) | `lib/` |
| PortaBilling REST client | `lib/services/portabilling_service.dart` |
| SIP bridge (Dart ↔ native, MethodChannel) | `lib/services/sip_service.dart` |
| SIP/RTP engine (baresip + libre, C) | `native/` — see [native/README.md](native/README.md) |
| C API shared by Android and iOS | `native/cosmiq/cosmiq_sip.{h,c}` |
| JNI bridge + Kotlin wrapper | `android/app/src/main/cpp/`, `.../CosmiqNativeSip.kt` |

The call engine is **baresip + libre** (3-clause BSD) behind a small C API, so
Android and iOS run the same engine rather than two implementations that drift.
It speaks plain **RTP/AVP with PCMA**, which is what the platform accepts; an
earlier WebRTC-based engine could register but never place a call, because
PortaSIP rejects DTLS-SRTP.

Building the engine is a separate step from the app's Gradle build:
`tools/fetch_native.sh` then `tools/build_native_android.sh`. Without it the
app still builds and runs — just without the engine.

Backends are configured in `lib/models/server_config.dart`:

| Service | Endpoint |
|---------|----------|
| SIP registration / media | `voice.cosmiqbroadband.co.za:5060` (UDP) |
| PortaBilling self-care API | `https://secure.backspace.co.za:8443/rest` |

## Building

Requires the **Flutter SDK** and the **Android SDK + NDK**.

### JDK version matters

Build with **JDK 21**. AGP 8.x and Gradle 8.x do not run on JDK 25, and the
failure is unhelpful - Gradle prints the version string and nothing else:

```
* What went wrong:
25.0.3
```

Android Studio ships whatever JDK it ships, and Flutter picks "the JDK bundled
with the latest Android Studio", so a Studio update can break the build without
a line of code changing. Pin it instead:

```bash
flutter config --jdk-dir "<path to JDK 21>"
```

Moving to JDK 25 is possible but is a **major migration, not a version bump**:
it needs Gradle 9.1+ (9.6+ for AGP 9.5) and AGP 9.x, which carries breaking
changes, and Flutter supports its own range of AGP versions. Worth doing
deliberately and on its own, so a breakage is unambiguous.

```bash
flutter pub get
flutter build apk --debug        # or: flutter run -d <device>
```

### Optional: enable G.729

G.729 uses **bcg729** (Belledonne Communications, **GPLv3**), which is **not
included** in this repository. To enable it, fetch it into place and rebuild:

```bash
git clone https://github.com/BelledonneCommunications/bcg729.git \
  android/app/src/main/cpp/bcg729
flutter build apk --debug
```

Without bcg729 the app still builds (G.729 is disabled and not offered; µ-law /
A-law continue to work). See [THIRD_PARTY.md](THIRD_PARTY.md) for the licensing
implications of shipping G.729.

## Repository layout

Two branches, deliberately:

| Branch | What it is |
|--------|------------|
| `main` | The app. Registers and places calls. |
| `push-gateway` | The APNs/FCM push gateway (its own service, in `push-gateway/`). Separate until it is deployed. |

Superseded work is kept as tags rather than branches, so the branch list stays
readable while nothing is lost:

| Tag | What it holds |
|-----|---------------|
| `archive/kotlin-engine` | The original hand-rolled Kotlin UDP engine |
| `archive/ios-webrtc` | The WebRTC engine (dead end — PortaSIP rejects DTLS-SRTP) |
| `archive/ios-callkit` | iOS CallKit/PushKit work, worth porting when iOS resumes |

## Status / known limitations

- Two-way call **audio** is not yet confirmed on physical hardware. Registration,
  call setup and RTP negotiation are verified against the live platform, but an
  emulator microphone proves nothing about audio quality.
- Only **x86_64** carries the native engine so far; `arm64-v8a` and `armeabi-v7a`
  are needed for release.
- **iOS** is not built yet. The C engine is portable; it needs a Swift bridge,
  `audiounit` instead of `opensles`, and no mbedTLS (Apple provides the crypto).
- Incoming calls, hold, transfer and DTMF are wired but unverified on the new engine.
- Voicemail **playback** is not implemented (listing/delete are wired to the API).
- Some account features depend on correct per-account provisioning on PortaBilling.

## License

Proprietary — Cosmiq Broadband. All rights reserved. See [LICENSE](LICENSE).
