import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// Muzofond.fm — поиск `/music/{query}`, файл из `li.play[data-url]`.
class MuzofondSource implements BrowserSource {
  MuzofondSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://muzofond.fm';

  static final _itemSplitRe = RegExp(
    r'<li\s+class="item"',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _playRe = RegExp(
    r'<li\s+class="play"[^>]*>',
    caseSensitive: false,
  );
  static final _artistRe = RegExp(
    r'<span\s+class="artist"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'<span\s+class="track"[^>]*>([\s\S]*?)</span>',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'muzofond';

  @override
  String get name => 'Muzofond';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.parse('$_origin/music/${Uri.encodeComponent(q)}');
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
    if (hit.id.isEmpty) {
      throw StateError('Muzofond: нет id трека');
    }
    // Обновляем со страницы трека, если есть.
    final page = Uri.parse('$_origin/track/${hit.id}');
    try {
      final html = await _getText(page);
      final items = _parseItems(html);
      for (final item in items) {
        if (item.id == hit.id && item.fileUrl.isNotEmpty) {
          return Uri.parse(item.fileUrl);
        }
      }
      if (items.isNotEmpty && items.first.fileUrl.isNotEmpty) {
        return Uri.parse(items.first.fileUrl);
      }
    } catch (_) {
      // Ниже — ошибка без кэша.
    }
    throw StateError('Muzofond: нет ссылки на файл');
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
        'Muzofond HTTP ${response.statusCode}',
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
    // parts[0] — преамбула до первого item.
    for (var i = 1; i < parts.length; i++) {
      final chunk = parts[i];
      final gt = chunk.indexOf('>');
      if (gt < 0) continue;
      final openAttrs = chunk.substring(0, gt);
      final body = chunk.substring(gt + 1);

      final attrs = <String, String>{};
      for (final a in _attrRe.allMatches(openAttrs)) {
        final name = a.group(1)!.toLowerCase();
        final value = (a.group(3) ?? a.group(4) ?? '').trim();
        attrs[name] = value;
      }
      final id = (attrs['data-id'] ?? '').trim();
      if (id.isEmpty || !seen.add(id)) continue;

      final playTag = _playRe.firstMatch(body)?.group(0) ?? '';
      final playAttrs = <String, String>{};
      for (final a in _attrRe.allMatches(playTag)) {
        final name = a.group(1)!.toLowerCase();
        final value = (a.group(3) ?? a.group(4) ?? '').trim();
        playAttrs[name] = value;
      }
      final fileUrl = (playAttrs['data-url'] ?? '').trim();
      if (fileUrl.isEmpty) continue;

      final title = _clean(_titleRe.firstMatch(body)?.group(1) ?? '');
      if (title.isEmpty) continue;
      final artist = _clean(_artistRe.firstMatch(body)?.group(1) ?? '');

      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          duration: _parseDurationSec(attrs['data-duration'] ?? ''),
          fileUrl: fileUrl,
        ),
      );
    }
    return out;
  }

  static bool _looksLikeFileUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('muzofond.fm/') ||
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
        .replaceAll('&mdash;', '—')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    return text.replaceAll(_wsRe, ' ').trim();
  }

  static Duration? _parseDurationSec(String raw) {
    final sec = int.tryParse(raw.trim());
    if (sec == null || sec <= 0) return null;
    return Duration(seconds: sec);
  }
}

class _TrackItem {
  const _TrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.fileUrl,
  });

  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String fileUrl;
}
