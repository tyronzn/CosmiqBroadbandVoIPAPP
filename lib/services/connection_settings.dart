import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_config.dart';

/// Where the app registers, and the only part of it a support engineer can
/// correct on the handset.
///
/// Users never see any of this: they sign in with an extension and password,
/// and the defaults below point at Cosmiq's own SIP service. The overrides
/// exist so a wrong or changed server can be corrected in the field without a
/// rebuild — which matters most on iOS, where rebuilding needs a Mac.
class ConnectionSettings {
  ConnectionSettings._();

  static const String _kSipHost = 'cosmiq_sip_host';
  static const String _kSipPort = 'cosmiq_sip_port';
  static const String _kSipDomain = 'cosmiq_sip_domain';

  static String _sipHost = ServerConfig.sipServer;
  static String _sipPort = ServerConfig.sipPort.toString();
  static String _sipDomain = ServerConfig.sipDomain;
  static bool _loaded = false;

  /// Host the SIP client connects to. Defaults to Cosmiq's SIP service.
  static String get sipHost => _sipHost;

  /// SIP port as a string, which is the form the SIP stack takes.
  static String get sipPort => _sipPort;

  /// Domain used in the SIP URI, as sip:<extension>@<domain>.
  static String get sipDomain => _sipDomain;

  static String get defaultSipHost => ServerConfig.sipServer;
  static String get defaultSipPort => ServerConfig.sipPort.toString();
  static String get defaultSipDomain => ServerConfig.sipDomain;

  static bool get isOverridden =>
      _sipHost != defaultSipHost ||
      _sipPort != defaultSipPort ||
      _sipDomain != defaultSipDomain;

  /// Load persisted overrides. Safe to call more than once.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final host = prefs.getString(_kSipHost)?.trim();
      final port = prefs.getString(_kSipPort)?.trim();
      final domain = prefs.getString(_kSipDomain)?.trim();
      if (host != null && host.isNotEmpty) _sipHost = host;
      if (port != null && port.isNotEmpty) _sipPort = port;
      if (domain != null && domain.isNotEmpty) _sipDomain = domain;
    } catch (_) {
      // Keep the compiled-in defaults if storage is unavailable.
    }
  }

  static Future<void> setSipHost(String value) async {
    _sipHost = value.trim().isEmpty ? defaultSipHost : value.trim();
    await _persist(_kSipHost, value.trim());
  }

  static Future<void> setSipPort(String value) async {
    _sipPort = value.trim().isEmpty ? defaultSipPort : value.trim();
    await _persist(_kSipPort, value.trim());
  }

  static Future<void> setSipDomain(String value) async {
    _sipDomain = value.trim().isEmpty ? defaultSipDomain : value.trim();
    await _persist(_kSipDomain, value.trim());
  }

  static Future<void> resetToDefaults() async {
    _sipHost = defaultSipHost;
    _sipPort = defaultSipPort;
    _sipDomain = defaultSipDomain;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kSipHost);
      await prefs.remove(_kSipPort);
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

  /// Human-readable problem with [host], or null if it looks usable.
  static String? validateSipHost(String host) {
    final value = host.trim();
    if (value.isEmpty) return 'Enter the SIP server address.';
    if (value.contains('/') || value.contains(' ')) {
      return 'Enter a host name only, e.g. voice.cosmiqbroadband.co.za';
    }
    if (value.contains(':')) return 'Put the port in the port field, not here.';
    if (!value.contains('.')) return 'That does not look like a server address.';
    return null;
  }

  /// Human-readable problem with [port], or null if it looks usable.
  static String? validateSipPort(String port) {
    final value = port.trim();
    if (value.isEmpty) return 'Enter the SIP port (normally 5060).';
    final parsed = int.tryParse(value);
    if (parsed == null) return 'The port must be a number.';
    if (parsed < 1 || parsed > 65535) return 'The port must be 1-65535.';
    return null;
  }

  /// Human-readable problem with [domain], or null if it looks usable.
  static String? validateSipDomain(String domain) {
    final value = domain.trim();
    if (value.isEmpty) return 'Enter the SIP domain.';
    if (value.contains('/') || value.contains(' ')) {
      return 'Enter a host name only, e.g. voice.cosmiqbroadband.co.za';
    }
    if (!value.contains('.')) return 'That does not look like a domain name.';
    return null;
  }
}
