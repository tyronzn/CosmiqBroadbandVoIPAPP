import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import '../models/server_config.dart';
import '../models/account_info.dart';
import '../models/call_record.dart';
import '../models/voicemail_message.dart';
import 'credential_service.dart';

/// Client for the PortaBilling REST API.
/// Handles authentication, CDR retrieval, voicemail, and account management.
///
/// PortaOne API docs: https://docs.portaone.com/
/// All calls go through: https://secure.backspace.co.za:8442/rest
class PortaBillingService {
  static final _log = Logger(printer: PrettyPrinter(methodCount: 0));

  String? _sessionId;
  AccountInfo? _accountInfo;

  /// Current session ID
  String? get sessionId => _sessionId;

  /// Cached account info
  AccountInfo? get accountInfo => _accountInfo;

  /// Whether we have an active session
  bool get isAuthenticated => _sessionId != null;

  // ---------------------------------------------------------------------------
  // Authentication
  // ---------------------------------------------------------------------------

  /// Login to PortaBilling self-care API.
  /// Returns true on success, false on failure.
  Future<bool> login(String username, String password) async {
    try {
      final response = await _post('/Session/login', {
        'login': username,
        'password': password,
        // Account self-care login requires the domain as a mandatory field.
        'domain': ServerConfig.portaLoginDomain,
      });

      if (response != null && response['session_id'] != null) {
        _sessionId = response['session_id'];
        await CredentialService.saveSessionId(_sessionId!);
        await CredentialService.saveCredentials(
          username: username,
          password: password,
        );
        _log.i('PortaBilling login successful for $username');

        // Fetch account info immediately after login
        await fetchAccountInfo();
        return true;
      }

      _log.w('PortaBilling login failed — no session_id in response');
      return false;
    } catch (e) {
      _log.e('PortaBilling login error: $e');
      return false;
    }
  }

  /// Try to restore a previous session.
  Future<bool> restoreSession() async {
    try {
      _sessionId = await CredentialService.getSessionId();
      if (_sessionId == null) return false;

      // Test if session is still valid by fetching account info
      final info = await fetchAccountInfo();
      return info != null;
    } catch (e) {
      _log.w('Session restore failed: $e');
      _sessionId = null;
      return false;
    }
  }

  /// Logout — destroy session.
  Future<void> logout() async {
    if (_sessionId != null) {
      try {
        await _post('/Session/logout', {});
      } catch (_) {}
    }
    _sessionId = null;
    _accountInfo = null;
    await CredentialService.clearAll();
    _log.i('Logged out');
  }

  // ---------------------------------------------------------------------------
  // Account Info
  // ---------------------------------------------------------------------------

