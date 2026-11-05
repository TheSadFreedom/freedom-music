import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// muzofan.net — DLE-поиск `?do=search`, файл из `data-file` (dl2.muzofan.net).
///
/// Apex `muzofan.net` часто без DNS (NXDOMAIN), а `www` отдаёт 523.
/// Для HTML ходим на IP `www` с SNI/Host `muzofan.net`.
class MuzofanSource implements BrowserSource {
  MuzofanSource({HttpClient? client}) : _owned = client == null {
    _client = client ?? _buildClient();
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _origin = 'https://muzofan.net';

  static final _itemSplitRe = RegExp(
    r'<div\s+class="new-player track-item[^"]*"',
    caseSensitive: false,
  );
  static final _openTagRe = RegExp(
    r'^([^>]*)>',
    caseSensitive: false,
  );
  static final _attrRe = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  );
  static final _titleLinkRe = RegExp(
    r'class="track-title[^"]*"[^>]*>([\s\S]*?)</a>',
    caseSensitive: false,
  );
  static final _subtitleRe = RegExp(
    r'class="track-subtitle"[^>]*>([\s\S]*?)</div>',
    caseSensitive: false,
  );
  static final _timeRe = RegExp(
    r'class="track-time"[^>]*>([^<]+)<',
    caseSensitive: false,
  );
  static final _pageRe = RegExp(
    r'href="([^"]*/(\d+)-[^"]+\.html)"',
    caseSensitive: false,
  );
  static final _tagRe = RegExp(r'<[^>]+>');
  static final _wsRe = RegExp(r'\s+');

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'muzofan';

  @override
  String get name => 'Muzofan';

  @override
  String get referer => '$_origin/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  static HttpClient _buildClient() {
    final client = HttpClient()
      ..userAgent = _ua
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      return Future(() async {
        if (proxyHost != null) {
          return Socket.startConnect(proxyHost, proxyPort!);
        }
        final port =
            uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
        if (uri.host == 'muzofan.net' && uri.scheme == 'https') {
          return _connectMuzofan(port);
        }
        return Socket.startConnect(uri.host, port);
      });
    };
    return client;
  }

  static Future<ConnectionTask<Socket>> _connectMuzofan(int port) async {
    // Apex часто NXDOMAIN — не зовём startConnect(host), он таймаутится.
    try {
      final native = await InternetAddress.lookup('muzofan.net')
          .timeout(const Duration(seconds: 3));
      if (native.isNotEmpty) {
        return Socket.startConnect('muzofan.net', port);
      }
    } catch (_) {}

    final addrs = await InternetAddress.lookup('www.muzofan.net');
    final ip = addrs.firstWhere(
      (a) => a.type == InternetAddressType.IPv4,
      orElse: () => addrs.first,
    );
    final raw = await Socket.connect(ip, port);
    final secure = await SecureSocket.secure(raw, host: 'muzofan.net');
    return ConnectionTask.fromSocket(Future.value(secure), () {
      secure.destroy();
    });
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.parse('$_origin/').replace(
      queryParameters: {
        'do': 'search',
        'subaction': 'search',
        'story': q,
      },
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
          downloadUrl: item.fileUrl,
        ),
    ];
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    final cached = hit.downloadUrl?.trim() ?? '';
    if (_looksLikeFileUrl(cached)) {
      return Uri.parse(_absUrl(cached));
    }
    if (hit.id.isEmpty) {
      throw StateError('Muzofan: нет id трека');
    }
    throw StateError('Muzofan: нет ссылки на файл');
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
        'Muzofan HTTP ${response.statusCode}',
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
      final fileUrl = _absUrl(attrs['data-file'] ?? '');
      if (!_looksLikeFileUrl(fileUrl)) continue;

      final artist = _clean(
        attrs['data-artist'] ??
            (_subtitleRe.firstMatch(body)?.group(1) ?? ''),
      );
      var title = _clean(_titleLinkRe.firstMatch(body)?.group(1) ?? '');
      if (title.isEmpty) {
        final label = _clean(attrs['data-title'] ?? '');
        final partsLabel = _splitArtistTitle(label);
        title = partsLabel.$2;
      }
      if (title.isEmpty) continue;

      final pageMatch = _pageRe.firstMatch(body);
      final idFromPath = (pageMatch?.group(2) ?? '').trim();
      final id = idFromPath.isNotEmpty ? idFromPath : fileUrl;
      if (!seen.add(id)) continue;

      out.add(
        _TrackItem(
          id: id,
          title: title,
          artist: artist,
          fileUrl: fileUrl,
          duration: _parseDuration(_clean(_timeRe.firstMatch(body)?.group(1) ?? '')),
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
    return lower.contains('.mp3') || lower.contains('dl2.muzofan.net');
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
