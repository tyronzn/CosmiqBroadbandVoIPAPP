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

Verified working: the NDK toolchain configures and compiles libre (110+ objects
before the HMAC backend stop, which mbedTLS resolves).

```bash
NDK=$ANDROID_HOME/ndk/28.2.13676358
CM=$ANDROID_HOME/cmake/3.22.1/bin

$CM/cmake -S re -B build-and-x86_64 -G Ninja \
  -DCMAKE_MAKE_PROGRAM=$CM/ninja \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-26 \
  -DUSE_OPENSSL=OFF -DLIBRE_BUILD_SHARED=OFF -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_INCLUDE_DIR= -DOPENSSL_CRYPTO_LIBRARY= -DOPENSSL_SSL_LIBRARY=
```

Two quirks worth knowing:

1. libre's `test/` subdirectory is added unconditionally
   (`add_subdirectory(test EXCLUDE_FROM_ALL)`) and references the OpenSSL
   variables. It never builds, but it must *configure*, hence passing the three
   empty `OPENSSL_*` values above rather than patching vendored code.
2. `ANDROID_ABI=x86_64` targets the emulator. Release builds also need
   `arm64-v8a` and `armeabi-v7a`.

## Remaining work

1. Cross-compile mbedTLS for Android and rebuild libre against it.
2. Build the baresip core plus the modules we need (`g711`, `aaudio`/
   `opensles`, `audiounit`, `stun`/`turn`/`ice`).
3. A thin C wrapper exposing register / call / answer / hangup / mute / hold /
   DTMF / transfer and an event callback.
4. JNI bridge for Android, Swift bridge for iOS, behind the existing
   `SipService` interface so the UI and AppState do not change.
5. Prove it on the Android emulator against PortaSIP before touching the Mac -
   the same sequencing that caught the WebRTC media problem cheaply.
