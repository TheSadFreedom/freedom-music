import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// MuzPace.net — поиск `/search/{query}/`, файл из `muz-single-track[data-url]`.
class MuzpaceSource implements BrowserSource {
  MuzpaceSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://muzpace.net';

  static final _searchItemRe = RegExp(
    r'<a\s+href="(/mp3/(\d+))"\s*>\s*<div[^>]*>\s*<div>([\s\S]*?)</div>',
    caseSensitive: false,
  );
  static final _singleTrackRe = RegExp(
    r'<div[^>]*class="[^"]*\bmuz-single-track\b[^"]*"[^>]*>',
    caseSensitive: false,
  );
  static final _trackRowRe = RegExp(
    r'<div[^>]*class="[^"]*\btrack-row\b[^"]*"[^>]*>',
    caseSensitive: false,
  );
  static final _idFromPathRe = RegExp(r'/mp3/(\d+)');
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'muzpace';

  @override
  String get name => 'MuzPace';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  /// Плейлист «Новинки» — https://muzpace.net/mp3/novinki
  Future<List<BrowserHit>> newest({int limit = 100}) {
    return _catalogPlaylist('novinki', limit: limit);
  }

  /// Плейлист «Топ» — https://muzpace.net/mp3/populyarnaya
  Future<List<BrowserHit>> popular({int limit = 100}) {
    return _catalogPlaylist('populyarnaya', limit: limit);
  }

  Future<List<BrowserHit>> _catalogPlaylist(
    String slug, {
    required int limit,
  }) async {
    final take = limit.clamp(1, 200);
    final hits = <BrowserHit>[];
    final seen = <String>{};
    for (var page = 1; page <= 5 && hits.length < take; page++) {
      final path = page == 1
          ? '$_origin/mp3/$slug'
          : '$_origin/mp3/$slug/page/$page';
      final html = await _getText(Uri.parse(path));
      final items = _parseTrackRows(html);
      if (items.isEmpty) break;
      for (final item in items) {
        if (!seen.add(item.id)) continue;
        hits.add(_toHit(item));
        if (hits.length >= take) break;
      }
    }
    return hits;
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    var html = await _getText(
      Uri.parse('$_origin/search/${Uri.encodeComponent(q)}/'),
    );
    var items = _parseSearchItems(html);
    if (items.isEmpty) {
      html = await _getText(
        Uri.parse('$_origin/search/').replace(queryParameters: {'q': q}),
      );
      items = _parseSearchItems(html);
    }
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
      downloadUrl: item.fileUrl.isNotEmpty ? item.fileUrl : item.pageUrl,
    );
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (_looksLikeFileUrl(cached)) {
      return Uri.parse(cached);
    }

    final pageUrl = cached.startsWith('http')
        ? cached
        : (hit.id.isNotEmpty ? '$_origin/mp3/${hit.id}' : '');
    if (pageUrl.isEmpty) {
      throw StateError('MuzPace: нет страницы трека');
    }

    final html = await _getText(Uri.parse(pageUrl));
    final fileUrl = _parseSingleTrackUrl(html);
    if (fileUrl == null || fileUrl.isEmpty) {
      throw StateError('MuzPace: на странице нет data-url');
    }
    return Uri.parse(fileUrl);
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
        'MuzPace HTTP ${response.statusCode}',
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

  static List<_TrackItem> _parseSearchItems(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _searchItemRe.allMatches(html)) {
      final id = (m.group(2) ?? '').trim();
      final path = (m.group(1) ?? '').trim();
      final label = _clean(m.group(3) ?? '');
      if (id.isEmpty || label.isEmpty || !seen.add(id)) continue;
      final parts = _splitArtistTitle(label);
      out.add(
        _TrackItem(
          id: id,
          artist: parts.$1,
          title: parts.$2,
          pageUrl: _absUrl(path),
          fileUrl: '',
        ),
      );
    }
    return out;
  }

  static List<_TrackItem> _parseTrackRows(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _trackRowRe.allMatches(html)) {
      final tag = m.group(0)!;
      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(tag)) {
        final name = a.group(1)!.toLowerCase();
        final value = (a.group(3) ?? a.group(4) ?? '').trim();
        attrs[name] = value;
      }
      final title = _clean(attrs['data-title'] ?? '');
      final artist = _clean(attrs['data-artist'] ?? '');
      final link = attrs['data-link'] ?? '';
      final idMatch = _idFromPathRe.firstMatch(link);
      final id = (idMatch?.group(1) ?? '').trim();
      if (id.isEmpty || title.isEmpty || !seen.add(id)) continue;
      out.add(
        _TrackItem(
          id: id,
          artist: artist,
          title: title,
          pageUrl: _absUrl(link),
          fileUrl: _absUrl(attrs['data-url'] ?? ''),
        ),
      );
    }
    return out;
  }

  static String? _parseSingleTrackUrl(String html) {
    final tag = _singleTrackRe.firstMatch(html)?.group(0);
    if (tag == null) return null;
    final attrs = <String, String>{};
    for (final a in _attrRe.allMatches(tag)) {
      final name = a.group(1)!.toLowerCase();
      final value = (a.group(3) ?? a.group(4) ?? '').trim();
      attrs[name] = value;
    }
    final url = attrs['data-url'] ?? '';
    if (url.isEmpty) return null;
    return _absUrl(url);
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
    return lower.contains('.mp3') || lower.contains('/dll/');
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
    this.fileUrl = '',
  });

  final String id;
  final String title;
  final String artist;
  final String pageUrl;
  final String fileUrl;
}
