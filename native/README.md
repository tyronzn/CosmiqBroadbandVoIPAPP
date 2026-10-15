# Native SIP engine (baresip / libre)

One call engine for **both Android and iOS**, replacing the WebRTC experiment
and, eventually, the Android-only Kotlin stack.

## Why this engine

The decision was forced by a measurement, not a preference. PortaSIP accepts
**plain RTP/AVP** and rejects WebRTC's DTLS-SRTP. Proven by a control test on
one emulator, same account and destination, minutes apart:

| Engine | SDP media | Result |
|---|---|---|
| sip_ua + flutter_webrtc | `UDP/TLS/RTP/SAVPF` + ICE | `403` in ~1.5s, never rang |
| native Kotlin stack | `RTP/AVP`, PCMA | connected, 1:14 call, clean BYE |

So the engine has to speak plain RTP. Of the options that do:

- **baresip / libre - chosen.** 3-clause **BSD**, so the app keeps its
  proprietary licence and there is no App Store conflict. Portable C99, one core
  for both platforms. Ships `g711` (the PCMA that PortaSIP actually negotiated),
  plus `audiounit` for iOS and `aaudio`/`opensles` for Android.
- **Linphone (GPLv3/AGPLv3) and PJSIP (GPLv2+)** - rejected. Both would force
  relicensing the app, and GPL conflicts with App Store terms (the VLC case was
  GPLv2, so PJSIP is no safer than Linphone here). A paid commercial licence
  from either vendor would remove the problem.

## Fetching

Sources are not vendored. Run once:

```bash
tools/fetch_native.sh
```

## Crypto backend, per platform

libre needs an HMAC-SHA256 backend. It supports OpenSSL, Apple, WIN32 and
mbedTLS, and **hard-errors with none** (`missing HMAC-SHA256 backend` in
`src/hmac/hmac_sha1.c`). That gives a different answer per platform:

- **iOS: nothing to add.** libre uses Apple's native crypto, so it builds with
  `-DUSE_OPENSSL=OFF` and no third-party dependency at all.
- **Android: mbedTLS.** Apache-2.0, CMake-native and quick to cross-compile -
  far less work than OpenSSL, which needs perl and its own configure dance.
  libre ships `cmake/FindMBEDTLS.cmake`, so it is a supported path.

TLS and SRTP are not required by the current deployment in any case: the SIP
host has **5061 closed** and negotiates plain RTP. The crypto backend is needed
only to satisfy libre's build.

## Android build

`tools/build_native_android.sh [abi] [api]` builds the whole chain and is the
only thing you should need. It defaults to `x86_64` / API 26 (the emulator and
the app's minSdk). **Status: working** - it produces

| library | size |
|---|---|
| `libre.a` | 6.9 MB |
| `libbaresip.a` | 3.2 MB |
| `libmbedcrypto.a` | 4.8 MB |

Modules built: `account auconv auresamp g711 stun turn ice srtp uuid opensles`.

### Things that cost time, recorded so they cost nothing next time

1. **mbedTLS from git has no generated sources.** Release tarballs ship
   `error.c` and `ssl_debug_helpers_generated.c`; a clone does not. Pass
   `-DGEN_FILES=ON`, which needs perl and the python modules listed in
   `mbedtls/scripts/basic.requirements.txt` (jinja2, jsonschema).
2. **libre adds `test/` unconditionally** and that target references the
   `OPENSSL_*` variables, so they must be defined - empty is fine - even with
   `USE_OPENSSL=OFF`. Same applies when configuring baresip, where a
   `NOTFOUND` leaks into the modules' include paths.
3. **`MBEDTLS_*` are find-module cache variables.** Setting them directly
   short-circuits the search, which the Android toolchain otherwise confines to
   the NDK sysroot, so `MBEDTLS_HINTS` is ignored.
4. **libre never adds `MBEDTLS_INCLUDE_DIRS` to its include path** - the
   variable is referenced nowhere in its CMakeLists - so the headers have to
   come in through `CMAKE_C_FLAGS`. Upstream gap.
5. **baresip needs libre *installed***, not just built: it does
   `find_package(re CONFIG)` and wants `lib/cmake/re/re-config.cmake`.
6. **`FindV4L2.cmake` calls `find_package(PkgConfig REQUIRED)`**, which
   hard-fails on Windows. The module list is hard-set rather than a cache
   variable, so `tools/trim_modules.py` rewrites it to the mobile set.
7. **The `aaudio` module requires API 28** (`AAudioStreamBuilder_setSessionId`
   and friends) while the app ships **minSdk 26**. Dropped in favour of
   `opensles`. Revisit if minSdk ever moves to 28 - AAudio has lower latency.
8. **baresip's executable target fails to link** because it does not pull in
   mbedTLS. Harmless: we want `libbaresip.a`, and our own wrapper does the
   final link.

## Remaining work

1. A thin C wrapper over baresip exposing register / call / answer / hangup /
   mute / hold / DTMF / transfer plus an event callback, linking
   `libbaresip.a` + `libre.a` + mbedTLS into one `.so`.
2. JNI bridge for Android, Swift bridge for iOS, behind the existing
   `SipService` interface so the UI and AppState do not change.
3. Prove it on the Android emulator against PortaSIP - registration, then a
   call with **plain RTP/AVP** - before any Mac is involved. That sequencing is
   what caught the WebRTC media problem cheaply.
4. iOS build: same sources, `audiounit` instead of `opensles`, and **no
   mbedTLS at all** since libre uses Apple's native crypto there.
5. Add `arm64-v8a` and `armeabi-v7a` for release.
