/// Represents a single voicemail message from PortaBilling.
class VoicemailMessage {
  final String id;
  final String callerNumber;
  final String? callerName;
  final DateTime timestamp;
  final Duration duration;
  final String? audioUrl;
  final String? transcript;
  final bool isRead;

  VoicemailMessage({
    required this.id,
    required this.callerNumber,
    this.callerName,
    required this.timestamp,
    required this.duration,
    this.audioUrl,
    this.transcript,
    this.isRead = false,
  });

  /// Parse from PortaBilling voicemail API response
  factory VoicemailMessage.fromPortaBilling(Map<String, dynamic> json) {
    return VoicemailMessage(
      id: json['i_message']?.toString() ?? '',
      callerNumber: json['caller_id'] ?? 'Unknown',
      callerName: json['caller_name'],
      timestamp:
          DateTime.tryParse(json['receive_date'] ?? '') ?? DateTime.now(),
      duration: Duration(
        seconds: (json['duration'] as num?)?.toInt() ?? 0,
      ),
      audioUrl: json['file_url'],
      transcript: json['transcript'],
      isRead: json['status'] == 'read',
    );
  }

  /// Formatted duration string
  String get durationFormatted {
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Display name
  String get displayName => callerName ?? callerNumber;

  /// Create a copy with updated fields
  VoicemailMessage copyWith({bool? isRead}) {
    return VoicemailMessage(
      id: id,
      callerNumber: callerNumber,
      callerName: callerName,
      timestamp: timestamp,
      duration: duration,
      audioUrl: audioUrl,
      transcript: transcript,
      isRead: isRead ?? this.isRead,
    );
  }
}
