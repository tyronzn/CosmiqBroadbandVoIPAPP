#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include <re.h>
#include <baresip.h>

#include "cosmiq_sip.h"

/*
 * All engine state lives here. libre is a single-threaded event loop, so this
 * is only ever touched either from the engine thread itself or under
 * re_thread_enter()/re_thread_leave(), which takes the same lock the loop does.
 */
static struct {
	struct ua *ua;
	struct call *call;
	cosmiq_event_cb cb;
	void *cb_arg;
	pthread_t thread;
	bool started;
	char domain[256];   /* kept so a bare number can be made into a URI */
} g;

/* Init happens on the engine thread, so the caller waits for its result. */
static pthread_mutex_t init_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t init_cnd = PTHREAD_COND_INITIALIZER;
static bool init_done;
static int init_err;

static void emit(const char *ev, const char *detail)
{
	if (g.cb)
		g.cb(ev, detail ? detail : "", g.cb_arg);
}

static void event_handler(enum bevent_ev ev, struct bevent *event, void *arg)
{
	struct call *call = bevent_get_call(event);
	const char *peer = call ? call_peeruri(call) : NULL;
	(void)arg;

	switch (ev) {

	case BEVENT_REGISTER_OK:
		emit("registered", "");
		break;

	case BEVENT_REGISTER_FAIL:
		emit("register_failed", bevent_get_text(event));
		break;

	case BEVENT_UNREGISTERING:
		emit("unregistered", "");
		break;

	case BEVENT_CALL_INCOMING:
		g.call = call;
		emit("call_incoming", peer);
		break;

	case BEVENT_CALL_RINGING:
		emit("call_ringing", peer);
		break;

	case BEVENT_CALL_ESTABLISHED:
		g.call = call;
		emit("call_established", peer);
		break;

	case BEVENT_CALL_CLOSED:
		/* Only clear if this is the call we are tracking: a stale leg
		 * closing must not wipe out a newer one. */
		if (call == g.call)
			g.call = NULL;
		emit("call_closed", bevent_get_text(event));
		break;

	default:
		break;
	}
}

static int engine_init(void)
{
	int err;

	err = libre_init();
	if (err)
		return err;

	/* Defaults are fine: no config file is shipped with the app. */
	err = conf_configure();
	if (err)
		return err;

	err = baresip_init(conf_config());
	if (err)
		return err;

	/* UDP and TCP, no TLS - the carrier has no TLS port open. */
	err = ua_init("Cosmiq VoIP", true, true, false);
	if (err)
		return err;

	return bevent_register(event_handler, NULL);
}

static void engine_close(void)
{
	g.call = NULL;
	g.ua = mem_deref(g.ua);
	ua_close();
	baresip_close();
	libre_close();
}

static void *engine_thread(void *arg)
{
	int err;
	(void)arg;

	err = engine_init();

	pthread_mutex_lock(&init_mtx);
	init_err = err;
	init_done = true;
	pthread_cond_signal(&init_cnd);
	pthread_mutex_unlock(&init_mtx);

	if (err)
		return NULL;

	/* Blocks until re_cancel(). */
	re_main(NULL);

	engine_close();
	return NULL;
}

int cosmiq_sip_start(cosmiq_event_cb cb, void *arg)
{
	int err;

	if (g.started)
		return 0;

	memset(&g, 0, sizeof(g));
	g.cb = cb;
	g.cb_arg = arg;
	init_done = false;
	init_err = 0;

	err = pthread_create(&g.thread, NULL, engine_thread, NULL);
	if (err)
		return err;

	/* Everything libre touches must be initialised on its own thread, so
	 * wait here rather than racing the first register(). */
	pthread_mutex_lock(&init_mtx);
	while (!init_done)
		pthread_cond_wait(&init_cnd, &init_mtx);
	err = init_err;
	pthread_mutex_unlock(&init_mtx);

	if (err) {
		pthread_join(g.thread, NULL);
		return err;
	}

	g.started = true;
	return 0;
}

