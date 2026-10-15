package za.co.cosmiq.voip

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Channel wiring between Flutter and the native SIP engine.
 *
 * The engine is baresip + libre behind [CosmiqSipBridge]. The channel names and
 * event formats are unchanged from the previous hand-rolled Kotlin stack, so
 * the Dart layer did not have to change when the engine did.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val SIP_METHOD_CHANNEL = "za.co.cosmiq.voip/sip"
        private const val REG_EVENT_CHANNEL = "za.co.cosmiq.voip/registration"
        private const val CALL_EVENT_CHANNEL = "za.co.cosmiq.voip/calls"
    }

    private lateinit var sip: CosmiqSipBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // baresip needs a writable directory for its config; the app's own
        // files directory is the only one guaranteed to exist in the sandbox.
        sip = CosmiqSipBridge(applicationContext.filesDir.absolutePath)
        sip.initialize()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SIP_METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> sip.register(
                    call.argument<String>("username") ?: "",
                    call.argument<String>("password") ?: "",
                    call.argument<String>("domain") ?: "",
                    // PortaSIP answers on both; UDP unless Dart says otherwise.
                    call.argument<String>("transport") ?: "udp",
                    result,
                )
                "unregister" -> sip.unregister(result)
                "makeCall" -> sip.makeCall(
                    call.argument<String>("target") ?: "", result
                )
                "answerCall" -> sip.answerCall(result)
                "hangUp" -> sip.hangUp(result)
                "setHold" -> sip.setHold(
                    call.argument<Boolean>("hold") ?: false, result
                )
                "transferCall" -> sip.transferCall(
                    call.argument<String>("target") ?: "", result
                )
                "toggleMute" -> sip.toggleMute(result)
                "sendDtmf" -> sip.sendDtmf(
                    call.argument<String>("tone") ?: "", result
                )

                // Speaker routing is handled by the platform audio session, not
                // the SIP engine; acknowledged so older Dart keeps working.
                "toggleSpeaker" -> result.success(true)

                // baresip negotiates the codec itself, and g711 (PCMA/PCMU) is
                // the module built in. Kept so the existing Dart calls resolve.
                "setPreferredCodec" -> result.success("PCMA")
                "isG729Available" -> result.success(false)

                "isEngineAvailable" -> result.success(sip.isAvailable)

                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            REG_EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sip.setRegistrationSink(events)
            }

            override fun onCancel(arguments: Any?) {
                sip.setRegistrationSink(null)
            }
        })

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CALL_EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sip.setCallSink(events)
            }

            override fun onCancel(arguments: Any?) {
                sip.setCallSink(null)
            }
        })
    }

    override fun onDestroy() {
        sip.destroy()
        super.onDestroy()
    }
}
