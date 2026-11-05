import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// box.hitplayer.ru — поиск `/?s=`, файл со страницы `/?dl=` (CDN downloadm .mp3).
class HitplayerSource implements BrowserSource {
  HitplayerSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://box.hitplayer.ru';

  static final _itemSplitRe = RegExp(
    r'<li\s+class="track"',
    caseSensitive: false,
  );
  static final _openTagRe = RegExp(r'^([^>]*)>');
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'class="track__title"[^>]*>([\s\S]*?)</a>',
    caseSensitive: false,
  );
  static final _artistRe = RegExp(
    r'class="track__artist"[^>]*>([\s\S]*?)</a>',
    caseSensitive: false,
  );
  static final _durationRe = RegExp(
    r'class="track__duration"[^>]*>([^<]+)<',
    caseSensitive: false,
  );
  static final _dlHrefRe = RegExp(
    r'href="(/\?dl=\d+)"',
    caseSensitive: false,
  );
  static final _dlIdRe = RegExp(r'[?&]dl=(\d+)');
  static final _fileHrefRe = RegExp(
    r'class="[^"]*dl-card__btn--download[^"]*"[^>]*href="([^"]+)"'
    r'|href="([^"]+)"[^>]*class="[^"]*dl-card__btn--download',
    caseSensitive: false,
  );
  static final _downloadmRe = RegExp(
    r'href="(https?://[^"]+/downloadm/[^"]+\.mp3[^"]*)"',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'hitplayer';

  @override
  String get name => 'Hitplayer';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.parse('$_origin/').replace(
      queryParameters: {'s': q},
    );
    final html = await _getText(uri);
    final items = _parseItems(html);
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
          downloadUrl: item.pageUrl,
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
        : (hit.id.isNotEmpty ? '$_origin/?dl=${hit.id}' : '');
    if (page.isEmpty) {
      throw StateError('Hitplayer: нет страницы скачивания');
    }
    final html = await _getText(Uri.parse(_absUrl(page)));
    final file = _extractFileUrl(html);
    if (file.isEmpty) {
      throw StateError('Hitplayer: нет ссылки на mp3');
    }
    return Uri.parse(file);
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
        'Hitplayer HTTP ${response.statusCode}',
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

      final title = _clean(_titleRe.firstMatch(body)?.group(1) ?? '');
      if (title.isEmpty) continue;
      final artists = [
        for (final m in _artistRe.allMatches(body)) _clean(m.group(1) ?? ''),
      ].where((a) => a.isNotEmpty).toList();
      final artist = artists.isEmpty ? 'Unknown' : artists.join(', ');

      final dlPath = (_dlHrefRe.firstMatch(body)?.group(1) ?? '').trim();
      if (dlPath.isEmpty) continue;
      final dlId = (_dlIdRe.firstMatch(dlPath)?.group(1) ?? '').trim();
      final audioId = (attrs['data-audio-id'] ?? '').trim();
      final id = dlId.isNotEmpty
          ? dlId
          : (audioId.isNotEmpty ? audioId : dlPath);
      if (!seen.add(id)) continue;

      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          pageUrl: _absUrl(dlPath),
          duration: _parseDuration(
            _clean(_durationRe.firstMatch(body)?.group(1) ?? ''),
          ),
        ),
      );
    }
    return out;
  }

  static String _extractFileUrl(String html) {
    final m = _fileHrefRe.firstMatch(html);
    var raw = (m?.group(1) ?? m?.group(2) ?? '').trim();
    if (raw.isEmpty) {
      raw = (_downloadmRe.firstMatch(html)?.group(1) ?? '').trim();
    }
    if (raw.isEmpty) return '';
    return _absUrl(raw.replaceAll('&amp;', '&'));
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
    return lower.contains('/downloadm/') || lower.contains('.mp3');
  }

  static String _absUrl(String raw) {
    var text = raw.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
    text = text.replaceAll('&amp;', '&');
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
    required this.duration,
  });

  final String id;
  final String title;
  final String artist;
  final String pageUrl;
  final Duration? duration;
}
