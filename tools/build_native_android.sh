#!/usr/bin/env bash
# Build the native SIP engine (mbedTLS -> libre -> baresip) for Android.
#
# Run tools/fetch_native.sh first. Produces static libraries that our JNI
# wrapper links into a single .so:
#   prefix-android-<abi>/lib/libre.a
#   prefix-android-<abi>/lib/libmbed{crypto,tls,x509}.a
#   build-baresip-<abi>/libbaresip.a
#
# ABI defaults to x86_64 (the emulator). Release builds need arm64-v8a and
# armeabi-v7a as well.
set -e

ABI="${1:-x86_64}"
API="${2:-26}"                      # matches the app's minSdk
SDK="${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}"
NDK="$SDK/ndk/28.2.13676358"
CM="$SDK/cmake/3.22.1/bin"

cd "$(dirname "$0")/../native"
PFX="$PWD/prefix-android-$ABI"

common=(
  -G Ninja
  -DCMAKE_MAKE_PROGRAM="$CM/ninja"
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI="$ABI"
  -DANDROID_PLATFORM="android-$API"
  -DCMAKE_BUILD_TYPE=Release
)

echo "==> mbedTLS ($ABI)"
# GEN_FILES=ON because a git checkout lacks the generated sources that release
# tarballs ship (error.c, ssl_debug_helpers_generated.c). Needs perl plus the
# python modules in mbedtls/scripts/basic.requirements.txt.
"$CM/cmake" -S mbedtls -B "build-mbedtls-$ABI" "${common[@]}" \
  -DGEN_FILES=ON -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF
"$CM/cmake" --build "build-mbedtls-$ABI" -j 8
"$CM/cmake" --install "build-mbedtls-$ABI" --prefix "$PFX"

echo "==> libre ($ABI)"
# Three quirks, each of which cost time to find:
#  1. libre adds test/ unconditionally and that target references the OPENSSL_*
#     variables, so they must be defined (empty) even with USE_OPENSSL=OFF.
#  2. MBEDTLS_* are find_path/find_library cache variables. Setting them
#     directly short-circuits the search, which the Android toolchain would
#     otherwise confine to the NDK sysroot.
#  3. libre defines USE_MBEDTLS but never adds MBEDTLS_INCLUDE_DIRS to its
#     include path (it is referenced nowhere in CMakeLists.txt), so the header
#     directory has to come in via CMAKE_C_FLAGS.
"$CM/cmake" -S re -B "build-re-$ABI" "${common[@]}" \
  -DUSE_OPENSSL=OFF -DUSE_MBEDTLS=ON \
  -DMBEDTLS_INCLUDE_DIR="$PFX/include" \
  -DMBEDTLS_LIBRARY="$PFX/lib/libmbedcrypto.a" \
  -DCMAKE_C_FLAGS="-I$PFX/include" \
  -DLIBRE_BUILD_SHARED=OFF \
  -DOPENSSL_INCLUDE_DIR= -DOPENSSL_CRYPTO_LIBRARY= -DOPENSSL_SSL_LIBRARY=
"$CM/cmake" --build "build-re-$ABI" --target re -j 8
"$CM/cmake" --install "build-re-$ABI" --prefix "$PFX"

echo "==> baresip ($ABI)"
# Only the static library is wanted. The baresip executable target fails to
# link here because it does not pull in mbedTLS, which does not matter: our JNI
# wrapper links libbaresip.a + libre.a + mbedTLS itself.
"$CM/cmake" -S baresip -B "build-baresip-$ABI" "${common[@]}" \
  -Dre_DIR="$PFX/lib/cmake/re" \
  -DRE_INCLUDE_DIR="$PWD/re/include" -DRE_LIBRARY="$PFX/lib/libre.a" \
  -DCMAKE_C_FLAGS="-I$PFX/include" -DSTATIC=ON \
  -DOPENSSL_INCLUDE_DIR= -DOPENSSL_CRYPTO_LIBRARY= -DOPENSSL_SSL_LIBRARY=
"$CM/cmake" --build "build-baresip-$ABI" --target baresip -j 8 || true

echo
echo "Built for $ABI:"
ls -la "$PFX/lib/libre.a" "$PFX/lib/libmbedcrypto.a" "build-baresip-$ABI/libbaresip.a" 2>/dev/null
