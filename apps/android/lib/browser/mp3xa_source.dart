import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// mp3xa.me — ajax_search → страница трека → `data-url` (cdnproxy).
///
/// HTML `/search/` сейчас часто пустой, поэтому основной путь — `op=ajax_search`.
class Mp3xaSource implements BrowserSource {
  Mp3xaSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://mp3xa.me';

  static final _itemSplitRe = RegExp(
    r'<div\s+class="plyr-item"',
    caseSensitive: false,
  );
  static final _openTagRe = RegExp(r'^([^>]*)>');
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _playRe = RegExp(
    r'<a([^>]*class="[^"]*\bplay\b[^"]*"[^>]*)>',
    caseSensitive: false,
  );
  static final _artistRe = RegExp(
    r'class="name"[^>]*>([\s\S]*?)</div>',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'class="song_name"[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)</a>',
    caseSensitive: false,
  );
  static final _durationRe = RegExp(
    r'class="duration"[^>]*>([^<]+)<',
    caseSensitive: false,
  );
  static final _metaNameRe = RegExp(
    r'itemprop="name"[^>]*content="([^"]+)"'
    r'|content="([^"]+)"[^>]*itemprop="name"'
    r'|<span[^>]*itemprop="name"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _packerKwRe = RegExp(r",\d+,\d+,'((?:\\'|[^'])*)'");
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'mp3xa';

  @override
  String get name => 'mp3xa';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    // 1) HTML-поиск (если снова заработает).
    var items = _parseItems(
      await _getTextSoft(
        Uri.parse('$_origin/search/').replace(
          queryParameters: {'story': q, 'type': '2'},
        ),
      ),
    );
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

    // 2) ajax_search → страницы треков.
    if (items.isEmpty) {
      final suggestions = await _ajaxSearch(q, type: '2');
      final pages = <_Suggest>[
        for (final s in suggestions)
          if (_looksLikeTrackPath(s.path)) s,
      ];
      final takePages = pages.take(limit.clamp(1, 50)).toList();
      final fetched = await Future.wait([
        for (final s in takePages) _itemFromTrackPage(s),
      ]);
      items = [
        for (final item in fetched)
          if (item != null) item,
      ];
    }

