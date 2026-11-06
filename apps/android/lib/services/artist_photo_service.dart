import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/track_key.dart';

class ArtistPhotoProgress {
  const ArtistPhotoProgress({
    required this.done,
    required this.total,
    this.updated = 0,
    this.current,
  });

  final int done;
  final int total;
  final int updated;
  final String? current;

  double get ratio => total == 0 ? 0 : done / total;
}

/// Resolves artist portraits without API keys:
/// Yandex Music → Genius → Deezer → Google Images.
class ArtistPhotoService {
  static const _ua = 'FreedomMusic/1.0 (local music player; artist photos)';
  static const _uaBrowser =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  HttpClient? _client;

  HttpClient get _http {
    return _client ??= HttpClient()..userAgent = _ua;
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }

  /// Download portrait bytes for [artistName], or null if not found.
  Future<Uint8List?> fetchPhotoBytes(String artistName) async {
    final name = artistName.trim();
    if (name.isEmpty || name.toLowerCase() == 'unknown') return null;

    final lookups = <({
      Future<String?> Function(String) find,
      String? referer,
    })>[
      (find: _yandexMusicImageUrl, referer: null),
      (find: _geniusImageUrl, referer: null),
      (find: _deezerImageUrl, referer: null),
      (find: _googleImagesUrl, referer: 'https://www.google.com/'),
    ];
    for (final lookup in lookups) {
      final url = await lookup.find(name);
      if (url == null || url.isEmpty) continue;
      final bytes = await _download(url, referer: lookup.referer);
      if (bytes != null && bytes.isNotEmpty) return bytes;
    }
    return null;
  }

