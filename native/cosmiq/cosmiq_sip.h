/*
 * Cosmiq VoIP - C API over baresip.
 *
 * One engine for Android and iOS. The platform bridges (JNI on Android, Swift
 * on iOS) call only these functions, so everything above them - including the
 * Dart SipService - stays identical on both platforms.
 *
 * Threading: baresip and libre are a single-threaded event loop. That loop runs
 * on a thread this library owns, and every function below is safe to call from
 * any other thread; each one takes the libre lock before touching engine state.
 * Events arrive on the engine thread, so the bridges must hop to their own
 * platform's main thread before touching UI.
 */
#ifndef COSMIQ_SIP_H
#define COSMIQ_SIP_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Engine events, delivered as strings so the bridges stay dumb.
 *
 *   registered | register_failed | unregistered
 *   call_incoming | call_ringing | call_established | call_closed
 *
 * `detail` carries the peer URI where there is one, the failure reason for
 * register_failed and call_closed, and is never NULL (it may be empty).
 */
typedef void (*cosmiq_event_cb)(const char *event, const char *detail,
                                void *arg);

/*
 * Start the engine and its event loop. Call once, before anything else.
 *
 * `config_path` is a writable directory baresip keeps its configuration in.
 * It has no sensible default on a mobile platform - baresip would look for a
 * home directory that does not exist in an app sandbox - so the caller must
 * supply one (the app's files directory on Android, Documents on iOS).
 *
 * `dns_servers` is a comma-separated list of resolver addresses. It is not
 * optional on Android: libre discovers nameservers by reading
 * /etc/resolv.conf, which does not exist there, and SIP's SRV lookup cannot
 * fall back to getaddrinfo. With none configured every REGISTER fails with
 * ENOTSUP, reported as "Operation not supported on transport endpoint".
 */
int cosmiq_sip_start(cosmiq_event_cb cb, void *arg, const char *config_path,
		     const char *dns_servers);

/* Tear the engine down and join its thread. */
void cosmiq_sip_stop(void);

/*
 * Register to a SIP server. `transport` is "udp" or "tcp" - PortaSIP answers
 * on both, and has no TLS port open. Returns 0 if the REGISTER was sent; the
 * outcome arrives as a `registered` or `register_failed` event.
 */
int cosmiq_sip_register(const char *user, const char *domain,
                        const char *password, const char *transport,
                        int expires);

int cosmiq_sip_unregister(void);

/* Dial. `target` may be a bare number or a full SIP URI. */
int cosmiq_sip_call(const char *target);

int cosmiq_sip_answer(void);
int cosmiq_sip_hangup(void);
int cosmiq_sip_mute(bool on);
int cosmiq_sip_hold(bool on);
int cosmiq_sip_dtmf(char digit);
int cosmiq_sip_transfer(const char *target);

/* True while a call exists, whether ringing, answered or on hold. */
bool cosmiq_sip_in_call(void);

#ifdef __cplusplus
}
#endif

#endif /* COSMIQ_SIP_H */
