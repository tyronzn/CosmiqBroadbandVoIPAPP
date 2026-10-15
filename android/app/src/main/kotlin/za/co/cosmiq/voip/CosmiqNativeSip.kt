package za.co.cosmiq.voip

import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Kotlin face of the shared C SIP engine (baresip + libre).
 *
 * Deliberately thin. Everything that decides anything lives in C, so iOS gets
 * the same behaviour through a Swift bridge rather than a second
 * implementation to keep in step.
 *
 * Engine events arrive on baresip's own thread; [onNativeEvent] is called from
 * there, so it hops to the main thread before handing anything upwards.
 */
class CosmiqNativeSip(private val onEvent: (event: String, detail: String) -> Unit) {

    private val main = Handler(Looper.getMainLooper())

    companion object {
        private const val TAG = "CosmiqNativeSip"

        /**
         * Whether the engine is present in this build. The .so is only produced
         * when the native libraries have been cross-compiled (see
         * tools/build_native_android.sh), so a plain clone builds and runs
         * without it rather than refusing to start.
         */
        val isAvailable: Boolean by lazy {
            try {
                System.loadLibrary("cosmiqsip")
                Log.i(TAG, "native SIP engine loaded")
                true
            } catch (e: UnsatisfiedLinkError) {
                Log.w(TAG, "native SIP engine not in this build: ${e.message}")
                false
            }
        }
    }

    /** Invoked from the engine thread by JNI. Do not rename without the JNI. */
    @Suppress("unused")
    fun onNativeEvent(event: String, detail: String) {
        Log.d(TAG, "event $event ${if (detail.isEmpty()) "" else "($detail)"}")
        main.post { onEvent(event, detail) }
    }

    fun start(): Boolean =
        if (!isAvailable) false else nativeStart(this) == 0

    fun stop() {
        if (isAvailable) nativeStop()
    }

    /**
     * [transport] is "udp" or "tcp". PortaSIP answers on both and has no TLS
     * port open, so there is no "tls" option here on purpose.
     */
    fun register(
        user: String,
        domain: String,
        password: String,
        transport: String = "udp",
        expires: Int = 600,
    ): Boolean = nativeRegister(user, domain, password, transport, expires) == 0

    fun unregister(): Boolean = nativeUnregister() == 0
    fun call(target: String): Boolean = nativeCall(target) == 0
    fun answer(): Boolean = nativeAnswer() == 0
    fun hangup(): Boolean = nativeHangup() == 0
    fun mute(on: Boolean): Boolean = nativeMute(on) == 0
    fun hold(on: Boolean): Boolean = nativeHold(on) == 0
    fun dtmf(digit: Char): Boolean = nativeDtmf(digit) == 0
    fun transfer(target: String): Boolean = nativeTransfer(target) == 0
    fun inCall(): Boolean = isAvailable && nativeInCall()

    private external fun nativeStart(listener: CosmiqNativeSip): Int
    private external fun nativeStop()
    private external fun nativeRegister(
        user: String, domain: String, password: String,
        transport: String, expires: Int,
    ): Int
    private external fun nativeUnregister(): Int
    private external fun nativeCall(target: String): Int
    private external fun nativeAnswer(): Int
    private external fun nativeHangup(): Int
    private external fun nativeMute(on: Boolean): Int
    private external fun nativeHold(on: Boolean): Int
    private external fun nativeDtmf(digit: Char): Int
    private external fun nativeTransfer(target: String): Int
    private external fun nativeInCall(): Boolean
}
