package za.co.cosmiq.voip

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * CosmiqSipManager — Pure Kotlin SIP/UDP client.
 *
 * Zero external dependencies. Uses DatagramSocket for SIP signalling
 * and Android AudioRecord/AudioTrack for G.711 RTP audio.
 *
 * Implements:
 *  - SIP REGISTER with DIGEST (MD5) authentication
 *  - Outbound calls (INVITE / ACK / BYE)
 *  - Inbound calls (INVITE / 200 OK / ACK / BYE)
 *  - G.711 μ-law (PCMU) audio codec
 *  - DTMF via RFC 2833 (telephone-event)
 */
class CosmiqSipManager(private val context: Context) {

    companion object {
        private const val TAG = "CosmiqSip"
        private const val SIP_PORT = 5060
        private const val LOCAL_RTP_PORT = 30000
        private const val SAMPLE_RATE = 8000
        private const val FRAME_SIZE = 160 // 20ms at 8kHz
    }

    // Config — set during register()
    private var username = ""
    private var password = ""
    private var domain = ""
    private var localIp = "0.0.0.0"

    // RFC 8599 push parameters (FCM) advertised in the REGISTER Contact so
    // PortaSIP can push incoming calls when the app is closed.
    private var pnProvider = ""
    private var pnParam = ""
    private var pnPrm = ""

    // SIP state
    private var cseq = 1
    private var callId = newCallId()
    private var tag = newTag()
    private var registered = false
    private var currentCallId = ""
    private var currentCallTag = ""
    private var currentToTag = ""          // To-tag learned from the remote party
    private var currentRemoteTarget = ""   // user part of the remote URI (for BYE)
    private var inviteCseq = 1             // CSeq counter for the current call dialog
    private var currentInviteBranch = ""   // Via branch of the latest INVITE (for CANCEL)
    private var callConfirmed = false      // true once the dialog is answered (200 OK)

    // Codec: user preference + the payload type actually negotiated for the call.
    // 0 = PCMU (G.711 µ-law), 8 = PCMA (G.711 A-law), 18 = G.729 (bcg729).
    private var preferredCodec = "PCMU"
    private var negotiatedPt = 0
    private var g729: G729Codec? = null   // non-null only while a G.729 call is up

    private val muted = AtomicBoolean(false)
    private val held = AtomicBoolean(false)

    // Established-dialog routing, captured from the 200 OK (outbound) or INVITE
    // (inbound) so in-dialog requests — re-INVITE (hold), REFER (transfer), BYE —
    // reach the remote through PortaSIP's Record-Route proxies.
    private var dlgRemoteTarget = ""                   // remote Contact = Request-URI
    private var dlgRemoteUri = ""                      // remote AOR for the To header
    private val dlgRouteSet = mutableListOf<String>()  // Route headers, in send order
    private var dlgCseq = 1                            // CSeq for in-dialog requests

    private var remoteRtpHost = ""
    private var remoteRtpPort = 0
    private var isIncomingCall = false
    private var incomingInvite = ""

    // True while the SIP socket is open and the receive loop should run.
    private val sipRunning = AtomicBoolean(false)

    // The single receive loop funnels SIP responses here, split by transaction
    // type so call threads and the (re-)register handshake never steal each
    // other's responses.
    private val sipResponses = LinkedBlockingQueue<String>()       // calls
    private val registerResponses = LinkedBlockingQueue<String>()  // REGISTER

    // Optional digest challenge data for an INVITE re-send.
    private data class Auth(
        val realm: String, val nonce: String, val response: String,
        val proxy: Boolean, val uri: String
    )

    // Sockets
    private var sipSocket: DatagramSocket? = null
    private var rtpSocket: DatagramSocket? = null

    // Audio
    private val audioRunning = AtomicBoolean(false)
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null

    // Flutter event sinks
    private var registrationSink: EventChannel.EventSink? = null
    private var callSink: EventChannel.EventSink? = null

    // ---------------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------------

    fun initialize() {
        Log.i(TAG, "SIP manager initialised (pure Kotlin/UDP)")
    }

    fun destroy() {
        sipRunning.set(false)
        registered = false
        stopAudio()
        sipSocket?.close()
        rtpSocket?.close()
    }

    // ---------------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------------

