import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Scrapes open.spotify.com artist HTML (no Spotify Web API).
///
/// Desktop HTML is often captcha-walled; mobile Safari UA returns SSR with
/// base64 `initialState` (discography) embedded in the page.
class SpotifyClient {
  SpotifyClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1';

  static final _artistIdRe = RegExp(
    r'(?:https?://)?open\.spotify\.com/(?:intl-[a-z]{2}/)?artist/'
    r'([A-Za-z0-9]{22})',
    caseSensitive: false,
  );

  static final _albumIdRe = RegExp(r'spotify:album:([A-Za-z0-9]{22})');

  static String? parseArtistId(String input) {
    final m = _artistIdRe.firstMatch(input.trim());
    return m?.group(1);
  }

  static String artistUrl(String artistId) =>
      'https://open.spotify.com/artist/$artistId';

  static String albumUrl(String albumId) =>
      'https://open.spotify.com/album/$albumId';

  Future<LatestRelease> fetchLatestRelease(String rawUrl) async {
    final artistId = parseArtistId(rawUrl);
    if (artistId == null) {
      throw StateError('Нужна ссылка вида open.spotify.com/artist/…');
    }

    final html = await _getHtml(artistUrl(artistId));
    final state = _decodeInitialState(html);
    if (state == null) {
      throw StateError('Не удалось прочитать данные со страницы Spotify');
    }

    final artistName = _artistNameFromState(state, artistId) ??
        _ogTitle(html) ??
        'Артист';

    final candidates = _candidateReleases(state);
    if (candidates.isEmpty) {
      throw StateError('На странице нет релизов');
    }

    _SpRelease? best;
    var bestMs = -1;
    for (final c in candidates) {
      final details = await _fetchAlbumDetails(c.albumId);
      final ms = details?.releaseDateMs ?? _yearMs(c.year);
      if (ms >= bestMs) {
        bestMs = ms;
        best = _SpRelease(
          albumId: c.albumId,
          title: details?.title.isNotEmpty == true ? details!.title : c.title,
          type: c.type,
          year: c.year,
          coverUrl: details?.coverUrl.isNotEmpty == true
              ? details!.coverUrl
              : c.coverUrl,
          artists: details?.artists ?? const [],
          releaseDateMs: ms,
          dateLabel: details?.dateLabel ?? _yearLabel(c.year),
        );
      }
    }

    if (best == null) {
      throw StateError('Не удалось определить последний релиз');
    }

    final names = best.artists.isNotEmpty
        ? best.artists.join(', ')
        : artistName;

    return LatestRelease(
      source: ReleaseSource.spotify,
      artistId: artistId,
      artistName: names,
      artistUrl: artistUrl(artistId),
      title: best.title,
      typeLabel: _typeLabel(best.type),
      dateLabel: best.dateLabel,
      releaseDateMs: best.releaseDateMs,
      coverUrl: best.coverUrl,
      releaseUrl: albumUrl(best.albumId),
    );
  }

  Future<_AlbumDetails?> _fetchAlbumDetails(String albumId) async {
    try {
      final html = await _getHtml(albumUrl(albumId));
      final ld = _firstLdJson(html);
      String title = '';
      String dateIso = '';
      if (ld != null) {
        title = '${ld['name'] ?? ''}'.trim();
        dateIso = '${ld['datePublished'] ?? ''}'.trim();
      }
      if (title.isEmpty) {
        title = _cleanAlbumTitle(_ogTitle(html) ?? '');
      }

      // «The Weeknd · album · 2025 · 22 songs» — artists before first ·
      final artists = _artistsFromOgDescription(_ogDescription(html));

      final cover = RegExp(
            r'property="og:image"\s+content="([^"]+)"',
            caseSensitive: false,
          ).firstMatch(html)?.group(1)?.trim() ??
          '';

      final dt = DateTime.tryParse(dateIso);
      final ms = dt?.toUtc().millisecondsSinceEpoch ?? 0;
      return _AlbumDetails(
        title: title,
        artists: artists,
        coverUrl: cover,
        releaseDateMs: ms,
        dateLabel: ms > 0 ? _dateLabel(dt!.toLocal()) : '',
      );
    } catch (_) {
      return null;
    }
  }

