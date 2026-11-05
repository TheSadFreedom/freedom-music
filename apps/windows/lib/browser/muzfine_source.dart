import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// muzfine.pro — DLE POST-поиск, файл из `data-track` (/files/...mp3).
class MuzfineSource implements BrowserSource {
  MuzfineSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://muzfine.pro';

  static final _itemSplitRe = RegExp(
    r'<div\s+class="[^"]*\bmf-track\b[^"]*\btrack\b[^"]*\bjs-item\b[^"]*"',
    caseSensitive: false,
  );
  static final _openTagRe = RegExp(r'^([^>]*)>');
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _subtitleRe = RegExp(
    r'class="[^"]*track__subtitle[^"]*"[^>]*>([\s\S]*?)</div>',
    caseSensitive: false,
  );
  static final _durationRe = RegExp(
    r'class="[^"]*track__time[^"]*"[^>]*>([^<]+)<',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'muzfine';

  @override
  String get name => 'MuzFine';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final html = await _postSearch(q);
    var items = _parseItems(html);
    if (items.isEmpty) {
      items = _parseItems(
        await _getTextSoft(
          Uri.parse('$_origin/').replace(
            queryParameters: {
              'do': 'search',
              'subaction': 'search',
              'story': q,
            },
          ),
        ),
      );
    }
    if (items.isEmpty) return const [];
    final take = limit.clamp(1, 50);
    return [
      for (final item in items.take(take))
        BrowserHit(
          sourceId: id,
          id: item.id,
          title: item.title,
          artist: item.artist.isEmpty ? 'Unknown' : item.artist,
          subtitle: null,
          duration: item.duration,
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
      throw StateError('MuzFine: нет ссылки на файл');
    }
    throw StateError('MuzFine: нет data-track');
  }

  Future<String> _postSearch(String query) async {
    final uri = Uri.parse('$_origin/index.php?do=search');
    final body = utf8.encode(
      'do=search&subaction=search&story=${Uri.encodeQueryComponent(query)}'
      '&titleonly=0&full_search=0&search_start=0&result_from=1',
    );
    final request = await _client.postUrl(uri);
    _applyHeaders(request);
    request.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    request.headers.contentLength = body.length;
    request.add(body);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'MuzFine HTTP ${response.statusCode}',
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

  /// Публичный парсер — для офлайн-smoke при TLS-блоке.
  static List<BrowserHit> parseHitsForTest(String html, {int limit = 30}) {
    final items = _parseItems(html);
    final take = limit.clamp(1, 50);
    return [
      for (final item in items.take(take))
        BrowserHit(
          sourceId: 'muzfine',
          id: item.id,
          title: item.title,
          artist: item.artist.isEmpty ? 'Unknown' : item.artist,
          subtitle: null,
          duration: item.duration,
          license: null,
          downloadUrl: item.fileUrl,
        ),
    ];
  }

  static List<_TrackItem> _parseItems(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    final parts = html.split(_itemSplitRe);
    for (var i = 1; i < parts.length; i++) {
      final body = parts[i];
      final open = _openTagRe.firstMatch(body)?.group(1) ?? '';
      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(open)) {
        attrs[a.group(1)!.toLowerCase()] =
            (a.group(3) ?? a.group(4) ?? '').trim();
      }

      final fileUrl = _absUrl(attrs['data-track'] ?? '');
      if (!_looksLikeFileUrl(fileUrl)) continue;

      final title = _clean(attrs['data-title'] ?? '');
      if (title.isEmpty) continue;
      final subtitle = _clean(_subtitleRe.firstMatch(body)?.group(1) ?? '');
      final artistAttr = _clean(attrs['data-artist'] ?? '');
      final artist = subtitle.isNotEmpty ? subtitle : artistAttr;

      final id = (attrs['data-id'] ?? fileUrl).trim();
      if (!seen.add(id)) continue;

      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          fileUrl: fileUrl,
          duration: _parseDuration(
            _clean(_durationRe.firstMatch(body)?.group(1) ?? ''),
          ),
        ),
      );
    }
    return out;
  }

  static Duration? _parseDuration(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parts = text.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p.trim());
      if (n == null) return null;
      nums.add(n);
    }
    if (nums.length == 2) {
      return Duration(minutes: nums[0], seconds: nums[1]);
    }
    return Duration(hours: nums[0], minutes: nums[1], seconds: nums[2]);
  }

  static bool _looksLikeFileUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp3') || lower.contains('/files/');
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
    required this.duration,
  });

  final String id;
  final String title;
  final String artist;
  final String fileUrl;
  final Duration? duration;
}
