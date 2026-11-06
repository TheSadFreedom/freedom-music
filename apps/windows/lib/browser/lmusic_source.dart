import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// lmusic.kz — поиск `/search/?q=`, файл `/api/download/{id}` (или stream).
class LmusicSource implements BrowserSource {
  LmusicSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://lmusic.kz';

  static final _itemSplitRe = RegExp(
    r'<div\s+class="c-card-mp3 js-item-mp3"',
    caseSensitive: false,
  );
  static final _openTagRe = RegExp(r'^([^>]*)>');
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _durationRe = RegExp(
    r'class="c-card-mp3__duration[^"]*"[^>]*>([\s\S]*?)</div>',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'lmusic';

  @override
  String get name => 'Lmusic';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  /// Каталог/чарт по пути, напр. `top_kz/monthly`, `hit-parade/shazam-music`.
  Future<List<BrowserHit>> catalog(String path, {int limit = 100}) async {
    final take = limit.clamp(1, 200);
    final clean = path.replaceAll(RegExp(r'^/+|/+$'), '');
    final html = await _getText(Uri.parse('$_origin/$clean'));
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
    final uri = Uri.parse('$_origin/search/').replace(
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
      id: item.id,
      title: item.title,
      artist: item.artist.isEmpty ? 'Unknown' : item.artist,
      subtitle: null,
      duration: item.duration,
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
      throw StateError('Lmusic: нет id трека');
    }
    return Uri.parse('$_origin/api/download/${hit.id}');
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
        'Lmusic HTTP ${response.statusCode}',
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
      final open = _openTagRe.firstMatch(body)?.group(1) ?? '';
      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(open)) {
        attrs[a.group(1)!.toLowerCase()] =
            (a.group(3) ?? a.group(4) ?? '').trim();
      }

      final id = (attrs['data-mp3_id'] ?? '').trim();
      final title = _clean(attrs['data-song_name'] ?? '');
      final artist = _clean(attrs['data-artist_name'] ?? '');
      if (id.isEmpty || title.isEmpty) continue;
      if (!seen.add(id)) continue;

      final download = _absUrl(attrs['data-download_url'] ?? '');
      final stream = _absUrl(attrs['data-src_url'] ?? '');
      final fileUrl = download.isNotEmpty
          ? download
          : (stream.isNotEmpty ? stream : '$_origin/api/download/$id');

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
    return lower.contains('/api/download/') || lower.contains('/api/stream/');
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
