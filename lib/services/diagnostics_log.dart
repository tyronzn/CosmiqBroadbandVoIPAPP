import 'package:flutter/foundation.dart';
import '../models/server_config.dart';
import 'connection_settings.dart';

enum DiagLevel { info, warn, error }

class DiagEntry {
  final DateTime time;
  final DiagLevel level;
  final String tag;
  final String message;

  const DiagEntry(this.time, this.level, this.tag, this.message);

  String get timestamp {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  String get line =>
      '$timestamp  ${level.name.toUpperCase().padRight(5)} [$tag] $message';
}

/// Rolling in-app log of connection and call events.
///
/// Exists because this app is tested on a handset with no console attached —
/// on iOS in particular, reading `flutter logs` needs a Mac. Settings →
/// Diagnostics renders this and copies it to the clipboard, so a failed
/// registration can be reported with the actual SIP cause attached instead of
/// "it didn't work".
///
/// Never log credentials here: the log is designed to be shared.
class DiagnosticsLog {
  DiagnosticsLog._();

  static const int maxEntries = 300;
  static final List<DiagEntry> _entries = <DiagEntry>[];

  /// Bumped on every change so widgets can rebuild without a full app state.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static List<DiagEntry> get entries => List.unmodifiable(_entries);
  static bool get isEmpty => _entries.isEmpty;

  static void info(String tag, String message) =>
      _add(DiagLevel.info, tag, message);
  static void warn(String tag, String message) =>
      _add(DiagLevel.warn, tag, message);
  static void error(String tag, String message) =>
      _add(DiagLevel.error, tag, message);

  static void _add(DiagLevel level, String tag, String message) {
    _entries.add(DiagEntry(DateTime.now(), level, tag, message));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    revision.value++;
    if (kDebugMode) debugPrint('[$tag] $message');
  }

  static void clear() {
    _entries.clear();
    revision.value++;
  }

  /// The log plus a header describing the build and endpoints, so a pasted
  /// report is self-describing to whoever receives it.
  static String asText() {
    final buffer = StringBuffer()
      ..writeln('Cosmiq VoIP diagnostics')
      ..writeln('App version : ${ServerConfig.appVersion}')
      ..writeln('Engine      : dart-sip-ua + WebRTC (SIP over WebSocket)')
      ..writeln('WSS URL     : ${ConnectionSettings.wssUrl}'
          '${ConnectionSettings.isOverridden ? "  (overridden)" : ""}')
      ..writeln('SIP domain  : ${ConnectionSettings.sipDomain}')
      ..writeln('Generated   : ${DateTime.now().toIso8601String()}')
      ..writeln('-' * 48);

    if (_entries.isEmpty) {
      buffer.writeln('(no events recorded)');
    } else {
      for (final entry in _entries) {
        buffer.writeln(entry.line);
      }
    }
    return buffer.toString();
  }
}
