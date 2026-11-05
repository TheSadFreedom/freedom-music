import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// one.lalamus.one — каталог `/newhit`+`/besthit`, файл из `data-id` (/media/music/...).
///
/// Серверный `/search/{q}/` сейчас отдаёт пустую 404-страницу, поэтому поиск
/// фильтрует локально по свежим/популярным спискам.
class LalamusSource implements BrowserSource, BrowserFeaturedSource {
  LalamusSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://one.lalamus.one';

  static final _itemSplitRe = RegExp(
    r'<li\s+class="sarki-liste"',
    caseSensitive: false,
  );
  static final _labelRe = RegExp(
    r'class="artist_name"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _dataIdRe = RegExp(
    r'data-id="([^"]+)"',
    caseSensitive: false,
  );
  static final _pageRe = RegExp(
    r'href="(/superhit/\d+)"',
    caseSensitive: false,
  );
  static final _idFromPathRe = RegExp(r'/superhit/(\d+)');
  static final _idFromMediaRe = RegExp(r'/media/music/\d+/(\d+)_');
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'lalamus';

  @override
  String get name => 'Lalamus';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> featured({int limit = 3}) async {
    final take = limit.clamp(1, 10);
    final pages = await Future.wait([
      _getTextSoft(Uri.parse('$_origin/newhit')),
      _getTextSoft(Uri.parse('$_origin/besthit')),
    ]);
    final merged = <_TrackItem>[];
    final seen = <String>{};
    for (final html in pages) {
      for (final item in _parseItems(html)) {
        if (seen.add(item.id)) merged.add(item);
      }
    }
    return _toHits(merged, take);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    // Сначала пробуем официальный search URL (на случай если починят).
    final slug = _slugify(q);
    var items = _parseItems(
      await _getTextSoft(Uri.parse('$_origin/search/$slug/')),
    );
    if (items.isEmpty) {
      final pages = await Future.wait([
        _getText(Uri.parse('$_origin/newhit')),
        _getText(Uri.parse('$_origin/besthit')),
        _getTextSoft(Uri.parse('$_origin/')),
      ]);
      final merged = <_TrackItem>[];
      final seen = <String>{};
      for (final html in pages) {
        for (final item in _parseItems(html)) {
          if (seen.add(item.id)) merged.add(item);
        }
      }
      final needle = q.toLowerCase();
      items = [
        for (final item in merged)
          if ('${item.artist} ${item.title}'.toLowerCase().contains(needle))
            item,
      ];
    }

    return _toHits(items, limit.clamp(1, 50));
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
    if (_looksLikeFileUrl(cached)) {
      return Uri.parse(_absUrl(cached));
    }
    if (hit.id.isEmpty) {
      throw StateError('Lalamus: нет id трека');
    }
    final page = Uri.parse('$_origin/superhit/${hit.id}');
    final html = await _getText(page);
    final file = (_dataIdRe.firstMatch(html)?.group(1) ?? '').trim();
    if (file.isEmpty) {
      throw StateError('Lalamus: нет data-id на странице');
    }
    return Uri.parse(_absUrl(file));
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
        'Lalamus HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    return text;
  }

  /// Не бросает на 404/пустых страницах — для битого `/search/` и опционального `/`.
  Future<String> _getTextSoft(Uri uri) async {
    try {
      final request = await _client.getUrl(uri);
      _applyHeaders(request);
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return '';
      }
      return text;
    } catch (_) {
      return '';
    }
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
      final file = _absUrl((_dataIdRe.firstMatch(body)?.group(1) ?? '').trim());
      if (file.isEmpty || !_looksLikeFileUrl(file)) continue;

      final label = _clean(_labelRe.firstMatch(body)?.group(1) ?? '');
      if (label.isEmpty) continue;
      final partsLabel = _splitArtistTitle(label);

      final pagePath = (_pageRe.firstMatch(body)?.group(1) ?? '').trim();
      final id = (_idFromPathRe.firstMatch(pagePath)?.group(1) ??
              _idFromMediaRe.firstMatch(file)?.group(1) ??
              '')
          .trim();
      final key = id.isNotEmpty ? id : file;
      if (!seen.add(key)) continue;

      out.add(
        _TrackItem(
          id: key,
          artist: partsLabel.$1,
          title: partsLabel.$2,
          fileUrl: file,
        ),
      );
    }
    return out;
  }

  static String _slugify(String text) {
    return text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-');
  }

  static (String, String) _splitArtistTitle(String label) {
    final idx = label.indexOf(' - ');
    if (idx <= 0) return ('Unknown', label);
    final artist = label.substring(0, idx).trim();
    final title = label.substring(idx + 3).trim();
    if (artist.isEmpty || title.isEmpty) return ('Unknown', label);
    return (artist, title);
  }

  static bool _looksLikeFileUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp3') || lower.contains('/media/music/');
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
