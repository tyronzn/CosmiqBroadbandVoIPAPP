import CosmiqSip
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // The SIP engine is a local pod, not a pub package, so it is not in the
    // generated registrant and has to be registered by hand. It starts the
    // native engine as it registers, which is why this happens here rather
    // than lazily on first use: an inbound INVITE will not wait for the UI.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CosmiqSipPlugin") {
      CosmiqSipPlugin.register(with: registrar)
    } else {
      NSLog("AppDelegate: could not obtain a registrar for CosmiqSipPlugin")
    }
  }
}
