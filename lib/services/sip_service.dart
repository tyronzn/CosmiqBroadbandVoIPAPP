import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sip_ua/sip_ua.dart';
import '../models/server_config.dart';
import '../models/call_record.dart';

/// Registration state (unchanged public enum so the UI doesn't change).
enum SipRegistrationState { unregistered, registering, registered, failed }

/// Call state.
enum SipCallState { none, calling, ringing, confirmed, held, ended }

/// Portable SIP service backed by dart-sip-ua (SIP-over-WebSocket) + WebRTC
/// media — runs identically on Android and iOS. Replaces the Android-only
/// native UDP stack. Requires PortaSIP's WebRTC/WSS gateway (see ServerConfig).
class SipService extends ChangeNotifier implements SipUaHelperListener {
  static final _log = Logger(printer: PrettyPrinter(methodCount: 0));

  final SIPUAHelper _helper = SIPUAHelper();
  Call? _activeCall;
  MediaStream? _remoteStream;

  SipRegistrationState _registrationState = SipRegistrationState.unregistered;
  SipCallState _callState = SipCallState.none;
  String _remoteIdentity = '';
  DateTime? _callStartTime;
  bool _isMuted = false;
  bool _isSpeaker = false;
  bool _isHeld = false;
  String? _registeredExtension;
  Completer<bool>? _registerCompleter;
  bool _listenerAdded = false;

  // WebRTC negotiates Opus/G.711 automatically; kept for UI compatibility.
  String get preferredCodec => 'Opus';
  bool get g729Available => false;
  Future<void> setPreferredCodec(String codec) async {}

  SipRegistrationState get registrationState => _registrationState;
  SipCallState get callState => _callState;
  String get remoteIdentity => _remoteIdentity;
  DateTime? get callStartTime => _callStartTime;
  bool get isMuted => _isMuted;
  bool get isSpeaker => _isSpeaker;
  bool get isHeld => _isHeld;
  bool get isInCall => _callState != SipCallState.none;
  String? get registeredExtension => _registeredExtension;

  /// Fired when a call ends — saves to call history.
  void Function(CallRecord)? onCallEnded;

