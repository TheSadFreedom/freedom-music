import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// gettune.pro — поиск `/search?q=` (DNS у домена часто мёртвый).
class GettuneSource implements BrowserSource {
  GettuneSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://gettune.pro';

  static final _dataUrlRe = RegExp(
    r'''data-(?:url|mp3|src|file)=("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'''(?:data-title|data-name)=("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _artistRe = RegExp(
    r'''(?:data-artist|data-author)=("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _itemRe = RegExp(
    r'''<[^>]+(?:data-url|data-mp3)=("https?://[^"]*"|'https?://[^']*')[^>]*>''',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'gettune';

  @override
  String get name => 'GetTune';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final take = limit.clamp(1, 50);
    final paths = <Uri>[
      Uri.parse('$_origin/search').replace(queryParameters: {'q': q}),
      Uri.parse('$_origin/').replace(queryParameters: {'q': q}),
    ];
    Object? lastError;
    for (final uri in paths) {
      try {
        final html = await _getText(uri);
        final items = _parseItems(html);
        if (items.isEmpty) continue;
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
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) throw lastError;
    return const [];
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (cached.startsWith('http')) return Uri.parse(cached);
    throw StateError('GetTune: нет ссылки на файл');
  }

  Future<String> _getText(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,*/*',
    );
    request.headers.set(HttpHeaders.refererHeader, referer);
    final response = await request.close().timeout(const Duration(seconds: 25));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('GetTune HTTP ${response.statusCode}', uri: uri);
    }
    return text;
  }

  static List<_TrackItem> _parseItems(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _itemRe.allMatches(html)) {
      final tag = m.group(0) ?? '';
      final fileUrl = _attr(_dataUrlRe.firstMatch(tag)).trim();
      if (!fileUrl.startsWith('http')) continue;
      final title = _clean(_attr(_titleRe.firstMatch(tag)));
      final artist = _clean(_attr(_artistRe.firstMatch(tag)));
      if (title.isEmpty) continue;
      if (!seen.add(fileUrl)) continue;
      out.add(
        _TrackItem(
          id: fileUrl,
          title: title,
          artist: artist,
          fileUrl: fileUrl,
        ),
      );
    }
    return out;
  }

  static String _attr(RegExpMatch? m) =>
      (m?.group(2) ?? m?.group(3) ?? '').trim();

  static String _clean(String raw) {
    return raw.replaceAll(_tagRe, ' ').replaceAll(_wsRe, ' ').trim();
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
