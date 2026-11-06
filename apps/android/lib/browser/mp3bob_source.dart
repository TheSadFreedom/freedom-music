import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// mp3bob.ru — поиск DLE `?do=search`, файл из `data-url-hq` / `data-url`.
class Mp3bobSource implements BrowserSource {
  Mp3bobSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://mp3bob.ru';

  static final _itemSplitRe = RegExp(
    r'<div\s+class="song-item"',
    caseSensitive: false,
  );
  static final _playBtnRe = RegExp(
    r'<div([^>]*class="[^"]*play-btn[^"]*"[^>]*)>',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'class="[^"]*song_nazv[^"]*"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _artistRe = RegExp(
    r'class="[^"]*song_artist[^"]*"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _pageRe = RegExp(
    r'href="(https?://[^"]*/news/\d+-[^"]+|(/news/\d+-[^"]+))"',
    caseSensitive: false,
  );
  static final _newsidRe = RegExp(
    r'data-newsid="(\d+)"',
    caseSensitive: false,
  );
  static final _idFromPathRe = RegExp(r'/news/(\d+)-', caseSensitive: false);
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'mp3bob';

  @override
  String get name => 'mp3bob';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  /// Плейлист «Топ» — https://mp3bob.ru/samye-populyarnye-pesni/
  Future<List<BrowserHit>> popular({int limit = 100}) async {
    final take = limit.clamp(1, 200);
    final html =
        await _getText(Uri.parse('$_origin/samye-populyarnye-pesni/'));
    final items = _parseItems(html);
    if (items.isEmpty) return const [];
    return [
      for (final item in items.take(take)) _toHit(item),
    ];
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.parse('$_origin/').replace(
      queryParameters: {
        'do': 'search',
        'subaction': 'search',
        'story': q,
      },
    );
    final html = await _getText(uri);
    final items = _parseItems(html);
    if (items.isEmpty) return const [];
    final take = limit.clamp(1, 50);
    return [
      for (final item in items.take(take)) _toHit(item),
    ];
  }

  BrowserHit _toHit(_TrackItem item) {
    return BrowserHit(
      sourceId: id,
      id: item.id,
      title: item.title,
      artist: item.artist.isEmpty ? 'Unknown' : item.artist,
      subtitle: null,
      duration: null,
      license: null,
      downloadUrl: item.fileUrl,
    );
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (_looksLikeFileUrl(cached)) {
      return Uri.parse(_absUrl(cached));
    }
    if (hit.id.isEmpty) {
      throw StateError('mp3bob: нет id трека');
    }
    final page = Uri.parse('$_origin/news/${hit.id}');
    final html = await _getText(page);
    final items = _parseItems(html);
    for (final item in items) {
      if (item.id == hit.id && item.fileUrl.isNotEmpty) {
        return Uri.parse(item.fileUrl);
      }
    }
    if (items.isNotEmpty && items.first.fileUrl.isNotEmpty) {
      return Uri.parse(items.first.fileUrl);
    }
    throw StateError('mp3bob: нет ссылки на файл');
  }

  Future<String> _getText(Uri uri) async {
    final request = await _client.getUrl(uri);
    _applyHeaders(request);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'mp3bob HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    return text;
  }

  void _applyHeaders(HttpClientRequest request) {
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,application/json,*/*',
    );
    request.headers.set(HttpHeaders.refererHeader, referer);
    request.headers.set('Origin', _origin);
  }

  static List<_TrackItem> _parseItems(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    final parts = html.split(_itemSplitRe);
    for (var i = 1; i < parts.length; i++) {
      final body = parts[i];
      final playTag = _playBtnRe.firstMatch(body)?.group(1) ?? '';
      final playAttrs = <String, String>{};
      for (final a in _attrRe.allMatches(playTag)) {
        playAttrs[a.group(1)!.toLowerCase()] =
            (a.group(3) ?? a.group(4) ?? '').trim();
      }
      final hq = (playAttrs['data-url-hq'] ?? '').trim();
      final sample = (playAttrs['data-url'] ?? '').trim();
      final fileUrl = _absUrl(hq.isNotEmpty ? hq : sample);
      if (fileUrl.isEmpty) continue;

      final title = _clean(_titleRe.firstMatch(body)?.group(1) ?? '');
      if (title.isEmpty) continue;
      final artist = _clean(_artistRe.firstMatch(body)?.group(1) ?? '');

      final newsid = (_newsidRe.firstMatch(body)?.group(1) ?? '').trim();
      final pageMatch = _pageRe.firstMatch(body);
      final pagePath =
          (pageMatch?.group(1) ?? pageMatch?.group(2) ?? '').trim();
      final idFromPath = _idFromPathRe.firstMatch(pagePath)?.group(1) ?? '';
      final id = newsid.isNotEmpty
          ? newsid
          : (idFromPath.isNotEmpty ? idFromPath : fileUrl);
      if (!seen.add(id)) continue;

      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          fileUrl: fileUrl,
        ),
      );
    }
    return out;
  }

  static bool _looksLikeFileUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp3') || lower.contains('/download/');
  }

  static String _absUrl(String raw) {
    final text = raw.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
    if (text.isEmpty) return '';
    if (text.startsWith('http://') || text.startsWith('https://')) return text;
    if (text.startsWith('//')) return 'https:$text';
    if (text.startsWith('/')) return '$_origin$text';
    return '$_origin/$text';
  }

  static String _clean(String raw) {
    var text = raw
        .replaceAll(_tagRe, ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    return text.replaceAll(_wsRe, ' ').trim();
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
