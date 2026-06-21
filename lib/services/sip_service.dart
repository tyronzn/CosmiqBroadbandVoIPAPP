import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_config.dart';
import '../models/call_record.dart';

/// Registration state
enum SipRegistrationState { unregistered, registering, registered, failed }

/// Call state
enum SipCallState { none, calling, ringing, confirmed, held, ended }

/// SIP service — communicates with native Android Linphone SDK
/// via Flutter MethodChannel and EventChannel.
/// Supports UDP port 5060 natively.
class SipService extends ChangeNotifier {
  static final _log = Logger(printer: PrettyPrinter(methodCount: 0));

  // Channels — must match MainActivity.kt channel names exactly
  static const _methodChannel =
      MethodChannel('za.co.cosmiq.voip/sip');
  static const _regEventChannel =
      EventChannel('za.co.cosmiq.voip/registration');
  static const _callEventChannel =
      EventChannel('za.co.cosmiq.voip/calls');

  // State
  SipRegistrationState _registrationState = SipRegistrationState.unregistered;
  SipCallState _callState = SipCallState.none;
  String _remoteIdentity = '';
  DateTime? _callStartTime;
  bool _isMuted = false;
  bool _isSpeaker = false;
  bool _isHeld = false;
  String? _registeredExtension;

  // Preferred codec: 'PCMU' (µ-law), 'PCMA' (A-law) or 'G729'. Persisted locally
  // and pushed to the native layer, which offers it first in call SDP.
  static const _codecPrefKey = 'cosmiq_preferred_codec';
  String _preferredCodec = 'PCMU';
  bool _g729Available = false;

  // Stream subscriptions
  StreamSubscription? _regSub;
  StreamSubscription? _callSub;

  // Resolves when a register() attempt settles (registered / failed / timeout).
  Completer<bool>? _registerCompleter;

  // Getters
  SipRegistrationState get registrationState => _registrationState;
  SipCallState get callState => _callState;
  String get remoteIdentity => _remoteIdentity;
  DateTime? get callStartTime => _callStartTime;
  bool get isMuted => _isMuted;
  bool get isSpeaker => _isSpeaker;
  bool get isHeld => _isHeld;
  bool get isInCall => _callState != SipCallState.none;
  String? get registeredExtension => _registeredExtension;
  String get preferredCodec => _preferredCodec;
  bool get g729Available => _g729Available;

  /// Fired when a call ends — saves to call history
  void Function(CallRecord)? onCallEnded;

  /// Start listening to native event channels.
  /// Idempotent — safe to call again on re-login without leaking subscriptions.
  Future<void> initialize() async {
    await _regSub?.cancel();
    await _callSub?.cancel();

    _regSub = _regEventChannel
        .receiveBroadcastStream()
        .listen(_onRegistrationEvent, onError: _onError);

    _callSub = _callEventChannel
        .receiveBroadcastStream()
        .listen(_onCallEvent, onError: _onError);

    // Is the native G.729 (bcg729) codec available on this device?
    _g729Available = await _checkG729Available();

    // Restore the saved codec preference and push it to the native layer.
    // The native side returns the codec it actually applied (e.g. it falls back
    // to PCMU if G.729 was saved but isn't available).
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_codecPrefKey) ?? 'PCMU';
    _preferredCodec = await _pushCodecToNative(saved);