  Future<void> initialize() async {
    if (!_listenerAdded) {
      _helper.addSipUaHelperListener(this);
      _listenerAdded = true;
    }
  }

  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) _log.w('Microphone permission not granted: $status');
    return status.isGranted;
  }

  /// Register over WSS. [pushProvider]/[pushParam]/[pushToken] are accepted for
  /// API compatibility (push is handled separately per platform).
  Future<bool> register({
    required String extension,
    required String password,
    String? pushProvider,
    String? pushParam,
    String? pushToken,
  }) async {
    await initialize();
    await _ensureMicPermission();

    _registrationState = SipRegistrationState.registering;
    _registeredExtension = extension;
    notifyListeners();

    final completer = Completer<bool>();
    _registerCompleter = completer;

    final settings = UaSettings()
      ..webSocketUrl = ServerConfig.wssUrl
      ..webSocketSettings.allowBadCertificate = false
      ..uri = 'sip:$extension@${ServerConfig.sipDomain}'
      ..authorizationUser = extension
      ..password = password
      ..displayName = extension
      ..userAgent = 'Cosmiq VoIP'
      ..dtmfMode = DtmfMode.RFC2833
      ..transportType = TransportType.WS
      ..register = true
      ..iceServers = [
        {'urls': ServerConfig.stunServer},
      ];

    try {
      await _helper.start(settings);
    } catch (e) {
      _log.e('SIP start failed: $e');
      _registrationState = SipRegistrationState.failed;
      notifyListeners();
      if (!completer.isCompleted) completer.complete(false);
    }

    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        if (_registrationState != SipRegistrationState.registered) {
          _registrationState = SipRegistrationState.failed;
          notifyListeners();
        }
        return _registrationState == SipRegistrationState.registered;
      },
    );
  }

  Future<void> unregister() async {
    try {
      _helper.unregister();
    } catch (_) {}
    _registrationState = SipRegistrationState.unregistered;
    _registeredExtension = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Call actions
  // ---------------------------------------------------------------------------

  Future<void> makeCall(String target) async {
    if (_callState != SipCallState.none) return;
    if (!await _ensureMicPermission()) return;

    final dest = target.replaceAll('sip:', '').split('@').first;
    final uri = 'sip:$dest@${ServerConfig.sipDomain}';
    _remoteIdentity = dest;
    _callState = SipCallState.calling;
    notifyListeners();

    final ok = await _helper.call(uri, voiceOnly: true);
    if (!ok) {
      _log.e('Call failed to start (not registered?)');
      _callState = SipCallState.none;
      _remoteIdentity = '';
      notifyListeners();
    }
  }

  Future<void> answerCall() async {
    if (!await _ensureMicPermission()) return;
    _activeCall?.answer(_helper.buildCallOptions(true));
  }

  Future<void> hangUp() async {
    _activeCall?.hangup();
  }

  Future<void> rejectCall() async {
    _activeCall?.hangup();
    _endCall(CallStatus.rejected);
  }

  void toggleMute() {
    final call = _activeCall;
    if (call == null) return;
    if (_isMuted) {
      call.unmute(true, false);
    } else {
      call.mute(true, false);
    }
  }

  void toggleSpeaker() {
    _isSpeaker = !_isSpeaker;
    Helper.setSpeakerphoneOn(_isSpeaker);
    notifyListeners();
  }

  void toggleHold() {
    final call = _activeCall;
    if (call == null) return;
    if (_isHeld) {
      call.unhold();
    } else {
      call.hold();
    }
  }

  void sendDtmf(String tone) {
    _activeCall?.sendDTMF(tone);
  }

  Future<bool> transferCall(String target) async {
    final call = _activeCall;
    if (call == null) return false;
    call.refer('sip:$target@${ServerConfig.sipDomain}');
    return true;
  }

  // ---------------------------------------------------------------------------
  // SipUaHelperListener
  // ---------------------------------------------------------------------------

  @override
  void registrationStateChanged(RegistrationState state) {
    switch (state.state) {
      case RegistrationStateEnum.REGISTERED:
        _registrationState = SipRegistrationState.registered;
        _completeRegister(true);
        break;
      case RegistrationStateEnum.REGISTRATION_FAILED:
        _registrationState = SipRegistrationState.failed;
        _completeRegister(false);
        break;
      case RegistrationStateEnum.UNREGISTERED:
        _registrationState = SipRegistrationState.unregistered;
        break;
      default:
        break;
    }
    notifyListeners();
  }

  @override
  void transportStateChanged(TransportState state) {
    if (state.state == TransportStateEnum.DISCONNECTED &&
        _registrationState == SipRegistrationState.registered) {
      _registrationState = SipRegistrationState.failed;
      notifyListeners();
    }
  }

  @override
  void callStateChanged(Call call, CallState state) {
    _activeCall = call;
    final isIncoming = call.direction == 'INCOMING';

    switch (state.state) {
      case CallStateEnum.CALL_INITIATION:
        _remoteIdentity = call.remote_identity ?? _remoteIdentity;
        _callState = isIncoming ? SipCallState.ringing : SipCallState.calling;
        break;
      case CallStateEnum.PROGRESS:
      case CallStateEnum.CONNECTING:
        _callState = isIncoming ? SipCallState.ringing : SipCallState.calling;
        break;
      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        _callState = SipCallState.confirmed;
        _callStartTime ??= DateTime.now();
        break;
      case CallStateEnum.STREAM:
        // Remote audio plays automatically on mobile; hold a ref to keep it alive.
        if (state.stream != null && state.originator == 'remote') {
          _remoteStream = state.stream;
        }
        break;
      case CallStateEnum.HOLD:
        _isHeld = true;
        _callState = SipCallState.held;
        break;
      case CallStateEnum.UNHOLD:
        _isHeld = false;
        _callState = SipCallState.confirmed;
        break;
      case CallStateEnum.MUTED:
        _isMuted = true;
        break;
      case CallStateEnum.UNMUTED:
        _isMuted = false;
        break;
      case CallStateEnum.FAILED:
        _endCall(CallStatus.missed);
        return;
      case CallStateEnum.ENDED:
        _endCall(_callStartTime != null
            ? CallStatus.answered
            : (isIncoming ? CallStatus.missed : CallStatus.rejected));
        return;
      case CallStateEnum.NONE:
      case CallStateEnum.REFER:
        break;
    }
    notifyListeners();
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}

  @override
  void onNewReinvite(ReInvite event) {}

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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

    try {
      _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;
    _activeCall = null;
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
    _helper.removeSipUaHelperListener(this);
    super.dispose();
  }
}