    fun register(
        user: String, pass: String, dom: String,
        pushProvider: String, pushParam: String, pushToken: String,
        result: MethodChannel.Result
    ) {
        username = user; password = pass; domain = dom
        pnProvider = pushProvider; pnParam = pushParam; pnPrm = pushToken
        callId = newCallId(); tag = newTag(); cseq = 1

        thread {
            try {
                sipSocket?.close()
                sipSocket = DatagramSocket(SIP_PORT)
                localIp = getLocalIp()
                sipRunning.set(true)
                // Receive loop runs for the whole socket lifetime so it can also
                // service periodic re-REGISTER responses.
                startReceiveLoop()

                sendEvent(registrationSink, "REGISTERING")
                result.success(true)

                if (doRegister()) {
                    registered = true
                    sendEvent(registrationSink, "REGISTERED")
                    Log.i(TAG, "SIP registered: $username@$domain")
                    startReRegisterLoop()
                } else {
                    sendEvent(registrationSink, "FAILED")
                    Log.w(TAG, "Registration failed")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Register error: ${e.message}")
                sendEvent(registrationSink, "FAILED")
            }
        }
    }

    /** One REGISTER handshake (REGISTER → 401 → authed REGISTER → 200). */
    private fun doRegister(): Boolean {
        registerResponses.clear()
        cseq++
        sendSip(buildRegister(null, null, null))
        val resp1 = registerResponses.poll(6, TimeUnit.SECONDS) ?: return false
        if (resp1.startsWith("SIP/2.0 200")) return true
        if (resp1.startsWith("SIP/2.0 401") || resp1.startsWith("SIP/2.0 407")) {
            val authHeader = extractHeader(resp1, "WWW-Authenticate")
                ?: extractHeader(resp1, "Proxy-Authenticate") ?: return false
            val realm = extractParam(authHeader, "realm") ?: domain
            val nonce = extractParam(authHeader, "nonce") ?: ""
            val authInfo = DigestAuth(username, password, realm, nonce,
                "sip:$domain", "REGISTER")
            cseq++
            sendSip(buildRegister(realm, nonce, authInfo))
            val resp2 = registerResponses.poll(6, TimeUnit.SECONDS) ?: return false
            return resp2.startsWith("SIP/2.0 200")
        }
        return false
    }

    /** Refresh the registration well before the 600s Expires lapses. */
    private fun startReRegisterLoop() {
        thread {
            while (registered && sipRunning.get()) {
                try { Thread.sleep(270_000) } catch (_: Exception) {}
                if (!registered || !sipRunning.get()) break
                if (doRegister()) {
                    Log.i(TAG, "SIP re-registered")
                } else {
                    Log.w(TAG, "Re-register failed")
                    sendEvent(registrationSink, "FAILED")
                }
            }
        }
    }

    fun unregister(result: MethodChannel.Result) {
        registered = false
        sipRunning.set(false)
        stopAudio()
        sipSocket?.close()
        sendEvent(registrationSink, "UNREGISTERED")
        result.success(true)
    }

    // ---------------------------------------------------------------------------
    // Outbound call
    // ---------------------------------------------------------------------------

    fun makeCall(target: String, dom: String, result: MethodChannel.Result) {
        currentCallId = newCallId()
        currentCallTag = newTag()
        currentToTag = ""
        currentRemoteTarget = target
        dlgRemoteUri = "sip:$target@$domain"
        isIncomingCall = false
        callConfirmed = false
        held.set(false)
        inviteCseq = 1
        sipResponses.clear()

        thread {
            try {
                sendEvent(callSink, "OUTGOING:$target")
                val uri = "sip:$target@$domain"
                var inviteBranch = newBranch()
                currentInviteBranch = inviteBranch
                sendSip(buildInvite(target, buildSdp(), inviteCseq, inviteBranch, null))
                result.success(true)

                var authed = false
                val deadline = System.currentTimeMillis() + 32_000
                while (System.currentTimeMillis() < deadline) {
                    val resp = sipResponses.poll(2, TimeUnit.SECONDS) ?: continue
                    // Only act on responses to our CURRENT INVITE transaction.
                    // Ignores the 200 that answers our own CANCEL, and stale
                    // retransmits of the pre-auth INVITE's 401 (older CSeq),
                    // which would otherwise be mistaken for a call failure.
                    if (extractCSeqMethod(resp) != "INVITE") continue
                    if (extractCSeqNum(resp) != inviteCseq) continue
                    val code = parseStatus(resp)
                    when {
                        code == 100 -> { /* Trying */ }
                        code == 180 || code == 183 -> sendEvent(callSink, "RINGING:$target")

                        (code == 401 || code == 407) && !authed -> {
                            authed = true
                            // A non-2xx final response must be ACKed on the
                            // INVITE's branch / CSeq before re-sending.
                            sendSip(buildAck(target, extractHeader(resp, "To") ?: "",
                                inviteCseq, inviteBranch, ack2xx = false))
                            val ch = extractHeader(resp, "WWW-Authenticate")
                                ?: extractHeader(resp, "Proxy-Authenticate")
                            if (ch == null) { sendEvent(callSink, "ERROR:$target"); return@thread }
                            val realm = extractParam(ch, "realm") ?: domain
                            val nonce = extractParam(ch, "nonce") ?: ""
                            val digest = DigestAuth(username, password, realm, nonce, uri, "INVITE")
                            inviteCseq++
                            inviteBranch = newBranch()
                            currentInviteBranch = inviteBranch
                            sendSip(buildInvite(target, buildSdp(), inviteCseq, inviteBranch,
                                Auth(realm, nonce, digest, code == 407, uri)))
                        }

                        code == 200 -> {
                            callConfirmed = true
                            currentToTag = extractTag(extractHeader(resp, "To") ?: "")
                            captureDialog(resp, isUac = true)
                            parseRemoteSdp(resp)
                            Log.i(TAG, "Call connected to $target " +
                                "(codec ${codecName(negotiatedPt)})")
                            // ACK for a 2xx is its own transaction (new branch).
                            sendSip(buildAck(target, extractHeader(resp, "To") ?: "",
                                inviteCseq, newBranch(), ack2xx = true))
                            sendEvent(callSink, "CONNECTED:$target")
                            startAudio()
                            // Block until the call ends (BYE/hangup stops audio).
                            while (audioRunning.get()) Thread.sleep(200)
                            return@thread
                        }

                        code in 400..699 -> {
                            sendSip(buildAck(target, extractHeader(resp, "To") ?: "",
                                inviteCseq, inviteBranch, ack2xx = false))
                            sendEvent(callSink, "ERROR:$target")
                            return@thread
                        }
                    }
                }
                // No final response in time.
                sendEvent(callSink, "ERROR:$target")
            } catch (e: Exception) {
                Log.e(TAG, "makeCall error: ${e.message}")
                sendEvent(callSink, "ERROR:$target")
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Inbound call
    // ---------------------------------------------------------------------------

    /**
     * The ONLY thread that reads sipSocket after registration. It routes SIP
     * responses to [sipResponses] (consumed by call threads) and handles
     * incoming requests (INVITE / BYE / OPTIONS) inline. This removes the
     * previous race where two threads read the same datagram socket.
     */
    private fun startReceiveLoop() {
        thread {
            while (sipRunning.get()) {
                try {
                    val msg = receiveSip(timeout = 1000) ?: continue
                    when {
                        msg.startsWith("SIP/2.0") ->
                            if (extractCSeqMethod(msg) == "REGISTER") registerResponses.offer(msg)
                            else sipResponses.offer(msg)
                        msg.startsWith("INVITE ") -> handleIncomingInvite(msg)
                        msg.startsWith("BYE ") -> {
                            sendSip(buildResponse(msg, 200, "OK"))
                            callConfirmed = false
                            stopAudio()
                            sendEvent(callSink, "ENDED:${remoteIdentityFromMsg(msg)}")
                        }
                        // Keep the NAT pinhole open and keep the registrar happy.
                        msg.startsWith("OPTIONS ") -> sendSip(buildResponse(msg, 200, "OK"))
                        // Transfer progress (sipfrag) — acknowledge so it stops retransmitting.
                        msg.startsWith("NOTIFY ") -> sendSip(buildResponse(msg, 200, "OK"))
                        else -> { /* ACK, INFO, CANCEL, etc. — ignore */ }
                    }
                } catch (e: Exception) { Log.w(TAG, "receive loop: ${e.message}") }
            }
        }
    }

    private fun handleIncomingInvite(invite: String) {
        val cid = extractHeader(invite, "Call-ID") ?: ""

        // In-dialog re-INVITE on the current call (e.g. remote hold/resume) —
        // answer it in place rather than treating it as a brand-new call.
        if (callConfirmed && cid == currentCallId) {
            val remoteDir = when {
                invite.contains("a=sendonly") || invite.contains("a=inactive") -> "recvonly"
                else -> "sendrecv"
            }
            sendSip(buildResponse(invite, 200, "OK", buildSdp(remoteDir)))
            return
        }

        incomingInvite = invite
        isIncomingCall = true
        callConfirmed = false
        held.set(false)
        val fromHeader = extractHeader(invite, "From") ?: "Unknown"
        val caller = extractSipUser(fromHeader)
        currentCallId = cid.ifEmpty { newCallId() }
        currentCallTag = newTag()
        currentToTag = extractTag(fromHeader)          // remote's tag
        currentRemoteTarget = caller
        dlgRemoteUri = extractUriOnly(fromHeader)       // remote AOR

        // Send 180 Ringing
        sendSip(buildResponse(invite, 180, "Ringing"))
        sendEvent(callSink, "INCOMING:$caller")
    }

    fun answerCall(result: MethodChannel.Result) {
        thread {
            try {
                val sdp = buildSdp()
                sendSip(buildResponse(incomingInvite, 200, "OK", sdp))
                parseRemoteSdp(incomingInvite)
                captureDialog(incomingInvite, isUac = false)
                callConfirmed = true
                val caller = extractSipUser(extractHeader(incomingInvite, "From") ?: "")
                sendEvent(callSink, "CONNECTED:$caller")
                startAudio()
                result.success(true)
                // The receive loop will fire ENDED on BYE; just hold the media open.
                while (audioRunning.get()) Thread.sleep(200)
            } catch (e: Exception) {
                result.error("ANSWER_ERROR", e.message, null)
            }
        }
    }

    /**
     * Terminate the current call. The correct SIP request depends on call state:
     *  - confirmed dialog (answered)        -> BYE
     *  - outbound call still proceeding      -> CANCEL (BYE is invalid here, which
     *                                           is why the far end kept ringing)
     *  - inbound call we never answered      -> 603 Decline to the INVITE
     */
    fun hangUp(result: MethodChannel.Result) {
        thread {
            try {
                when {
                    callConfirmed -> sendSip(buildBye())
                    !isIncomingCall && currentCallId.isNotEmpty() -> sendSip(buildCancel())
                    isIncomingCall && incomingInvite.isNotEmpty() ->
                        sendSip(buildResponse(incomingInvite, 603, "Decline"))
                }
                callConfirmed = false
                stopAudio()
                sendEvent(callSink, "ENDED:")
                result.success(true)
            } catch (e: Exception) {
                result.error("HANGUP_ERROR", e.message, null)
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Hold / Transfer (in-dialog requests)
    // ---------------------------------------------------------------------------

    /** Put the call on hold (re-INVITE a=sendonly) or resume it (a=sendrecv). */
    fun setHold(hold: Boolean, result: MethodChannel.Result) {
        thread {
            try {
                if (!callConfirmed) { result.success(held.get()); return@thread }
                val sdp = buildSdp(if (hold) "sendonly" else "sendrecv")
                val ok = sendDialogRequest("INVITE") { cseq, branch, auth ->
                    buildInDialog("INVITE", cseq, branch, auth, sdp, "application/sdp")
                }
                if (ok != null) {
                    // ACK the 2xx re-INVITE (same CSeq number, new branch).
                    sendSip(buildInDialog("ACK", extractCSeqNum(ok), newBranch()))
                    held.set(hold)
                    Log.i(TAG, if (hold) "Call held" else "Call resumed")
                }
                result.success(held.get())
            } catch (e: Exception) {
                result.error("HOLD_ERROR", e.message, null)
            }
        }
    }

    /** Blind-transfer the call to [target] (REFER). The remote then BYEs us. */
    fun transferCall(target: String, result: MethodChannel.Result) {
        thread {
            try {
                if (!callConfirmed) { result.success(false); return@thread }
                val referHeaders = "Refer-To: <sip:$target@$domain>\r\n" +
                    "Referred-By: <sip:$username@$domain>\r\n"
                val resp = sendDialogRequest("REFER") { cseq, branch, auth ->
                    buildInDialog("REFER", cseq, branch, auth, extraHeaders = referHeaders)
                }
                val accepted = resp != null && parseStatus(resp) in 200..299
                if (accepted) {
                    Log.i(TAG, "Transfer to $target accepted (REFER ${parseStatus(resp!!)})")
                    // Blind transfer: the remote leg re-targets and will BYE us;
                    // the receive loop fires ENDED when that BYE arrives.
                }
                result.success(accepted)
            } catch (e: Exception) {
                result.error("TRANSFER_ERROR", e.message, null)
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Mute / Speaker / DTMF
    // ---------------------------------------------------------------------------

    fun toggleMute(result: MethodChannel.Result) {
        val m = !muted.get()
        muted.set(m)
        result.success(m)
    }

    /** Select the preferred codec offered on the next call. */
    fun setPreferredCodec(codec: String, result: MethodChannel.Result) {
        preferredCodec = when {
            codec.equals("G729", true) && G729Codec.available -> "G729"
            codec.equals("PCMA", true) || codec.equals("alaw", true) -> "PCMA"
            else -> "PCMU"
        }
        Log.i(TAG, "Preferred codec: $preferredCodec")
        result.success(preferredCodec)
    }

    /** Whether the G.729 (bcg729) native codec loaded on this device. */
    fun isG729Available(result: MethodChannel.Result) {
        result.success(G729Codec.available)
    }

    fun toggleSpeaker(result: MethodChannel.Result) {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.isSpeakerphoneOn = !am.isSpeakerphoneOn
        result.success(am.isSpeakerphoneOn)
    }

    fun sendDtmf(tone: String, result: MethodChannel.Result) {
        // RFC 2833 DTMF — send as RTP telephone-event
        // For simplicity, send as SIP INFO
        thread {
            try {
                val info = buildInfo(tone)
                sendSip(info)
                result.success(true)
            } catch (e: Exception) {
                result.error("DTMF_ERROR", e.message, null)
            }
        }
    }

    // ---------------------------------------------------------------------------
    // RTP Audio (G.711 μ-law)
    // ---------------------------------------------------------------------------

    private fun startAudio() {
        if (audioRunning.get()) return
        audioRunning.set(true)
        muted.set(false)

        // Spin up a G.729 codec instance for this call if it was negotiated.
        g729 = if (negotiatedPt == 18 && G729Codec.available)
            G729Codec().apply { start() } else null

        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        am.isSpeakerphoneOn = false

        rtpSocket = DatagramSocket(LOCAL_RTP_PORT)
        rtpSocket!!.soTimeout = 100

        // Send thread — microphone → G.711 → RTP
        thread {
            val bufSize = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(FRAME_SIZE * 2)

            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, bufSize
            )
            audioRecord!!.startRecording()

            val pcmBuf = ShortArray(FRAME_SIZE)
            val rtpBuf = ByteArray(12 + FRAME_SIZE)
            val g729Out = ByteArray(64)
            var seq = 0; var ts = 0; val ssrc = (Math.random() * Int.MAX_VALUE).toInt()
            var micPeak = 0; var micFrames = 0   // diagnostics: outbound mic level

            while (audioRunning.get()) {
                val read = audioRecord!!.read(pcmBuf, 0, FRAME_SIZE)
                if (read <= 0) continue

                // Diagnostic: log the peak mic amplitude (~every 2s). A peak that
                // stays near 0 while you speak means no real mic input is being
                // captured (e.g. an emulator without host-mic forwarding).
                for (i in 0 until read) {
                    val a = kotlin.math.abs(pcmBuf[i].toInt())
                    if (a > micPeak) micPeak = a
                }
                if (++micFrames >= 100) {
                    Log.d(TAG, "mic level (peak 0..32767) = $micPeak")
                    micPeak = 0; micFrames = 0
                }

                // Muted or on hold: keep the RTP clock running, send no voice.
                if (muted.get() || held.get()) { seq = (seq + 1) and 0xFFFF; ts += read; continue }

                val pt = negotiatedPt
                // Build RTP header
                rtpBuf[0] = 0x80.toByte()                 // V=2, P=0, X=0, CC=0
                rtpBuf[1] = (pt and 0x7F).toByte()        // M=0, PT (0=PCMU/8=PCMA/18=G729)
                rtpBuf[2] = (seq shr 8).toByte()
                rtpBuf[3] = (seq and 0xFF).toByte()
                rtpBuf[4] = (ts shr 24).toByte()
                rtpBuf[5] = (ts shr 16).toByte()
                rtpBuf[6] = (ts shr 8).toByte()
                rtpBuf[7] = (ts and 0xFF).toByte()
                rtpBuf[8] = (ssrc shr 24).toByte()
                rtpBuf[9] = (ssrc shr 16).toByte()
                rtpBuf[10] = (ssrc shr 8).toByte()
                rtpBuf[11] = (ssrc and 0xFF).toByte()

                // Encode the payload with the negotiated codec.
                val codec = g729
                val payloadLen: Int
                if (pt == 18 && codec != null) {
                    payloadLen = codec.encode(pcmBuf, read, g729Out)   // 10 bytes / 10ms
                    System.arraycopy(g729Out, 0, rtpBuf, 12, payloadLen)
                } else {
                    for (i in 0 until read) {
                        rtpBuf[12 + i] = encodeSample(pcmBuf[i].toInt(), pt)
                    }
                    payloadLen = read
                }

                if (remoteRtpHost.isNotEmpty() && remoteRtpPort > 0) {
                    try {
                        val addr = InetAddress.getByName(remoteRtpHost)
                        val pkt = DatagramPacket(rtpBuf, 12 + payloadLen, addr, remoteRtpPort)
                        rtpSocket?.send(pkt)
                    } catch (_: Exception) {}
                }

                seq = (seq + 1) and 0xFFFF
                ts += read   // RTP clock advances by samples (160 = 20ms) for all codecs
            }
            audioRecord?.stop()
            audioRecord?.release()
        }

        // Receive thread — RTP → G.711 → speaker
        thread {
            val bufSize = AudioTrack.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(FRAME_SIZE * 2)

            audioTrack = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(SAMPLE_RATE)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(bufSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            audioTrack!!.play()

            val pktBuf = ByteArray(1500)
            val pcmOut = ShortArray(2048)
            val g729In = ByteArray(256)

            while (audioRunning.get()) {
                try {
                    val pkt = DatagramPacket(pktBuf, pktBuf.size)
                    rtpSocket?.receive(pkt)
                    val payload = pkt.length - 12
                    if (payload <= 0) continue

                    // Decode using the packet's own payload type. Ignore anything
                    // we don't handle (e.g. RFC 2833 telephone-event PT 101),
                    // which would otherwise be rendered as noise.
                    val pt = pktBuf[1].toInt() and 0x7F
                    val codec = g729
                    val n: Int
                    if (pt == 18 && codec != null) {
                        val len = payload.coerceAtMost(g729In.size)
                        System.arraycopy(pktBuf, 12, g729In, 0, len)
                        n = codec.decode(g729In, len, pcmOut)        // 80 samples / 10 bytes
                    } else if (pt == 0 || pt == 8) {
                        n = payload.coerceAtMost(pcmOut.size)
                        for (i in 0 until n) {
                            pcmOut[i] = decodeSample(pktBuf[12 + i], pt).toShort()
                        }
                    } else continue
                    audioTrack!!.write(pcmOut, 0, n)
                } catch (_: Exception) {}
            }
            audioTrack?.stop()
            audioTrack?.release()
        }
    }

    private fun stopAudio() {
        audioRunning.set(false)
        rtpSocket?.close()
        g729?.stop()
        g729 = null
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.mode = AudioManager.MODE_NORMAL
    }

    // ---------------------------------------------------------------------------
    // G.711 μ-law codec
    // ---------------------------------------------------------------------------

    private fun linearToUlaw(sample: Int): Byte {
        var s = sample
        val sign = if (s < 0) { s = -s; 0x80 } else 0
        s = s.coerceAtMost(32767)
        s += 132
        var exp = 7
        var mask = 0x4000
        while (exp > 0 && s and mask == 0) { exp--; mask = mask shr 1 }
        val mantissa = s shr (exp + 3) and 0x0F
        return (sign or (exp shl 4) or mantissa).inv().toByte()
    }

    private fun ulawToLinear(ulaw: Byte): Int {
        val u = ulaw.toInt().inv() and 0xFF
        val sign = u and 0x80
        val exp = (u shr 4) and 0x07
        val mantissa = u and 0x0F
        var sample = ((mantissa shl 3) + 132) shl exp
        return if (sign != 0) -sample else sample
    }

    // ---- G.711 A-law codec (PCMA, payload type 8) ----

    private fun linearToAlaw(sample: Int): Byte {
        var s = sample
        val sign = if (s >= 0) 0x80 else { s = -s - 1; 0x00 }
        if (s > 32635) s = 32635
        val exponent: Int
        val mantissa: Int
        if (s >= 256) {
            exponent = (Integer.numberOfTrailingZeros(Integer.highestOneBit(s)) - 4)
            mantissa = (s shr (exponent + 3)) and 0x0F
        } else {
            exponent = 0
            mantissa = s shr 4
        }
        val alaw = (sign or (exponent shl 4) or mantissa)
        return (alaw xor 0x55).toByte()
    }

    private fun alawToLinear(alaw: Byte): Int {
        val a = (alaw.toInt() and 0xFF) xor 0x55
        val sign = a and 0x80
        val exponent = (a shr 4) and 0x07
        val mantissa = a and 0x0F
        var sample = (mantissa shl 4) + 8
        if (exponent != 0) sample = (sample + 0x100) shl (exponent - 1)
        return if (sign != 0) sample else -sample
    }

    /** Encode one PCM16 sample with the codec for [pt] (0 = µ-law, 8 = A-law). */
    private fun encodeSample(sample: Int, pt: Int): Byte =
        if (pt == 8) linearToAlaw(sample) else linearToUlaw(sample)

    /** Decode one codec byte for [pt] back to PCM16. */
    private fun decodeSample(b: Byte, pt: Int): Int =
        if (pt == 8) alawToLinear(b) else ulawToLinear(b)

    private fun codecName(pt: Int): String = when (pt) {
        8 -> "PCMA"
        18 -> "G729"
        else -> "PCMU"
    }

    // ---------------------------------------------------------------------------
    // SIP message builders
    // ---------------------------------------------------------------------------

    private fun buildRegister(
        realm: String?, nonce: String?, auth: String?
    ): String {
        val sb = StringBuilder()
        sb.append("REGISTER sip:$domain SIP/2.0\r\n")
        sb.append("Via: SIP/2.0/UDP $localIp:$SIP_PORT;branch=${newBranch()}\r\n")
        sb.append("Max-Forwards: 70\r\n")
        sb.append("From: <sip:$username@$domain>;tag=$tag\r\n")
        sb.append("To: <sip:$username@$domain>\r\n")
        sb.append("Call-ID: $callId\r\n")
        sb.append("CSeq: $cseq REGISTER\r\n")
        // RFC 8599: advertise push params so PortaSIP can wake the app on a call.
        val pnParams = if (pnProvider.isNotEmpty() && pnPrm.isNotEmpty())
            ";pn-provider=$pnProvider;pn-param=$pnParam;pn-prm=$pnPrm" else ""
        sb.append("Contact: <sip:$username@$localIp:$SIP_PORT$pnParams>\r\n")
        sb.append("Expires: 600\r\n")
        sb.append("User-Agent: CosmiqVoIP/1.0\r\n")
        if (auth != null && realm != null && nonce != null) {
            sb.append("Authorization: Digest username=\"$username\",")
            sb.append("realm=\"$realm\",")
            sb.append("nonce=\"$nonce\",")
            sb.append("uri=\"sip:$domain\",")
            sb.append("response=\"$auth\",")
            sb.append("algorithm=MD5\r\n")
        }
        sb.append("Content-Length: 0\r\n\r\n")
        return sb.toString()
    }

    private fun buildInvite(
        target: String, sdp: String, cseqN: Int, branch: String, auth: Auth?
    ): String {
        val sb = StringBuilder()
        sb.append("INVITE sip:$target@$domain SIP/2.0\r\n")
        sb.append("Via: SIP/2.0/UDP $localIp:$SIP_PORT;branch=$branch;rport\r\n")
        sb.append("Max-Forwards: 70\r\n")
        sb.append("From: <sip:$username@$domain>;tag=$currentCallTag\r\n")
        sb.append("To: <sip:$target@$domain>\r\n")
        sb.append("Call-ID: $currentCallId\r\n")
        sb.append("CSeq: $cseqN INVITE\r\n")
        sb.append("Contact: <sip:$username@$localIp:$SIP_PORT>\r\n")
        if (auth != null) {
            val header = if (auth.proxy) "Proxy-Authorization" else "Authorization"
            sb.append("$header: Digest username=\"$username\",")
            sb.append("realm=\"${auth.realm}\",")
            sb.append("nonce=\"${auth.nonce}\",")
            sb.append("uri=\"${auth.uri}\",")
            sb.append("response=\"${auth.response}\",")
            sb.append("algorithm=MD5\r\n")
        }
        sb.append("Content-Type: application/sdp\r\n")
        sb.append("User-Agent: CosmiqVoIP/1.0\r\n")
        sb.append("Content-Length: ${sdp.toByteArray().size}\r\n\r\n")
        sb.append(sdp)
        return sb.toString()
    }

    /**
     * ACK builder. For a 2xx response [ack2xx]=true → new transaction (own
     * branch, CSeq matches the accepted INVITE). For a non-2xx final response
     * the ACK must reuse the INVITE's [branch] and CSeq number.
     */
    private fun buildAck(
        target: String, toHeader: String, cseqN: Int, branch: String, ack2xx: Boolean
    ): String {
        val to = if (toHeader.isNotBlank()) toHeader else "<sip:$target@$domain>"
        return "ACK sip:$target@$domain SIP/2.0\r\n" +
            "Via: SIP/2.0/UDP $localIp:$SIP_PORT;branch=$branch;rport\r\n" +
            "Max-Forwards: 70\r\n" +
            "From: <sip:$username@$domain>;tag=$currentCallTag\r\n" +
            "To: $to\r\n" +
            "Call-ID: $currentCallId\r\n" +
            "CSeq: $cseqN ACK\r\n" +
            "Content-Length: 0\r\n\r\n"
    }

    private fun buildBye(): String = buildInDialog("BYE", nextCseq(), newBranch())

    /**
     * CANCEL must match the INVITE it cancels: same Request-URI, Call-ID, From
     * (with tag), To (WITHOUT a to-tag), the INVITE's top Via branch, and the
     * same CSeq number with method CANCEL.
     */
    private fun buildCancel(): String {
        return "CANCEL sip:$currentRemoteTarget@$domain SIP/2.0\r\n" +
            "Via: SIP/2.0/UDP $localIp:$SIP_PORT;branch=$currentInviteBranch;rport\r\n" +
            "Max-Forwards: 70\r\n" +
            "From: <sip:$username@$domain>;tag=$currentCallTag\r\n" +
            "To: <sip:$currentRemoteTarget@$domain>\r\n" +
            "Call-ID: $currentCallId\r\n" +
            "CSeq: $inviteCseq CANCEL\r\n" +
            "Content-Length: 0\r\n\r\n"
    }

    private fun buildResponse(
        request: String, code: Int, reason: String, sdp: String = ""
    ): String {
        val vias = extractAllHeaders(request, "Via")   // echo every Via, in order
        val from = extractHeader(request, "From") ?: ""
        val toHdr = extractHeader(request, "To") ?: ""
        // Add our tag only if the request's To doesn't already carry one
        // (in-dialog requests like BYE/re-INVITE already include it).
        val to = if (toHdr.contains("tag=", ignoreCase = true)) toHdr
                 else "$toHdr;tag=$currentCallTag"
        val callIdH = extractHeader(request, "Call-ID") ?: ""
        val cseqH = extractHeader(request, "CSeq") ?: ""
        val sb = StringBuilder()
        sb.append("SIP/2.0 $code $reason\r\n")
        for (v in vias) sb.append("Via: $v\r\n")
        sb.append("From: $from\r\n")
        sb.append("To: $to\r\n")
        sb.append("Call-ID: $callIdH\r\n")
        sb.append("CSeq: $cseqH\r\n")
        if (sdp.isNotEmpty()) {
            sb.append("Contact: <sip:$username@$localIp:$SIP_PORT>\r\n")
            sb.append("Content-Type: application/sdp\r\n")
            sb.append("Content-Length: ${sdp.toByteArray().size}\r\n\r\n")
            sb.append(sdp)
        } else {
            sb.append("Content-Length: 0\r\n\r\n")
        }
        return sb.toString()
    }

    /**
     * Build an in-dialog request (re-INVITE, REFER, BYE, ACK) routed to the
     * remote target through the dialog's Route set (captured from Record-Route).
     */
    private fun buildInDialog(
        method: String, cseqN: Int, branch: String, auth: Auth? = null,
        body: String = "", contentType: String = "", extraHeaders: String = ""
    ): String {
        val ruri = if (dlgRemoteTarget.isNotEmpty()) dlgRemoteTarget
                   else "sip:$currentRemoteTarget@$domain"
        val toUri = if (dlgRemoteUri.isNotEmpty()) dlgRemoteUri
                    else "sip:$currentRemoteTarget@$domain"
        val toTag = if (currentToTag.isNotEmpty()) ";tag=$currentToTag" else ""
        val sb = StringBuilder()
        sb.append("$method $ruri SIP/2.0\r\n")
        sb.append("Via: SIP/2.0/UDP $localIp:$SIP_PORT;branch=$branch;rport\r\n")
        for (r in dlgRouteSet) sb.append("Route: $r\r\n")
        sb.append("Max-Forwards: 70\r\n")
        sb.append("From: <sip:$username@$domain>;tag=$currentCallTag\r\n")
        sb.append("To: <$toUri>$toTag\r\n")
        sb.append("Call-ID: $currentCallId\r\n")
        sb.append("CSeq: $cseqN $method\r\n")
        sb.append("Contact: <sip:$username@$localIp:$SIP_PORT>\r\n")
        sb.append("User-Agent: CosmiqVoIP/1.0\r\n")
        if (auth != null) {
            val h = if (auth.proxy) "Proxy-Authorization" else "Authorization"
            sb.append("$h: Digest username=\"$username\",realm=\"${auth.realm}\",")
            sb.append("nonce=\"${auth.nonce}\",uri=\"${auth.uri}\",")
            sb.append("response=\"${auth.response}\",algorithm=MD5\r\n")
        }
        sb.append(extraHeaders)
        if (body.isNotEmpty()) {
            sb.append("Content-Type: $contentType\r\n")
            sb.append("Content-Length: ${body.toByteArray().size}\r\n\r\n")
            sb.append(body)
        } else {
            sb.append("Content-Length: 0\r\n\r\n")
        }
        return sb.toString()
    }

    /**
     * Send an in-dialog request and wait for its final response, handling a
     * 401/407 challenge by resending with credentials. Returns the 2xx response,
     * or null on failure. [buildReq] receives (cseq, branch, auth?).
     */
    private fun sendDialogRequest(
        method: String, buildReq: (Int, String, Auth?) -> String
    ): String? {
        sipResponses.clear()
        var cseq = nextCseq()
        var branch = newBranch()
        sendSip(buildReq(cseq, branch, null))
        var authed = false
        val deadline = System.currentTimeMillis() + 8_000
        while (System.currentTimeMillis() < deadline) {
            val resp = sipResponses.poll(2, TimeUnit.SECONDS) ?: continue
            if (extractCSeqMethod(resp) != method) continue
            if (extractCSeqNum(resp) != cseq) continue
            val code = parseStatus(resp)
            when {
                code in 100..199 -> { /* provisional, keep waiting */ }
                (code == 401 || code == 407) && !authed -> {
                    authed = true
                    val ch = extractHeader(resp, "WWW-Authenticate")
                        ?: extractHeader(resp, "Proxy-Authenticate") ?: return null
                    val realm = extractParam(ch, "realm") ?: domain
                    val nonce = extractParam(ch, "nonce") ?: ""
                    val uri = dlgRemoteTarget.ifEmpty { "sip:$currentRemoteTarget@$domain" }
                    val digest = DigestAuth(username, password, realm, nonce, uri, method)
                    cseq = nextCseq(); branch = newBranch()
                    sendSip(buildReq(cseq, branch, Auth(realm, nonce, digest, code == 407, uri)))
                }
                code in 200..299 -> return resp
                else -> return null
            }
        }
        return null
    }

    /** Capture in-dialog routing (remote Contact + Route set) for later requests. */
    private fun captureDialog(msg: String, isUac: Boolean) {
        dlgRemoteTarget = extractContactUri(msg) ?: "sip:$currentRemoteTarget@$domain"
        val rr = extractAllHeaders(msg, "Record-Route")
        dlgRouteSet.clear()
        // A UAC reverses the Record-Route order; a UAS keeps it.
        dlgRouteSet.addAll(if (isUac) rr.asReversed() else rr)
        dlgCseq = if (isUac) inviteCseq else 1
    }

    private fun nextCseq(): Int { dlgCseq += 1; return dlgCseq }

    private fun buildInfo(tone: String): String {
        val body = "Signal=$tone\r\nDuration=160\r\n"
        return "INFO sip:$domain SIP/2.0\r\n" +
            "Via: SIP/2.0/UDP $localIp:$SIP_PORT;branch=${newBranch()}\r\n" +
            "Max-Forwards: 70\r\n" +
            "From: <sip:$username@$domain>;tag=$currentCallTag\r\n" +
            "To: <sip:$domain>\r\n" +
            "Call-ID: $currentCallId\r\n" +
            "CSeq: 3 INFO\r\n" +
            "Content-Type: application/dtmf-relay\r\n" +
            "Content-Length: ${body.length}\r\n\r\n$body"
    }

    private fun buildSdp(direction: String = "sendrecv"): String {
        val g729 = G729Codec.available
        // List the preferred codec first so the remote end picks it; keep the
        // others as fallbacks for interop. G.729 (18) is only offered if its
        // native codec loaded on this device.
        val order = when {
            preferredCodec == "G729" && g729 -> "18 0 8"
            preferredCodec == "PCMA" -> if (g729) "8 0 18" else "8 0"
            else -> if (g729) "0 8 18" else "0 8"
        }
        val sb = StringBuilder()
        sb.append("v=0\r\n")
        sb.append("o=$username 0 0 IN IP4 $localIp\r\n")
        sb.append("s=CosmiqVoIP\r\n")
        sb.append("c=IN IP4 $localIp\r\n")
        sb.append("t=0 0\r\n")
        sb.append("m=audio $LOCAL_RTP_PORT RTP/AVP $order 101\r\n")
        sb.append("a=rtpmap:0 PCMU/8000\r\n")
        sb.append("a=rtpmap:8 PCMA/8000\r\n")
        if (g729) {
            sb.append("a=rtpmap:18 G729/8000\r\n")
            sb.append("a=fmtp:18 annexb=no\r\n")   // VAD/DTX disabled
        }
        sb.append("a=rtpmap:101 telephone-event/8000\r\n")
        sb.append("a=fmtp:101 0-15\r\n")
        sb.append("a=$direction\r\n")
        return sb.toString()
    }

    // ---------------------------------------------------------------------------
    // UDP send / receive
    // ---------------------------------------------------------------------------

    private fun sendSip(message: String) {
        try {
            val bytes = message.toByteArray(Charsets.UTF_8)
            val addr = InetAddress.getByName(domain)
            val pkt = DatagramPacket(bytes, bytes.size, addr, SIP_PORT)
            sipSocket?.send(pkt)
            Log.d(TAG, "SENT:\n${message.take(200)}")
        } catch (e: Exception) {
            Log.e(TAG, "Send error: ${e.message}")
        }
    }

    private fun receiveSip(timeout: Int = 5000): String? {
        return try {
            sipSocket?.soTimeout = timeout
            // SIP-over-UDP messages (a 200 OK with SDP + Record-Route) can exceed
            // 4 KB; a too-small buffer silently truncates the datagram.
            val buf = ByteArray(65536)
            val pkt = DatagramPacket(buf, buf.size)
            sipSocket?.receive(pkt)
            // Strip any leading CRLF / whitespace / NUL framing some servers
            // prepend (notably to large 200 OKs); otherwise startsWith("SIP/2.0")
            // fails and the answer is silently dropped.
            val msg = String(pkt.data, 0, pkt.length, Charsets.UTF_8)
                .dropWhile { it == '\r' || it == '\n' || it == ' ' || it == '\t' || it.code == 0 }
            Log.d(TAG, "RECEIVED:\n${msg.take(120)}")
            msg
        } catch (e: java.net.SocketTimeoutException) {
            null
        } catch (e: Exception) {
            Log.w(TAG, "receiveSip error: ${e.message}")
            null
        }
    }

    // ---------------------------------------------------------------------------
    // SIP parsing helpers
    // ---------------------------------------------------------------------------

    private fun extractHeader(msg: String, name: String): String? {
        val lines = msg.lines()
        for (line in lines) {
            if (line.startsWith("$name:", ignoreCase = true)) {
                return line.substringAfter(":").trim()
            }
            // Short form headers
            val shortForms = mapOf("v" to "Via", "f" to "From", "t" to "To",
                "i" to "Call-ID", "m" to "Contact")
            val shortName = shortForms.entries.find { it.value.equals(name, true) }?.key
            if (shortName != null && line.startsWith("$shortName:", ignoreCase = true)) {
                return line.substringAfter(":").trim()
            }
        }
        return null
    }

    private fun extractParam(header: String, param: String): String? {
        val regex = Regex("""$param="?([^",;>]+)"?""", RegexOption.IGNORE_CASE)
        return regex.find(header)?.groupValues?.get(1)
    }

    /** Parse the numeric status code from a SIP response's first line. */
    private fun parseStatus(response: String): Int {
        return response.lineSequence().firstOrNull()
            ?.split(" ")?.getOrNull(1)?.toIntOrNull() ?: 0
    }

    /** Extract the tag= parameter from a To/From header value. */
    private fun extractTag(header: String): String {
        return Regex("""tag=([^;>\s]+)""").find(header)?.groupValues?.get(1) ?: ""
    }

    /** Method name from a response's CSeq header (e.g. "INVITE", "CANCEL"). */
    private fun extractCSeqMethod(resp: String): String {
        val cseq = extractHeader(resp, "CSeq") ?: return ""
        return cseq.trim().split(" ").getOrNull(1)?.uppercase() ?: ""
    }

    /** Numeric sequence from a response's CSeq header. */
    private fun extractCSeqNum(resp: String): Int {
        val cseq = extractHeader(resp, "CSeq") ?: return -1
        return cseq.trim().split(" ").getOrNull(0)?.toIntOrNull() ?: -1
    }

    /** All values of a (possibly repeated / comma-separated) header, in order. */
    private fun extractAllHeaders(msg: String, name: String): List<String> {
        val out = mutableListOf<String>()
        for (line in msg.lines()) {
            if (line.startsWith("$name:", ignoreCase = true)) {
                for (part in splitOutsideAngles(line.substringAfter(":").trim())) {
                    if (part.isNotBlank()) out.add(part.trim())
                }
            }
        }
        return out
    }

    /** Split on commas that are not inside <...> (for Record-Route / Via lists). */
    private fun splitOutsideAngles(s: String): List<String> {
        val out = mutableListOf<String>(); val cur = StringBuilder(); var depth = 0
        for (c in s) {
            when (c) {
                '<' -> { depth++; cur.append(c) }
                '>' -> { depth--; cur.append(c) }
                ',' -> if (depth == 0) { out.add(cur.toString()); cur.clear() } else cur.append(c)
                else -> cur.append(c)
            }
        }
        if (cur.isNotEmpty()) out.add(cur.toString())
        return out
    }

    /** The URI from a Contact header (inside <...>, or up to the first ';'). */
    private fun extractContactUri(msg: String): String? {
        val c = extractHeader(msg, "Contact") ?: return null
        return Regex("<([^>]+)>").find(c)?.groupValues?.get(1)
            ?: c.substringBefore(";").trim()
    }

    /** The bare URI from a From/To header value (inside <...>, no tag/params). */
    private fun extractUriOnly(header: String): String {
        return Regex("<([^>]+)>").find(header)?.groupValues?.get(1)
            ?: header.substringBefore(";").trim()
    }

    private fun extractSipUser(sipUri: String): String {
        return try {
            sipUri.substringAfter("sip:").substringBefore("@")
                .substringBefore(">").trim()
        } catch (_: Exception) { sipUri }
    }

    private fun remoteIdentityFromMsg(msg: String): String {
        val from = extractHeader(msg, "From") ?: return "Unknown"
        return extractSipUser(from)
    }

    private fun parseRemoteSdp(msg: String) {
        val sdpPart = msg.substringAfter("\r\n\r\n")
        val cLine = sdpPart.lines().find { it.startsWith("c=") }
        val mLine = sdpPart.lines().find { it.startsWith("m=audio") }
        if (cLine != null && mLine != null) {
            remoteRtpHost = cLine.trim().split(" ").lastOrNull() ?: ""
            val parts = mLine.trim().split(" ")
            remoteRtpPort = parts.getOrNull(1)?.toIntOrNull() ?: 0
            // The negotiated codec is the remote's first audio payload type we
            // support (0 = µ-law, 8 = A-law, 18 = G.729); default to µ-law.
            negotiatedPt = parts.drop(3).map { it.toIntOrNull() }
                .firstOrNull { it == 0 || it == 8 || (it == 18 && G729Codec.available) } ?: 0
            Log.i(TAG, "Remote RTP: $remoteRtpHost:$remoteRtpPort pt=$negotiatedPt " +
                "(${codecName(negotiatedPt)})")
        }
    }

    // ---------------------------------------------------------------------------
    // DIGEST MD5 authentication
    // ---------------------------------------------------------------------------

    private fun DigestAuth(
        user: String, pass: String, realm: String,
        nonce: String, uri: String, method: String
    ): String {
        val ha1 = md5("$user:$realm:$pass")
        val ha2 = md5("$method:$uri")
        return md5("$ha1:$nonce:$ha2")
    }

    private fun md5(input: String): String {
        val bytes = MessageDigest.getInstance("MD5").digest(input.toByteArray())
        return bytes.joinToString("") { "%02x".format(it) }
    }

    // ---------------------------------------------------------------------------
    // Utility
    // ---------------------------------------------------------------------------

    private fun newCallId() = "${UUID.randomUUID().toString().replace("-", "")}@$domain"
    private fun newTag() = UUID.randomUUID().toString().replace("-", "").take(8)
    private fun newBranch() = "z9hG4bK${UUID.randomUUID().toString().replace("-", "").take(12)}"

    private fun getLocalIp(): String {
        // SIP is UDP-only on :5060, so a TCP connect here fails and yields
        // 0.0.0.0. A connected DatagramSocket selects the right source
        // interface without sending anything, exposing the real local IP.
        return try {
            DatagramSocket().use { s ->
                s.connect(InetAddress.getByName(domain), SIP_PORT)
                s.localAddress?.hostAddress ?: "0.0.0.0"
            }
        } catch (_: Exception) {
            "0.0.0.0"
        }
    }

    private fun sendEvent(sink: EventChannel.EventSink?, event: String) {
        try {
            // Must be called on main thread for Flutter
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                sink?.success(event)
            }
        } catch (_: Exception) {}
    }

    // ---------------------------------------------------------------------------
    // Flutter event sink setters
    // ---------------------------------------------------------------------------

    fun setRegistrationSink(sink: EventChannel.EventSink?) { registrationSink = sink }
    fun setCallSink(sink: EventChannel.EventSink?) { callSink = sink }
}
