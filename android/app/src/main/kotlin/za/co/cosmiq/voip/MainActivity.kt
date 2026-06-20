package za.co.cosmiq.voip

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val SIP_METHOD_CHANNEL = "za.co.cosmiq.voip/sip"
        private const val REG_EVENT_CHANNEL = "za.co.cosmiq.voip/registration"
        private const val CALL_EVENT_CHANNEL = "za.co.cosmiq.voip/calls"
    }

    private lateinit var sipManager: CosmiqSipManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        sipManager = CosmiqSipManager(applicationContext)
        sipManager.initialize()

        // ---- Method channel (Flutter → Native) ----
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SIP_METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> {
                    val username = call.argument<String>("username") ?: ""
                    val password = call.argument<String>("password") ?: ""
                    val domain = call.argument<String>("domain") ?: ""
                    sipManager.register(username, password, domain, result)
                }
                "unregister" -> sipManager.unregister(result)
                "makeCall" -> {
                    val target = call.argument<String>("target") ?: ""
                    val domain = call.argument<String>("domain") ?: ""
                    sipManager.makeCall(target, domain, result)
                }
                "answerCall" -> sipManager.answerCall(result)
                "hangUp" -> sipManager.hangUp(result)
                "toggleMute" -> sipManager.toggleMute(result)
                "toggleSpeaker" -> sipManager.toggleSpeaker(result)
                "setPreferredCodec" -> {
                    val codec = call.argument<String>("codec") ?: "PCMU"
                    sipManager.setPreferredCodec(codec, result)
                }
                "isG729Available" -> sipManager.isG729Available(result)
                "sendDtmf" -> {
                    val tone = call.argument<String>("tone") ?: ""
                    sipManager.sendDtmf(tone, result)
                }
                else -> result.notImplemented()
            }
        }

        // ---- Registration event channel (Native → Flutter) ----
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            REG_EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sipManager.setRegistrationSink(events)
            }
            override fun onCancel(arguments: Any?) {
                sipManager.setRegistrationSink(null)
            }
        })

        // ---- Call event channel (Native → Flutter) ----
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CALL_EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sipManager.setCallSink(events)
            }
            override fun onCancel(arguments: Any?) {
                sipManager.setCallSink(null)
            }
        })
    }

    override fun onDestroy() {
        sipManager.destroy()
        super.onDestroy()
    }
}
