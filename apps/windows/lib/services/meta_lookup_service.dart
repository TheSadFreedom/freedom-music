import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/track_key.dart';
import 'genius_service.dart';

/// Looks up album / year / genre / track numbers online (iTunes, then Deezer).
class OnlineMetaHit {
  const OnlineMetaHit({
    this.album,
    this.albumArtist,
    this.year,
    this.genre,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.producer,
    this.lyrics,
    this.coverUrl,
    this.source = '',
  });

  final String? album;
  final String? albumArtist;
  final int? year;
  final String? genre;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final String? producer;
  final String? lyrics;
  final String? coverUrl;
  final String source;
}

class MetaLookupService {
  MetaLookupService({GeniusService? genius}) : _genius = genius ?? GeniusService();

  final GeniusService _genius;

  static const _ua = 'FreedomMusic/1.0 (local; metadata autofill)';

  HttpClient? _client;

  HttpClient get _http {
    return _client ??= HttpClient()..userAgent = _ua;
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }

  /// True while album, album artist, year, track number, or track total
  /// is still missing. Producer is filled when found, but its absence
  /// does not keep the track in «Без метаданных».
  static bool needsFill({
    required String album,
    String? albumArtist,
    int? year,
    int? trackNumber,
    int? trackTotal,
  }) {
    return _albumMissing(album) ||
        albumArtistMissing(albumArtist) ||
        _yearMissing(year) ||
        trackNumber == null ||
        trackNumber < 1 ||
        trackTotal == null ||
        trackTotal < 1;
  }

  /// Names of the fields [needsFill] still treats as empty.
  static List<String> missingFieldNames({
    required String album,
    String? albumArtist,
    int? year,
    int? trackNumber,
    int? trackTotal,
  }) {
    return [
      if (_albumMissing(album)) 'альбом',
      if (albumArtistMissing(albumArtist)) 'артист альбома',
      if (_yearMissing(year)) 'год',
      if (trackNumber == null || trackNumber < 1) 'номер',
      if (trackTotal == null || trackTotal < 1) 'число треков',
    ];
  }

  static bool albumArtistMissing(String? albumArtist) {
    final a = albumArtist?.trim().toLowerCase() ?? '';
    return a.isEmpty || a == 'unknown';
  }

  static bool _albumMissing(String album) {
    final a = album.trim().toLowerCase();
    return a.isEmpty ||
        a == 'unknown' ||
        a == 'мне нравится' ||
        a == 'мне нужен ui';
  }

  static bool _yearMissing(int? year) => year == null || year < 1000;

  static String cleanAlbum(String name) {
    var s = name.trim();
    s = s.replaceAll(
      RegExp(r'\s*[-–—]\s*(single|ep|maxi[\s-]?single|album)\s*$',
          caseSensitive: false),
      '',
    );
    s = s.replaceAll(
      RegExp(r'\s*\((single|ep)\)\s*$', caseSensitive: false),
      '',
    );
    return s.trim().replaceAll(RegExp(r'^[\s\-–—]+|[\s\-–—]+$'), '');
  }

  Future<OnlineMetaHit?> lookup({
    required String artist,
    required String title,
    String? note,
  }) async {
    final a = artist.trim();
    final t = title.trim();
    final label = _noteText(note);
    if (a.isEmpty || t.isEmpty || a.toLowerCase() == 'unknown') return null;

    final genius = await _fromGenius(a, t, note: label);
    if (genius != null) {
      // Genius редко отдаёт обложку — добираем URL с iTunes/Deezer.
      if (genius.coverUrl != null && genius.coverUrl!.isNotEmpty) {
        return genius;
      }
      final cover = await _coverUrlOnly(a, t, note: label);
      if (cover == null) return genius;
      return OnlineMetaHit(
        album: genius.album,
        albumArtist: genius.albumArtist,
        year: genius.year,
        genre: genius.genre,
        trackNumber: genius.trackNumber,
        trackTotal: genius.trackTotal,
        discNumber: genius.discNumber,
        producer: genius.producer,
        lyrics: genius.lyrics,
        coverUrl: cover,
        source: genius.source,
      );
    }
    final itunes = await _itunes(a, t, note: label);
    if (itunes != null) return itunes;
    return _deezer(a, t, note: label);
  }

