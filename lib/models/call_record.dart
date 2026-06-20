/// Represents a single call record (CDR) from PortaBilling or local storage.
enum CallDirection { incoming, outgoing }
enum CallStatus { answered, missed, rejected }

class CallRecord {
  final String id;
  final String remoteNumber;
  final String? remoteName;
  final CallDirection direction;
  final CallStatus status;
  final DateTime timestamp;
  final Duration duration;
  final String? extensionLabel; // e.g. "Ext. 2000"

  CallRecord({
    required this.id,
    required this.remoteNumber,
    this.remoteName,
    required this.direction,
    required this.status,
    required this.timestamp,
    required this.duration,
    this.extensionLabel,
  });

  /// Parse from PortaBilling CDR JSON
  factory CallRecord.fromPortaBilling(Map<String, dynamic> json) {
    final cld = json['CLD'] ?? '';
    final cli = json['CLI'] ?? '';
    final isOutgoing = json['charged_party'] == 'originator';

    return CallRecord(
      id: json['i_xdr']?.toString() ?? DateTime.now().toIso8601String(),
      remoteNumber: isOutgoing ? cld : cli,
      remoteName: null, // resolved later via contacts
      direction: isOutgoing ? CallDirection.outgoing : CallDirection.incoming,
      status: (json['connect_time'] != null && json['connect_time'] != '')
          ? CallStatus.answered
          : CallStatus.missed,
      timestamp: DateTime.tryParse(json['bill_time'] ?? '') ?? DateTime.now(),
      duration: Duration(
        seconds: (json['charged_quantity'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  /// Create from a local SIP call event
  factory CallRecord.fromSipCall({
    required String remoteNumber,
    String? remoteName,
    required CallDirection direction,
    required CallStatus status,
    required DateTime timestamp,
    required Duration duration,
  }) {
    return CallRecord(
      id: 'local_${timestamp.millisecondsSinceEpoch}',
      remoteNumber: remoteNumber,
      remoteName: remoteName,
      direction: direction,
      status: status,
      timestamp: timestamp,
      duration: duration,
    );
  }

  /// Formatted duration string (e.g. "02:14")
  String get durationFormatted {
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      final h = duration.inHours.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '$m:$s';
  }

  /// Display name: use remoteName if available, fallback to number
  String get displayName => remoteName ?? remoteNumber;

  /// Direction arrow for UI
  String get directionArrow {
    switch (direction) {
      case CallDirection.incoming:
        return status == CallStatus.missed ? '↙' : '↘';
      case CallDirection.outgoing:
        return '↗';
    }
  }

  /// Subtitle text for list items
  String get subtitle {
    final dir = direction == CallDirection.outgoing ? 'outgoing' : 'mobile';
    final prefix = status == CallStatus.missed ? 'missed' : directionArrow;
    return '$prefix $dir';
  }
}