  List<String> _artistsFromOgDescription(String? description) {
    final raw = (description ?? '').trim();
    if (raw.isEmpty) return const [];
    final head = raw.split('·').first.trim();
    if (head.isEmpty) return const [];
    final names = <String>[];
    for (final part in head.split(',')) {
      final name = part.trim();
      if (name.isEmpty) continue;
      if (!names.any((n) => n.toLowerCase() == name.toLowerCase())) {
        names.add(name);
      }
    }
    return names;
  }

  String _cleanAlbumTitle(String raw) {
    var title = raw.trim();
    title = title
        .replaceFirst(RegExp(r'^Listen to\s+', caseSensitive: false), '')
        .replaceFirst(
          RegExp(
            r'\s+-\s+(?:Single|Album|EP|Compilation)\b.*$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(RegExp(r'\s+\|\s+Spotify\s*$', caseSensitive: false), '')
        .trim();
    return title;
  }

  String? _ogDescription(String html) {
    return RegExp(
      r'property="og:description"\s+content="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html)?.group(1)?.trim();
  }

  List<_SpCandidate> _candidateReleases(Map<String, dynamic> state) {
    final disco = _findDiscography(state);
    if (disco == null) return const [];

    final out = <_SpCandidate>[];
    final seen = <String>{};

    void addRelease(Map<String, dynamic>? release) {
      if (release == null) return;
      final uri = '${release['uri'] ?? ''}';
      final albumId = _albumIdRe.firstMatch(uri)?.group(1);
      if (albumId == null || !seen.add(albumId)) return;
      final title = '${release['name'] ?? ''}'.trim();
      if (title.isEmpty) return;
      final type = '${release['type'] ?? ''}'.trim();
      final date = release['date'];
      var year = 0;
      if (date is Map) {
        year = date['year'] is int
            ? date['year'] as int
            : int.tryParse('${date['year']}') ?? 0;
      }
      out.add(
        _SpCandidate(
          albumId: albumId,
          title: title,
          type: type,
          year: year,
          coverUrl: _bestCover(release['coverArt']),
        ),
      );
    }

    final latest = disco['latest'];
    if (latest is Map) {
      addRelease(Map<String, dynamic>.from(latest));
    }

    for (final key in ['singles', 'albums', 'compilations']) {
      final bucket = disco[key];
      if (bucket is! Map) continue;
      final items = bucket['items'];
      if (items is! List || items.isEmpty) continue;
      // Spotify lists newest first — take the head of each shelf.
      final first = items.first;
      if (first is! Map) continue;
      final releases = first['releases'];
      if (releases is Map) {
        final inner = releases['items'];
        if (inner is List && inner.isNotEmpty && inner.first is Map) {
          addRelease(Map<String, dynamic>.from(inner.first as Map));
          continue;
        }
      }
      // popularReleasesAlbums-style flat item
      addRelease(Map<String, dynamic>.from(first));
    }

    return out;
  }

  Map<String, dynamic>? _findDiscography(Object? node) {
    if (node is Map) {
      final map = Map<String, dynamic>.from(node);
      if (map.containsKey('singles') && map.containsKey('albums')) {
        return map;
      }
      if (map['discography'] is Map) {
        final d = Map<String, dynamic>.from(map['discography'] as Map);
        if (d.containsKey('singles') || d.containsKey('albums')) return d;
      }
      for (final value in map.values) {
        final found = _findDiscography(value);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final item in node) {
        final found = _findDiscography(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  String? _artistNameFromState(Map<String, dynamic> state, String artistId) {
    String? found;
    void walk(Object? node) {
      if (found != null) return;
      if (node is Map) {
        final map = Map<String, dynamic>.from(node);
        final uri = '${map['uri'] ?? ''}';
        if (uri == 'spotify:artist:$artistId' || map['id'] == artistId) {
          final name = '${map['name'] ?? ''}'.trim();
          if (name.isNotEmpty) {
            found = name;
            return;
          }
        }
        for (final v in map.values) {
          walk(v);
        }
      } else if (node is List) {
        for (final item in node) {
          walk(item);
        }
      }
    }

    walk(state);
    return found ?? _ogTitleFromStateFallback(state);
  }

  String? _ogTitleFromStateFallback(Map<String, dynamic> state) {
    // SEO / entity often nests profile name near MusicGroup — skip if hard.
    return null;
  }

  Map<String, dynamic>? _decodeInitialState(String html) {
    final m = RegExp(
      r'<script id="initialState" type="text/plain">([^<]+)</script>',
    ).firstMatch(html);
    final b64 = m?.group(1)?.trim();
    if (b64 == null || b64.isEmpty) return null;
    try {
      final decoded = utf8.decode(base64.decode(b64));
      final json = jsonDecode(decoded);
      if (json is Map<String, dynamic>) return json;
      if (json is Map) return Map<String, dynamic>.from(json);
    } catch (_) {
      return null;
    }
    return null;
  }

  Map<String, dynamic>? _firstLdJson(String html) {
    final m = RegExp(
      r'<script type="application/ld\+json"[^>]*>(.*?)</script>',
      dotAll: true,
    ).firstMatch(html);
    final raw = m?.group(1)?.trim();
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        return Map<String, dynamic>.from(decoded.first as Map);
      }
    } catch (_) {}
    return null;
  }

  Future<String> _getHtml(String url) async {
    final response = await _http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': _ua,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'en-US,en;q=0.9,ru;q=0.8',
      },
    );
    if (response.statusCode == 404) {
      throw StateError('Артист не найден');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Страница недоступна (${response.statusCode})');
    }
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (body.contains('recaptcha') && !body.contains('initialState')) {
      throw StateError('Spotify заблокировал запрос (captcha)');
    }
    return body;
  }

  String _bestCover(Object? coverArt) {
    if (coverArt is! Map) return '';
    final sources = coverArt['sources'];
    if (sources is! List || sources.isEmpty) return '';
    Map? best;
    var bestH = -1;
    for (final s in sources) {
      if (s is! Map) continue;
      final h = s['height'] is int
          ? s['height'] as int
          : int.tryParse('${s['height']}') ?? 0;
      if (h >= bestH && h <= 640) {
        bestH = h;
        best = s;
      }
    }
    best ??= sources.first is Map ? sources.first as Map : null;
    return '${best?['url'] ?? ''}'.trim();
  }

  String? _ogTitle(String html) {
    final m = RegExp(
      r'property="og:title"\s+content="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    return m?.group(1)?.trim();
  }

  String _typeLabel(String type) {
    switch (type.trim().toUpperCase()) {
      case 'SINGLE':
        return 'Сингл';
      case 'EP':
        return 'EP';
      case 'COMPILATION':
        return 'Сборник';
      default:
        return 'Альбом';
    }
  }

  int _yearMs(int year) {
    if (year <= 0) return 0;
    return DateTime.utc(year).millisecondsSinceEpoch;
  }

  String _yearLabel(int year) => year > 0 ? '$year' : '';

  String _dateLabel(DateTime local) {
    const months = <String>[
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    return '${local.day} ${months[local.month - 1]} ${local.year} г.';
  }

  void close() => _http.close();
}

class _SpCandidate {
  const _SpCandidate({
    required this.albumId,
    required this.title,
    required this.type,
    required this.year,
    required this.coverUrl,
  });

  final String albumId;
  final String title;
  final String type;
  final int year;
  final String coverUrl;
}

class _SpRelease {
  const _SpRelease({
    required this.albumId,
    required this.title,
    required this.type,
    required this.year,
    required this.coverUrl,
    required this.artists,
    required this.releaseDateMs,
    required this.dateLabel,
  });

  final String albumId;
  final String title;
  final String type;
  final int year;
  final String coverUrl;
  final List<String> artists;
  final int releaseDateMs;
  final String dateLabel;
}

class _AlbumDetails {
  const _AlbumDetails({
    required this.title,
    required this.artists,
    required this.coverUrl,
    required this.releaseDateMs,
    required this.dateLabel,
  });

  final String title;
  final List<String> artists;
  final String coverUrl;
  final int releaseDateMs;
  final String dateLabel;
}
