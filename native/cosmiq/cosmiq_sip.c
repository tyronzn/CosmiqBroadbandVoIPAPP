#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include <re.h>
#include <baresip.h>

#include "cosmiq_sip.h"

/*
 * libre writes its own diagnostics to stdout, which Android discards, so
 * engine startup is logged explicitly. Without this a failed init is just a
 * non-zero return with no indication of which step gave up.
 */
#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "CosmiqSipNative", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "CosmiqSipNative", __VA_ARGS__)
#else
#define LOGI(...) do {} while (0)
#define LOGE(...) do {} while (0)
#endif

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
	char config_path[512];
} g;

/* Init happens on the engine thread, so the caller waits for its result. */
static pthread_mutex_t init_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t init_cnd = PTHREAD_COND_INITIALIZER;
static bool init_done;
static int init_err;

/*
 * baresip writes its diagnostics to stdout, which Android throws away, so
 * they are forwarded into the platform log. Without this the only thing a
 * failure leaves behind is an errno, and the reason stays invisible.
 */
static void baresip_log_handler(uint32_t level, const char *msg)
{
	if (!msg || !*msg)
		return;

	if (level >= 2)
		LOGE("%s", msg);
	else
		LOGI("%s", msg);
}

static struct log g_baresip_log;

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
	if (err) {
		LOGE("libre_init failed: %d", err);
		return err;
	}

	/*
	 * Point baresip at a writable directory before configuring. Without
	 * this it looks for a home directory that does not exist inside an app
	 * sandbox and conf_configure() fails with ENOENT. It writes a default
	 * config there on first run.
	 */
	if (g.config_path[0]) {
		err = conf_path_set(g.config_path);
		if (err) {
			LOGE("conf_path_set(%s) failed: %d", g.config_path, err);
			return err;
		}
	}

	err = conf_configure();
	if (err) {
		LOGE("conf_configure failed: %d", err);
		return err;
	}

	g_baresip_log.h = baresip_log_handler;
	log_register_handler(&g_baresip_log);
	log_enable_info(true);
	log_enable_debug(true);

	err = baresip_init(conf_config());
	if (err) {
		LOGE("baresip_init failed: %d", err);
		return err;
	}

	/* UDP and TCP, no TLS - the carrier has no TLS port open. */
	err = ua_init("Cosmiq VoIP", true, true, false);
	if (err) {
		LOGE("ua_init failed: %d", err);
		return err;
	}

	/*
	 * baresip ends its transport setup with sip_transp_set_default() using
	 * whatever the generated config names. On a fresh install that default
	 * can be a transport this build does not include (TLS), and every
	 * register then fails with EOPNOTSUPP even though UDP is bound. Pin it.
	 */
	sip_transp_set_default(uag_sip(), SIP_TRANSP_UDP);

	LOGI("engine initialised");

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

int cosmiq_sip_start(cosmiq_event_cb cb, void *arg, const char *config_path)
{
	int err;

	if (g.started)
		return 0;

	memset(&g, 0, sizeof(g));
	g.cb = cb;
	g.cb_arg = arg;
	if (config_path)
		re_snprintf(g.config_path, sizeof(g.config_path), "%s", config_path);
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
	/*
	 * baresip splits this into URI parameters, which belong inside the
	 * angle brackets, and account parameters, which follow them. Putting
	 * transport outside the brackets makes the account fail to parse.
	 */
	/*
	 * No transport parameter: pinning it made ua_register fail with
	 * EOPNOTSUPP even though UDP transports were bound on every local
	 * address. Leaving it out lets baresip match a transport itself, and
	 * the carrier answers on both UDP and TCP anyway.
	 */
	(void)transport;
	re_snprintf(aor, sizeof(aor),
		    "<sip:%s@%s>;auth_pass=%s;regint=%d",
		    user, domain,
		    password ? password : "",
		    expires > 0 ? expires : 600);

	re_snprintf(g.domain, sizeof(g.domain), "%s", domain);

	re_thread_enter();
	g.ua = mem_deref(g.ua);          /* drop any previous account */
	err = ua_alloc(&g.ua, aor);
	if (!err) {
		/* ua_alloc only creates the account; nothing goes on the wire
		 * until this. */
		err = ua_register(g.ua);
		if (err)
			LOGE("ua_register failed: %d", err);
	}
	re_thread_leave();

	if (err)
		LOGE("ua_alloc failed: %d", err);
	else
		LOGI("account registered: sip:%s@%s (%s)", user, domain,
		     transport ? transport : "udp");

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
