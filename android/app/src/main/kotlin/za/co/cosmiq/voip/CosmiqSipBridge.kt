package za.co.cosmiq.voip

import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Puts the native baresip engine behind the MethodChannel contract the Dart
 * layer already speaks, so swapping engines does not ripple into the UI.
 *
 * The contract, unchanged from the previous Kotlin stack:
 *  - registration events are bare strings: REGISTERED / FAILED / UNREGISTERED
 *  - call events are "STATE:identity", where STATE is one of
 *    OUTGOING, INCOMING, RINGING, CONNECTED, HELD, ENDED, ERROR
 *
 * Only outgoing-call and hold states are synthesised here. Everything else is
 * reported by the engine, because only it knows what the far end actually did.
 */
class CosmiqSipBridge(private val configPath: String) {

    companion object {
        private const val TAG = "CosmiqSipBridge"
    }

    private var registrationSink: EventChannel.EventSink? = null
    private var callSink: EventChannel.EventSink? = null

    /** Remembered so ENDED and HELD can name the peer, as the old stack did. */
    private var remoteIdentity: String = ""

    /** Whether the engine came up, and why not when it did not. Surfaced
     *  through the channel because logcat tags from this process have not
     *  been reaching the host reliably. */
    private var started = false
    private var startDetail = "initialize() was never called"

    private val engine = CosmiqNativeSip { event, detail -> onEngineEvent(event, detail) }

    val isAvailable: Boolean get() = CosmiqNativeSip.isAvailable

    fun initialize(): Boolean {
        if (!isAvailable) {
            Log.w(TAG, "native engine absent - build it with tools/build_native_android.sh")
            return false
        }
        started = engine.start(configPath)
        startDetail = if (started) "ok" else "engine start rc=${engine.lastStartRc}"
        Log.i(TAG, "engine start: $startDetail")
        return started
    }

    fun destroy() {
        engine.stop()
        registrationSink = null
        callSink = null
    }

    fun setRegistrationSink(sink: EventChannel.EventSink?) {
        registrationSink = sink
    }

    fun setCallSink(sink: EventChannel.EventSink?) {
        callSink = sink
    }

    private fun emitCall(state: String, identity: String = remoteIdentity) {
        callSink?.success(if (identity.isEmpty()) state else "$state:$identity")
    }

    private fun onEngineEvent(event: String, detail: String) {
        when (event) {
            "registered" -> registrationSink?.success("REGISTERED")
            "register_failed" ->
                registrationSink?.success(
                    if (detail.isEmpty()) "FAILED" else "FAILED:$detail"
                )
            "unregistered" -> registrationSink?.success("UNREGISTERED")

            "call_incoming" -> {
                remoteIdentity = detail
                emitCall("INCOMING")
            }
            "call_ringing" -> {
                if (detail.isNotEmpty()) remoteIdentity = detail
                emitCall("RINGING")
            }
            "call_established" -> {
                if (detail.isNotEmpty()) remoteIdentity = detail
                emitCall("CONNECTED")
            }
            "call_closed" -> {
                emitCall("ENDED")
                remoteIdentity = ""
            }
            else -> Log.d(TAG, "unhandled engine event: $event")
        }
    }

    // ---- MethodChannel surface -------------------------------------------

    private fun ok(result: MethodChannel.Result, success: Boolean) {
        if (success) result.success(true)
        else result.error("SIP_ERROR", "native engine rejected the request", null)
    }

    fun register(
        username: String,
        password: String,
        domain: String,
        transport: String,
        result: MethodChannel.Result,
    ) {
        if (!isAvailable) {
            result.error("NO_ENGINE", "native SIP engine is not in this build", null)
            return
        }
        if (!started) {
            result.error("NO_ENGINE", "engine did not start: $startDetail", null)
            return
        }
        if (engine.register(username, domain, password, transport)) {
            result.success(true)
        } else {
            result.error(
                "SIP_ERROR",
                "ua_alloc failed, rc=${engine.lastRegisterRc}",
                null,
            )
        }
    }

    fun unregister(result: MethodChannel.Result) = ok(result, engine.unregister())

    fun makeCall(target: String, result: MethodChannel.Result) {
        remoteIdentity = target
        val started = engine.call(target)
        // The engine reports RINGING and CONNECTED; OUTGOING is ours to emit so
        // the UI can show the in-call screen the moment dialling begins.
        if (started) emitCall("OUTGOING") else emitCall("ERROR")
        ok(result, started)
    }

    fun answerCall(result: MethodChannel.Result) = ok(result, engine.answer())

    fun hangUp(result: MethodChannel.Result) = ok(result, engine.hangup())

    fun setHold(hold: Boolean, result: MethodChannel.Result) {
        val done = engine.hold(hold)
        // call_hold has no engine event of its own, so reflect it here.
        if (done) emitCall(if (hold) "HELD" else "CONNECTED")
        ok(result, done)
    }

    fun transferCall(target: String, result: MethodChannel.Result) =
        ok(result, engine.transfer(target))

    fun toggleMute(result: MethodChannel.Result) {
        muted = !muted
        ok(result, engine.mute(muted))
    }

    private var muted = false

    fun sendDtmf(tone: String, result: MethodChannel.Result) {
        if (tone.isEmpty()) {
            result.error("SIP_ERROR", "no DTMF digit given", null)
            return
        }
        ok(result, engine.dtmf(tone[0]))
    }
}
