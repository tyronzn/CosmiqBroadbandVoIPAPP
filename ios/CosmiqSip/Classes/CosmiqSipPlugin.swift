import AVFoundation
import Flutter
import Foundation

/// Puts the native baresip engine behind the MethodChannel contract the Dart
/// layer already speaks, so the UI does not know or care which platform it is
/// running on. This is the iOS counterpart of `CosmiqSipBridge.kt`, and the
/// contract is deliberately identical:
///
///  - registration events are bare strings: REGISTERED / FAILED / UNREGISTERED
///  - call events are "STATE:identity", where STATE is one of
///    OUTGOING, INCOMING, RINGING, CONNECTED, HELD, ENDED, ERROR
///
/// Only OUTGOING and HELD are synthesised here. Everything else comes from the
/// engine, because only it knows what the far end actually did.
///
/// The one thing this class does that the Android bridge does not is own the
/// `AVAudioSession`. baresip's audiounit module drives AudioUnit directly and
/// never configures a session, so without the work below there is no
/// microphone, no routing and no audio in the background.
public class CosmiqSipPlugin: NSObject {

    private static let methodChannelName = "za.co.cosmiq.voip/sip"
    private static let registrationChannelName = "za.co.cosmiq.voip/registration"
    private static let callChannelName = "za.co.cosmiq.voip/calls"

    private var registrationSink: FlutterEventSink?
    private var callSink: FlutterEventSink?

    /// Remembered so ENDED and HELD can still name the peer, as on Android.
    private var remoteIdentity = ""

    private var muted = false
    private var speakerOn = false
    private var started = false
    private var startDetail = "initialize() was never called"

    // MARK: - Registration with the Flutter engine

    @objc
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CosmiqSipPlugin()
        instance.start()

        let method = FlutterMethodChannel(name: methodChannelName,
                                          binaryMessenger: registrar.messenger())
        method.setMethodCallHandler { [weak instance] call, result in
            instance?.handle(call, result: result)
        }

        FlutterEventChannel(name: registrationChannelName,
                            binaryMessenger: registrar.messenger())
            .setStreamHandler(SinkHandler { [weak instance] sink in
                instance?.registrationSink = sink
            })

        FlutterEventChannel(name: callChannelName,
                            binaryMessenger: registrar.messenger())
            .setStreamHandler(SinkHandler { [weak instance] sink in
                instance?.callSink = sink
            })

