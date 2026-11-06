#!/usr/bin/env bash
# Build the native SIP engine (libre -> baresip) for iOS and stage it as a
# local CocoaPod at ios/CosmiqSip/.
#
# Run tools/fetch_native.sh first. Must run on macOS: it needs Xcode's clang
# and the iOS SDK, neither of which exists on Windows. In practice that means
# Codemagic, which is why codemagic.yaml calls it.
#
# Simpler than the Android build in one important way: there is no mbedTLS.
# libre picks its crypto backend OpenSSL -> Apple -> generic, so with
# USE_OPENSSL=OFF an Apple target compiles src/aes/apple/aes.c and
# src/hmac/apple/hmac.c against CommonCrypto. That also leaves USE_TLS
# undefined (cmake/re-config.cmake only defines it under USE_OPENSSL), so every
# tls_* call in libre and baresip compiles out. That is fine - PortaSIP has no
# TLS port open - and it is why no tls stub is needed on this path.
#
# Stages into ios/CosmiqSip/, where CosmiqSip.podspec expects it:
#   lib/libre.a  lib/libbaresip.a      prebuilt archives
#   src/cosmiq_sip.c                   compiled by the pod, so Xcode picks the arch
#   include/cosmiq_sip.h               the pod's one public header
#   vendor-include/                    re + baresip headers the wrapper needs
set -e

SDK="${1:-iphoneos}"          # iphoneos | iphonesimulator
ARCH="${2:-arm64}"            # arm64 everywhere; x86_64 only for an Intel sim
MINVER="${3:-13.0}"           # matches IPHONEOS_DEPLOYMENT_TARGET in the Xcode project

case "$SDK" in
  iphoneos|iphonesimulator) ;;
  *) echo "usage: $0 [iphoneos|iphonesimulator] [arch] [min-version]" >&2; exit 2 ;;
esac

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found - this script only runs on macOS with Xcode." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/native"

if [ ! -d re ] || [ ! -d baresip ]; then
  echo "error: native sources missing - run tools/fetch_native.sh first." >&2
  exit 1
fi

TAG="ios-$SDK-$ARCH"
PFX="$PWD/prefix-$TAG"

common=(
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_ARCHITECTURES="$ARCH"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINVER"
  -DCMAKE_OSX_SYSROOT="$SDK"
  -DCMAKE_BUILD_TYPE=Release
  # Let CMake's feature probes link as static libraries. Without this they try
  # to produce runnable binaries for a device that is not attached, and every
  # check silently comes back false.
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
)

echo "==> libre ($TAG)"
# OPENSSL_* are set empty deliberately: libre adds test/ unconditionally and
# that target dereferences them even when USE_OPENSSL is off. Same quirk as
# the Android build.
cmake -S re -B "build-re-$TAG" "${common[@]}" \
  -DUSE_OPENSSL=OFF -DUSE_MBEDTLS=OFF \
  -DLIBRE_BUILD_SHARED=OFF \
  -DOPENSSL_INCLUDE_DIR= -DOPENSSL_CRYPTO_LIBRARY= -DOPENSSL_SSL_LIBRARY=
cmake --build "build-re-$TAG" --target re --parallel
cmake --install "build-re-$TAG" --prefix "$PFX"

echo "==> baresip ($TAG)"
# Only the static library; baresip_exe is a separate target and never built.
# STATIC=ON also matters for correctness here, not just size: it takes the
# branch that generates src/static.c registering the modules, instead of the
# one that marks each module -undefined dynamic_lookup for runtime loading.
cmake -S baresip -B "build-baresip-$TAG" "${common[@]}" \
  -Dre_DIR="$PFX/lib/cmake/re" \
  -DRE_INCLUDE_DIR="$PWD/re/include" -DRE_LIBRARY="$PFX/lib/libre.a" \
  -DSTATIC=ON \
  -DOPENSSL_INCLUDE_DIR= -DOPENSSL_CRYPTO_LIBRARY= -DOPENSSL_SSL_LIBRARY=
cmake --build "build-baresip-$TAG" --target baresip --parallel

echo "==> staging the pod"
POD="$ROOT/ios/CosmiqSip"
rm -rf "$POD/lib" "$POD/src" "$POD/include" "$POD/vendor-include"
mkdir -p "$POD/lib" "$POD/src" "$POD/include" "$POD/vendor-include"

cp "$PFX/lib/libre.a"                "$POD/lib/"
cp "build-baresip-$TAG/libbaresip.a" "$POD/lib/"

# The wrapper is handed to the pod as source rather than prebuilt, so Xcode
# compiles it for whatever it is currently targeting. cosmiq_sip.h includes
# only <stdbool.h>, which is why the pod can expose exactly one public header
# while keeping the re/baresip headers private.
cp cosmiq/cosmiq_sip.c "$POD/src/"
cp cosmiq/cosmiq_sip.h "$POD/include/"
cp -R re/include/.      "$POD/vendor-include/"
cp baresip/include/.    "$POD/vendor-include/" 2>/dev/null || \
  cp baresip/include/*.h "$POD/vendor-include/"

echo
echo "Built for $TAG:"
for f in libre.a libbaresip.a; do
  printf '  %-16s %s\n' "$f" "$(lipo -archs "$POD/lib/$f" 2>/dev/null || echo '?')"
done
printf '  %-16s %s headers\n' "vendor-include" "$(ls "$POD/vendor-include" | wc -l | tr -d ' ')"
echo
echo "Staged in ios/CosmiqSip/. Note the archives carry $ARCH for $SDK only -"
echo "rerun with 'iphonesimulator' if you also need to run in the Simulator."
