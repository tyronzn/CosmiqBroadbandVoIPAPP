package za.co.cosmiq.voip

import android.util.Log

/**
 * Thin Kotlin wrapper over the bcg729 G.729 codec (payload type 18).
 *
 * G.729 operates on 10 ms frames: 80 PCM16 samples <-> 10 bytes. One instance
 * holds one encoder + one decoder context for the lifetime of a call.
 *
 * NOTE: bcg729 is GPLv3. See the licensing note in the project docs.
 */
class G729Codec {
    private var encCtx = 0L
    private var decCtx = 0L

    fun start() {
        encCtx = nativeInitEncoder()
        decCtx = nativeInitDecoder()
    }

    fun stop() {
        if (encCtx != 0L) nativeCloseEncoder(encCtx)
        if (decCtx != 0L) nativeCloseDecoder(decCtx)
        encCtx = 0L
        decCtx = 0L
    }

    /** Encode [samples] PCM16 from [pcm] into [out]; returns bytes written. */
    fun encode(pcm: ShortArray, samples: Int, out: ByteArray): Int =
        nativeEncode(encCtx, pcm, samples, out)

    /** Decode [bytes] of G.729 from [input] into [pcmOut]; returns samples. */
    fun decode(input: ByteArray, bytes: Int, pcmOut: ShortArray): Int =
        nativeDecode(decCtx, input, bytes, pcmOut)

    private external fun nativeIsReal(): Boolean
    private external fun nativeInitEncoder(): Long
    private external fun nativeInitDecoder(): Long
    private external fun nativeEncode(ctx: Long, pcm: ShortArray, samples: Int, out: ByteArray): Int
    private external fun nativeDecode(ctx: Long, input: ByteArray, bytes: Int, pcmOut: ShortArray): Int
    private external fun nativeCloseEncoder(ctx: Long)
    private external fun nativeCloseDecoder(ctx: Long)

    companion object {
        /**
         * True only if the library loaded AND it's the real bcg729 codec (not the
         * stub built when bcg729 isn't bundled). Gates whether G.729 is offered.
         */
        @Volatile
        var available = false
            private set

        init {
            available = try {
                System.loadLibrary("cosmiqg729")
                val real = G729Codec().nativeIsReal()
                Log.i("CosmiqSip",
                    if (real) "G.729 (bcg729) codec loaded"
                    else "G.729 unavailable (bcg729 not bundled)")
                real
            } catch (t: Throwable) {
                Log.w("CosmiqSip", "G.729 codec unavailable: ${t.message}")
                false
            }
        }
    }
}
