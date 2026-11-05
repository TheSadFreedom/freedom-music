import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// zvuch.re / wwv.zvuch.com — поиск `/search?q=`, файл из `li.play[data-url]`.
class ZvuchSource implements BrowserSource, BrowserFeaturedSource {
  ZvuchSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  /// Форма на zvuch.re ведёт сюда; сам .re поиск не роутит.
  static const _origin = 'https://wwv.zvuch.com';

  static final _itemRe = RegExp(
    r'<li([^>]*\bclass="item"[^>]*\bdata-artist=[^>]*)>',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _playRe = RegExp(
    r'<li([^>]*\bclass="[^"]*\bplay\b[^"]*"[^>]*)>',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');
  static final _artistHrefRe = RegExp(
    r'href="(/artists/[^"#?]+)"',
    caseSensitive: false,
  );
  static final _mainSongsArtistRe = RegExp(
    r'class="[^"]*\bmainSongs\b[^"]*"[^>]*\bdata-url="(https?://[^"]+/artists/[^"]+|/artists/[^"]+)"',
    caseSensitive: false,
  );

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'zvuch';

  @override
  String get name => 'Zvuch';

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
    var items = _rankByQuery(_parseItems(html), q);
    // На выдаче сверху виджеты; релевантные часто в карточке артиста.
    if (items.isEmpty || !_looksRelevant(items.first, q)) {
      final artistPath = _firstArtistPath(html);
      if (artistPath != null) {
        final artistHtml = await _getText(Uri.parse('$_origin$artistPath'));
        final fromArtist = _rankByQuery(_parseItems(artistHtml), q);
        if (fromArtist.isNotEmpty) {
          items = fromArtist;
        }
      }
    }
    return _toHits(items, limit.clamp(1, 50));
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
    throw StateError('Zvuch: нет ссылки на файл');
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
        'Zvuch HTTP ${response.statusCode}',
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
    final matches = _itemRe.allMatches(html).toList();
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final open = m.group(1) ?? '';
      final end = i + 1 < matches.length ? matches[i + 1].start : html.length;
      final body = html.substring(m.start, end);

      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(open)) {
        attrs[a.group(1)!.toLowerCase()] =
            (a.group(3) ?? a.group(4) ?? '').trim();
      }

      final title = _clean(attrs['data-title'] ?? '');
      final artist = _clean(attrs['data-artist'] ?? '');
      if (title.isEmpty) continue;

      final playTag = _playRe.firstMatch(body)?.group(1) ?? '';
      final playAttrs = <String, String>{};
      for (final a in _attrRe.allMatches(playTag)) {
        playAttrs[a.group(1)!.toLowerCase()] =
            (a.group(3) ?? a.group(4) ?? '').trim();
      }
      final fileUrl = (playAttrs['data-url'] ?? '').trim();
      if (!_looksLikeFileUrl(fileUrl)) continue;

      final id = (attrs['data-id'] ?? playAttrs['data-id'] ?? fileUrl).trim();
      if (!seen.add(id)) continue;

      final durSec = int.tryParse((attrs['data-duration'] ?? '').trim());
      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          fileUrl: fileUrl,
          duration: durSec == null ? null : Duration(seconds: durSec),
        ),
      );
    }
    return out;
  }

  /// Виджеты на странице поиска идут первыми — поднимаем совпадения по запросу.
  static List<_TrackItem> _rankByQuery(List<_TrackItem> items, String query) {
    final tokens = _queryTokens(query);
    if (items.isEmpty || tokens.isEmpty) return items;
    final scored = <({int score, _TrackItem item})>[
      for (final item in items) (score: _score(item, tokens), item: item),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final matched = [
      for (final e in scored)
        if (e.score > 0) e.item,
    ];
    return matched.isNotEmpty ? matched : items;
  }

  static bool _looksRelevant(_TrackItem item, String query) {
    return _score(item, _queryTokens(query)) > 0;
  }

  static List<String> _queryTokens(String query) {
    return [
      for (final t in query.toLowerCase().split(RegExp(r'\s+')))
        if (t.length >= 2) t,
    ];
  }

  static int _score(_TrackItem item, List<String> tokens) {
    if (tokens.isEmpty) return 0;
    final artist = item.artist.toLowerCase();
    final title = item.title.toLowerCase();
    final hay = '$artist $title';
    var score = 0;
    for (final t in tokens) {
      if (artist.contains(t)) score += 3;
      if (title.contains(t)) score += 2;
      if (!artist.contains(t) && !title.contains(t) && hay.contains(t)) {
        score += 1;
      }
    }
    return score;
  }

  static String? _firstArtistPath(String html) {
    final main = _mainSongsArtistRe.firstMatch(html)?.group(1)?.trim();
    if (main != null && main.isNotEmpty) {
      final uri = Uri.tryParse(main);
      if (uri != null && uri.path.startsWith('/artists/')) {
        return uri.path;
      }
      if (main.startsWith('/artists/')) return main;
    }
    final m = _artistHrefRe.firstMatch(html);
    final path = m?.group(1)?.trim();
    if (path == null || path.isEmpty) return null;
    return path;
  }

  static bool _looksLikeFileUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('zvuch.com/') ||
        lower.contains('.mp3') ||
        lower.contains('mp3poisk');
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
