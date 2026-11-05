import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// muzskil.com — DLE POST-поиск (`fs-result`), файл `data-src` на странице трека.
class MuzskilSource implements BrowserSource {
  MuzskilSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://muzskil.com';

  static final _resultSplitRe = RegExp(
    r'<a\s+href="(https://muzskil\.com/\d+-[^"]+\.html)"[^>]*class="[^"]*fs-result',
    caseSensitive: false,
  );
  static final _resultTitleRe = RegExp(
    r'class="fs-result__title[^"]*"[^>]*>([\s\S]*?)</div>',
    caseSensitive: false,
  );
  static final _homeItemRe = RegExp(
    r'<div\s+class="track-item[^"]*"[^>]*>',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _dataSrcRe = RegExp(
    r'data-src="([^"]+\.mp3)"',
    caseSensitive: false,
  );
  static final _idFromPathRe = RegExp(
    r'muzskil\.com/(\d+)-',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'muzskil';

  @override
  String get name => 'Muzskil';

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
    var items = _parseSearchResults(html);
    // На главной иногда уже есть data-src — дополняем, если поиск пуст.
    if (items.isEmpty) {
      final home = await _getText(Uri.parse('$_origin/'));
      items = _parseHomeItems(home, needle: q.toLowerCase());
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
          downloadUrl: item.fileUrl.isNotEmpty ? item.fileUrl : item.pageUrl,
        ),
    ];
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (_looksLikeFileUrl(cached)) {
      return Uri.parse(_absUrl(cached));
    }
    final page = cached.isNotEmpty
        ? cached
        : (hit.id.isNotEmpty ? '$_origin/${hit.id}' : '');
    if (page.isEmpty) {
      throw StateError('Muzskil: нет страницы трека');
    }
    final html = await _getText(Uri.parse(_absUrl(page)));
    final file = (_dataSrcRe.firstMatch(html)?.group(1) ?? '').trim();
    if (file.isEmpty) {
      throw StateError('Muzskil: нет data-src на странице');
    }
    return Uri.parse(_absUrl(file));
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
        'Muzskil HTTP ${response.statusCode}',
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
        'Muzskil HTTP ${response.statusCode}',
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

  static List<_TrackItem> _parseSearchResults(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    final matches = _resultSplitRe.allMatches(html).toList();
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final pageUrl = (m.group(1) ?? '').trim();
      if (pageUrl.isEmpty) continue;
      final end = i + 1 < matches.length ? matches[i + 1].start : html.length;
      final body = html.substring(m.start, end);
      final label = _clean(_resultTitleRe.firstMatch(body)?.group(1) ?? '');
      if (label.isEmpty) continue;
      final parts = _splitArtistTitle(label);
      final id = (_idFromPathRe.firstMatch(pageUrl)?.group(1) ?? pageUrl).trim();
      if (!seen.add(id)) continue;
      out.add(
        _TrackItem(
          id: id,
          artist: parts.$1,
          title: parts.$2,
          pageUrl: pageUrl,
          fileUrl: '',
          duration: null,
        ),
      );
    }
    return out;
  }

  static List<_TrackItem> _parseHomeItems(String html, {required String needle}) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _homeItemRe.allMatches(html)) {
      final tag = m.group(0)!;
      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(tag)) {
        attrs[a.group(1)!.toLowerCase()] =
            (a.group(3) ?? a.group(4) ?? '').trim();
      }
      final file = _absUrl(attrs['data-src'] ?? '');
      if (!_looksLikeFileUrl(file)) continue;
      final label = _clean(attrs['data-title'] ?? attrs['data-subtitle'] ?? '');
      if (label.isEmpty) continue;
      if (needle.isNotEmpty && !label.toLowerCase().contains(needle)) continue;
      final id = (attrs['data-id'] ?? file).trim();
      if (!seen.add(id)) continue;
      final parts = _splitArtistTitle(label);
      final durRaw = (attrs['data-time'] ?? '').trim();
      out.add(
        _TrackItem(
          id: id,
          artist: parts.$1,
          title: parts.$2,
          pageUrl: '',
          fileUrl: file,
          duration: _parseDuration(durRaw),
        ),
      );
    }
    return out;
  }

  static (String, String) _splitArtistTitle(String label) {
    final idx = label.indexOf(' - ');
    if (idx <= 0) return ('Unknown', label);
    final artist = label.substring(0, idx).trim();
    final title = label.substring(idx + 3).trim();
    if (artist.isEmpty || title.isEmpty) return ('Unknown', label);
    return (artist, title);
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
    return lower.contains('.mp3') || lower.contains('/uploads/files/');
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
    required this.duration,
  });

  final String id;
  final String title;
  final String artist;
  final String pageUrl;
  final String fileUrl;
  final Duration? duration;
}
