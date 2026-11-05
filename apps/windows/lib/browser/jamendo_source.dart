import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// Jamendo API v3 — `tracks/?search=`, стрим `audio` / скачивание `audiodownload`.
class JamendoSource implements BrowserSource, BrowserFeaturedSource {
  JamendoSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://www.jamendo.com';
  /// Публичный client_id из open-source примеров Jamendo.
  static const _clientId = '33aa6c40';

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'jamendo';

  @override
  String get name => 'Jamendo';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> featured({int limit = 3}) async {
    final take = limit.clamp(1, 10);
    final uri = Uri.parse('https://api.jamendo.com/v3.0/tracks/').replace(
      queryParameters: {
        'client_id': _clientId,
        'format': 'json',
        'limit': '$take',
        'order': 'popularity_total',
        'audioformat': 'mp32',
        'audiodlformat': 'mp32',
      },
    );
    final body = await _getJson(uri);
    final results = body['results'];
    if (results is! List) return const [];
    return _mapResults(results, take);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final take = limit.clamp(1, 50);
    final uri = Uri.parse('https://api.jamendo.com/v3.0/tracks/').replace(
      queryParameters: {
        'client_id': _clientId,
        'format': 'json',
        'limit': '$take',
        'namesearch': q,
        'search': q,
        'audioformat': 'mp32',
        'audiodlformat': 'mp32',
        'include': 'licenses',
      },
    );
    final body = await _getJson(uri);
    final headers = body['headers'];
    if (headers is Map && '${headers['status']}' != 'success') {
      final msg = '${headers['error_message'] ?? headers['status']}';
      throw StateError('Jamendo: $msg');
    }
    final results = body['results'];
    if (results is! List || results.isEmpty) {
      // Иногда `search` пустой при лимите — пробуем только namesearch.
      final fallbackUri = Uri.parse('https://api.jamendo.com/v3.0/tracks/').replace(
        queryParameters: {
          'client_id': _clientId,
          'format': 'json',
          'limit': '$take',
          'namesearch': q,
          'audioformat': 'mp32',
          'audiodlformat': 'mp32',
        },
      );
      final fallback = await _getJson(fallbackUri);
      final alt = fallback['results'];
      if (alt is! List) return const [];
      return _mapResults(alt, take);
    }
    return _mapResults(results, take);
  }

  List<BrowserHit> _mapResults(List<dynamic> results, int take) {
    final hits = <BrowserHit>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final map = raw.map((k, v) => MapEntry('$k', v));
      final id = '${map['id'] ?? ''}'.trim();
      final title = _clean('${map['name'] ?? ''}');
      if (id.isEmpty || title.isEmpty) continue;
      final artist = _clean('${map['artist_name'] ?? ''}');
      final audio = '${map['audio'] ?? ''}'.trim();
      final download = '${map['audiodownload'] ?? ''}'.trim();
      final allowed = map['audiodownload_allowed'] == true;
      final file = (allowed && download.isNotEmpty)
          ? download
          : (audio.isNotEmpty ? audio : download);
      if (file.isEmpty) continue;
      final dur = map['duration'];
      Duration? duration;
      if (dur is num && dur > 0) {
        duration = Duration(seconds: dur.round());
      }
      final license =
          _clean('${map['license_ccurl'] ?? map['license_cc'] ?? ''}');
      final album = _clean('${map['album_name'] ?? ''}');
      hits.add(
        BrowserHit(
          sourceId: this.id,
          id: id,
          title: title,
          artist: artist.isEmpty ? 'Unknown' : artist,
          subtitle: album.isEmpty ? null : album,
          duration: duration,
          license: license.isEmpty ? null : license,
          downloadUrl: file,
        ),
      );
      if (hits.length >= take) break;
    }
    return hits;
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (cached.startsWith('http')) return Uri.parse(cached);
    throw StateError('Jamendo: нет ссылки на файл');
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.refererHeader, referer);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Jamendo HTTP ${response.statusCode}', uri: uri);
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Jamendo: неожиданный JSON');
    }
    return decoded;
  }

  static final _wsRe = RegExp(r'\s+');

  static String _clean(String raw) => raw.replaceAll(_wsRe, ' ').trim();
}
