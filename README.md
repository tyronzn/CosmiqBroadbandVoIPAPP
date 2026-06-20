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
| Native SIP/RTP stack (Kotlin/UDP) | `android/app/src/main/kotlin/za/co/cosmiq/voip/CosmiqSipManager.kt` |
| G.729 JNI + codec | `android/app/src/main/cpp/` |

Backends are configured in `lib/models/server_config.dart`:

| Service | Endpoint |
|---------|----------|
| SIP registration / media | `voice.cosmiqbroadband.co.za:5060` (UDP) |
| PortaBilling self-care API | `https://secure.backspace.co.za:8443/rest` |

## Building

Requires the **Flutter SDK** and the **Android SDK + NDK**.

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

## Status / known limitations

- Voicemail **playback** is not yet implemented (listing/delete are wired to the API).
- Call **hold** and **transfer** are not yet functional (need in-dialog Record-Route handling).
- Two-way call **audio** should be validated on a physical device (emulator microphones are unreliable).
- Some account features depend on correct per-account provisioning on the PortaBilling side.

## License

Proprietary — Cosmiq Broadband. All rights reserved. See [LICENSE](LICENSE).