  /// Fetch account info (balance, plan, caller ID, etc.)
  Future<AccountInfo?> fetchAccountInfo() async {
    try {
      final response = await _post('/Account/get_account_info', {});
      if (response != null && response['account_info'] != null) {
        _accountInfo = AccountInfo.fromPortaBilling(response['account_info']);
        return _accountInfo;
      }
    } catch (e) {
      _log.e('Failed to fetch account info: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Call History (CDRs)
  // ---------------------------------------------------------------------------

  /// Fetch call history / CDR list.
  /// [limit] — max records to return (default 50).
  /// [offset] — pagination offset.
  /// [fromDate]/[toDate] — PortaBilling requires an explicit date window;
  /// defaults to the last 90 days.
  Future<List<CallRecord>> fetchCallHistory({
    int limit = 50,
    int offset = 0,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    try {
      final to = toDate ?? DateTime.now();
      final from = fromDate ?? to.subtract(const Duration(days: 90));
      final response = await _post('/Account/get_xdr_list', {
        'limit': limit,
        'offset': offset,
        'from_date': _fmtDate(from),
        'to_date': _fmtDate(to),
      });

      if (response != null && response['xdr_list'] is List) {
        return (response['xdr_list'] as List)
            .map((json) => CallRecord.fromPortaBilling(json))
            .toList();
      }
    } catch (e) {
      _log.e('Failed to fetch call history: $e');
    }
    return [];
  }

  // ---------------------------------------------------------------------------
  // Voicemail
  // ---------------------------------------------------------------------------

  /// Fetch voicemail messages.
  Future<List<VoicemailMessage>> fetchVoicemails() async {
    try {
      final response = await _post('/Account/get_vm_list', {});

      if (response != null && response['messages'] is List) {
        return (response['messages'] as List)
            .map((json) => VoicemailMessage.fromPortaBilling(json))
            .toList();
      }
    } catch (e) {
      _log.e('Failed to fetch voicemails: $e');
    }
    return [];
  }

  /// Delete a voicemail message.
  Future<bool> deleteVoicemail(String messageId) async {
    try {
      await _post('/Account/delete_vm', {'i_message': messageId});
      return true;
    } catch (e) {
      _log.e('Failed to delete voicemail: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Call Forwarding / DND
  // ---------------------------------------------------------------------------

  /// Update call forwarding settings.
  Future<bool> setCallForwarding({
    required bool enabled,
    String? forwardNumber,
  }) async {
    try {
      await _post('/Account/update_account', {
        'account_info': {
          'follow_me_enabled': enabled ? 'Y' : 'N',
          if (forwardNumber != null) 'follow_me_number': forwardNumber,
        },
      });
      await fetchAccountInfo(); // refresh
      return true;
    } catch (e) {
      _log.e('Failed to update call forwarding: $e');
      return false;
    }
  }

  /// Toggle "send callers straight to voicemail", which this app surfaces as
  /// Do Not Disturb. NOTE: this maps to PortaBilling's `vm_enabled` flag, not a
  /// true DND service feature. Real DND lives in the account's service features
  /// (update_service_features) and is config-specific per install — wire that up
  /// once the server's service set is confirmed.
  Future<bool> setDnd(bool enabled) async {
    try {
      await _post('/Account/update_account', {
        'account_info': {
          'vm_enabled': enabled ? 'Y' : 'N',
        },
      });
      await fetchAccountInfo(); // refresh
      return true;
    } catch (e) {
      _log.e('Failed to update DND: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // HTTP helper
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>?> _post(
    String endpoint,
    Map<String, dynamic> params,
  ) async {
    // The endpoint strings already carry the service segment
    // (e.g. "/Session/login", "/Account/get_account_info"), so the base
    // must be the bare ".../rest" — not ".../rest/Account".
    final url = Uri.parse('${ServerConfig.portaBillingApiUrl}$endpoint');
    final isLogin = endpoint.contains('login');

    // PortaBilling expects application/x-www-form-urlencoded with `params`
    // and `auth_info` as separate fields, each a JSON-encoded string.
    // Passing a Map<String, String> as `body` makes package:http set that
    // content type and URL-encode the values automatically.
    Map<String, String> buildBody() {
      final form = <String, String>{'params': jsonEncode(params)};
      if (_sessionId != null && !isLogin) {
        form['auth_info'] = jsonEncode({'session_id': _sessionId});
      }
      return form;
    }

    var response = await http
        .post(url, body: buildBody())
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    // Session expired — try re-auth and retry once. Never do this for the
    // login call itself, or a failing login would recurse infinitely.
    if ((response.statusCode == 401 || response.statusCode == 500) &&
        !isLogin) {
      final reauthed = await _tryReauth();
      if (reauthed) {
        // buildBody() re-reads the refreshed _sessionId.
        response = await http
            .post(url, body: buildBody())
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          return jsonDecode(response.body) as Map<String, dynamic>;
        }
      }
    }

    _log.w('API error ${response.statusCode}: ${response.body}');
    return null;
  }

  /// Format a date as PortaBilling expects it: "YYYY-MM-DD HH:MM:SS".
  String _fmtDate(DateTime d) {
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(d.year, 4)}-${p(d.month)}-${p(d.day)} '
        '${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
  }

  /// Attempt to re-authenticate using saved credentials.
  Future<bool> _tryReauth() async {
    final username = await CredentialService.getUsername();
    final password = await CredentialService.getPassword();
    if (username != null && password != null) {
      return login(username, password);
    }
    return false;
  }
}
