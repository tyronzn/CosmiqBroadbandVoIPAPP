import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/call_record.dart';

/// On-device persistence for call history (Recents), so it survives app
/// restarts and is available offline before the billing CDRs load.
class CallHistoryStore {
  static const _key = 'cosmiq_call_history';
  static const _maxRecords = 200;

  /// Load persisted history (most recent first). Returns [] on any error.
  static Future<List<CallRecord>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return [];
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => CallRecord.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Persist [records] (capped to the most recent [_maxRecords]).
  static Future<void> save(List<CallRecord> records) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final trimmed = records.take(_maxRecords).toList();
      await prefs.setString(
          _key, jsonEncode(trimmed.map((r) => r.toJson()).toList()));
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }

  /// Merge server CDRs with locally-recorded calls, de-duplicated and sorted
  /// newest-first. A local record is dropped if a server CDR covers the same
  /// number within ~2 minutes (the server's copy of a call we just made).
  static List<CallRecord> merge(
      List<CallRecord> serverCdrs, List<CallRecord> local) {
    final result = <CallRecord>[...serverCdrs];
    for (final l in local) {
      final dup = serverCdrs.any((s) =>
          s.remoteNumber == l.remoteNumber &&
          (s.timestamp.difference(l.timestamp).inSeconds).abs() < 120);
      if (!dup) result.add(l);
    }
    result.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return result.take(_maxRecords).toList();
  }
}
