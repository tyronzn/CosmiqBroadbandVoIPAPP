import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:uuid/uuid.dart';

import 'diagnostics_log.dart';

/// Bridges SIP calls to the native iOS call UI (CallKit).
///
/// On iOS this is not a nicety: Apple requires an app woken by a VoIP push to
/// report an incoming call to CallKit immediately, or the system terminates the
/// process. It also gives iOS ownership of the call, so the phone rings, the
/// call appears in Recents, and the lock screen works.
///
/// Deliberately iOS-only. Android already shows incoming calls through
/// [PushService]'s full-screen notification, and running both would produce two
/// competing call screens.
class CallKitService {
  CallKitService._();

  static const Uuid _uuid = Uuid();
  static StreamSubscription<CallEvent?>? _subscription;
  static String? _currentCallId;
  static String? _voipToken;

  /// Whether the native call UI is used on this platform.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// PushKit token for this device — the address a VoIP push is delivered to.
  /// Null until iOS hands one over (and always null off iOS).
  static String? get voipPushToken => _voipToken;

  /// The call currently reported to the OS, if any.
  static String? get currentCallId => _currentCallId;

  static String newCallId() => _uuid.v4();

  // Wired by SipService so the native UI's buttons drive the SIP session.
  static void Function()? onAccept;
  static void Function()? onDecline;
  static void Function()? onEnd;
  static void Function(bool muted)? onMuteToggled;
  static void Function(bool onHold)? onHoldToggled;
  static void Function(String digits)? onDtmf;

  static Future<void> init() async {
    if (!isSupported) return;
    _subscription ??= FlutterCallkitIncoming.onEvent.listen(_handleEvent);
    await refreshVoipToken();
  }

  /// Ask iOS for the current PushKit token.
  ///
  /// The token itself is never logged — it addresses pushes to this device.
  static Future<String?> refreshVoipToken() async {
    if (!isSupported) return null;
    try {
      final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      if (token != null && token.isNotEmpty && token != _voipToken) {
        _voipToken = token;
        DiagnosticsLog.info(
            'CALLKIT', 'VoIP push token received (${token.length} chars)');
      }
      return _voipToken;
    } catch (e) {
      DiagnosticsLog.warn('CALLKIT', 'Could not read VoIP push token: $e');
      return null;
    }
  }

  /// Ring the phone for an inbound SIP call.
  static Future<void> showIncoming({
    required String id,
    required String caller,
  }) async {
    if (!isSupported) return;
    _currentCallId = id;
    DiagnosticsLog.info('CALLKIT', 'Reporting incoming call from $caller');
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(
        _params(id: id, caller: caller),
      );
    } catch (e) {
      DiagnosticsLog.error('CALLKIT', 'showCallkitIncoming failed: $e');
    }
  }

  /// Tell iOS about an outbound call, so it owns the audio session and the call
  /// shows up in Recents like any other.
  static Future<void> reportOutgoing({
    required String id,
    required String target,
  }) async {
    if (!isSupported) return;
    _currentCallId = id;
    try {
      await FlutterCallkitIncoming.startCall(_params(id: id, caller: target));
    } catch (e) {
      DiagnosticsLog.error('CALLKIT', 'startCall failed: $e');
    }
  }

  /// Stop the "connecting" state — the call is now up.
  static Future<void> setConnected([String? id]) async {
    if (!isSupported) return;
    final callId = id ?? _currentCallId;
    if (callId == null) return;
    try {
      await FlutterCallkitIncoming.setCallConnected(callId);
    } catch (e) {
      DiagnosticsLog.warn('CALLKIT', 'setCallConnected failed: $e');
    }
  }

  /// Take the call out of the OS's hands — always pair this with the SIP call
  /// ending, or iOS keeps showing an active call that no longer exists.
  static Future<void> endCall([String? id]) async {
    if (!isSupported) return;
    final callId = id ?? _currentCallId;
    _currentCallId = null;
    if (callId == null) return;
    try {
      await FlutterCallkitIncoming.endCall(callId);
    } catch (e) {
      DiagnosticsLog.warn('CALLKIT', 'endCall failed: $e');
    }
  }

  static Future<void> endAll() async {
    if (!isSupported) return;
    _currentCallId = null;
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (e) {
      DiagnosticsLog.warn('CALLKIT', 'endAllCalls failed: $e');
    }
  }

  static Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  static CallKitParams _params({
    required String id,
    required String caller,
  }) =>
      CallKitParams(
        id: id,
        nameCaller: caller,
        appName: 'Cosmiq VoIP',
        handle: caller,
        type: 0, // audio
        duration: 45000,
        ios: const IOSParams(
          handleType: 'generic',
          supportsVideo: false,
          maximumCallGroups: 1,
          maximumCallsPerCallGroup: 1,
          supportsDTMF: true,
          supportsHolding: true,
          supportsGrouping: false,
          supportsUngrouping: false,
          includesCallsInRecents: true,
          // flutter_webrtc configures AVAudioSession itself. Letting CallKit do
          // it as well makes the two fight over the session, so this is off.
          // If iOS calls connect but are silent, this is the first knob to try
          // — see SETUP_CALLKIT.md.
          configureAudioSession: false,
        ),
      );

  static void _handleEvent(CallEvent? event) {
    if (event == null) return;
    switch (event) {
      case CallEventActionDidUpdateDevicePushTokenVoip():
        refreshVoipToken();
      case CallEventActionCallAccept():
        DiagnosticsLog.info('CALLKIT', 'Answered from the native call screen');
        onAccept?.call();
      case CallEventActionCallDecline():
        DiagnosticsLog.info('CALLKIT', 'Declined from the native call screen');
        onDecline?.call();
      case CallEventActionCallEnded():
        DiagnosticsLog.info('CALLKIT', 'Ended from the native call screen');
        onEnd?.call();
      case CallEventActionCallTimeout():
        DiagnosticsLog.info('CALLKIT', 'Call timed out unanswered');
        onDecline?.call();
      case CallEventActionCallToggleMute(:final isMuted):
        onMuteToggled?.call(isMuted);
      case CallEventActionCallToggleHold(:final isOnHold):
        onHoldToggled?.call(isOnHold);
      case CallEventActionCallToggleDmtf(:final digits):
        onDtmf?.call(digits);
      default:
        break;
    }
  }
}
