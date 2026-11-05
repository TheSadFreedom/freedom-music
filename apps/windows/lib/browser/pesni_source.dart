import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// pesni.cc — поиск `/search/{query}/`, файл из `playlist-play[data-url]`.
class PesniSource implements BrowserSource {
  PesniSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://pesni.cc';

  static final _itemSplitRe = RegExp(
    r'<li\s+class="[^"]*__adv_list_track[^"]*"',
    caseSensitive: false,
  );
  static final _dataUrlRe = RegExp(
    r'data-url="([^"]+)"',
    caseSensitive: false,
  );
  static final _dataUrlSongRe = RegExp(
    r'data-urlsong="([^"]+)"',
    caseSensitive: false,
  );
  static final _songViewRe = RegExp(
    r'id="SongView"[^>]*href="([^"]+)"|href="([^"]+)"[^>]*id="SongView"',
    caseSensitive: false,
  );
  static final _artistRe = RegExp(
    r'class="[^"]*playlist-name-artist[^"]*"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'class="[^"]*playlist-name-title[^"]*"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _pageRe = RegExp(
    r'<a[^>]*href="([^"]+)"[^>]*class="[^"]*playlist-down'
    r'|<a[^>]*class="[^"]*playlist-down[^"]*"[^>]*href="([^"]+)"',
    caseSensitive: false,
  );
  static final _downTitleRe = RegExp(
    r'class="[^"]*playlist-down[^"]*"[^>]*title="Скачать\s+([^"]+)"'
    r'|title="Скачать\s+([^"]+)"[^>]*class="[^"]*playlist-down',
    caseSensitive: false,
  );
  static final _durationRe = RegExp(
    r'class="playlist-duration"[^>]*>([^<]+)<',
    caseSensitive: false,
  );
  static final _trackIdRe = RegExp(
    r'/track/[^/]+/(\d+)-',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'pesni';

  @override
  String get name => 'Pesni.cc';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.parse('$_origin/search/${Uri.encodeComponent(q)}/');
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
          downloadUrl: item.pageUrl.isNotEmpty ? item.pageUrl : item.fileUrl,
        ),
    ];
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (_looksLikeFileUrl(cached)) {
      return Uri.parse(cached);
    }

    final pageUrl = cached.startsWith('http')
        ? cached
        : (cached.startsWith('/') ? '$_origin$cached' : '');
    if (pageUrl.isEmpty) {
      throw StateError('Pesni.cc: нет страницы трека');
    }

    final html = await _getText(Uri.parse(pageUrl));
    // Основной трек на странице: SongView / data-urlsong (не related playlist).
    final songView = _songViewRe.firstMatch(html);
    final fromView =
        (songView?.group(1) ?? songView?.group(2) ?? '').trim();
    if (_looksLikeFileUrl(fromView)) {
      return Uri.parse(_absUrl(fromView));
    }
    final fromSong = (_dataUrlSongRe.firstMatch(html)?.group(1) ?? '').trim();
    if (_looksLikeFileUrl(fromSong)) {
      return Uri.parse(_absUrl(fromSong));
    }

    final items = _parseItems(html);
    for (final item in items) {
      if (item.id == hit.id && item.fileUrl.isNotEmpty) {
        return Uri.parse(item.fileUrl);
      }
    }
    throw StateError('Pesni.cc: нет ссылки на файл');
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
        'Pesni.cc HTTP ${response.statusCode}',
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
      final fileUrl = _absUrl(_dataUrlRe.firstMatch(body)?.group(1) ?? '');
      if (fileUrl.isEmpty) continue;

      var artist = _clean(_artistRe.firstMatch(body)?.group(1) ?? '');
      var title = _clean(_titleRe.firstMatch(body)?.group(1) ?? '');

      if (artist.isEmpty || title.isEmpty) {
        final down = _downTitleRe.firstMatch(body);
        final label = _clean(down?.group(1) ?? down?.group(2) ?? '');
        final split = _splitArtistTitle(label);
        if (artist.isEmpty) artist = split.$1;
        if (title.isEmpty) title = split.$2;
      }
      if (title.isEmpty) continue;

      final pageMatch = _pageRe.firstMatch(body);
      final pagePath =
          ((pageMatch?.group(1) ?? pageMatch?.group(2) ?? '')).trim();
      // Иногда «Скачать» сразу ведёт на CDN — это и есть файл, не страница.
      final pageIsFile = _looksLikeFileUrl(pagePath);
      final pageUrl = pageIsFile ? '' : _absUrl(pagePath);
      final pickFile = pageIsFile ? _absUrl(pagePath) : fileUrl;
      final trackId = _trackIdRe.firstMatch(pagePath)?.group(1) ?? '';
      final id = trackId.isNotEmpty ? trackId : pickFile;
      if (!seen.add(id)) continue;

      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          duration: _parseDuration(
            _durationRe.firstMatch(body)?.group(1) ?? '',
          ),
          pageUrl: pageUrl,
          fileUrl: pickFile,
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

  static bool _looksLikeFileUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp3') ||
        lower.contains('sunproxy.net') ||
        lower.contains('/file/');
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
    required this.pageUrl,
    required this.fileUrl,
  });

  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String pageUrl;
  final String fileUrl;
}