  Future<String?> _coverUrlOnly(
    String artist,
    String title, {
    String? note,
  }) async {
    final itunes = await _itunes(artist, title, note: note);
    final fromItunes = itunes?.coverUrl?.trim();
    if (fromItunes != null && fromItunes.isNotEmpty) return fromItunes;
    final deezer = await _deezer(artist, title, note: note);
    final fromDeezer = deezer?.coverUrl?.trim();
    if (fromDeezer != null && fromDeezer.isNotEmpty) return fromDeezer;
    return null;
  }

  String? _noteText(String? note) {
    final raw = note?.trim() ?? '';
    if (raw.isEmpty || isBlankMeta(raw)) return null;
    return raw;
  }

  bool _hasNote(String found, String note) {
    final label = _norm(note);
    if (label.isEmpty) return true;
    return _norm(found).contains(label);
  }

  Future<OnlineMetaHit?> _fromGenius(
    String artist,
    String title, {
    String? note,
  }) async {
    final hit = await _genius.lookup(
      artist: artist,
      title: title,
      note: note,
    );
    if (hit == null) return null;
    final lyrics = hit.lyrics?.trim();
    final coverUrl = hit.coverUrl?.trim();
    final album = hit.album?.trim();
    if (album == null || album.isEmpty) {
      // No album block on the song page: this is a single.
      return OnlineMetaHit(
        album: title.trim(),
        albumArtist: artist.trim(),
        year: hit.year,
        genre: hit.genre,
        trackNumber: 1,
        trackTotal: 1,
        discNumber: 1,
        producer: hit.producer,
        lyrics: lyrics,
        coverUrl: coverUrl,
        source: 'genius',
      );
    }
    if (!hit.hasMeta &&
        (lyrics == null || lyrics.isEmpty) &&
        (coverUrl == null || coverUrl.isEmpty)) {
      return null;
    }
    return OnlineMetaHit(
      album: hit.album,
      albumArtist: hit.albumArtist,
      year: hit.year,
      genre: hit.genre,
      trackNumber: hit.trackNumber,
      trackTotal: hit.trackTotal,
      discNumber: hit.discNumber,
      producer: hit.producer,
      lyrics: hit.lyrics,
      coverUrl: coverUrl,
      source: 'genius',
    );
  }

  String _primaryArtist(String artist) {
    final parts = splitArtists(artist);
    return parts.isEmpty ? artist.trim() : parts.first;
  }