  /// Unofficial Yandex Music search — cover.uri uses `%%` size placeholder.
  Future<String?> _yandexMusicImageUrl(String artist) async {
    final data = await _getJson(
      Uri.https('api.music.yandex.net', '/search', {
        'text': artist,
        'type': 'artist',
        'page': '0',
        'nocorrect': 'false',
      }),
      delay: const Duration(milliseconds: 250),
      userAgent: _uaBrowser,
    );
    final result = data?['result'];
    if (result is! Map) return null;
    final artists = result['artists'];
    if (artists is! Map) return null;
    final list = artists['results'];
    if (list is! List || list.isEmpty) return null;

    for (final raw in list) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final found = '${map['name'] ?? ''}';
      if (!_artistClose(artist, found)) continue;
      final cover = map['cover'];
      if (cover is! Map) continue;
      var uri = '${cover['uri'] ?? ''}'.trim();
      if (uri.isEmpty) continue;
      if (uri.startsWith('//')) uri = 'https:$uri';
      if (!uri.startsWith('http')) uri = 'https://$uri';
      return uri.replaceAll('%%', '400x400');
    }
    return null;
  }

  Future<String?> _geniusImageUrl(String artist) async {
    final data = await _getJson(
      Uri.https('genius.com', '/api/search/multi', {
        'q': artist,
        'per_page': '5',
      }),
      delay: const Duration(milliseconds: 200),
    );
    final sections = data?['response'];
    if (sections is! Map) return null;
    final list = sections['sections'];
    if (list is! List) return null;

    String? fromArtistSection;
    String? fromSongPrimary;

    for (final raw in list) {
      if (raw is! Map) continue;
      final section = Map<String, dynamic>.from(raw);
      final type = '${section['type'] ?? ''}';
      final hits = section['hits'];
      if (hits is! List) continue;

      for (final hitRaw in hits) {
        if (hitRaw is! Map) continue;
        final hit = Map<String, dynamic>.from(hitRaw);
        final result = hit['result'];
        if (result is! Map) continue;
        final map = Map<String, dynamic>.from(result);

        if (type == 'artist' || type == 'top_hit') {
          final found = '${map['name'] ?? ''}';
          final image = '${map['image_url'] ?? ''}';
          if (image.isNotEmpty && _artistClose(artist, found)) {
            if (type == 'artist') return image;
            fromArtistSection ??= image;
          }
        }

        if (type == 'song' || type == 'top_hit') {
          final primary = map['primary_artist'];
          if (primary is Map) {
            final found = '${primary['name'] ?? ''}';
            final image = '${primary['image_url'] ?? ''}';
            if (image.isNotEmpty && _artistClose(artist, found)) {
              fromSongPrimary ??= image;
            }
          }
        }
      }
    }

    return fromArtistSection ?? fromSongPrimary;
  }

  Future<String?> _deezerImageUrl(String artist) async {
    final data = await _getJson(
      Uri.https('api.deezer.com', '/search/artist', {
        'q': artist,
        'limit': '8',
      }),
      delay: const Duration(milliseconds: 200),
    );
    final list = data?['data'];
    if (list is! List || list.isEmpty) return null;

    for (final raw in list) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final found = '${map['name'] ?? ''}';
      if (!_artistClose(artist, found)) continue;
      for (final key in [
        'picture_xl',
        'picture_big',
        'picture_medium',
        'picture',
      ]) {
        final url = '${map[key] ?? ''}';
        if (url.isNotEmpty && !url.contains('artist-default')) return url;
      }
    }
    return null;
  }

  /// Unofficial Google Images HTML scrape — first usable result URL.
  Future<String?> _googleImagesUrl(String artist) async {
    final html = await _getHtml(
      Uri.https('www.google.com', '/search', {
        'q': artist,
        'tbm': 'isch',
        'hl': 'ru',
        'gl': 'ru',
        'safe': 'active',
        'ijn': '0',
      }),
      delay: const Duration(milliseconds: 350),
      userAgent: _uaBrowser,
    );
    if (html == null || html.isEmpty) return null;

    // Full-size originals embedded as "ou":"https://..."
    for (final m in RegExp(r'"ou":"(https?:\\/\\/[^"]+)"').allMatches(html)) {
      final url = _decodeGoogleUrl(m.group(1)!);
      if (_usableImageUrl(url)) return url;
    }

    // AF_initDataCallback payloads: ["https://…", width, height]
    var data = html.replaceAll(
      RegExp(
        r'\["https://encrypted-tbn0\.gstatic\.com/images\?[^"]+",\d+,\d+\]',
      ),
      '',
    );
    for (final m in RegExp(
      r'(?:,|\[)"(https?://[^"]+)",\d{2,5},\d{2,5}\]',
    ).allMatches(data)) {
      final url = _decodeGoogleUrl(m.group(1)!);
      if (_usableImageUrl(url)) return url;
    }

    // Last resort: first Google thumbnail.
    final thumb = RegExp(
      r'(https://encrypted-tbn0\.gstatic\.com/images\?[^"\\]+)',
    ).firstMatch(html);
    if (thumb != null) {
      final url = _decodeGoogleUrl(thumb.group(1)!);
      if (url.isNotEmpty) return url;
    }
    return null;
  }

  String _decodeGoogleUrl(String raw) {
    var s = raw.replaceAll(r'\/', '/');
    try {
      final decoded = jsonDecode('"$s"');
      if (decoded is String && decoded.isNotEmpty) return decoded;
    } catch (_) {}
    return s
        .replaceAll(r'\u003d', '=')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\u002F', '/');
  }

  bool _usableImageUrl(String url) {
    if (url.isEmpty) return false;
    final u = url.toLowerCase();
    if (!(u.startsWith('http://') || u.startsWith('https://'))) return false;
    if (u.contains('gstatic.com/images/branding')) return false;
    if (u.contains('google.com/logos')) return false;
    if (u.contains('favicon')) return false;
    return true;
  }

  Future<Uint8List?> _download(String url, {String? referer}) async {
    try {
      final uri = Uri.parse(url);
      final req = await _http.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, _uaBrowser);
      if (referer != null) {
        req.headers.set(HttpHeaders.refererHeader, referer);
      }
      final res = await req.close().timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
        if (builder.length > 8 << 20) {
          await res.drain<void>();
          return null;
        }
      }
      final bytes = builder.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getJson(
    Uri uri, {
    Duration delay = const Duration(milliseconds: 250),
    String? userAgent,
  }) async {
    await Future<void>.delayed(delay);
    try {
      final req = await _http.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent ?? _ua);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getHtml(
    Uri uri, {
    Duration delay = const Duration(milliseconds: 250),
    String? userAgent,
  }) async {
    await Future<void>.delayed(delay);
    try {
      final req = await _http.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent ?? _uaBrowser);
      req.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      req.headers.set('Accept-Language', 'ru-RU,ru;q=0.9,en;q=0.8');
      final res = await req.close().timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      return await res.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    }
  }

  String _norm(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _artistClose(String wanted, String found) {
    final nw = _norm(splitArtists(wanted).isEmpty
        ? wanted
        : splitArtists(wanted).first);
    final nf = _norm(found);
    if (nw.isEmpty || nf.isEmpty) return false;
    if (nw == nf || nw.contains(nf) || nf.contains(nw)) return true;
    final wa = nw.replaceAll(RegExp(r'\W'), '');
    final fa = nf.replaceAll(RegExp(r'\W'), '');
    return wa.length >= 3 && (wa.contains(fa) || fa.contains(wa));
  }
}
