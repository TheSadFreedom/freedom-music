import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// muzok.net — карточки `song-item` + `mp3source`, поиск `/search/{q}`.
class MuzokSource implements BrowserSource, BrowserFeaturedSource {
  MuzokSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://muzok.net';

  static final _itemRe = RegExp(
    r'<div class="song-item">([\s\S]*?)</div>\s*</div>',
    caseSensitive: false,
  );
  static final _mp3Re = RegExp(
    r'mp3source="([^"]+)"',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'<span>([^<]+)</span>',
    caseSensitive: false,
  );
  static final _hrefRe = RegExp(
    r'href="(https?://[^"]+/tr/\d+)"',
    caseSensitive: false,
  );
  static final _idRe = RegExp(r'/tr/(\d+)');
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'muzok';

  @override
  String get name => 'Muzok';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> featured({int limit = 3}) async {
    final take = limit.clamp(1, 10);
    final html = await _getText(Uri.parse('$_origin/'));
    return _toHits(_parseItems(html), take);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final take = limit.clamp(1, 50);
    final slug = q.replaceAll(RegExp(r'\s+'), '-');
    final uri = Uri.parse(
      '$_origin/search/${Uri.encodeComponent(slug)}',
    );
    var html = await _getText(uri);
    var items = _parseItems(html);
    // Поиск на сайте часто пустой — подстраховываемся главной с фильтром.
    if (items.isEmpty) {
      html = await _getText(Uri.parse('$_origin/'));
      items = _rankByQuery(_parseItems(html), q);
    }
    return _toHits(items, take);
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
    throw StateError('Muzok: нет ссылки на файл');
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
      throw HttpException('Muzok HTTP ${response.statusCode}', uri: uri);
    }
    return text;
  }

  static List<_TrackItem> _parseItems(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _itemRe.allMatches(html)) {
      final block = m.group(0) ?? '';
      final mp3Raw = (_mp3Re.firstMatch(block)?.group(1) ?? '').trim();
      final fileUrl = mp3Raw.replaceAll(r'\', '').trim();
      if (!fileUrl.startsWith('http')) continue;
      final rawTitle = _clean(_titleRe.firstMatch(block)?.group(1) ?? '');
      if (rawTitle.isEmpty) continue;
      String artist;
      String title;
      final split = rawTitle.indexOf(' - ');
      if (split > 0) {
        artist = rawTitle.substring(0, split).trim();
        title = rawTitle.substring(split + 3).trim();
      } else {
        artist = '';
        title = rawTitle;
      }
      final href = (_hrefRe.firstMatch(block)?.group(1) ?? '').trim();
      final id = (_idRe.firstMatch(href)?.group(1) ?? fileUrl).trim();
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

  static List<_TrackItem> _rankByQuery(List<_TrackItem> items, String query) {
    final tokens = [
      for (final t in query.toLowerCase().split(RegExp(r'\s+')))
        if (t.length >= 2) t,
    ];
    if (tokens.isEmpty) return items;
    final scored = <({int score, _TrackItem item})>[];
    for (final item in items) {
      final hay = '${item.artist} ${item.title}'.toLowerCase();
      var score = 0;
      for (final t in tokens) {
        if (hay.contains(t)) score += 1;
      }
      if (score > 0) scored.add((score: score, item: item));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return [for (final e in scored) e.item];
  }

  static String _clean(String raw) {
    return raw
        .replaceAll(_tagRe, ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
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