  String _norm(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _titleClose(String a, String b) {
    final na = _norm(a);
    final nb = _norm(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    if (na.length >= 8 && (na.contains(nb) || nb.contains(na))) return true;
    return false;
  }

  bool _artistClose(String wanted, String found) {
    final nw = _norm(_primaryArtist(wanted));
    final nf = _norm(found);
    if (nw.isEmpty || nf.isEmpty) return false;
    if (nw == nf || nw.contains(nf) || nf.contains(nw)) return true;
    final wa = nw.replaceAll(RegExp(r'\W'), '');
    final fa = nf.replaceAll(RegExp(r'\W'), '');
    return wa.length >= 4 && (wa.contains(fa) || fa.contains(wa));
  }

  Future<Map<String, dynamic>?> _getJson(
    Uri uri, {
    Duration delay = const Duration(milliseconds: 350),
  }) async {
    await Future<void>.delayed(delay);
    try {
      final req = await _http.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<OnlineMetaHit?> _itunes(
    String artist,
    String title, {
    String? note,
  }) async {
    final primary = _primaryArtist(artist);
    final term = note == null ? '$primary $title' : '$primary - $title $note';
    for (final country in ['ru', 'us']) {
      final uri = Uri.https('itunes.apple.com', '/search', {
        'term': term,
        'media': 'music',
        'entity': 'song',
        'limit': '12',
        'country': country,
      });
      final data = await _getJson(uri);
      final results = data?['results'];
      if (results is! List || results.isEmpty) continue;

      for (final raw in results) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        final trackName = '${map['trackName'] ?? ''}';
        final artistName = '${map['artistName'] ?? ''}';
        if (!_titleClose(title, trackName)) continue;
        if (!_artistClose(artist, artistName)) continue;
        if (note != null && !_hasNote(trackName, note)) continue;

        final album = cleanAlbum('${map['collectionName'] ?? ''}');
        final date = '${map['releaseDate'] ?? ''}';
        final yearMatch = RegExp(r'(19|20)\d{2}').firstMatch(date);
        final year = yearMatch != null ? int.tryParse(yearMatch.group(0)!) : null;
        final genre = '${map['primaryGenreName'] ?? ''}'.trim();
        final trackNumber = _asPositiveInt(map['trackNumber']);
        final trackTotal = _asPositiveInt(map['trackCount']);
        final discNumber = _asPositiveInt(map['discNumber']);
        final coverUrl = _itunesCoverUrl('${map['artworkUrl100'] ?? ''}');
        if (album.isEmpty &&
            year == null &&
            genre.isEmpty &&
            trackNumber == null &&
            coverUrl == null) {
          continue;
        }
        return OnlineMetaHit(
          album: album.isEmpty ? null : album,
          albumArtist: _cleanName('${map['collectionArtistName'] ?? ''}'),
          year: year,
          genre: genre.isEmpty ? null : genre,
          trackNumber: trackNumber,
          trackTotal: trackTotal,
          discNumber: discNumber,
          coverUrl: coverUrl,
          source: 'itunes',
        );
      }
    }
    return null;
  }

  static String? _cleanName(String raw) {
    final name = raw.trim();
    if (name.isEmpty || name.toLowerCase() == 'unknown') return null;
    return name;
  }

  static String? _itunesCoverUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return null;
    // 100x100bb → более крупный квадрат.
    return url.replaceAll(
      RegExp(r'\d+x\d+bb'),
      '600x600bb',
    );
  }

  static String? _deezerCoverUrl(Map album) {
    for (final key in ['cover_xl', 'cover_big', 'cover_medium', 'cover']) {
      final value = '${album[key] ?? ''}'.trim();
      if (value.startsWith('http')) return value;
    }
    return null;
  }

  /// Скачивает обложку по URL (для редактора / автозаполнения).
  Future<({Uint8List bytes, String mime})?> fetchCoverBytes(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    try {
      final uri = Uri.parse(trimmed);
      final req = await _http.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      req.headers.set(HttpHeaders.acceptHeader, 'image/*,*/*');
      final res = await req.close().timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
        if (builder.length > 8 << 20) {
          await res.drain<void>();
          return null;
        }
      }
      final bytes = builder.takeBytes();
      if (bytes.length < 256) return null;
      final contentType =
          res.headers.contentType?.mimeType.trim().toLowerCase() ?? '';
      final mime = switch (contentType) {
        'image/png' || 'image/webp' || 'image/jpeg' || 'image/jpg' =>
          contentType == 'image/jpg' ? 'image/jpeg' : contentType,
        _ => _mimeFromBytes(bytes) ?? 'image/jpeg',
      };
      return (bytes: bytes, mime: mime);
    } catch (_) {
      return null;
    }
  }

  static String? _mimeFromBytes(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  int? _asPositiveInt(Object? v) {
    if (v is int) return v > 0 ? v : null;
    if (v is num) {
      final i = v.toInt();
      return i > 0 ? i : null;
    }
    if (v is String) {
      final i = int.tryParse(v.trim());
      if (i != null && i > 0) return i;
    }
    return null;
  }

  Future<OnlineMetaHit?> _deezer(
    String artist,
    String title, {
    String? note,
  }) async {
    final primary = _primaryArtist(artist);
    final trackQuery = note == null ? title : '$title $note';
    final q = 'artist:"$primary" track:"$trackQuery"';
    final searchUri = Uri.https('api.deezer.com', '/search', {
      'q': q,
      'limit': '10',
    });
    var data = await _getJson(searchUri);
    var list = data?['data'];
    if (list is! List || list.isEmpty) {
      final q2 = note == null ? '$primary $title' : '$primary - $title $note';
      data = await _getJson(
        Uri.https('api.deezer.com', '/search', {'q': q2, 'limit': '10'}),
      );
      list = data?['data'];
    }
    if (list is! List || list.isEmpty) return null;

    for (final raw in list) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final trackTitle = '${map['title'] ?? ''}';
      final art = map['artist'];
      final artName = art is Map ? '${art['name'] ?? ''}' : '';
      if (!_titleClose(title, trackTitle)) continue;
      if (!_artistClose(artist, artName)) continue;
      if (note != null && !_hasNote(trackTitle, note)) continue;

      var album = '';
      String? coverUrl;
      final alb = map['album'];
      if (alb is Map) {
        album = cleanAlbum('${alb['title'] ?? ''}');
        coverUrl = _deezerCoverUrl(alb);
      }

      String? albumArtist;
      int? year;
      String? genre;
      int? trackNumber = _asPositiveInt(map['track_position']);
      int? trackTotal = _asPositiveInt(map['track_total'] ?? map['nb_tracks']);
      int? discNumber = _asPositiveInt(map['disk_number']);
      final id = map['id'];
      if (id != null) {
        final detail = await _getJson(Uri.https('api.deezer.com', '/track/$id'));
        if (detail != null) {
          final rd = '${detail['release_date'] ?? ''}';
          final ym = RegExp(r'(19|20)\d{2}').firstMatch(rd);
          if (ym != null) year = int.tryParse(ym.group(0)!);
          trackNumber ??= _asPositiveInt(detail['track_position']);
          discNumber ??= _asPositiveInt(detail['disk_number']);
          final dalb = detail['album'];
          if (dalb is Map) {
            coverUrl ??= _deezerCoverUrl(dalb);
          }
          final albId = dalb is Map ? dalb['id'] : null;
          if (albId != null) {
            final albumJson =
                await _getJson(Uri.https('api.deezer.com', '/album/$albId'));
            if (albumJson != null) {
              if (album.isEmpty) {
                album = cleanAlbum('${albumJson['title'] ?? ''}');
              }
              coverUrl ??= _deezerCoverUrl(albumJson);
              if (year == null) {
                final ard = '${albumJson['release_date'] ?? ''}';
                final aym = RegExp(r'(19|20)\d{2}').firstMatch(ard);
                if (aym != null) year = int.tryParse(aym.group(0)!);
              }
              trackTotal ??= _asPositiveInt(albumJson['nb_tracks']);
              final albumArt = albumJson['artist'];
              if (albumArt is Map) {
                albumArtist ??= _cleanName('${albumArt['name'] ?? ''}');
              }
              final genres = albumJson['genres'];
              if (genres is Map && genres['data'] is List) {
                final gList = genres['data'] as List;
                if (gList.isNotEmpty && gList.first is Map) {
                  genre = '${(gList.first as Map)['name'] ?? ''}'.trim();
                  if (genre.isEmpty) genre = null;
                }
              }
            }
          }
        }
      }

      if (album.isEmpty &&
          year == null &&
          genre == null &&
          trackNumber == null &&
          (coverUrl == null || coverUrl.isEmpty)) {
        continue;
      }
      return OnlineMetaHit(
        album: album.isEmpty ? null : album,
        albumArtist: albumArtist,
        year: year,
        genre: genre,
        trackNumber: trackNumber,
        trackTotal: trackTotal,
        discNumber: discNumber,
        coverUrl: coverUrl,
        source: 'deezer',
      );
    }
    return null;
  }
}
