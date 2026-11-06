import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// one.muzso.net — поиск `/query?q=`, файл через `/api/download/{tid}`.
class MuzsoSource implements BrowserSource {
  MuzsoSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://one.muzso.net';

  static final _itemRe = RegExp(
    r'<div[^>]*class="[^"]*\bt-item\b[^"]*"[^>]*>',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'muzso';

  @override
  String get name => 'MuzSo';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  /// Плейлист «Новинки» — https://one.muzso.net/newmusic
  Future<List<BrowserHit>> newest({int limit = 100}) {
    return _catalogPlaylist('newmusic', limit: limit);
  }

  /// Плейлист «Хиты» — https://one.muzso.net/hits
  Future<List<BrowserHit>> popular({int limit = 100}) {
    return _catalogPlaylist('hits', limit: limit);
  }

  Future<List<BrowserHit>> _catalogPlaylist(
    String path, {
    required int limit,
  }) async {
    final take = limit.clamp(1, 200);
    final html = await _getText(Uri.parse('$_origin/$path'));
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
    final uri = Uri.parse('$_origin/query').replace(
      queryParameters: {'q': q},
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
      id: item.tid,
      title: item.title,
      artist: item.artist.isEmpty ? 'Unknown' : item.artist,
      subtitle: null,
      duration: item.duration,
      license: null,
      downloadUrl: null,
    );
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final tid = hit.id.trim();
    if (tid.isEmpty) {
      throw StateError('MuzSo: пустой id трека');
    }
    final uri = Uri.parse('$_origin/api/download/$tid').replace(
      queryParameters: {
        'artist': hit.artist,
        'title': hit.title,
      },
    );
    final body = await _getJson(uri);
    final url = '${body['url'] ?? ''}'.trim();
    if (url.isEmpty) {
      throw StateError('MuzSo: нет url в ответе download');
    }
    return Uri.parse(url);
  }

  Future<String> _getText(Uri uri) async {
    final request = await _client.getUrl(uri);
    _applyHeaders(request, acceptHtml: true);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'MuzSo HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    return text;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final request = await _client.getUrl(uri);
    _applyHeaders(request, acceptHtml: false);
    final response = await request.close().timeout(const Duration(seconds: 45));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'MuzSo HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw StateError('MuzSo: неожиданный JSON');
    }
    return decoded.cast<String, dynamic>();
  }

  void _applyHeaders(HttpClientRequest request, {required bool acceptHtml}) {
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(
      HttpHeaders.acceptHeader,
      acceptHtml
          ? 'text/html,application/xhtml+xml,application/json,*/*'
          : 'application/json,*/*',
    );
    request.headers.set(HttpHeaders.refererHeader, referer);
    request.headers.set('Origin', _origin);
  }

  static List<_TrackItem> _parseItems(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _itemRe.allMatches(html)) {
      final tag = m.group(0)!;
      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(tag)) {
        final name = a.group(1)!.toLowerCase();
        final value = (a.group(3) ?? a.group(4) ?? '').trim();
        attrs[name] = value;
      }
      final tid = (attrs['data-tid'] ?? '').trim();
      final title = _clean(attrs['data-title'] ?? '');
      if (tid.isEmpty || title.isEmpty || !seen.add(tid)) continue;
      out.add(
        _TrackItem(
          tid: tid,
          title: title,
          artist: _clean(attrs['data-artist'] ?? ''),
          duration: _parseDuration(attrs['data-duration'] ?? ''),
        ),
      );
    }
    return out;
  }

  static String _clean(String raw) {
    return raw
        .replaceAll('\u0000', '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(_wsRe, ' ')
        .trim();
  }

  static Duration? _parseDuration(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parts = text.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null) return null;
      nums.add(n);
    }
    if (nums.length == 2) {
      return Duration(minutes: nums[0], seconds: nums[1]);
    }
    return Duration(hours: nums[0], minutes: nums[1], seconds: nums[2]);
  }
}

class _TrackItem {
  const _TrackItem({
    required this.tid,
    required this.title,
    required this.artist,
    required this.duration,
  });

  final String tid;
  final String title;
  final String artist;
  final Duration? duration;
}
