import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// Tribe of Noise Pro Search — `/api/search?q=`, прямые MP3 на FMA CDN.
class TribeSource implements BrowserSource, BrowserFeaturedSource {
  TribeSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://prosearch.tribeofnoise.com';

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'tribe';

  @override
  String get name => 'Tribe of Noise';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> featured({int limit = 3}) async {
    // API требует q — берём широкий запрос как «чарт».
    return search('music', limit: limit.clamp(1, 10));
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final take = limit.clamp(1, 50);
    final uri = Uri.parse('$_origin/api/search').replace(
      queryParameters: {'q': q},
    );
    final list = await _getJsonList(uri);
    final hits = <BrowserHit>[];
    final seen = <String>{};
    for (final raw in list) {
      if (raw is! Map) continue;
      final map = raw.map((k, v) => MapEntry('$k', v));
      final title = _clean('${map['title'] ?? ''}');
      final artist = _clean('${map['artist'] ?? ''}');
      final file = '${map['url'] ?? ''}'.trim();
      if (title.isEmpty || !file.startsWith('http')) continue;
      final id = file;
      if (!seen.add(id)) continue;
      hits.add(
        BrowserHit(
          sourceId: this.id,
          id: id,
          title: title,
          artist: artist.isEmpty ? 'Unknown' : artist,
          subtitle: null,
          duration: null,
          license: null,
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
    throw StateError('Tribe of Noise: нет ссылки на файл');
  }

  Future<List<dynamic>> _getJsonList(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json,*/*');
    request.headers.set(HttpHeaders.refererHeader, referer);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Tribe of Noise HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final decoded = jsonDecode(text);
    if (decoded is! List) return const [];
    return decoded;
  }

  static final _wsRe = RegExp(r'\s+');

  static String _clean(String raw) => raw.replaceAll(_wsRe, ' ').trim();
}
