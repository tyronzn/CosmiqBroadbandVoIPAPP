cmake_minimum_required(VERSION 3.18.1)
project(cosmiqg729 C)

# bcg729 (BelledonneCommunications, GPLv3) is NOT bundled in the public repo.
# If it has been fetched into ./bcg729 (see README), build the real G.729 codec;
# otherwise build a stub so the app still loads (G.729 just isn't offered).
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/bcg729/include/bcg729/encoder.h")
    file(GLOB BCG729_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/bcg729/src/*.c)
    add_library(cosmiqg729 SHARED g729_jni.c ${BCG729_SOURCES})
    target_include_directories(cosmiqg729 PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/bcg729/include
        ${CMAKE_CURRENT_SOURCE_DIR}/bcg729/src)
    message(STATUS "Cosmiq: building real G.729 codec from bcg729")
else()
    add_library(cosmiqg729 SHARED g729_stub.c)
    message(STATUS "Cosmiq: bcg729 not found — building G.729 stub (codec disabled)")
endif()

find_library(log-lib log)
target_link_libraries(cosmiqg729 ${log-lib})


# ---------------------------------------------------------------------------
# cosmiqsip - the SIP engine (baresip + libre + mbedTLS) behind a JNI bridge.
#
# The static libraries are built out-of-tree by tools/build_native_android.sh,
# because cross-compiling them is slow and has nothing to do with the app's own
# Gradle build. As with bcg729 above, the target is skipped when they are
# absent, so a fresh clone still builds and runs - just without this engine.
# ---------------------------------------------------------------------------

set(COSMIQ_NATIVE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native)
set(COSMIQ_PREFIX ${COSMIQ_NATIVE}/prefix-android-${ANDROID_ABI})
set(COSMIQ_BARESIP_LIB ${COSMIQ_NATIVE}/build-baresip-${ANDROID_ABI}/libbaresip.a)

# CMake's configure fingerprint does not track the results of if(EXISTS ...),
# so an ABI first configured before tools/build_native_android.sh had run would
# stay configured without the engine forever - the APK then silently ships that
# ABI with no libcosmiqsip.so. Listing the archives here makes CMake re-run
# configure for that ABI as soon as they appear.
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    ${COSMIQ_BARESIP_LIB}
    ${COSMIQ_PREFIX}/lib/libre.a)

if(EXISTS ${COSMIQ_BARESIP_LIB} AND EXISTS ${COSMIQ_PREFIX}/lib/libre.a)

    add_library(cosmiqsip SHARED
        cosmiq_sip_jni.c
        ${COSMIQ_NATIVE}/cosmiq/cosmiq_sip.c)

    target_include_directories(cosmiqsip PRIVATE
        ${COSMIQ_NATIVE}/cosmiq
        ${COSMIQ_NATIVE}/re/include
        ${COSMIQ_NATIVE}/baresip/include
        ${COSMIQ_PREFIX}/include)

    find_library(log-lib-sip log)

    # Order matters for static archives: baresip calls into libre, libre calls
    # into mbedTLS. OpenSLES is what the opensles audio module drives.
    target_link_libraries(cosmiqsip
        ${COSMIQ_BARESIP_LIB}
        ${COSMIQ_PREFIX}/lib/libre.a
        ${COSMIQ_PREFIX}/lib/libmbedcrypto.a
        OpenSLES
        z              # libre is built with USE_ZLIB and calls crc32
        ${log-lib-sip})

    message(STATUS "Cosmiq: building native SIP engine for ${ANDROID_ABI}")
else()
    message(STATUS
        "Cosmiq: native SIP engine not built for ${ANDROID_ABI} "
        "(run tools/build_native_android.sh ${ANDROID_ABI}) - skipping")
endif()
