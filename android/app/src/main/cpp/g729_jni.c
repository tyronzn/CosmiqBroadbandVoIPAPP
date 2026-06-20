// JNI bridge for the bcg729 G.729 codec.
// G.729 frames are 10 ms: 80 PCM16 samples <-> 10 bytes. The helpers below
// process a whole RTP frame (a multiple of 80 samples / 10 bytes) per call.

#include <jni.h>
#include <stdint.h>
#include "bcg729/encoder.h"
#include "bcg729/decoder.h"

// Real codec present (bcg729 was bundled at build time).
JNIEXPORT jboolean JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeIsReal(JNIEnv *env, jobject thiz) {
    return JNI_TRUE;
}

JNIEXPORT jlong JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeInitEncoder(JNIEnv *env, jobject thiz) {
    // VAD/DTX disabled — emit a full 10-byte frame every 10 ms.
    return (jlong)(uintptr_t) initBcg729EncoderChannel(0);
}

JNIEXPORT jlong JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeInitDecoder(JNIEnv *env, jobject thiz) {
    return (jlong)(uintptr_t) initBcg729DecoderChannel();
}

JNIEXPORT jint JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeEncode(JNIEnv *env, jobject thiz,
        jlong ctx, jshortArray pcmIn, jint samples, jbyteArray out) {
    bcg729EncoderChannelContextStruct *enc =
        (bcg729EncoderChannelContextStruct *)(uintptr_t) ctx;
    if (enc == 0) return 0;
    jshort *pcm = (*env)->GetShortArrayElements(env, pcmIn, NULL);
    jbyte *outB = (*env)->GetByteArrayElements(env, out, NULL);
    int frames = samples / 80;
    int outLen = 0;
    for (int f = 0; f < frames; f++) {
        uint8_t len = 0;
        bcg729Encoder(enc, (const int16_t *)(pcm + f * 80),
                      (uint8_t *)(outB + outLen), &len);
        outLen += len;
    }
    (*env)->ReleaseShortArrayElements(env, pcmIn, pcm, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, out, outB, 0);
    return outLen;
}

JNIEXPORT jint JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeDecode(JNIEnv *env, jobject thiz,
        jlong ctx, jbyteArray in, jint bytes, jshortArray pcmOut) {
    bcg729DecoderChannelContextStruct *dec =
        (bcg729DecoderChannelContextStruct *)(uintptr_t) ctx;
    if (dec == 0) return 0;
    jbyte *inB = (*env)->GetByteArrayElements(env, in, NULL);
    jshort *pcm = (*env)->GetShortArrayElements(env, pcmOut, NULL);
    int frames = bytes / 10;
    int outSamples = 0;
    for (int f = 0; f < frames; f++) {
        // frameErasureFlag=0, SIDFrameFlag=0, rfc3389PayloadFlag=0
        bcg729Decoder(dec, (const uint8_t *)(inB + f * 10), 10, 0, 0, 0,
                      (int16_t *)(pcm + outSamples));
        outSamples += 80;
    }
    (*env)->ReleaseByteArrayElements(env, in, inB, JNI_ABORT);
    (*env)->ReleaseShortArrayElements(env, pcmOut, pcm, 0);
    return outSamples;
}

JNIEXPORT void JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeCloseEncoder(JNIEnv *env, jobject thiz, jlong ctx) {
    if (ctx != 0) closeBcg729EncoderChannel(
        (bcg729EncoderChannelContextStruct *)(uintptr_t) ctx);
}

JNIEXPORT void JNICALL
Java_za_co_cosmiq_voip_G729Codec_nativeCloseDecoder(JNIEnv *env, jobject thiz, jlong ctx) {
    if (ctx != 0) closeBcg729DecoderChannel(
        (bcg729DecoderChannelContextStruct *)(uintptr_t) ctx);
}
