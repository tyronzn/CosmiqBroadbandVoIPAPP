import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sip_ua/sip_ua.dart';
import '../models/server_config.dart';
import '../models/call_record.dart';
import 'callkit_service.dart';
import 'connection_settings.dart';
import 'diagnostics_log.dart';

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
  String? _lastError;

  /// Identifies the current call to the OS's call UI (iOS CallKit).
  String? _callKitId;

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

  /// Why the last registration or call attempt failed, phrased so the user can
  /// act on it. Null when nothing has failed since the last success.
  String? get lastError => _lastError;

  /// Fired when a call ends — saves to call history.
  void Function(CallRecord)? onCallEnded;

  Future<void> initialize() async {
    if (!_listenerAdded) {
      _helper.addSipUaHelperListener(this);
      _listenerAdded = true;
    }

    // Native iOS call UI. No-op on Android, where PushService already presents
    // incoming calls, so the two can't fight over the screen.
    await CallKitService.init();
    CallKitService.onAccept = answerCall;
    CallKitService.onDecline = rejectCall;
    CallKitService.onEnd = hangUp;
    CallKitService.onMuteToggled = (muted) {
      if (muted != _isMuted) toggleMute();
    };
    CallKitService.onHoldToggled = (onHold) {
      if (onHold != _isHeld) toggleHold();
    };
    CallKitService.onDtmf = sendDtmf;
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

    // Fail immediately on an unusable endpoint instead of burning the 20s
    // timeout on a connection that can never open.
    final endpointProblem =
        ConnectionSettings.validateWssUrl(ConnectionSettings.wssUrl);
    if (endpointProblem != null) {
      _lastError = 'WebRTC endpoint is not configured. $endpointProblem';
      DiagnosticsLog.error('SIP', _lastError!);
      _registrationState = SipRegistrationState.failed;
      notifyListeners();
      return false;
    }

    // A second register() while one is still in flight would otherwise strand
    // the first caller's future until it times out.
    _completeRegister(false);

    _lastError = null;
    _registrationState = SipRegistrationState.registering;
    _registeredExtension = extension;
    notifyListeners();

    DiagnosticsLog.info(
      'SIP',
      'Registering $extension@${ConnectionSettings.sipDomain} '
          'via ${ConnectionSettings.wssUrl}',
    );

    final completer = Completer<bool>();
    _registerCompleter = completer;

    final settings = UaSettings()
      ..webSocketUrl = ConnectionSettings.wssUrl
      ..webSocketSettings.allowBadCertificate = false
      ..uri = 'sip:$extension@${ConnectionSettings.sipDomain}'
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
      _lastError = 'Could not open a connection to the WebRTC gateway ($e).';
      DiagnosticsLog.error('SIP', 'helper.start() threw: $e');
      _registrationState = SipRegistrationState.failed;
      notifyListeners();
      if (!completer.isCompleted) completer.complete(false);
    }

    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        if (_registrationState != SipRegistrationState.registered) {
          _lastError ??=
              'The gateway did not respond within 20 seconds. Check the WSS URL '
              'in Settings → Connection, and that the WebRTC gateway is enabled '
              'for this account.';
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
      _helper.unregister();
      // Also drop the WebSocket. Without this the transport stays open and a
      // later register() can reuse a half-dead connection.
      _helper.stop();
    } catch (_) {}
    DiagnosticsLog.info('SIP', 'Unregistered');
    _registrationState = SipRegistrationState.unregistered;
    _registeredExtension = null;
    _lastError = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Call actions
  // ---------------------------------------------------------------------------

  Future<void> makeCall(String target) async {
    if (_callState != SipCallState.none) return;

    // Distinguish "not registered" from "call rejected" — otherwise a dial
    // attempt while offline just silently does nothing.
    if (!_helper.registered) {
      _lastError =
          'Not registered, so the call cannot be placed. See Settings → Status.';
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

    final dest = target.replaceAll('sip:', '').split('@').first;
    final uri = 'sip:$dest@${ConnectionSettings.sipDomain}';
    _remoteIdentity = dest;
    _callState = SipCallState.calling;
    _lastError = null;
    notifyListeners();

    DiagnosticsLog.info('CALL', 'Dialling $uri');

    _callKitId = CallKitService.newCallId();
    unawaited(CallKitService.reportOutgoing(id: _callKitId!, target: dest));

    final ok = await _helper.call(uri, voiceOnly: true);
    if (!ok) {
      _lastError = 'The call could not be started.';
      DiagnosticsLog.error('CALL', 'helper.call() returned false for $uri');
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
    DiagnosticsLog.info('CALL', 'Transferring to $target');
    call.refer('sip:$target@${ConnectionSettings.sipDomain}');
    return true;
  }

  // ---------------------------------------------------------------------------
  // SipUaHelperListener
  // ---------------------------------------------------------------------------

  @override
  void registrationStateChanged(RegistrationState state) {
    switch (state.state) {
      case RegistrationStateEnum.REGISTERED:
        _lastError = null;
        _registrationState = SipRegistrationState.registered;
        DiagnosticsLog.info('SIP', 'Registered as $_registeredExtension');
        _completeRegister(true);
        break;
      case RegistrationStateEnum.REGISTRATION_FAILED:
        _lastError = _friendlyRegisterError(state.cause);
        _registrationState = SipRegistrationState.failed;
        DiagnosticsLog.error(
          'SIP',
          'Registration failed — '
              '${_causeText(state.cause) ?? "no cause reported"}',
        );
        _completeRegister(false);
        break;
      case RegistrationStateEnum.UNREGISTERED:
        _registrationState = SipRegistrationState.unregistered;
        DiagnosticsLog.info('SIP', 'Unregistered by server');
        break;
      default:
        break;
    }
    notifyListeners();
  }

  @override
  void transportStateChanged(TransportState state) {
    switch (state.state) {
      case TransportStateEnum.CONNECTING:
        DiagnosticsLog.info('WS', 'Connecting to ${ConnectionSettings.wssUrl}');
        break;
      case TransportStateEnum.CONNECTED:
        DiagnosticsLog.info('WS', 'WebSocket connected');
        break;
      case TransportStateEnum.DISCONNECTED:
        final cause = _causeText(state.cause);
        DiagnosticsLog.error(
            'WS', 'WebSocket disconnected${cause != null ? " — $cause" : ""}');
        // A transport drop mid-registration would otherwise leave the login
        // spinner running until the 20s timeout with nothing to explain it.
        if (_registrationState == SipRegistrationState.registering ||
            _registrationState == SipRegistrationState.registered) {
          _lastError = 'Lost the connection to the WebRTC gateway'
              '${cause != null ? " ($cause)" : ""}. Check the WSS URL in '
              'Settings → Connection, and your network.';
          _registrationState = SipRegistrationState.failed;
        }
        _completeRegister(false);
        break;
      case TransportStateEnum.NONE:
        break;
    }
    notifyListeners();
  }

  @override
  void callStateChanged(Call call, CallState state) {
    _activeCall = call;
    final isIncoming = call.direction == 'INCOMING';

    DiagnosticsLog.info('CALL',
        '${state.state.name} (${isIncoming ? "incoming" : "outgoing"})');

    switch (state.state) {
      case CallStateEnum.CALL_INITIATION:
        _remoteIdentity = call.remote_identity ?? _remoteIdentity;
        _callState = isIncoming ? SipCallState.ringing : SipCallState.calling;
        if (isIncoming) {
          _callKitId ??= CallKitService.newCallId();
          unawaited(CallKitService.showIncoming(
            id: _callKitId!,
            caller: _remoteIdentity,
          ));
        }
        break;
      case CallStateEnum.PROGRESS:
      case CallStateEnum.CONNECTING:
        _callState = isIncoming ? SipCallState.ringing : SipCallState.calling;
        break;
      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        _callState = SipCallState.confirmed;
        _callStartTime ??= DateTime.now();
        unawaited(CallKitService.setConnected(_callKitId));
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
        final failCause = _causeText(state.cause);
        _lastError =
            failCause != null ? 'Call failed — $failCause' : 'Call failed.';
        DiagnosticsLog.error('CALL', _lastError!);
        // "Missed" means an inbound call we didn't pick up; a failed outbound
        // attempt is not that.
        _endCall(isIncoming ? CallStatus.missed : CallStatus.rejected);
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

  // sip_ua's ErrorCause type lives under src/ and isn't exported from the
  // package barrel, so these take dynamic rather than importing package
  // internals. Both are only ever called with a `state.cause`.

  /// Compact "code reason" summary of a sip_ua error cause, for the log.
  String? _causeText(dynamic cause) {
    if (cause == null) return null;
    final parts = <String>[];
    final code = cause.status_code;
    if (code != null) parts.add(code.toString());
    final reason = (cause.reason_phrase as String?)?.trim();
    final raw = (cause.cause as String?)?.trim();
    if (reason != null && reason.isNotEmpty) {
      parts.add(reason);
    } else if (raw != null && raw.isNotEmpty) {
      parts.add(raw);
    }
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// Turn a registration failure into something the user can act on.
  String _friendlyRegisterError(dynamic cause) {
    final code = cause?.status_code as int?;
    switch (code) {
      case 401:
      case 403:
        return 'Extension or password rejected by the server.';
      case 404:
        return 'That extension does not exist on the server.';
      case 408:
        return 'The server did not respond in time.';
      case 503:
        return 'The server is temporarily unavailable. Try again shortly.';
    }
    final detail = _causeText(cause);
    return 'Registration failed${detail != null ? " ($detail)" : ""}. Check the '
        'WSS URL in Settings → Connection.';
  }

  void _endCall(CallStatus status) {
    final duration = _callStartTime != null
        ? DateTime.now().difference(_callStartTime!)
        : Duration.zero;

    // Hand the call back to the OS, or iOS keeps showing one that has ended.
    unawaited(CallKitService.endCall(_callKitId));
    _callKitId = null;

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
    try {
      _helper.stop();
    } catch (_) {}
    super.dispose();
  }
}
