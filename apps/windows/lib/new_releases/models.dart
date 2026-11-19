import 'dart:math';

enum ReleaseSource { yandex, spotify }

extension ReleaseSourceX on ReleaseSource {
  String get id => switch (this) {
        ReleaseSource.yandex => 'yandex',
        ReleaseSource.spotify => 'spotify',
      };

  static ReleaseSource parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'spotify':
        return ReleaseSource.spotify;
      default:
        return ReleaseSource.yandex;
    }
  }
}

class WatchedArtist {
  const WatchedArtist({
    required this.id,
    required this.name,
    this.yandexUrl,
    this.spotifyUrl,
    required this.source,
    required this.releaseTitle,
    required this.releaseType,
    required this.releaseDate,
    required this.releaseDateMs,
    required this.coverUrl,
    required this.fetchedAtMs,
    this.releaseUrl,
  });

  /// Stable watchlist id.
  final String id;

  /// Display name entered by the user.
  final String name;

  final String? yandexUrl;
  final String? spotifyUrl;

  /// Source of the currently shown (newest) release.
  final ReleaseSource source;
  final String releaseTitle;
  final String releaseType;

  /// Human label, e.g. «13 ноября 2026 г.»
  final String releaseDate;

  /// UTC millis for newest→oldest sort. 0 if unknown.
  final int releaseDateMs;
  final String coverUrl;
  final int fetchedAtMs;
  final String? releaseUrl;

  WatchedArtist copyWith({
    String? name,
    String? yandexUrl,
    String? spotifyUrl,
    ReleaseSource? source,
    String? releaseTitle,
    String? releaseType,
    String? releaseDate,
    int? releaseDateMs,
    String? coverUrl,
    int? fetchedAtMs,
    String? releaseUrl,
  }) {
    return WatchedArtist(
      id: id,
      name: name ?? this.name,
      yandexUrl: yandexUrl ?? this.yandexUrl,
      spotifyUrl: spotifyUrl ?? this.spotifyUrl,
      source: source ?? this.source,
      releaseTitle: releaseTitle ?? this.releaseTitle,
      releaseType: releaseType ?? this.releaseType,
      releaseDate: releaseDate ?? this.releaseDate,
      releaseDateMs: releaseDateMs ?? this.releaseDateMs,
      coverUrl: coverUrl ?? this.coverUrl,
      fetchedAtMs: fetchedAtMs ?? this.fetchedAtMs,
      releaseUrl: releaseUrl ?? this.releaseUrl,
    );
  }

  factory WatchedArtist.fromJson(Map<String, dynamic> json) {
    final source = ReleaseSourceX.parse('${json['source']}');
    final name = '${json['name'] ?? json['artistName'] ?? ''}'.trim();
    final yandexUrl = _nullable('${json['yandexUrl'] ?? ''}');
    final spotifyUrl = _nullable('${json['spotifyUrl'] ?? ''}');
    // Migrate old single-url entries.
    final legacyUrl = _nullable('${json['artistUrl'] ?? ''}');
    final migratedYandex = yandexUrl ??
        (source == ReleaseSource.yandex ? legacyUrl : null);
    final migratedSpotify = spotifyUrl ??
        (source == ReleaseSource.spotify ? legacyUrl : null);
    final id = '${json['id'] ?? ''}'.trim().isNotEmpty
        ? '${json['id']}'.trim()
        : _legacyId(source, '${json['artistId'] ?? ''}');

    return WatchedArtist(
      id: id,
      name: name.isEmpty ? 'Артист' : name,
      yandexUrl: migratedYandex,
      spotifyUrl: migratedSpotify,
      source: source,
      releaseTitle: '${json['releaseTitle'] ?? ''}',
      releaseType: '${json['releaseType'] ?? ''}',
      releaseDate: '${json['releaseDate'] ?? ''}',
      releaseDateMs: _asInt(json['releaseDateMs']),
      coverUrl: '${json['coverUrl'] ?? ''}',
      fetchedAtMs: _asInt(json['fetchedAtMs']),
      releaseUrl: _nullable('${json['releaseUrl']}'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (yandexUrl != null) 'yandexUrl': yandexUrl,
        if (spotifyUrl != null) 'spotifyUrl': spotifyUrl,
        'source': source.id,
        'releaseTitle': releaseTitle,
        'releaseType': releaseType,
        'releaseDate': releaseDate,
        'releaseDateMs': releaseDateMs,
        'coverUrl': coverUrl,
        'fetchedAtMs': fetchedAtMs,
        if (releaseUrl != null) 'releaseUrl': releaseUrl,
      };

  static String newId() {
    final r = Random();
    final ms = DateTime.now().millisecondsSinceEpoch;
    return 'w_${ms.toRadixString(16)}_${r.nextInt(1 << 32).toRadixString(16)}';
  }

  static String _legacyId(ReleaseSource source, String artistId) {
    final id = artistId.trim();
    if (id.isEmpty) return newId();
    return '${source.id}_$id';
  }

  static String? _nullable(String value) {
    final t = value.trim();
    return t.isEmpty ? null : t;
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}

class LatestRelease {
  const LatestRelease({
    required this.source,
    required this.artistId,
    required this.artistName,
    required this.artistUrl,
    required this.title,
    required this.typeLabel,
    required this.dateLabel,
    required this.releaseDateMs,
    required this.coverUrl,
    this.releaseUrl,
  });

  final ReleaseSource source;
  final String artistId;
  final String artistName;
  final String artistUrl;
  final String title;
  final String typeLabel;
  final String dateLabel;
  final int releaseDateMs;
  final String coverUrl;
  final String? releaseUrl;
}