    // 3) Страница исполнителя + фильтр каталогов.
    if (items.isEmpty) {
      final slug = _slugify(q);
      final pages = await Future.wait([
        _getTextSoft(Uri.parse('$_origin/singer/$slug/')),
        _getTextSoft(Uri.parse('$_origin/hits/')),
        _getTextSoft(Uri.parse('$_origin/novye_pesni/')),
      ]);
      final merged = <_TrackItem>[];
      final seen = <String>{};
      for (final html in pages) {
        for (final item in _parseItems(html)) {
          if (seen.add(item.id)) merged.add(item);
        }
      }
      final needle = q.toLowerCase();
      items = [
        for (final item in merged)
          if ('${item.artist} ${item.title}'.toLowerCase().contains(needle))
            item,
      ];
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
      return Uri.parse(cached);
    }
    if (cached.isEmpty && hit.id.isEmpty) {
      throw StateError('mp3xa: нет ссылки на трек');
    }
    final page = cached.isNotEmpty
        ? cached
        : '$_origin/track/${hit.id}';
    final html = await _getText(Uri.parse(_absUrl(page)));
    final file = _extractPlayUrl(html);
    if (file.isEmpty) {
      throw StateError('mp3xa: нет data-url на странице');
    }
    return Uri.parse(file);
  }

  Future<_TrackItem?> _itemFromTrackPage(_Suggest suggest) async {
    try {
      final html = await _getText(Uri.parse(_absUrl(suggest.path)));
      final parsed = _parseItems(html);
      if (parsed.isNotEmpty) {
        final first = parsed.first;
        return _TrackItem(
          id: suggest.id.isNotEmpty ? suggest.id : first.id,
          title: first.title.isNotEmpty ? first.title : suggest.title,
          artist: first.artist.isNotEmpty ? first.artist : suggest.artist,
          fileUrl: first.fileUrl,
          pageUrl: _absUrl(suggest.path),
          duration: first.duration,
        );
      }
      final file = _extractPlayUrl(html);
      if (file.isEmpty) return null;
      return _TrackItem(
        id: suggest.id.isNotEmpty ? suggest.id : suggest.path,
        title: suggest.title,
        artist: suggest.artist,
        fileUrl: file,
        pageUrl: _absUrl(suggest.path),
        duration: null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<_Suggest>> _ajaxSearch(String query, {required String type}) async {
    final uri = Uri.parse('$_origin/').replace(
      queryParameters: {
        'do': 'search',
        'op': 'ajax_search',
        'type': type,
        'q': query,
      },
    );
    final raw = await _getText(uri);
    final b64 = _packerPayload(raw);
    if (b64.isEmpty) return const [];
    try {
      final pad = '=' * ((4 - b64.length % 4) % 4);
      final decoded = Uri.decodeComponent(
        utf8.decode(base64.decode('$b64$pad')),
      );
      final list = jsonDecode(decoded);
      if (list is! List) return const [];
      final out = <_Suggest>[];
      for (final row in list) {
        if (row is! Map) continue;
        final path = '${row['label'] ?? ''}'.trim();
        final value = _clean('${row['value'] ?? ''}');
        final id = '${row['id'] ?? ''}'.trim();
        if (path.isEmpty || value.isEmpty) continue;
        final parts = _splitArtistTitle(value);
        out.add(
          _Suggest(
            id: id,
            path: path,
            artist: parts.$1,
            title: parts.$2,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
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
        'mp3xa HTTP ${response.statusCode}',
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
      final fileUrl = _extractPlayUrl(body);
      if (fileUrl.isEmpty) continue;

      var artist = _cleanArtist(_artistRe.firstMatch(body)?.group(1) ?? '');
      var title = _clean(_titleRe.firstMatch(body)?.group(1) ?? '');
      if (title.isEmpty) {
        for (final m in _metaNameRe.allMatches(body)) {
          final t = _clean(m.group(1) ?? m.group(2) ?? m.group(3) ?? '');
          if (t.isNotEmpty && t != artist) {
            title = t;
            break;
          }
        }
      }
      if (title.isEmpty) continue;

      final id = (attrs['data-id'] ?? fileUrl).trim();
      if (!seen.add(id)) continue;

      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          fileUrl: fileUrl,
          pageUrl: '',
          duration: _parseDuration(
            _clean(_durationRe.firstMatch(body)?.group(1) ?? ''),
          ),
        ),
      );
    }
    return out;
  }

  static String _extractPlayUrl(String html) {
    final playTag = _playRe.firstMatch(html)?.group(1) ?? '';
    if (playTag.isEmpty) {
      // fallback: любой data-url на cdnproxy
      final m = RegExp(
        r'data-url="(https://cdnproxy\d*\.mp3xa\.me/[^"]+)"',
        caseSensitive: false,
      ).firstMatch(html);
      return (m?.group(1) ?? '').trim();
    }
    final attrs = <String, String>{};
    for (final a in _attrRe.allMatches(playTag)) {
      attrs[a.group(1)!.toLowerCase()] =
          (a.group(3) ?? a.group(4) ?? '').trim();
    }
    final hq = (attrs['data-url'] ?? '').trim();
    final lq = (attrs['data-url_lq'] ?? '').trim();
    final pick = hq.isNotEmpty ? hq : lq;
    return _looksLikeFileUrl(pick) ? pick : '';
  }

  static String _packerPayload(String raw) {
    final m = _packerKwRe.firstMatch(raw);
    if (m == null) return '';
    final kws = (m.group(1) ?? '')
        .replaceAll(r"\'", "'")
        .split('|');
    if (kws.isEmpty) return '';
    return kws.reduce((a, b) => a.length >= b.length ? a : b);
  }

  static bool _looksLikeTrackPath(String path) {
    final p = path.toLowerCase();
    if (p.contains('/singer/')) return false;
    return p.contains('.html') || p.contains('/track/');
  }

  static bool _looksLikeFileUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('cdnproxy') && lower.contains('mp3xa.me');
  }

  static String _slugify(String text) {
    return text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-');
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

  static String _absUrl(String raw) {
    final text = raw.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
    if (text.isEmpty) return '';
    if (text.startsWith('http://') || text.startsWith('https://')) return text;
    if (text.startsWith('//')) return 'https:$text';
    if (text.startsWith('/')) return '$_origin$text';
    return '$_origin/$text';
  }

  static String _cleanArtist(String raw) {
    // «MiyaGi & Эндшпиль» из нескольких ссылок.
    final names = <String>[];
    for (final m in _metaNameRe.allMatches(raw)) {
      final n = _clean(m.group(1) ?? m.group(2) ?? m.group(3) ?? '');
      if (n.isNotEmpty) names.add(n);
    }
    if (names.isNotEmpty) return names.join(' & ');
    return _clean(raw);
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

class _Suggest {
  const _Suggest({
    required this.id,
    required this.path,
    required this.artist,
    required this.title,
  });

  final String id;
  final String path;
  final String artist;
  final String title;
}

class _TrackItem {
  const _TrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.fileUrl,
    required this.pageUrl,
    required this.duration,
  });

  final String id;
  final String title;
  final String artist;
  final String fileUrl;
  final String pageUrl;
  final Duration? duration;
}