void cosmiq_sip_stop(void)
{
	if (!g.started)
		return;

	re_thread_enter();
	re_cancel();
	re_thread_leave();

	pthread_join(g.thread, NULL);
	g.started = false;
}

int cosmiq_sip_register(const char *user, const char *domain,
			const char *password, const char *transport,
			int expires)
{
	char aor[512];
	int err;

	if (!g.started || !user || !domain)
		return EINVAL;

	/*
	 * baresip takes the whole account as one AOR string. auth_pass carries
	 * the secret, and regint is the re-REGISTER interval in seconds.
	 */
	re_snprintf(aor, sizeof(aor),
		    "sip:%s@%s;auth_pass=%s;transport=%s;regint=%d",
		    user, domain, password ? password : "",
		    transport ? transport : "udp",
		    expires > 0 ? expires : 600);

	re_snprintf(g.domain, sizeof(g.domain), "%s", domain);

	re_thread_enter();
	g.ua = mem_deref(g.ua);          /* drop any previous account */
	err = ua_alloc(&g.ua, aor);
	re_thread_leave();

	return err;
}

int cosmiq_sip_unregister(void)
{
	if (!g.started || !g.ua)
		return EINVAL;

	re_thread_enter();
	ua_unregister(g.ua);
	re_thread_leave();

	return 0;
}

int cosmiq_sip_call(const char *target)
{
	char uri[512];
	int err;

	if (!g.started || !g.ua || !target)
		return EINVAL;

	/* Accept a bare number or a full URI. */
	if (0 == re_regex(target, strlen(target), "sip:"))
		re_snprintf(uri, sizeof(uri), "%s", target);
	else
		re_snprintf(uri, sizeof(uri), "sip:%s@%s", target, g.domain);

	re_thread_enter();
	err = ua_connect(g.ua, &g.call, NULL, uri, VIDMODE_OFF);
	re_thread_leave();

	return err;
}

int cosmiq_sip_answer(void)
{
	int err;

	if (!g.started || !g.call)
		return EINVAL;

	re_thread_enter();
	err = call_answer(g.call, 200, VIDMODE_OFF);
	re_thread_leave();

	return err;
}

int cosmiq_sip_hangup(void)
{
	if (!g.started || !g.call)
		return EINVAL;

	re_thread_enter();
	/* ua_hangup sends CANCEL or BYE as appropriate for the call state. */
	ua_hangup(g.ua, g.call, 0, NULL);
	g.call = NULL;
	re_thread_leave();

	return 0;
}

int cosmiq_sip_mute(bool on)
{
	if (!g.started || !g.call)
		return EINVAL;

	re_thread_enter();
	audio_mute(call_audio(g.call), on);
	re_thread_leave();

	return 0;
}

int cosmiq_sip_hold(bool on)
{
	int err;

	if (!g.started || !g.call)
		return EINVAL;

	re_thread_enter();
	err = call_hold(g.call, on);
	re_thread_leave();

	return err;
}

int cosmiq_sip_dtmf(char digit)
{
	int err;

	if (!g.started || !g.call)
		return EINVAL;

	re_thread_enter();
	err = call_send_digit(g.call, digit);
	re_thread_leave();

	return err;
}

int cosmiq_sip_transfer(const char *target)
{
	char uri[512];
	int err;

	if (!g.started || !g.call || !target)
		return EINVAL;

	if (0 == re_regex(target, strlen(target), "sip:"))
		re_snprintf(uri, sizeof(uri), "%s", target);
	else
		re_snprintf(uri, sizeof(uri), "sip:%s@%s", target, g.domain);

	re_thread_enter();
	err = call_transfer(g.call, uri);
	re_thread_leave();

	return err;
}

bool cosmiq_sip_in_call(void)
{
	return g.started && g.call != NULL;
}
