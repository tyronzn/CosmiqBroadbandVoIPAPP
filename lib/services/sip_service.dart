import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/call_record.dart';
import 'connection_settings.dart';
import 'diagnostics_log.dart';

/// Registration state (unchanged public enum, so the UI is untouched).
enum SipRegistrationState { unregistered, registering, registered, failed }

/// Call state.
enum SipCallState { none, calling, ringing, confirmed, held, ended }

/// SIP service driving the native engine (baresip + libre) over a platform
/// channel.
///
/// The engine is shared C, so Android and iOS behave identically and this class
/// never needs to know which it is talking to. It replaced a WebRTC engine that
/// could register but never place a call: PortaSIP accepts plain RTP/AVP and
/// rejects WebRTC DTLS-SRTP, which a control test proved rather than assumed.
class SipService extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('za.co.cosmiq.voip/sip');
  static const EventChannel _registrationEvents =
      EventChannel('za.co.cosmiq.voip/registration');
  static const EventChannel _callEvents =
      EventChannel('za.co.cosmiq.voip/calls');

  StreamSubscription<dynamic>? _regSub;
  StreamSubscription<dynamic>? _callSub;

  SipRegistrationState _registrationState = SipRegistrationState.unregistered;
  SipCallState _callState = SipCallState.none;
  String _remoteIdentity = '';
  DateTime? _callStartTime;
  bool _isMuted = false;
  bool _isSpeaker = false;
  bool _isHeld = false;
  String? _registeredExtension;
  String? _lastError;
  Completer<bool>? _registerCompleter;
  bool _initialised = false;

  SipRegistrationState get registrationState => _registrationState;
  SipCallState get callState => _callState;
  String get remoteIdentity => _remoteIdentity;
  DateTime? get callStartTime => _callStartTime;
  bool get isMuted => _isMuted;
  bool get isSpeaker => _isSpeaker;
  bool get isHeld => _isHeld;
  bool get isInCall => _callState != SipCallState.none;
  String? get registeredExtension => _registeredExtension;

  /// Why the last registration or call attempt failed, phrased so the user can
  /// act on it. Null when nothing has failed since the last success.
  String? get lastError => _lastError;

  /// baresip negotiates the codec itself, and g711 (PCMA/PCMU) is the module
  /// built in, so there is nothing to choose. Kept so Settings has something
  /// honest to display.
  String get preferredCodec => 'PCMA';
  bool get g729Available => false;
  Future<void> setPreferredCodec(String codec) async {}

  /// Fired when a call ends, so the history can record it.
  void Function(CallRecord)? onCallEnded;

  Future<void> initialize() async {
    if (_initialised) return;
    _initialised = true;

    _regSub = _registrationEvents
        .receiveBroadcastStream()
        .listen(_onRegistrationEvent, onError: _onStreamError);
    _callSub = _callEvents
        .receiveBroadcastStream()
        .listen(_onCallEvent, onError: _onStreamError);

    DiagnosticsLog.info('SIP', 'Native engine channel ready');
  }

  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      DiagnosticsLog.warn('SIP', 'Microphone permission denied');
    }
    return status.isGranted;
  }

  /// Register. Resolves when the server answers, or after 20 seconds.
  Future<bool> register({
    required String extension,
    required String password,
    String? pushProvider,
    String? pushParam,
    String? pushToken,
  }) async {
    await initialize();
    await _ensureMicPermission();

    // A second register() while one is in flight would otherwise strand the
    // first caller's future until it times out.
    _completeRegister(false);

    _lastError = null;
    _registrationState = SipRegistrationState.registering;
    _registeredExtension = extension;
    notifyListeners();

    DiagnosticsLog.info(
      'SIP',
      'Registering $extension@${ConnectionSettings.sipDomain} via '
          '${ConnectionSettings.sipHost}:${ConnectionSettings.sipPort}',
    );

    final completer = Completer<bool>();
    _registerCompleter = completer;

    try {
      await _channel.invokeMethod<bool>('register', <String, dynamic>{
        'username': extension,
        'password': password,
        'domain': ConnectionSettings.sipDomain,
        'transport': 'udp',
      });
    } on PlatformException catch (e) {
      _lastError = e.code == 'NO_ENGINE'
          ? 'The calling engine is missing from this build.'
          : 'Could not start registration (${e.message}).';
      DiagnosticsLog.error('SIP', 'register failed: ${e.code} ${e.message}');
      _registrationState = SipRegistrationState.failed;
      notifyListeners();
      _completeRegister(false);
    }

    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        if (_registrationState != SipRegistrationState.registered) {
          _lastError ??=
              'No reply from the SIP server within 20 seconds. The usual '
              'cause is a wrong extension or password; it can also mean the '
              'server is unreachable. Check your details, then '
              'Settings and Connection.';
          DiagnosticsLog.error('SIP', 'Registration timed out after 20s');
          _registrationState = SipRegistrationState.failed;
          notifyListeners();
        }
        return _registrationState == SipRegistrationState.registered;
      },
    );
  }

  Future<void> unregister() async {
    try {
      await _channel.invokeMethod('unregister');
    } on PlatformException catch (_) {}
    DiagnosticsLog.info('SIP', 'Unregistered');
    _registrationState = SipRegistrationState.unregistered;
    _registeredExtension = null;
    _lastError = null;
    notifyListeners();
  }

  Future<void> makeCall(String target) async {
    if (_callState != SipCallState.none) return;

    // Distinguish "not registered" from a rejected call, otherwise dialling
    // while offline silently does nothing.
    if (_registrationState != SipRegistrationState.registered) {
      _lastError =
          'Not registered, so the call cannot be placed. See Settings.';
      DiagnosticsLog.error('CALL', 'Dial refused: not registered');
      notifyListeners();
      return;
    }
    if (!await _ensureMicPermission()) {
      _lastError = 'Microphone permission is required to make a call.';
      DiagnosticsLog.error('CALL', 'Dial refused: microphone denied');
      notifyListeners();
      return;
    }

    _lastError = null;
    DiagnosticsLog.info('CALL', 'Dialling $target');

    try {
      await _channel.invokeMethod('makeCall', <String, dynamic>{
        'target': target,
      });
    } on PlatformException catch (e) {
      _lastError = 'The call could not be started (${e.message}).';
      DiagnosticsLog.error('CALL', 'makeCall failed: ${e.message}');
      notifyListeners();
    }
  }

  Future<void> answerCall() async {
    if (!await _ensureMicPermission()) return;
    try {
      await _channel.invokeMethod('answerCall');
    } on PlatformException catch (e) {
      DiagnosticsLog.error('CALL', 'answer failed: ${e.message}');
    }
  }

  Future<void> hangUp() async {
    try {
      await _channel.invokeMethod('hangUp');
    } on PlatformException catch (e) {
      DiagnosticsLog.error('CALL', 'hangup failed: ${e.message}');
    }
  }

  Future<void> rejectCall() => hangUp();

  Future<void> toggleMute() async {
    try {
      await _channel.invokeMethod('toggleMute');
      _isMuted = !_isMuted;
      notifyListeners();
    } on PlatformException catch (_) {}
  }

  Future<void> toggleSpeaker() async {
    try {
      await _channel.invokeMethod('toggleSpeaker');
      _isSpeaker = !_isSpeaker;
      notifyListeners();
    } on PlatformException catch (_) {}
  }

  Future<void> toggleHold() async {
    try {
      await _channel.invokeMethod('setHold', <String, dynamic>{
        'hold': !_isHeld,
      });
    } on PlatformException catch (_) {}
  }

  Future<void> sendDtmf(String tone) async {
    try {
      await _channel.invokeMethod('sendDtmf', <String, dynamic>{'tone': tone});
    } on PlatformException catch (_) {}
  }

  Future<bool> transferCall(String target) async {
    try {
      await _channel.invokeMethod('transferCall', <String, dynamic>{
        'target': target,
      });
      DiagnosticsLog.info('CALL', 'Transferring to $target');
      return true;
    } on PlatformException catch (e) {
      DiagnosticsLog.error('CALL', 'transfer failed: ${e.message}');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Events from the native engine
  // ---------------------------------------------------------------------------

  void _onRegistrationEvent(dynamic event) {
    final raw = event.toString();
    final state = raw.toUpperCase();
    DiagnosticsLog.info('SIP', 'Registration: $raw');

    if (state.contains('UNREGISTERED')) {
      _registrationState = SipRegistrationState.unregistered;
    } else if (state.contains('REGISTERED')) {
      _lastError = null;
      _registrationState = SipRegistrationState.registered;
      _completeRegister(true);
    } else if (state.contains('FAILED')) {
      _lastError = _friendlyRegisterError(raw);
      _registrationState = SipRegistrationState.failed;
      _completeRegister(false);
    }
    notifyListeners();
  }

  void _onCallEvent(dynamic event) {
    final raw = event.toString();
    final parts = raw.split(':');
    final state = parts.first.toUpperCase();
    final identity = parts.length > 1 ? parts.sublist(1).join(':') : '';

    DiagnosticsLog.info('CALL', raw);

    switch (state) {
      case 'OUTGOING':
        if (identity.isNotEmpty) _remoteIdentity = identity;
        _callState = SipCallState.calling;
        break;
      case 'INCOMING':
        if (identity.isNotEmpty) _remoteIdentity = identity;
        _callState = SipCallState.ringing;
        break;
      case 'RINGING':
        if (identity.isNotEmpty) _remoteIdentity = identity;
        // An inbound call stays "ringing"; an outbound one is still dialling.
        if (_callState != SipCallState.ringing) {
          _callState = SipCallState.calling;
        }
        break;
      case 'CONNECTED':
        if (identity.isNotEmpty) _remoteIdentity = identity;
        _callStartTime ??= DateTime.now();
        _isHeld = false;
        _callState = SipCallState.confirmed;
        break;
      case 'HELD':
        _isHeld = true;
        _callState = SipCallState.held;
        break;
      case 'ENDED':
        _endCall(_callStartTime != null
            ? CallStatus.answered
            : CallStatus.rejected);
        return;
      case 'ERROR':
        _lastError = identity.isEmpty ? 'Call failed.' : 'Call failed: $identity';
        DiagnosticsLog.error('CALL', _lastError!);
        _endCall(CallStatus.rejected);
        return;
    }
    notifyListeners();
  }

  void _onStreamError(dynamic error) {
    DiagnosticsLog.error('SIP', 'Event stream error: $error');
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Turn a registration failure into something the user can act on.
  String _friendlyRegisterError(String raw) {
    final detail = raw.contains(':') ? raw.split(':').sublist(1).join(':') : '';
    final text = detail.toLowerCase();

    if (text.contains('401') ||
        text.contains('403') ||
        text.contains('auth')) {
      return 'Extension or password rejected by the server.';
    }
    if (text.contains('404')) {
      return 'That extension does not exist on the server.';
    }
    if (text.contains('408') || text.contains('timeout')) {
      return 'The server did not respond in time.';
    }
    if (text.contains('503')) {
      return 'The server is temporarily unavailable. Try again shortly.';
    }
    return detail.isEmpty
        ? 'Registration failed. Check your extension and password.'
        : 'Registration failed ($detail).';
  }

  void _completeRegister(bool success) {
    final c = _registerCompleter;
    _registerCompleter = null;
    if (c != null && !c.isCompleted) c.complete(success);
  }

  void _endCall(CallStatus status) {
    final duration = _callStartTime != null
        ? DateTime.now().difference(_callStartTime!)
        : Duration.zero;

    if (_remoteIdentity.isNotEmpty && onCallEnded != null) {
      onCallEnded!(CallRecord.fromSipCall(
        remoteNumber: _remoteIdentity,
        direction: status == CallStatus.missed
            ? CallDirection.incoming
            : CallDirection.outgoing,
        status: status,
        timestamp: _callStartTime ?? DateTime.now(),
        duration: duration,
      ));
    }

    _callState = SipCallState.none;
    _callStartTime = null;
    _isMuted = false;
    _isSpeaker = false;
    _isHeld = false;
    _remoteIdentity = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _regSub?.cancel();
    _callSub?.cancel();
    super.dispose();
  }
}
