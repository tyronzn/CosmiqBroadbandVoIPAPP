import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import '../models/call_record.dart';
import '../models/voicemail_message.dart';
import '../models/account_info.dart';
import 'sip_service.dart';
import 'portabilling_service.dart';
import 'credential_service.dart';

/// Central app state, exposed via Provider.
/// Orchestrates SIP registration, PortaBilling API, call history, voicemail.
class AppState extends ChangeNotifier {
  static final _log = Logger(printer: PrettyPrinter(methodCount: 0));

  final SipService sip = SipService();
  final PortaBillingService billing = PortaBillingService();

  // Auth state
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _loginError;

  // Data
  List<CallRecord> _callHistory = [];
  List<VoicemailMessage> _voicemails = [];

  // Getters
  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get loginError => _loginError;
  AccountInfo? get accountInfo => billing.accountInfo;
  List<CallRecord> get callHistory => _callHistory;
  List<VoicemailMessage> get voicemails => _voicemails;

  AppState() {
    // Listen to SIP state changes
    sip.addListener(_onSipChanged);

    // Register callback for call ended events
    sip.onCallEnded = _onCallEnded;
  }

  /// Try to auto-login with saved credentials.
  /// Delegates to [login], which is SIP-primary, so it re-registers for calling
  /// even if the billing API is unreachable.
  Future<bool> tryAutoLogin() async {
    if (!await CredentialService.hasCredentials()) return false;

    final username = await CredentialService.getUsername();
    final password = await CredentialService.getPassword();
    if (username == null || password == null) return false;

    return login(username, password);
  }

  /// Login with username and password.
  ///
  /// SIP registration is the primary auth gate — succeeding here means the user
  /// can make and receive calls, and counts as "logged in". The PortaBilling API
  /// (call history, voicemail, balance) is best-effort: if those credentials
  /// don't also work against the billing platform, data features are simply
  /// unavailable, but the user is never locked out of calling.
  Future<bool> login(String username, String password) async {
    _isLoading = true;
    _loginError = null;
    notifyListeners();

    try {
      // Primary: register SIP. This proves the credentials and enables calling.
      await sip.initialize();
      final registered =
          await sip.register(extension: username, password: password);

      if (!registered) {
        _loginError = 'Could not register. Check your extension and password.';
        _isLoggedIn = false;
        _isLoading = false;
        notifyListeners();
        return false;
      }

      _isLoggedIn = true;
      _loginError = null;
      _log.i('SIP registration successful for $username');

      // Persist credentials so auto-login works next launch (independent of
      // whether the billing API accepts them).
      await CredentialService.saveCredentials(
        username: username,
        password: password,
      );

      // Best-effort: PortaBilling API for history/voicemail/balance.
      // A failure here must NOT block login or calling.
      final billingOk = await billing.login(username, password);
      if (billingOk) {
        _refreshData();
      } else {
        _log.w('PortaBilling API login failed — call history, voicemail and '
            'balance will be unavailable (SIP calling still works).');
      }
    } catch (e) {
      _loginError = 'Connection failed. Please check your network.';
      _log.e('Login failed: $e');
      _isLoggedIn = false;
    }

    _isLoading = false;
    notifyListeners();
    return _isLoggedIn;
  }

  /// Logout — unregister SIP, clear session, clear data.
  Future<void> logout() async {
    await sip.unregister();
    await billing.logout();
    _isLoggedIn = false;
    _callHistory = [];
    _voicemails = [];
    notifyListeners();
    _log.i('Logged out');
  }

  /// Refresh all data from PortaBilling.
  Future<void> _refreshData() async {
    await Future.wait([
      refreshCallHistory(),
      refreshVoicemails(),
    ]);
  }

  /// Refresh call history from PortaBilling CDRs.
  Future<void> refreshCallHistory() async {
    try {
      _callHistory = await billing.fetchCallHistory(limit: 50);
      notifyListeners();
    } catch (e) {
      _log.e('Failed to refresh call history: $e');
    }
  }

  /// Refresh voicemails.
  Future<void> refreshVoicemails() async {
    try {
      _voicemails = await billing.fetchVoicemails();
      notifyListeners();
    } catch (e) {
      _log.e('Failed to refresh voicemails: $e');
    }
  }

  /// Called when a SIP call ends — add to local history.
  void _onCallEnded(CallRecord record) {
    _callHistory.insert(0, record);
    notifyListeners();
  }

  /// React to SIP state changes.
  void _onSipChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    sip.removeListener(_onSipChanged);
    sip.dispose();
    super.dispose();
  }
}
