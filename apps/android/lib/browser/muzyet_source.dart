import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// thirteen.muzyet.com — каталог `/newmusic`+`/hitmusic`, файл `data-id` (cdn.muzyet.com).
///
/// Серверный `/search/{q}/` сейчас 404, поэтому поиск фильтрует локально.
/// Ссылки `/music/...` часто тоже 404 — качаем напрямую с CDN.
/// В списках `data-id` иногда с хвостовым `\`; без него CDN отвечает 400.
class MuzyetSource implements BrowserSource, BrowserFeaturedSource {
  MuzyetSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://thirteen.muzyet.com';

  static final _itemSplitRe = RegExp(
    r'<li\s+class="sarki-liste"',
    caseSensitive: false,
  );
  static final _labelRe = RegExp(
    r'class="artist_name"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _dataIdRe = RegExp(
    r'data-id="(https://cdn\.muzyet\.com/\?h=[^"]+)"',
    caseSensitive: false,
  );
  static final _pageRe = RegExp(
    r'href="((?:https://thirteen\.muzyet\.com)?/music/[^"]+)"',
    caseSensitive: false,
  );
  static final _slugRe = RegExp(r'/music/([^"/]+)');
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'muzyet';

  @override
  String get name => 'Muzyet';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> featured({int limit = 3}) async {
    final take = limit.clamp(1, 10);
    final pages = await Future.wait([
      _getTextSoft(Uri.parse('$_origin/newmusic')),
      _getTextSoft(Uri.parse('$_origin/hitmusic')),
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

  /// Плейлист «Новинки» — https://thirteen.muzyet.com/newmusic
  Future<List<BrowserHit>> newest({int limit = 100}) async {
    final take = limit.clamp(1, 200);
    final html = await _getText(Uri.parse('$_origin/newmusic'));
    return _toHits(_parseItems(html), take);
  }

  /// Плейлист «Хиты» — https://thirteen.muzyet.com/hitmusic
  Future<List<BrowserHit>> popular({int limit = 100}) async {
    final take = limit.clamp(1, 200);
    final html = await _getTextSoft(Uri.parse('$_origin/hitmusic'));
    if (html.isEmpty) {
      // Fallback: блок на главной.
      return _toHits(
        _parseItems(await _getText(Uri.parse('$_origin/'))),
        take,
      );
    }
    return _toHits(_parseItems(html), take);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final slug = _slugify(q);
    var items = _parseItems(
      await _getTextSoft(Uri.parse('$_origin/search/$slug/')),
    );
    if (items.isEmpty) {
      final pages = await Future.wait([
        _getText(Uri.parse('$_origin/newmusic')),
        _getText(Uri.parse('$_origin/hitmusic')),
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
          downloadUrl: item.fileUrl.isNotEmpty ? item.fileUrl : item.pageUrl,
        ),
    ];
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (_looksLikeCdnUrl(cached)) {
      return _cdnUri(cached);
    }
    final page = cached.isNotEmpty
        ? cached
        : (hit.id.isNotEmpty ? '$_origin/music/${hit.id}' : '');
    if (page.isEmpty) {
      throw StateError('Muzyet: нет ссылки на файл');
    }
    // Страницы `/music/...` часто 404 — пробуем мягко.
    final html = await _getTextSoft(Uri.parse(_absUrl(page)));
    final raw = (_dataIdRe.firstMatch(html)?.group(1) ?? '').trim();
    if (raw.isEmpty) {
      throw StateError('Muzyet: нет data-id');
    }
    return _cdnUri(raw);
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
        'Muzyet HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    return text;
  }

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
      final fileRaw = (_dataIdRe.firstMatch(body)?.group(1) ?? '').trim();
      final fileUrl = _normalizeCdn(fileRaw);
      if (fileUrl.isEmpty) continue;

      final label = _clean(_labelRe.firstMatch(body)?.group(1) ?? '');
      if (label.isEmpty) continue;
      final partsLabel = _splitArtistTitle(label);

      final pagePath = (_pageRe.firstMatch(body)?.group(1) ?? '').trim();
      final pageUrl = pagePath.isEmpty ? '' : _absUrl(pagePath);
      final slug = (_slugRe.firstMatch(pageUrl)?.group(1) ?? '').trim();
      final key = slug.isNotEmpty ? slug : fileUrl;
      if (!seen.add(key)) continue;

      out.add(
        _TrackItem(
          id: key,
          artist: partsLabel.$1,
          title: partsLabel.$2,
          pageUrl: pageUrl,
          fileUrl: fileUrl,
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

  /// Сохраняет хвостовые `\` из разметки — без них часть CDN-токенов отдаёт 400.
  static String _normalizeCdn(String raw) {
    var text = raw.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
    if (text.isEmpty) return '';
    // Убираем только мусор после токена, не трогая `\` внутри/в конце hash.
    text = text.replaceAll(RegExp(r'[\s"]+$'), '');
    if (!_looksLikeCdnUrl(text)) return '';
    return text;
  }

  static Uri _cdnUri(String raw) {
    final url = _normalizeCdn(raw);
    if (url.isEmpty) {
      throw StateError('Muzyet: пустой CDN URL');
    }
    // Страничные токены без `\`; хвостовой `\` из списков оставляем как есть.
    final qi = url.indexOf('?h=');
    if (qi < 0) return Uri.parse(url);
    final h = url.substring(qi + 3);
    return Uri.https('cdn.muzyet.com', '/', {'h': h});
  }

  static bool _looksLikeCdnUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('cdn.muzyet.com/?h=') ||
        lower.contains('cdn.muzyet.com?h=');
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
    required this.pageUrl,
    required this.fileUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String pageUrl;
  final String fileUrl;
}
