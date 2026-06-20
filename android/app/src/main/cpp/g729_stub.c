// Stub used when bcg729 is NOT bundled (e.g. a fresh clone of the public repo,
// which excludes the GPLv3 bcg729 source). The library still loads so the app
// runs, but reports G.729 as unavailable, so it's simply never offered.
//
// To enable real G.729, fetch bcg729 into android/app/src/main/cpp/bcg729 (see
// README) and rebuild — CMake then compiles g729_jni.c against it instead.

#include <jni.h>

JNIEXPORT jboolean JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeIsReal(JNIEnv *env, jobject thiz) {
    return JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeInitEncoder(JNIEnv *env, jobject thiz) { return 0; }

JNIEXPORT jlong JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeInitDecoder(JNIEnv *env, jobject thiz) { return 0; }

JNIEXPORT jint JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeEncode(JNIEnv *env, jobject thiz,
        jlong ctx, jshortArray pcmIn, jint samples, jbyteArray out) { return 0; }

JNIEXPORT jint JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeDecode(JNIEnv *env, jobject thiz,
        jlong ctx, jbyteArray in, jint bytes, jshortArray pcmOut) { return 0; }

JNIEXPORT void JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeCloseEncoder(JNIEnv *env, jobject thiz, jlong ctx) {}

JNIEXPORT void JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeCloseDecoder(JNIEnv *env, jobject thiz, jlong ctx) {}
