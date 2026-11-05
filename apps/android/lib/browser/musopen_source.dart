import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// MusOpen — royalty-free / public domain записи (в основном классика).
/// API: `https://musopen.org/api/v2/recordings/?search=`
class MusOpenSource implements BrowserSource, BrowserFeaturedSource {
  MusOpenSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _searchUrl = 'https://musopen.org/api/v2/recordings/';
  static const _detailUrl = 'https://api.musopen.org/v2/recordings/';

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'musopen';

  @override
  String get name => 'MusOpen';

  @override
  String get referer => 'https://musopen.org/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> featured({int limit = 3}) async {
    final take = limit.clamp(1, 10);
    final uri = Uri.parse(_searchUrl).replace(
      queryParameters: {'page_size': '$take'},
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
    final pageSize = limit.clamp(1, 50);
    final uri = Uri.parse(_searchUrl).replace(
      queryParameters: {
        'search': q,
        'page_size': '$pageSize',
      },
    );
    final body = await _getJson(uri);
    final results = body['results'];
    if (results is! List) return const [];
    return _mapResults(results, pageSize);
  }

  List<BrowserHit> _mapResults(List<dynamic> results, int take) {
    final hits = <BrowserHit>[];
    for (final raw in results) {
      final map = _asMap(raw);
      if (map == null) continue;
      final id = '${map['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      final title = _clean('${map['title'] ?? ''}');
      if (title.isEmpty) continue;
      final piece = _asMap(map['piece']);
      final composer = _asMap(piece?['composer']);
      final artist = composer == null
          ? ''
          : _clean(
              '${composer['first_name'] ?? ''} ${composer['last_name'] ?? ''}',
            );
      final performer = _asMap(map['performer']);
      final subtitle = performer == null
          ? null
          : _clean('${performer['name'] ?? ''}');
      final seconds = map['length'];
      Duration? duration;
      if (seconds is num && seconds > 0) {
        duration = Duration(milliseconds: (seconds * 1000).round());
      }
      final fileUrl = '${map['fileurl'] ?? ''}'.trim();
      final hq = '${map['hq_fileurl'] ?? ''}'.trim();
      final download = fileUrl.isNotEmpty ? fileUrl : hq;
      hits.add(
        BrowserHit(
          sourceId: this.id,
          id: id,
          title: title,
          artist: artist.isEmpty ? 'Unknown' : artist,
          subtitle: (subtitle == null || subtitle.isEmpty) ? null : subtitle,
          duration: duration,
          license: map['license']?.toString(),
          downloadUrl: download.isEmpty ? null : download,
        ),
      );
      if (hits.length >= take) break;
    }
    return hits;
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim();
    if (cached != null && cached.isNotEmpty) {
      return Uri.parse(cached);
    }
    final uri = Uri.parse('$_detailUrl${hit.id}/');
    final body = await _getJson(uri);
    final fileUrl = '${body['fileurl'] ?? ''}'.trim();
    final hq = '${body['hq_fileurl'] ?? ''}'.trim();
    final pick = fileUrl.isNotEmpty ? fileUrl : hq;
    if (pick.isEmpty) {
      throw StateError(
        'MusOpen: нет ссылки на файл (лимит загрузок или нужна подписка)',
      );
    }
    return Uri.parse(pick);
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    final response = await request.close().timeout(
      const Duration(seconds: 30),
    );
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'MusOpen HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final decoded = jsonDecode(text);
    final map = _asMap(decoded);
    if (map == null) {
      throw StateError('MusOpen: неожиданный JSON');
    }
    return map;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String _clean(String raw) {
    return raw
        .replaceAll('\u0000', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
