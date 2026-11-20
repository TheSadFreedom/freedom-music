import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'network_util.dart';

/// Scrapes Yandex Music artist HTML (no api.music.yandex.net).
///
/// The main artist page marks «Новый релиз» as lazy-loaded. The same release
/// is embedded in `/artist/{id}/albums` as `preloadedAlbums.albums[0]`.
class YmClient {
  YmClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static final _artistIdRe = RegExp(
    r'(?:https?://)?(?:music\.)?yandex\.(?:ru|com|kz|by|uz)/artist/(\d+)',
    caseSensitive: false,
  );

  static String? parseArtistId(String input) {
    final m = _artistIdRe.firstMatch(input.trim());
    return m?.group(1);
  }

  static String artistUrl(String artistId) =>
      'https://music.yandex.ru/artist/$artistId';

  Future<LatestRelease> fetchLatestRelease(String rawUrl) async {
    final artistId = parseArtistId(rawUrl);
    if (artistId == null) {
      throw StateError('Нужна ссылка вида music.yandex.ru/artist/…');
    }

    final albumsHtml = await _getHtml(artistUrl(artistId) + '/albums');
    final album = _parsePreloadedFirstAlbum(albumsHtml);
    if (album == null) {
      throw StateError('На странице нет блока с последним релизом');
    }

    final artists = album['artists'];
    final names = <String>[];
    if (artists is List) {
      for (final item in artists) {
        if (item is! Map) continue;
        final name = '${item['name'] ?? ''}'.trim();
        if (name.isEmpty) continue;
        if (!names.any((n) => n.toLowerCase() == name.toLowerCase())) {
          names.add(name);
        }
      }
    }
    var artistName = names.join(', ');
    if (artistName.isEmpty) {
      artistName = _ogTitle(albumsHtml) ?? 'Артист $artistId';
    }

    final title = '${album['title'] ?? ''}'.trim();
    if (title.isEmpty) {
      throw StateError('Не удалось прочитать название релиза');
    }

    final typeRaw = '${album['type'] ?? ''}'.trim().toLowerCase();
    final typeLabel = _typeLabel(typeRaw);
    final releaseIso = '${album['releaseDate'] ?? ''}'.trim();
    final dateLabel = _dateLabel(releaseIso);
    final releaseDateMs = DateTime.tryParse(releaseIso)?.toUtc().millisecondsSinceEpoch ?? 0;
    final coverUrl = _coverUrl('${album['coverUri'] ?? album['ogImage'] ?? ''}');
    final albumId = '${album['id'] ?? ''}'.trim();
    final releaseUrl = albumId.isEmpty
        ? null
        : 'https://music.yandex.ru/album/$albumId';

    return LatestRelease(
      source: ReleaseSource.yandex,
      artistId: artistId,
      artistName: artistName,
      artistUrl: artistUrl(artistId),
      title: title,
      typeLabel: typeLabel,
      dateLabel: dateLabel,
      releaseDateMs: releaseDateMs,
      coverUrl: coverUrl,
      releaseUrl: releaseUrl,
    );
  }

  Future<String> _getHtml(String url) async {
    return withNetworkRetry(() async {
      final response = await _http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _ua,
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'ru-RU,ru;q=0.9,en;q=0.8',
        },
      );
      if (response.statusCode == 404) {
        throw StateError('Артист не найден');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Страница недоступна (${response.statusCode})');
      }
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    });
  }

  Map<String, dynamic>? _parsePreloadedFirstAlbum(String html) {
    const marker = 'preloadedAlbums';
    final markerIdx = html.indexOf(marker);
    if (markerIdx < 0) return null;

    final albumsKey = html.indexOf('albums', markerIdx);
    if (albumsKey < 0) return null;
    final arrayStart = html.indexOf('[', albumsKey);
    if (arrayStart < 0) return null;

    final firstObjStart = html.indexOf('{', arrayStart);
    if (firstObjStart < 0) return null;

    final escapedObj = _extractBalancedObject(html, firstObjStart);
    if (escapedObj == null) return null;

    final jsonText = _unescapeJsonString(escapedObj);
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  /// [start] points at `{` of an object that may use `\"` escapes.
  String? _extractBalancedObject(String source, int start) {
    if (start < 0 || start >= source.length || source[start] != '{') {
      return null;
    }
    var depth = 0;
    var i = start;
    while (i < source.length) {
      final ch = source[i];
      if (ch == '\\' && i + 1 < source.length) {
        i += 2;
        continue;
      }
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          return source.substring(start, i + 1);
        }
      }
      i++;
    }
    return null;
  }

  String _unescapeJsonString(String escaped) {
    // Fragment lives inside a JS/JSON string: quotes are \", slashes \\/
    final buf = StringBuffer();
    for (var i = 0; i < escaped.length; i++) {
      final ch = escaped[i];
      if (ch == '\\' && i + 1 < escaped.length) {
        final next = escaped[i + 1];
        switch (next) {
          case '"':
            buf.write('"');
            i++;
            break;
          case '\\':
            buf.write('\\');
            i++;
            break;
          case '/':
            buf.write('/');
            i++;
            break;
          case 'n':
            buf.write('\n');
            i++;
            break;
          case 'r':
            buf.write('\r');
            i++;
            break;
          case 't':
            buf.write('\t');
            i++;
            break;
          case 'u':
            if (i + 5 < escaped.length) {
              final hex = escaped.substring(i + 2, i + 6);
              final code = int.tryParse(hex, radix: 16);
              if (code != null) {
                buf.writeCharCode(code);
                i += 5;
                break;
              }
            }
            buf.write(ch);
            break;
          default:
            buf.write(ch);
        }
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  String? _ogTitle(String html) {
    final m = RegExp(
      r'property="og:title"\s+content="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    final raw = m?.group(1)?.trim();
    if (raw == null || raw.isEmpty) return null;
    // "Zivert — слушать…" → Zivert
    final cut = raw.split(RegExp(r'\s+[—\-–]\s+')).first.trim();
    return cut.isEmpty ? raw : cut;
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'single':
        return 'Сингл';
      case 'ep':
        return 'EP';
      case 'compilation':
        return 'Сборник';
      case 'podcast':
        return 'Подкаст';
      default:
        return type.isEmpty ? 'Релиз' : 'Альбом';
    }
  }

  String _dateLabel(String iso) {
    final trimmed = iso.trim();
    if (trimmed.isEmpty) return '';
    final dt = DateTime.tryParse(trimmed);
    if (dt == null) return trimmed;
    const months = <String>[
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    final local = dt.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year} г.';
  }

  String _coverUrl(String uri) {
    var u = uri.trim();
    if (u.isEmpty) return '';
    u = u.replaceAll(r'\/', '/');
    if (u.contains('%%')) {
      u = u.replaceAll('%%', '400x400');
    }
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    return 'https://$u';
  }

  void close() => _http.close();
}