    _log.i('SIP service initialized (native Kotlin/UDP), codec=$_preferredCodec, '
        'g729=$_g729Available');
  }

  Future<bool> _checkG729Available() async {
    try {
      return (await _methodChannel.invokeMethod('isG729Available')) == true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _pushCodecToNative(String codec) async {
    try {
      final applied =
          await _methodChannel.invokeMethod('setPreferredCodec', {'codec': codec});
      return (applied as String?) ?? codec;
    } catch (e) {
      _log.w('Failed to set codec: $e');
      return codec;
    }
  }

  /// Change the preferred call codec ('PCMU', 'PCMA' or 'G729'). Persists and
  /// applies to the next call.
  Future<void> setPreferredCodec(String codec) async {
    final up = codec.toUpperCase();
    final requested = (up == 'PCMA' || up == 'G729') ? up : 'PCMU';
    final applied = await _pushCodecToNative(requested);
    if (applied == _preferredCodec) return;
    _preferredCodec = applied;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_codecPrefKey, _preferredCodec);
    notifyListeners();
  }

  /// Register with PortaSIP — UDP port 5060.
  /// Returns true once the native layer reports a successful REGISTER, false on
  /// failure or timeout. This is the app's primary auth gate.
  Future<bool> register({
    required String extension,
    required String password,
    String? pushProvider,
    String? pushParam,
    String? pushToken,
  }) async {
    _registrationState = SipRegistrationState.registering;
    _registeredExtension = extension;
    notifyListeners();

    final completer = Completer<bool>();
    _registerCompleter = completer;

    try {
      await _methodChannel.invokeMethod('register', {
        'username': extension,
        'password': password,
        'domain': ServerConfig.sipServer,
        // RFC 8599 push params — tells PortaSIP where to push incoming calls.
        'pushProvider': pushProvider ?? '',
        'pushParam': pushParam ?? '',
        'pushToken': pushToken ?? '',
      });
      _log.i('SIP register called for $extension');
    } catch (e) {
      _log.e('Register failed: $e');
      _registrationState = SipRegistrationState.failed;
      notifyListeners();
      _completeRegister(false);
    }

    // Wait for the native registration event, with a safety timeout so a
    // silent server never hangs the login flow.
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _log.w('SIP registration timed out');
        if (_registrationState != SipRegistrationState.registered) {
          _registrationState = SipRegistrationState.failed;
          notifyListeners();
        }
        return _registrationState == SipRegistrationState.registered;
      },
    );
  }

  /// Resolve a pending register() future exactly once.
  void _completeRegister(bool success) {
    final c = _registerCompleter;
    _registerCompleter = null;
    if (c != null && !c.isCompleted) c.complete(success);
  }

  /// Unregister
  Future<void> unregister() async {
    try {
      await _methodChannel.invokeMethod('unregister');
    } catch (_) {}
    _regSub?.cancel();
    _callSub?.cancel();
    _registrationState = SipRegistrationState.unregistered;
    _registeredExtension = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Call actions
  // ---------------------------------------------------------------------------

  /// Request the microphone runtime permission. Audio capture (and therefore
  /// the call) cannot start without it on Android.
  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) _log.w('Microphone permission not granted: $status');
    return status.isGranted;
  }

  Future<void> makeCall(String target) async {
    if (_callState != SipCallState.none) return;
    if (!await _ensureMicPermission()) return;

    final dest = target
        .replaceAll('sip:', '')
        .split('@')
        .first;

    _remoteIdentity = dest;
    _callState = SipCallState.calling;
    notifyListeners();

    try {
      await _methodChannel.invokeMethod('makeCall', {
        'target': dest,
        'domain': ServerConfig.sipServer,
      });
    } catch (e) {
      _log.e('makeCall error: $e');
      _callState = SipCallState.none;
      _remoteIdentity = '';
      notifyListeners();
    }
  }

  Future<void> answerCall() async {
    if (!await _ensureMicPermission()) return;
    try {
      await _methodChannel.invokeMethod('answerCall');
    } catch (e) {
      _log.e('answerCall error: $e');
    }
  }

  Future<void> hangUp() async {
    try {
      await _methodChannel.invokeMethod('hangUp');
    } catch (_) {}
    _endCall(CallStatus.answered);
  }

  Future<void> rejectCall() async {
    try {
      await _methodChannel.invokeMethod('hangUp');
    } catch (_) {}
    _endCall(CallStatus.rejected);
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    _methodChannel.invokeMethod('toggleMute').catchError((_) {});
    notifyListeners();
  }

  void toggleSpeaker() {
    _isSpeaker = !_isSpeaker;
    _methodChannel.invokeMethod('toggleSpeaker').catchError((_) {});
    notifyListeners();
  }

  Future<void> toggleHold() async {
    final target = !_isHeld;
    try {
      final res = await _methodChannel.invokeMethod('setHold', {'hold': target});
      _isHeld = (res as bool?) ?? target;
    } catch (e) {
      _log.e('Hold error: $e');
    }
    notifyListeners();
  }

  void sendDtmf(String tone) {
    _methodChannel
        .invokeMethod('sendDtmf', {'tone': tone})
        .catchError((_) {});
  }

  Future<bool> transferCall(String target) async {
    try {
      final res = await _methodChannel.invokeMethod('transferCall', {'target': target});
      return res == true;
    } catch (e) {
      _log.e('Transfer error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  void _onRegistrationEvent(dynamic event) {
    final state = event.toString().toUpperCase();
    _log.i('Registration event: $state');

    if (state.contains('REGISTERED') && !state.contains('UN')) {
      _registrationState = SipRegistrationState.registered;
      _completeRegister(true);
    } else if (state.contains('FAILED')) {
      _registrationState = SipRegistrationState.failed;
      _completeRegister(false);
    } else if (state.contains('REGISTERING') || state.contains('PROGRESS')) {
      _registrationState = SipRegistrationState.registering;
    } else if (state.contains('UNREGISTERED') || state.contains('CLEARED')) {
      _registrationState = SipRegistrationState.unregistered;
    }
    notifyListeners();
  }

  void _onCallEvent(dynamic event) {
    final raw = event.toString();
    final state = raw.split(':').first.toUpperCase();
    final identity = raw.contains(':') ? raw.split(':').last : '';

    _log.i('Call event: $state identity: $identity');

    switch (state) {
      case 'OUTGOING':
        _callState = SipCallState.calling;
        break;
      case 'INCOMING':
        _callState = SipCallState.ringing;
        _remoteIdentity = identity;
        break;
      case 'RINGING':
        // Outbound call is ringing at the far end — stay in the calling state.
        _callState = SipCallState.calling;
        break;
      case 'CONNECTED':
        _callState = SipCallState.confirmed;
        _callStartTime = DateTime.now();
        if (identity.isNotEmpty) _remoteIdentity = identity;
        break;
      case 'HELD':
        _callState = SipCallState.held;
        break;
      case 'ENDED':
        _endCall(CallStatus.answered);
        return;
      case 'ERROR':
        _endCall(CallStatus.missed);
        return;
    }
    notifyListeners();
  }

  void _onError(dynamic error) {
    _log.e('SIP channel error: $error');
  }

  void _endCall(CallStatus status) {
    final duration = _callStartTime != null
        ? DateTime.now().difference(_callStartTime!)
        : Duration.zero;

    if (_remoteIdentity.isNotEmpty && onCallEnded != null) {
      final record = CallRecord.fromSipCall(
        remoteNumber: _remoteIdentity,
        direction: status == CallStatus.missed
            ? CallDirection.incoming
            : CallDirection.outgoing,
        status: status,
        timestamp: _callStartTime ?? DateTime.now(),
        duration: duration,
      );
      onCallEnded!(record);
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
