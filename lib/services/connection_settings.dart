import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_config.dart';

/// Connection endpoints that can be corrected on the device, without a rebuild.
///
/// The WebRTC/WSS gateway ships with a compile-time default, but the exact
/// host, port and path are supplied by the carrier (Backspace/PortaSIP) and may
/// not match. Keeping these editable in Settings means a wrong endpoint costs a
/// field edit on the phone instead of a rebuild — which matters most on iOS,
/// where rebuilding requires a Mac.
class ConnectionSettings {
  ConnectionSettings._();

  static const String _kWssUrl = 'cosmiq_wss_url';
  static const String _kSipDomain = 'cosmiq_sip_domain';

  static String _wssUrl = ServerConfig.wssUrl;
  static String _sipDomain = ServerConfig.sipDomain;
  static bool _loaded = false;

  /// Effective WSS gateway URL — the override if one is saved, else the default.
  static String get wssUrl => _wssUrl;

  /// Effective SIP domain used in `sip:<extension>@<domain>`.
  static String get sipDomain => _sipDomain;

  static String get defaultWssUrl => ServerConfig.wssUrl;
  static String get defaultSipDomain => ServerConfig.sipDomain;

  static bool get isOverridden =>
      _wssUrl != ServerConfig.wssUrl || _sipDomain != ServerConfig.sipDomain;

  /// True while the app is still pointing at the shipped WSS default, which has
  /// never been confirmed against the carrier's gateway. Registration is
  /// expected to fail in this state, so the UI warns instead of looking broken.
  static bool get isUsingUnconfirmedDefault => _wssUrl == ServerConfig.wssUrl;

  /// Load persisted overrides. Safe to call more than once.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final wss = prefs.getString(_kWssUrl)?.trim();
      final domain = prefs.getString(_kSipDomain)?.trim();
      if (wss != null && wss.isNotEmpty) _wssUrl = wss;
      if (domain != null && domain.isNotEmpty) _sipDomain = domain;
    } catch (_) {
      // Keep the compiled-in defaults if storage is unavailable.
    }
  }

  static Future<void> setWssUrl(String value) async {
    _wssUrl = value.trim().isEmpty ? ServerConfig.wssUrl : value.trim();
    await _persist(_kWssUrl, value.trim());
  }

  static Future<void> setSipDomain(String value) async {
    _sipDomain = value.trim().isEmpty ? ServerConfig.sipDomain : value.trim();
    await _persist(_kSipDomain, value.trim());
  }

  static Future<void> resetToDefaults() async {
    _wssUrl = ServerConfig.wssUrl;
    _sipDomain = ServerConfig.sipDomain;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kWssUrl);
      await prefs.remove(_kSipDomain);
    } catch (_) {}
  }

  static Future<void> _persist(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, value);
      }
    } catch (_) {}
  }

  /// Human-readable problem with [url], or null if it looks usable.
  static String? validateWssUrl(String url) {
    final value = url.trim();
    if (value.isEmpty) {
      return 'Enter the WebSocket URL supplied by your provider.';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      return 'That is not a valid URL.';
    }
    if (uri.scheme != 'wss' && uri.scheme != 'ws') {
      return 'The URL must start with wss:// (ws:// only for local testing).';
    }
    return null;
  }

  /// Human-readable problem with [domain], or null if it looks usable.
  static String? validateSipDomain(String domain) {
    final value = domain.trim();
    if (value.isEmpty) return 'Enter the SIP domain supplied by your provider.';
    if (value.contains('/') || value.contains(' ')) {
      return 'Enter a host name only, e.g. voice.cosmiqbroadband.co.za';
    }
    if (!value.contains('.')) return 'That does not look like a domain name.';
    return null;
  }
}
