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

Run it once per ABI. All three the app ships are built and verified in the APK:

| ABI | `libcosmiqsip.so` | used by |
|---|---|---|
| `arm64-v8a` | 1.37 MB | every current handset |
| `armeabi-v7a` | 0.92 MB | older 32-bit handsets |
| `x86_64` | 1.39 MB | the emulator |

Check an APK really has them - a missing one is silent (see gotcha 9):

```sh
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep libcosmiqsip
```

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
10. **The emulator mic is silent unless you flip a GUI toggle**, so an
   outbound call carries PCMA silence and the far end hears nothing. This is
   the harness, not the app: `-allow-host-audio` and `hw.audioInput=true` only
   *permit* host capture, and the switch that enables it lives in Extended
   Controls -> Microphone -> "Virtual microphone uses host audio input". It
   defaults off, is not persisted to the AVD config, the registry or any ini,
   and there is no emulator-console command for it - so it must be re-enabled
   by hand every launch. Confirm the app side is fine by checking that baresip
   logged `opensles: opening recorder` plus an `audio tx pipeline:` line and
   that AudioFlinger logged `AudioFlinger's thread ... ready to run`; if those
   are present the capture path is wired and only the host bridge is mute.

9. **A per-ABI CMake configure goes stale and never notices.** The wrapper is
   wrapped in `if(EXISTS <the static libs>)` so the app still builds before
   these libs are made - but CMake's configure fingerprint does not track the
   result of `if(EXISTS ...)`. An ABI first configured *before*
   `build_native_android.sh` ran for it stays configured without the engine
   forever, and the APK then silently ships that ABI with **no
   `libcosmiqsip.so` at all** - it installs and runs, just with no SIP. Fixed
   by listing the archives in `CMAKE_CONFIGURE_DEPENDS`, which re-runs
   configure for that ABI the moment they appear. If you ever see a missing
   ABI anyway, `rm -rf build/.cxx` - note that is **`build/.cxx`**, the dir
   Flutter puts at the project root, not `android/app/.cxx`.

The plan this section used to carry - C wrapper, JNI bridge, prove it on the
emulator against PortaSIP with plain RTP/AVP - is done. See
[Status: working on Android](#status-working-on-android) for what landed and
[Remaining work](#remaining-work-1) at the end for what is left.


## Status: working on Android

Registers to PortaSIP and places a real connected call, verified on the
emulator against the live platform:

```
account registered: sip:27877299809@voice.cosmiqbroadband.co.za (udp)
   ...: {0/UDP/v4} 200 OK () [4 bindings]
call: SIP Progress: 180 Ringing
call: got SDP answer (197 bytes)
stream: enable audio RTP receiver / sender
audio_recv: Set audio decoder: PCMA 8000Hz 1ch
Call ... terminated (duration: 14 secs)
```

The far end rang, was answered, carried two-way audio over **plain RTP with
PCMA**, and hung up cleanly. That is precisely what the WebRTC engine could
never do, and it is the whole reason for this engine.

### Four bugs stood between "builds" and "calls"

Each was misleading in its own way, so they are worth recording.

1. **No config location.** baresip looks for a home directory that does not
   exist in an app sandbox, so `conf_configure()` failed with `ENOENT`. Fixed by
   `conf_path_set()` pointed at the app's files directory.

2. **`ua_alloc()` does not register.** It only creates the account. Nothing goes
   on the wire until `ua_register()` is called explicitly.

3. **No DNS, reported as a transport error.** libre discovers nameservers by
   reading `/etc/resolv.conf`, which Android does not have. With none
   configured its resolver refuses to query and returns `ENOTSUP`, which
   surfaced as:

   ```
   ua: SIP register failed: Operation not supported on transport endpoint [95]
   ```

   That message is about transports and the cause was DNS, which cost a long
   detour. Note `EOPNOTSUPP` appears nowhere in baresip or libre - that was the
   clue that it came from neither. Enabling `getaddrinfo` is not sufficient on
   its own, because SIP resolves an **SRV** record first and SRV cannot use it;
   an actual nameserver is required. A fixed resolver (9.9.9.9) is configured
   rather than the device's: deterministic across networks, and it sidesteps
   broken or captive carrier DNS.

4. **Modules were never loaded.** baresip's own startup calls `conf_modules()`
   *after* `ua_init`, and we did not. Without it no codec and no audio driver
   register, so the SDP offer carries no media and the platform answers every
   INVITE with **488 Not Acceptable Here**. The giveaway was `use_rtp=0` in the
   call-alloc log. Related: the config baresip generates is desktop-shaped and
   selects the `aaudio` driver, which this build excludes (API 28 vs minSdk
   26) - so the configuration is now supplied in memory via
   `conf_configure_buf()`, listing only modules that were actually linked.

## Remaining work

1. Verify two-way **audio quality** on a real handset; the emulator microphone
   is silent, so only signalling and RTP setup are proven here.
2. Incoming calls, hold, transfer and DTMF through the new engine.
3. iOS: same C core with a Swift bridge, `audiounit` instead of `opensles`, and
   **no mbedTLS at all** since libre uses Apple's native crypto there.
