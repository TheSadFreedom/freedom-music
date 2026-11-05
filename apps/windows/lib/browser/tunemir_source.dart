import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// TuneMir (DLE) — поиск POST `do=search`, файл из `data-dl` / `data-src`.
class TunemirSource implements BrowserSource {
  TunemirSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://tunemir.com';

  static final _trackItemRe = RegExp(
    r'<div[^>]*class="[^"]*track-item[^"]*"[^>]*>',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'tunemir';

  @override
  String get name => 'TuneMir';

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
    final items = _parseTrackItems(html);
    if (items.isEmpty) return const [];
    final take = limit.clamp(1, 50);
    return [
      for (final item in items.take(take))
        BrowserHit(
          sourceId: this.id,
          id: item.id,
          title: item.title,
          artist: item.artist.isEmpty ? 'Unknown' : item.artist,
          subtitle: null,
          duration: item.duration,
          license: null,
          // Страница трека — оттуда освежаем data-dl / data-src.
          downloadUrl: item.pageUrl.isNotEmpty
              ? item.pageUrl
              : (item.downloadUrl.isNotEmpty
                  ? item.downloadUrl
                  : item.streamUrl),
        ),
    ];
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    // Прямая mp3 / download-ссылка уже в hit.
    if (_looksLikeFileUrl(cached)) {
      return Uri.parse(cached);
    }

    final pageUrl = cached.startsWith('http')
        ? cached
        : (hit.id.isNotEmpty ? '$_origin/track/${hit.id}/' : '');
    if (pageUrl.isEmpty) {
      throw StateError('TuneMir: нет страницы трека');
    }

    final html = await _getText(Uri.parse(pageUrl));
    final items = _parseTrackItems(html);
    _TrackItem? match;
    for (final item in items) {
      if (item.id == hit.id) {
        match = item;
        break;
      }
    }
    match ??= items.isEmpty ? null : items.first;
    if (match == null) {
      throw StateError('TuneMir: на странице нет файла');
    }
    final pick = match.downloadUrl.isNotEmpty
        ? match.downloadUrl
        : match.streamUrl;
    if (pick.isEmpty) {
      throw StateError('TuneMir: пустая ссылка на файл');
    }
    return Uri.parse(pick);
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
        'TuneMir HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    return text;
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
        'TuneMir HTTP ${response.statusCode}',
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

  static List<_TrackItem> _parseTrackItems(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _trackItemRe.allMatches(html)) {
      final tag = m.group(0)!;
      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(tag)) {
        final name = a.group(1)!.toLowerCase();
        final value = (a.group(3) ?? a.group(4) ?? '').trim();
        attrs[name] = value;
      }
      final id = (attrs['data-id'] ?? '').trim();
      final title = _clean(attrs['data-title'] ?? '');
      if (id.isEmpty || title.isEmpty) continue;
      if (!seen.add(id)) continue;
      final stream = _absUrl(attrs['data-src'] ?? '');
      final download = _absUrl(attrs['data-dl'] ?? '');
      final page = _absUrl(attrs['data-link'] ?? '');
      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: _clean(attrs['data-subtitle'] ?? ''),
          duration: _parseDuration(attrs['data-time'] ?? ''),
          streamUrl: stream,
          downloadUrl: download,
          pageUrl: page,
        ),
      );
    }
    return out;
  }

  static bool _looksLikeFileUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp3') ||
        lower.contains('do=download') ||
        lower.contains('/download');
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
    return raw
        .replaceAll('\u0000', '')
        .replaceAll(RegExp(r'\s+'), ' ')
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
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.streamUrl,
    required this.downloadUrl,
    required this.pageUrl,
  });

  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String streamUrl;
  final String downloadUrl;
  final String pageUrl;
}