        // Held by the registrar for the life of the app; without this the
        // instance is released the moment this function returns and every
        // channel call lands on nil.
        registrar.publish(instance)
    }

    // MARK: - Engine lifecycle

    /// baresip needs a writable directory for its configuration. Application
    /// Support rather than Documents: these files are ours, not the user's,
    /// and Documents can be exposed through the Files app.
    private static func configDirectory() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("cosmiq-sip", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func start() {
        observeAudioSessionNotifications()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let rc = cosmiq_sip_start(engineEventCallback, ctx,
                                  Self.configDirectory(), Self.dnsServers)
        started = (rc == 0)
        startDetail = started ? "ok" : "engine start rc=\(rc)"
        NSLog("CosmiqSipPlugin: engine start: %@", startDetail)
    }

    /// Resolver for the SIP stack, matching Android.
    ///
    /// A fixed public resolver rather than the device's own: it is
    /// deterministic across networks and sidesteps broken or captive carrier
    /// DNS, which is a common cause of a softphone that works on wifi and not
    /// on mobile data.
    private static let dnsServers = "9.9.9.9"

    // MARK: - Engine events

    /// C function pointers cannot capture context, so the instance travels
    /// through the engine's `void *arg` and is reconstituted here.
    private let engineEventCallback: cosmiq_event_cb = { eventPtr, detailPtr, arg in
        guard let arg = arg else { return }
        let plugin = Unmanaged<CosmiqSipPlugin>.fromOpaque(arg).takeUnretainedValue()
        let event = eventPtr.map { String(cString: $0) } ?? ""
        let detail = detailPtr.map { String(cString: $0) } ?? ""

        // Events arrive on the engine's own thread; Flutter channels must be
        // touched on the platform thread only.
        DispatchQueue.main.async { plugin.onEngineEvent(event, detail) }
    }

    private func emitCall(_ state: String, _ identity: String? = nil) {
        let who = identity ?? remoteIdentity
        callSink?(who.isEmpty ? state : "\(state):\(who)")
    }

    private func onEngineEvent(_ event: String, _ detail: String) {
        switch event {
        case "registered":
            registrationSink?("REGISTERED")
        case "register_failed":
            registrationSink?(detail.isEmpty ? "FAILED" : "FAILED:\(detail)")
        case "unregistered":
            registrationSink?("UNREGISTERED")

        case "call_incoming":
            remoteIdentity = detail
            activateAudioSession()
            emitCall("INCOMING")
        case "call_ringing":
            if !detail.isEmpty { remoteIdentity = detail }
            emitCall("RINGING")
        case "call_established":
            if !detail.isEmpty { remoteIdentity = detail }
            activateAudioSession()
            emitCall("CONNECTED")
        case "call_closed":
            emitCall("ENDED")
            remoteIdentity = ""
            muted = false
            speakerOn = false
            deactivateAudioSession()

        default:
            NSLog("CosmiqSipPlugin: unhandled engine event: %@", event)
        }
    }

    // MARK: - AVAudioSession
    //
    // The audiounit module is pure AudioUnit C and never configures a session.
    // Everything below exists because of that.

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .voiceChat pairs with kAudioUnitSubType_VoiceProcessingIO, which
            // the module already uses, and is what enables echo cancellation
            // rather than merely permitting it.
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true, options: [])
        } catch {
            NSLog("CosmiqSipPlugin: audio session activate failed: %@",
                  error.localizedDescription)
        }
    }

    private func deactivateAudioSession() {
        do {
            // notifyOthersOnDeactivation so music or a podcast the user paused
            // for the call resumes instead of staying silent.
            try AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            NSLog("CosmiqSipPlugin: audio session deactivate failed: %@",
                  error.localizedDescription)
        }
    }

    private func observeAudioSessionNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
    }

    /// A cellular call, Siri or an alarm takes the session away mid-call. iOS
    /// does not give it back on its own, so the session is re-activated when
    /// the interruption ends and the call is still up.
    @objc private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            NSLog("CosmiqSipPlugin: audio interrupted")
        case .ended:
            // Reactivate whenever a call is still up, without consulting
            // .shouldResume. That flag is advice for media playback; a live
            // call should come back regardless, and honouring it would leave
            // some interruptions ending in permanent silence.
            guard cosmiq_sip_in_call() else { return }
            activateAudioSession()
            applySpeakerRoute()
        @unknown default:
            break
        }
    }

    /// Unplugging a headset mid-call otherwise leaves audio pointed at a route
    /// that is gone.
    @objc private func handleRouteChange(_ note: Notification) {
        guard
            cosmiq_sip_in_call(),
            let info = note.userInfo,
            let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            applySpeakerRoute()
        }
    }

    private func applySpeakerRoute() {
        do {
            try AVAudioSession.sharedInstance()
                .overrideOutputAudioPort(speakerOn ? .speaker : .none)
        } catch {
            NSLog("CosmiqSipPlugin: speaker route failed: %@",
                  error.localizedDescription)
        }
    }

    // MARK: - MethodChannel

    private func ok(_ result: FlutterResult, _ success: Bool) {
        if success {
            result(true)
        } else {
            result(FlutterError(code: "SIP_ERROR",
                                message: "native engine rejected the request",
                                details: nil))
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        func str(_ k: String) -> String { args[k] as? String ?? "" }

        switch call.method {
        case "register":
            guard started else {
                result(FlutterError(code: "NO_ENGINE",
                                    message: "engine did not start: \(startDetail)",
                                    details: nil))
                return
            }
            // PortaSIP answers on both; UDP unless Dart says otherwise.
            let transport = (args["transport"] as? String) ?? "udp"
            let rc = cosmiq_sip_register(str("username"), str("domain"),
                                         str("password"), transport, 600)
            if rc == 0 {
                result(true)
            } else {
                result(FlutterError(code: "SIP_ERROR",
                                    message: "ua_alloc failed, rc=\(rc)",
                                    details: nil))
            }

        case "unregister":
            ok(result, cosmiq_sip_unregister() == 0)

        case "makeCall":
            let target = str("target")
            remoteIdentity = target
            activateAudioSession()
            let begun = cosmiq_sip_call(target) == 0
            // The engine reports RINGING and CONNECTED; OUTGOING is ours so
            // the UI can show the in-call screen the moment dialling starts.
            emitCall(begun ? "OUTGOING" : "ERROR")
            if !begun { deactivateAudioSession() }
            ok(result, begun)

        case "answerCall":
            activateAudioSession()
            ok(result, cosmiq_sip_answer() == 0)

        case "hangUp":
            ok(result, cosmiq_sip_hangup() == 0)

        case "setHold":
            let hold = args["hold"] as? Bool ?? false
            let done = cosmiq_sip_hold(hold) == 0
            // call_hold has no engine event of its own, so reflect it here.
            if done { emitCall(hold ? "HELD" : "CONNECTED") }
            ok(result, done)

        case "transferCall":
            ok(result, cosmiq_sip_transfer(str("target")) == 0)

        case "toggleMute":
            muted.toggle()
            ok(result, cosmiq_sip_mute(muted) == 0)

        case "sendDtmf":
            let tone = str("tone")
            guard let digit = tone.utf8.first else {
                result(FlutterError(code: "SIP_ERROR",
                                    message: "no DTMF digit given", details: nil))
                return
            }
            ok(result, cosmiq_sip_dtmf(CChar(digit)) == 0)

        case "toggleSpeaker":
            // Android acknowledges this and lets the platform route; on iOS the
            // session is ours, so it can actually be honoured.
            speakerOn.toggle()
            applySpeakerRoute()
            result(speakerOn)

        case "setPreferredCodec":
            // baresip negotiates the codec itself and g711 is the module built
            // in. Kept so the existing Dart calls resolve.
            result("PCMA")

        case "isG729Available":
            result(false)

        case "isEngineAvailable":
            result(started)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cosmiq_sip_stop()
    }
}

/// Small adapter so the two event channels do not each need their own class.
private final class SinkHandler: NSObject, FlutterStreamHandler {
    private let assign: (FlutterEventSink?) -> Void

    init(_ assign: @escaping (FlutterEventSink?) -> Void) {
        self.assign = assign
    }

    func onListen(withArguments _: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        assign(events)
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        assign(nil)
        return nil
    }
}
