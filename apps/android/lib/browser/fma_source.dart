import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// Free Music Archive — поиск `?quicksearch=`, файл из `playbackUrl` / `downloadUrl`.
class FmaSource implements BrowserSource, BrowserFeaturedSource {
  FmaSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://freemusicarchive.org';

  static final _trackInfoRe = RegExp(
    r"data-track-info='([^']*)'",
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'fma';

  @override
  String get name => 'FMA';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> featured({int limit = 3}) async {
    final take = limit.clamp(1, 10);
    // Главная / свежие треки на FMA.
    final html = await _getText(Uri.parse('$_origin/'));
    var items = _parseItems(html);
    if (items.isEmpty) {
      final uri = Uri.parse('$_origin/search/').replace(
        queryParameters: {
          'quicksearch': 'piano',
          'pageSize': '$take',
          'page': '1',
        },
      );
      items = _parseItems(await _getText(uri));
    }
    return _toHits(items, take);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final take = limit.clamp(1, 50);
    final uri = Uri.parse('$_origin/search/').replace(
      queryParameters: {
        'quicksearch': q,
        'pageSize': '$take',
        'page': '1',
      },
    );
    final html = await _getText(uri);
    return _toHits(_parseItems(html), take);
  }

  List<BrowserHit> _toHits(List<_TrackItem> items, int take) {
    if (items.isEmpty) return const [];
    return [
      for (final item in items.take(take))
        BrowserHit(
          sourceId: id,
          id: item.id,
          title: item.title,
          artist: item.artist.isEmpty ? 'Unknown' : item.artist,
          subtitle: null,
          duration: null,
          license: null,
          downloadUrl: item.fileUrl,
        ),
    ];
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (cached.startsWith('http')) return Uri.parse(cached);
    throw StateError('FMA: нет ссылки на файл');
  }

  Future<String> _getText(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,*/*',
    );
    request.headers.set(HttpHeaders.refererHeader, referer);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('FMA HTTP ${response.statusCode}', uri: uri);
    }
    return text;
  }

  static List<_TrackItem> _parseItems(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _trackInfoRe.allMatches(html)) {
      final raw = _unescape(m.group(1) ?? '');
      Map<String, dynamic>? map;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) map = decoded;
      } catch (_) {
        continue;
      }
      if (map == null) continue;
      final id = '${map['id'] ?? map['handle'] ?? ''}'.trim();
      final title = _clean('${map['title'] ?? ''}');
      final artist = _clean('${map['artistName'] ?? ''}');
      if (id.isEmpty || title.isEmpty) continue;
      final playback = '${map['playbackUrl'] ?? ''}'.trim();
      final download = '${map['downloadUrl'] ?? ''}'.trim();
      final file = playback.isNotEmpty ? playback : download;
      if (!file.startsWith('http')) continue;
      if (!seen.add(id)) continue;
      out.add(
        _TrackItem(id: id, title: title, artist: artist, fileUrl: file),
      );
    }
    return out;
  }

  static String _unescape(String raw) => raw
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  static String _clean(String raw) {
    return raw
        .replaceAll(_tagRe, ' ')
        .replaceAll(_wsRe, ' ')
        .trim();
  }
}

class _TrackItem {
  const _TrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.fileUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String fileUrl;
}
