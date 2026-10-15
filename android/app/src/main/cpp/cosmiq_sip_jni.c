/*
 * JNI bridge to the shared C engine (native/cosmiq/cosmiq_sip.c).
 *
 * Deliberately thin: it marshals arguments and forwards events. All call logic
 * lives in the C layer so iOS can reuse it unchanged through a Swift bridge.
 */
#include <jni.h>
#include <stdbool.h>
#include <string.h>

#include "cosmiq_sip.h"

static JavaVM *g_vm;
static jobject g_listener;      /* global ref to the Kotlin listener */
static jmethodID g_on_event;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
	(void)reserved;
	g_vm = vm;
	return JNI_VERSION_1_6;
}

/*
 * Engine events arrive on baresip's own thread, which the JVM knows nothing
 * about, so it has to be attached before any JNI call and detached after.
 * Kotlin is responsible for hopping to the main thread from here.
 */
static void event_cb(const char *event, const char *detail, void *arg)
{
	JNIEnv *env = NULL;
	bool attached = false;
	jstring jev, jdet;

	(void)arg;

	if (!g_vm || !g_listener || !g_on_event)
		return;

	if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
		if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK)
			return;
		attached = true;
	}

	jev = (*env)->NewStringUTF(env, event ? event : "");
	jdet = (*env)->NewStringUTF(env, detail ? detail : "");

	if (jev && jdet)
		(*env)->CallVoidMethod(env, g_listener, g_on_event, jev, jdet);

	/* Swallow anything thrown in Kotlin: an exception left pending here
	 * would blow up the next JNI call on this thread instead. */
	if ((*env)->ExceptionCheck(env))
		(*env)->ExceptionClear(env);

	if (jev)
		(*env)->DeleteLocalRef(env, jev);
	if (jdet)
		(*env)->DeleteLocalRef(env, jdet);

	if (attached)
		(*g_vm)->DetachCurrentThread(g_vm);
}

#define JNI_FN(name) \
	Java_za_co_cosmiq_voip_CosmiqNativeSip_##name

JNIEXPORT jint JNICALL JNI_FN(nativeStart)(JNIEnv *env, jobject thiz,
					   jobject listener)
{
	jclass cls;

	if (g_listener)
		(*env)->DeleteGlobalRef(env, g_listener);

	g_listener = (*env)->NewGlobalRef(env, listener);
	cls = (*env)->GetObjectClass(env, listener);
	g_on_event = (*env)->GetMethodID(env, cls, "onNativeEvent",
					 "(Ljava/lang/String;Ljava/lang/String;)V");
	(void)thiz;

	if (!g_on_event)
		return -1;

	return cosmiq_sip_start(event_cb, NULL);
}

JNIEXPORT void JNICALL JNI_FN(nativeStop)(JNIEnv *env, jobject thiz)
{
	(void)thiz;
	cosmiq_sip_stop();

	if (g_listener) {
		(*env)->DeleteGlobalRef(env, g_listener);
		g_listener = NULL;
	}
	g_on_event = NULL;
}

JNIEXPORT jint JNICALL JNI_FN(nativeRegister)(JNIEnv *env, jobject thiz,
					      jstring user, jstring domain,
					      jstring password,
					      jstring transport, jint expires)
{
	const char *u = (*env)->GetStringUTFChars(env, user, NULL);
	const char *d = (*env)->GetStringUTFChars(env, domain, NULL);
	const char *p = (*env)->GetStringUTFChars(env, password, NULL);
	const char *t = (*env)->GetStringUTFChars(env, transport, NULL);
	int err;

	(void)thiz;
	err = cosmiq_sip_register(u, d, p, t, (int)expires);

	(*env)->ReleaseStringUTFChars(env, user, u);
	(*env)->ReleaseStringUTFChars(env, domain, d);
	(*env)->ReleaseStringUTFChars(env, password, p);
	(*env)->ReleaseStringUTFChars(env, transport, t);
	return err;
}

JNIEXPORT jint JNICALL JNI_FN(nativeUnregister)(JNIEnv *env, jobject thiz)
{
	(void)env; (void)thiz;
	return cosmiq_sip_unregister();
}

JNIEXPORT jint JNICALL JNI_FN(nativeCall)(JNIEnv *env, jobject thiz,
					  jstring target)
{
	const char *t = (*env)->GetStringUTFChars(env, target, NULL);
	int err;

	(void)thiz;
	err = cosmiq_sip_call(t);
	(*env)->ReleaseStringUTFChars(env, target, t);
	return err;
}

JNIEXPORT jint JNICALL JNI_FN(nativeAnswer)(JNIEnv *env, jobject thiz)
{
	(void)env; (void)thiz;
	return cosmiq_sip_answer();
}

JNIEXPORT jint JNICALL JNI_FN(nativeHangup)(JNIEnv *env, jobject thiz)
{
	(void)env; (void)thiz;
	return cosmiq_sip_hangup();
}

JNIEXPORT jint JNICALL JNI_FN(nativeMute)(JNIEnv *env, jobject thiz, jboolean on)
{
	(void)env; (void)thiz;
	return cosmiq_sip_mute(on == JNI_TRUE);
}

JNIEXPORT jint JNICALL JNI_FN(nativeHold)(JNIEnv *env, jobject thiz, jboolean on)
{
	(void)env; (void)thiz;
	return cosmiq_sip_hold(on == JNI_TRUE);
}

JNIEXPORT jint JNICALL JNI_FN(nativeDtmf)(JNIEnv *env, jobject thiz, jchar digit)
{
	(void)env; (void)thiz;
	return cosmiq_sip_dtmf((char)digit);
}

JNIEXPORT jint JNICALL JNI_FN(nativeTransfer)(JNIEnv *env, jobject thiz,
					      jstring target)
{
	const char *t = (*env)->GetStringUTFChars(env, target, NULL);
	int err;

	(void)thiz;
	err = cosmiq_sip_transfer(t);
	(*env)->ReleaseStringUTFChars(env, target, t);
	return err;
}

JNIEXPORT jboolean JNICALL JNI_FN(nativeInCall)(JNIEnv *env, jobject thiz)
{
	(void)env; (void)thiz;
	return cosmiq_sip_in_call() ? JNI_TRUE : JNI_FALSE;
}
