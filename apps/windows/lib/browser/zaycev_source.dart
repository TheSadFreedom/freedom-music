import 'dart:convert';
import 'dart:io';

import 'browser_hit.dart';
import 'browser_source.dart';

/// Zaycev.net — поиск и скачивание через публичный `/api/external`.
class ZaycevSource implements BrowserSource {
  ZaycevSource({HttpClient? client}) : _owned = client == null {
    _client = client ??
        (HttpClient()
          ..userAgent = _ua
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 30));
  }

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _api = 'https://zaycev.net/api/external';

  final bool _owned;
  late final HttpClient _client;

  @override
  String get id => 'zaycev';

  @override
  String get name => 'Zaycev.net';

  @override
  String get referer => 'https://zaycev.net/';

  void close() {
    if (_owned) _client.close(force: true);
  }

  @override
  Future<List<BrowserHit>> search(String query, {int limit = 30}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final pageSize = limit.clamp(1, 50);
    final uri = Uri.parse('$_api/pages/search/tracks').replace(
      queryParameters: {
        'q': q,
        'page': '1',
        'limit': '$pageSize',
      },
    );
    final body = await _getJson(uri);
    final ids = body['trackIds'];
    final info = _asMap(body['tracksInfo']) ?? const <String, dynamic>{};
    if (ids is! List || ids.isEmpty) return const [];

    final idList = <int>[];
    for (final raw in ids) {
      final id = raw is int ? raw : int.tryParse('$raw');
      if (id != null) idList.add(id);
    }
    final meta = await _filezmeta(idList);

    final hits = <BrowserHit>[];
    for (final id in idList) {
      final row = _asMap(info['$id']);
      if (row == null) continue;
      final title = _clean('${row['track'] ?? ''}');
      if (title.isEmpty) continue;
      final artist = _clean('${row['artistName'] ?? ''}');
      final hashes = meta[id];
      final downloadHash = hashes?.download ?? '';
      final streamHash = hashes?.streaming ?? '';
      // Многие современные треки без «открытой загрузки», но stream URL
      // отдаёт тот же mp3 — его и скачиваем в библиотеку.
      final token = downloadHash.isNotEmpty
          ? 'd:$downloadHash'
          : (streamHash.isNotEmpty ? 'p:$streamHash' : '');
      if (token.isEmpty) continue;
      final viaStream = token.startsWith('p:');
      hits.add(
        BrowserHit(
          sourceId: this.id,
          id: '$id',
          title: title,
          artist: artist.isEmpty ? 'Unknown' : artist,
          subtitle: [
            if (_bitrateLabel(row['bitrate']) != null) _bitrateLabel(row['bitrate'])!,
            if (viaStream) 'stream',
          ].join(' · '),
          duration: _parseDuration('${row['duration'] ?? ''}'),
          license: null,
          downloadUrl: token,
        ),
      );
    }
    return hits;
  }

  @override
  Future<Uri> resolveDownload(BrowserHit hit) async {
    var token = hit.downloadUrl?.trim() ?? '';
    if (token.isEmpty) {
      final id = int.tryParse(hit.id);
      if (id == null) {
        throw StateError('Zaycev.net: некорректный id трека');
      }
      final meta = await _filezmeta([id]);
      final row = meta[id];
      if (row == null) {
        throw StateError('Zaycev.net: нет ссылки на файл');
      }
      token = row.download.isNotEmpty
          ? 'd:${row.download}'
          : (row.streaming.isNotEmpty ? 'p:${row.streaming}' : '');
    }

    if (token.startsWith('d:')) {
      return _urlFromDownloadHash(token.substring(2));
    }
    if (token.startsWith('p:')) {
      return _urlFromPlayHash(token.substring(2));
    }
    // Старый формат без префикса — пробуем как download hash.
    try {
      return await _urlFromDownloadHash(token);
    } catch (_) {
      return _urlFromPlayHash(token);
    }
  }

  Future<Uri> _urlFromDownloadHash(String hash) async {
    if (hash.isEmpty) {
      throw StateError('Zaycev.net: пустой download hash');
    }
    final text =
        (await _getText(Uri.parse('$_api/track/download/$hash'))).trim();
    if (text.isEmpty) {
      throw StateError('Zaycev.net: пустой ответ download');
    }
    if (text.startsWith('{')) {
      final map = _asMap(jsonDecode(text));
      final url = '${map?['url'] ?? ''}'.trim();
      if (url.isEmpty) {
        throw StateError('Zaycev.net: нет url в ответе download');
      }
      return Uri.parse(url);
    }
    if (!text.startsWith('http')) {
      throw StateError('Zaycev.net: неожиданный ответ download');
    }
    return Uri.parse(text);
  }

  Future<Uri> _urlFromPlayHash(String hash) async {
    if (hash.isEmpty) {
      throw StateError('Zaycev.net: пустой play hash');
    }
    final body = await _getJson(Uri.parse('$_api/track/play/$hash'));
    final url = '${body['url'] ?? ''}'.trim();
    if (url.isEmpty || !url.startsWith('http')) {
      throw StateError('Zaycev.net: нет url в ответе play');
    }
    return Uri.parse(url);
  }

  Future<Map<int, ({String streaming, String download})>> _filezmeta(
    List<int> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final uri = Uri.parse('$_api/track/filezmeta');
    final body = await _postJson(uri, {
      'trackIds': ids,
      'subscription': false,
    });
    final tracks = body['tracks'];
    final out = <int, ({String streaming, String download})>{};
    if (tracks is! List) return out;
    for (final raw in tracks) {
      final map = _asMap(raw);
      if (map == null) continue;
      final id = map['id'];
      final trackId = id is int ? id : int.tryParse('$id');
      if (trackId == null) continue;
      out[trackId] = (
        streaming: _token(map['streaming']),
        download: _token(map['download']),
      );
    }
    return out;
  }

  /// filezmeta часто отдаёт `download: false` (bool), а не hash.
  static String _token(dynamic value) {
    if (value == null || value is bool) return '';
    final text = '$value'.trim();
    if (text.isEmpty || text == 'false' || text == 'true') return '';
    if (!RegExp(r'^[a-fA-F0-9]{8,}$').hasMatch(text)) return '';
    return text;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final text = await _getText(uri);
    final decoded = jsonDecode(text);
    final map = _asMap(decoded);
    if (map == null) throw StateError('Zaycev.net: неожиданный JSON');
    return map;
  }

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    Map<String, Object?> payload,
  ) async {
    final request = await _client.postUrl(uri);
    _applyHeaders(request);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Zaycev.net HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final decoded = jsonDecode(text);
    final map = _asMap(decoded);
    if (map == null) throw StateError('Zaycev.net: неожиданный JSON');
    return map;
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
        'Zaycev.net HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    return text;
  }

  void _applyHeaders(HttpClientRequest request) {
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json, */*');
    request.headers.set(HttpHeaders.refererHeader, referer);
    request.headers.set('Origin', 'https://zaycev.net');
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String _clean(String raw) {
    return raw
        .replaceAll('\u0000', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String? _bitrateLabel(dynamic bitrate) {
    if (bitrate is num && bitrate > 0) return '${bitrate.round()} kbps';
    final parsed = int.tryParse('$bitrate');
    if (parsed != null && parsed > 0) return '$parsed kbps';
    return null;
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
