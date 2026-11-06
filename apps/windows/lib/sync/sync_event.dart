import 'dart:convert';

/// Append-only sync event stored locally and in Drive JSONL chunks.
class SyncEvent {
  const SyncEvent({
    required this.id,
    required this.deviceId,
    required this.at,
    required this.type,
    required this.payload,
  });

  final String id;
  final String deviceId;
  final DateTime at;
  final String type;
  final Map<String, Object?> payload;

  static const playlistUpsert = 'playlist_upsert';
  static const playRecorded = 'play_recorded';
  static const playCountsMerge = 'play_counts_merge';
  static const artistAlias = 'artist_alias';
  static const producerAlias = 'producer_alias';
  static const settingsFlags = 'settings_flags';

  Map<String, Object?> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'at': at.toUtc().toIso8601String(),
        'type': type,
        'payload': payload,
      };

  factory SyncEvent.fromJson(Map<String, Object?> json) {
    final payloadRaw = json['payload'];
    return SyncEvent(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      at: DateTime.parse(json['at'] as String),
      type: json['type'] as String,
      payload: payloadRaw is Map
          ? payloadRaw.map((k, v) => MapEntry(k.toString(), v))
          : const {},
    );
  }

  String toJsonLine() => jsonEncode(toJson());

  static SyncEvent? tryParseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    return SyncEvent.fromJson(
      decoded.map((k, v) => MapEntry(k.toString(), v)),
    );
  }
}
