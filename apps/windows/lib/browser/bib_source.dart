import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// bib.fm — поиск `/search?q=`, файл из `data-url` (fine.sunproxy.net).
class BibSource implements BrowserSource, BrowserFeaturedSource {
  BibSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://bib.fm';

  static final _itemSplitRe = RegExp(
    r'<li\s+class="[^"]*__adv_list_track',
    caseSensitive: false,
  );
  static final _playRe = RegExp(
    r'<a([^>]*class="[^"]*playlist-play[^"]*"[^>]*)>',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _artistRe = RegExp(
    r'class="playlist-name-artist[^"]*"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'class="playlist-name-title[^"]*"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _durationRe = RegExp(
    r'class="playlist-duration"[^>]*>([^<]+)',
    caseSensitive: false,
  );
  static final _songIdRe = RegExp(
    r'/song/(\d+)-',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'bib';

  @override
  String get name => 'bib.fm';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> featured({int limit = 3}) async {
    final take = limit.clamp(1, 10);
    final html = await _getText(Uri.parse('$_origin/'));
    return _toHits(_parseItems(html), take);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.parse('$_origin/search').replace(
      queryParameters: {'q': q},
    );
    final html = await _getText(uri);
    return _toHits(_parseItems(html), limit.clamp(1, 50));
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
      return Uri.parse(cached);
    }
    throw StateError('bib.fm: нет ссылки на файл');
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
        'bib.fm HTTP ${response.statusCode}',
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
      final playTag = _playRe.firstMatch(body)?.group(1) ?? '';
      final playAttrs = <String, String>{};
      for (final a in _attrRe.allMatches(playTag)) {
        playAttrs[a.group(1)!.toLowerCase()] =
            (a.group(3) ?? a.group(4) ?? '').trim();
      }
      final fileUrl = (playAttrs['data-url'] ?? '').trim();
      if (!_looksLikeFileUrl(fileUrl)) continue;

      final artist = _clean(_artistRe.firstMatch(body)?.group(1) ?? '');
      var title = _clean(_titleRe.firstMatch(body)?.group(1) ?? '');
      if (title.isEmpty) continue;

      // Иногда title = «Artist - Song».
      if (artist.isNotEmpty) {
        final prefix = '$artist - ';
        if (title.startsWith(prefix)) {
          title = title.substring(prefix.length).trim();
        }
      }

      final songId = (_songIdRe.firstMatch(body)?.group(1) ?? '').trim();
      final id = songId.isNotEmpty ? songId : fileUrl;
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
    return lower.contains('.mp3') || lower.contains('sunproxy.net');
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
