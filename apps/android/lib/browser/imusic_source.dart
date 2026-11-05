import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// two.imusic.fm — поиск `/search/{query}/`, файл через `data-mp3` → play_mp3.php.
class ImusicSource implements BrowserSource {
  ImusicSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://two.imusic.fm';

  static final _trackBlockRe = RegExp(
    r'<li[^>]*class="[^"]*\btrack\b[^"]*"[^>]*>([\s\S]*?)</li>',
    caseSensitive: false,
  );
  static final _trackOpenRe = RegExp(
    r'<li[^>]*class="[^"]*\btrack\b[^"]*"[^>]*>',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _artistRe = RegExp(
    r'class="playlist-name"[\s\S]*?<b>\s*<a[^>]*>([\s\S]*?)</a>',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'class="playlist-name"[\s\S]*?<em>\s*<a[^>]*>([\s\S]*?)</a>',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'imusic';

  @override
  String get name => 'iMusic';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    var html = await _getText(
      Uri.parse('$_origin/search/${Uri.encodeComponent(q)}/'),
    );
    var items = _parseTracks(html);
    if (items.isEmpty) {
      html = await _getText(
        Uri.parse('$_origin/').replace(
          queryParameters: {'a': 'search', 'q': q},
        ),
      );
      items = _parseTracks(html);
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
          downloadUrl: item.playUrl,
        ),
    ];
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (_looksLikePlayOrFile(cached)) {
      return Uri.parse(_absUrl(cached));
    }
    if (hit.id.isEmpty) {
      throw StateError('iMusic: нет id трека');
    }
    // Обновляем hash со страницы трека / поиска по id — fallback: song page.
    final page = Uri.parse('$_origin/song/${hit.id}');
    final html = await _getText(page);
    final items = _parseTracks(html);
    _TrackItem? match;
    for (final item in items) {
      if (item.id == hit.id) {
        match = item;
        break;
      }
    }
    match ??= items.isEmpty ? null : items.first;
    final play = match?.playUrl ?? '';
    if (play.isEmpty) {
      throw StateError('iMusic: нет data-mp3');
    }
    return Uri.parse(play);
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
        'iMusic HTTP ${response.statusCode}',
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

  static List<_TrackItem> _parseTracks(String html) {
    final out = <_TrackItem>[];
    final seen = <String>{};
    for (final m in _trackBlockRe.allMatches(html)) {
      final open = _trackOpenRe.firstMatch(m.group(0)!)?.group(0) ?? '';
      final body = m.group(1) ?? '';
      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(open)) {
        final name = a.group(1)!.toLowerCase();
        final value = (a.group(3) ?? a.group(4) ?? '').trim();
        attrs[name] = value;
      }
      final id = (attrs['data-id'] ?? '').trim();
      final play = _absUrl((attrs['data-mp3'] ?? '').replaceAll('&amp;', '&'));
      if (id.isEmpty || play.isEmpty || !seen.add(id)) continue;
      if (id.startsWith('radio-')) continue;

      var artist = _clean(_artistRe.firstMatch(body)?.group(1) ?? '');
      var title = _clean(_titleRe.firstMatch(body)?.group(1) ?? '');
      if (title.isEmpty) {
        final fromQuery = Uri.tryParse(play);
        title = _clean(fromQuery?.queryParameters['title'] ?? '');
        if (artist.isEmpty) {
          artist = _clean(fromQuery?.queryParameters['artist'] ?? '');
        }
      }
      if (title.isEmpty) continue;

      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          duration: _parseDurationMs(attrs['data-duration'] ?? ''),
          playUrl: play,
        ),
      );
    }
    return out;
  }

  static bool _looksLikePlayOrFile(String url) {
    final lower = url.toLowerCase();
    return lower.contains('play_mp3.php') ||
        lower.contains('.mp3') ||
        lower.contains('imusic.fm/');
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
        .replaceAll('&ndash;', '–')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    return text.replaceAll(_wsRe, ' ').trim();
  }

  static Duration? _parseDurationMs(String raw) {
    final ms = int.tryParse(raw.trim());
    if (ms == null || ms <= 0) return null;
    return Duration(milliseconds: ms);
  }
}

class _TrackItem {
  const _TrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.playUrl,
  });

  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String playUrl;
}
