import Flutter
import UIKit
import PushKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register for VoIP pushes so the platform can wake the app for an incoming
    // call while it is closed. Once woken, iOS requires the call to be reported
    // to CallKit immediately — see pushRegistry(_:didReceiveIncomingPushWith:).
    let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [.voIP]

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // MARK: - PKPushRegistryDelegate

  /// iOS issued a new VoIP push token. It is handed to the plugin, which
  /// forwards it to Dart so it can be registered with the push gateway.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate credentials: PKPushCredentials,
    for type: PKPushType
  ) {
    let deviceToken = credentials.token.map { String(format: "%02x", $0) }.joined()
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(deviceToken)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  /// A VoIP push arrived. iOS terminates the app if this does not result in a
  /// reported incoming call, so the call must be raised here — it cannot be
  /// deferred to Dart, which may not be running yet.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    let info = payload.dictionaryPayload
    let id = (info["id"] as? String) ?? UUID().uuidString
    let caller = (info["nameCaller"] as? String) ?? "Unknown caller"
    let handle = (info["handle"] as? String) ?? caller

    // Module-qualified: the plugin's Data type would otherwise collide with
    // Foundation.Data.
    let data = flutter_callkit_incoming.Data(
      id: id,
      nameCaller: caller,
      handle: handle,
      type: 0 // audio
    )
    data.appName = "Cosmiq VoIP"

    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(
      data,
      fromPushKit: true,
      completion: { completion() }
    )
  }
}
