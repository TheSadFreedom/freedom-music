import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';
import '../data/track_key.dart';

/// Official Genius API hit mapped to Freedom Music fields.
class GeniusApiHit {
  const GeniusApiHit({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.producer,
    this.genre,
    this.year,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.coverUrl,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? producer;
  final String? genre;
  final int? year;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final String? coverUrl;
}

/// Read/write Genius Client Access Token for the metadata editor.
class GeniusTokenStore {
  GeniusTokenStore(this.paths);

  final AppPaths paths;

  String get tokenFilePath =>
      p.join(paths.dataDir, 'mods', 'metadata', 'genius_token');

  Future<String?> readToken() async {
    final file = File(tokenFilePath);
    if (!await file.exists()) return null;
    final raw = (await file.readAsString()).trim();
    return raw.isEmpty ? null : raw;
  }

  Future<void> writeToken(String token) async {
    final file = File(tokenFilePath);
    await file.parent.create(recursive: true);
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString(trimmed);
  }

  Future<bool> hasToken() async {
    final t = await readToken();
    return t != null && t.isNotEmpty;
  }
}

/// Official api.genius.com client (Bearer Client Access Token).
class GeniusApiClient {
  GeniusApiClient({required this.accessToken});

  final String accessToken;

  /// Album id → tracklist (batch Genius fill hits the same album often).
  final Map<int, List<Map>> _albumTracksCache = {};

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) FreedomMusic/1.0';

  Future<GeniusApiHit?> lookup({
    required String artist,
    required String title,
    String? note,
  }) async {
    final a = artist.trim();
    final t = title.trim();
    if (a.isEmpty && t.isEmpty) return null;
    final label = _noteText(note);
    final base = a.isEmpty ? t : (t.isEmpty ? a : '$a - $t');
    final query = label == null ? base : '$base $label'.trim();
    final songId = await _searchSongId(
      query,
      artist: a,
      title: t,
      note: label,
    );
    if (songId == null) return null;
    return _fetchSong(songId);
  }

  static String? _noteText(String? note) {
    final raw = note?.trim() ?? '';
    if (raw.isEmpty || isBlankMeta(raw)) return null;
    return raw;
  }

  Future<int?> _searchSongId(
    String query, {
    required String artist,
    required String title,
    String? note,
  }) async {
    final uri = Uri.https('api.genius.com', '/search', {'q': query});
    final json = await _getJson(uri);
    if (json == null) return null;
    final response = json['response'];
    if (response is! Map) return null;
    final hits = response['hits'];
    if (hits is! List || hits.isEmpty) return null;

    int? bestId;
    var bestScore = 0;
    final wantTitle = _matchKey(title);
    final wantArtist = _matchKey(artist);
    final wantNote = note == null ? '' : _matchKey(note);

    for (final hit in hits) {
      if (hit is! Map) continue;
      if ('${hit['type']}' != 'song') continue;
      final result = hit['result'];
      if (result is! Map) continue;
      final id = result['id'];
      if (id is! int && id is! num) continue;

      final songTitle = _matchKey('${result['title'] ?? ''}');
      final primary = result['primary_artist'];
      final primaryName =
          primary is Map ? '${primary['name'] ?? ''}' : '';
      final songArtist = _matchKey(
        primaryName.isNotEmpty
            ? primaryName
            : '${result['artist_names'] ?? ''}',
      );
      final artistNames = _matchKey('${result['artist_names'] ?? ''}');

      final titleScore = _titleScore(wantTitle, songTitle);
      var artistScore = 1;
      if (wantArtist.isNotEmpty) {
        final byPrimary = _artistScore(wantArtist, songArtist);
        final byNames = _artistScore(wantArtist, artistNames);
        artistScore = byPrimary >= byNames ? byPrimary : byNames;
      }

      // Both sides must look related — never take a random first hit.
      if (wantTitle.isNotEmpty && titleScore == 0) continue;
      if (wantArtist.isNotEmpty && artistScore == 0) continue;

      // Note boosts rank but is not required (many notes are not in Genius titles).
      final noteBonus = wantNote.isNotEmpty && _titleHasNote(songTitle, wantNote)
          ? 8
          : 0;
      final score = titleScore * 10 + artistScore + noteBonus;
      if (score > bestScore) {
        bestScore = score;
        bestId = id is int ? id : (id as num).toInt();
      }
    }
    return bestId;
  }

  static bool _titleHasNote(String songTitle, String note) {
    if (songTitle.contains(note)) return true;
    final compactTitle = _compact(songTitle);
    final compactNote = _compact(note);
    return compactNote.isNotEmpty && compactTitle.contains(compactNote);
  }

  /// Normalize for match: strip Genius Latin translation, lower-case, collapse spaces.
  static String _matchKey(String value) =>
      normalizeTag(_withoutTranslation(value));

  static String _compact(String value) => value
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '')
      .toLowerCase();

  /// 0 = no match. Short titles require exact/compact equality.
  /// Longer Genius titles may keep a Latin translation suffix.
  static int _titleScore(String want, String found) {
    if (want.isEmpty || found.isEmpty) return 0;
    if (want == found) return 5;
    final a = _compact(want);
    final b = _compact(found);
    if (a.isNotEmpty && a == b) return 5;

    const minContains = 4;
    // Local title inside Genius title (common when Genius appends «(English)»).
    if (a.length >= minContains && b.contains(a)) {
      if (b.length <= a.length + 32) return 4;
      return 3;
    }
    if (want.length >= minContains && found.startsWith(want)) return 3;
    if (want.length >= minContains && found.contains(want)) {
      if (found.length <= want.length + 32) return 3;
    }
    if (b.length >= minContains && a.contains(b)) {
      if (a.length <= b.length + 16) return 2;
    }
    return 0;
  }

  static int _artistScore(String want, String found) {
    if (want.isEmpty || found.isEmpty) return 0;
    if (want == found) return 5;

    final wantParts = want
        .split(RegExp(r'\s*,\s*|\s*&\s*|\s+x\s+|\s+feat\.?\s+|\s+ft\.?\s+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    final foundParts = found
        .split(RegExp(r'\s*,\s*|\s*&\s*|\s+x\s+|\s+feat\.?\s+|\s+ft\.?\s+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);

    for (final w in wantParts) {
      for (final f in foundParts) {
        if (w == f) return 4;
        final cw = _compact(w);
        final cf = _compact(f);
        if (cw.isNotEmpty && cw == cf) return 4;
        // «нехудожник.» vs «нехудожник. (nexudozhnik.)»
        if (cw.length >= 3 && cf.startsWith(cw)) return 4;
        if (cw.length >= 4 &&
            cf.length >= 4 &&
            (cf.contains(cw) || cw.contains(cf))) {
          return 3;
        }
      }
    }
    final cw = _compact(want);
    final cf = _compact(found);
    if (cw.length >= 3 && cf.startsWith(cw)) return 3;
    if (want.length >= 4 && found.contains(want)) return 2;
    if (found.length >= 4 && want.contains(found)) return 2;
    return 0;
  }

  Future<GeniusApiHit?> _fetchSong(int songId) async {
    final uri = Uri.https(
      'api.genius.com',
      '/songs/$songId',
      {'text_format': 'plain'},
    );
    final json = await _getJson(uri);
    if (json == null) return null;
    final response = json['response'];
    if (response is! Map) return null;
    final song = response['song'];
    if (song is! Map) return null;
    return _mapSong(song);
  }

  Future<GeniusApiHit> _mapSong(Map song) async {
    final title = _clean('${song['title'] ?? ''}');
    final artist = _primaryArtist(song);
    final producers = _namedList(song['producer_artists']);
    final genre = _tagsGenre(song);

    int? year;
    final parts = song['release_date_components'];
    if (parts is Map) {
      final y = parts['year'];
      if (y is int) {
        year = y;
      } else if (y is num) {
        year = y.toInt();
      }
    }
    year ??= _yearFrom('${song['release_date'] ?? ''}');
    year ??= _yearFrom('${song['release_date_for_display'] ?? ''}');

    String? album;
    String? albumArtist;
    int? trackNumber;
    int? trackTotal;
    int? discNumber;
    final albumRaw = song['album'];
    if (albumRaw is Map) {
      album = _clean('${albumRaw['name'] ?? ''}');
      final aa = albumRaw['artist'];
      if (aa is Map) {
        albumArtist = _clean('${aa['name'] ?? ''}');
      }
      albumArtist ??= _clean('${albumRaw['artist_name'] ?? ''}');
      trackNumber = _positive(song['album_track_number']) ??
          _positive(albumRaw['track_number']);
      trackTotal = _positive(albumRaw['tracks_count']) ??
          _positive(albumRaw['song_count']);
      discNumber = _positive(song['album_disc_number']);

      void applyTracklist(List tracks) {
        if (tracks.isEmpty) return;
        trackTotal ??= tracks.length;
        final id = song['id'];
        for (var i = 0; i < tracks.length; i++) {
          final item = tracks[i];
          if (item is! Map) continue;
          final songObj = item['song'] is Map ? item['song'] as Map : item;
          final sid = songObj['id'];
          if (sid != id) continue;
          trackNumber ??= _positive(item['number']) ??
              _positive(item['track_number']) ??
              (i + 1);
          discNumber ??=
              _positive(item['disc_number']) ?? _positive(item['disc']);
          break;
        }
      }

      final embedded =
          albumRaw['tracks'] ?? albumRaw['song_list'] ?? albumRaw['tracklist'];
      if (embedded is List && embedded.isNotEmpty) {
        applyTracklist(embedded);
      }

      // Song payload rarely includes the full tracklist — fetch album tracks.
      final albumId = _positive(albumRaw['id']);
      if (albumId != null && (trackTotal == null || trackNumber == null)) {
        final remote = await _fetchAlbumTracks(albumId);
        if (remote.isNotEmpty) applyTracklist(remote);
      }
    } else {
      // Single — no album block.
      albumArtist = artist;
      trackNumber = 1;
      trackTotal = 1;
      discNumber = 1;
    }

    final cover = _firstUrl([
      song['song_art_image_url'],
      song['header_image_url'],
      song['song_art_image_thumbnail_url'],
    ]);

    return GeniusApiHit(
      title: title.isEmpty ? null : title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      producer: producers,
      genre: genre,
      year: year,
      trackNumber: trackNumber,
      trackTotal: trackTotal,
      discNumber: discNumber,
      coverUrl: cover,
    );
  }

  Future<List<Map>> _fetchAlbumTracks(int albumId) async {
    final cached = _albumTracksCache[albumId];
    if (cached != null) return cached;

    final all = <Map>[];
    for (var page = 1; page <= 20; page++) {
      final uri = Uri.https(
        'api.genius.com',
        '/albums/$albumId/tracks',
        {
          'per_page': '50',
          'page': '$page',
          'text_format': 'plain',
        },
      );
      final json = await _getJson(uri);
      if (json == null) break;
      final response = json['response'];
      if (response is! Map) break;
      final tracks = response['tracks'];
      if (tracks is! List || tracks.isEmpty) break;
      for (final item in tracks) {
        if (item is Map) all.add(item);
      }
      if (tracks.length < 50) break;
    }
    _albumTracksCache[albumId] = all;
    return all;
  }

  String? _primaryArtist(Map song) {
    final names = <String>[];
    final seen = <String>{};

    void addName(String? raw) {
      final n = _clean(raw ?? '');
      if (n.isEmpty) return;
      final key = n.toLowerCase();
      if (!seen.add(key)) return;
      names.add(n);
    }

    void addArtistMap(Object? raw) {
      if (raw is Map) addName('${raw['name'] ?? ''}');
    }

    final primaries = song['primary_artists'];
    if (primaries is List && primaries.isNotEmpty) {
      for (final a in primaries) {
        addArtistMap(a);
      }
    } else {
      addArtistMap(song['primary_artist']);
    }

    final featured = song['featured_artists'];
    if (featured is List) {
      for (final a in featured) {
        addArtistMap(a);
      }
    }

    if (names.isEmpty) {
      final fallback = _clean('${song['artist_names'] ?? ''}');
      return fallback.isEmpty ? null : fallback;
    }
    return names.join(', ');
  }

  String? _tagsGenre(Map song) {
    final names = <String>[];
    void addTag(Object? raw) {
      if (raw is Map) {
        final n = _clean('${raw['name'] ?? ''}');
        if (n.isNotEmpty) names.add(n);
      }
    }

    addTag(song['primary_tag']);
    final tags = song['tags'];
    if (tags is List) {
      for (final t in tags) {
        addTag(t);
      }
    }
    // Dedupe preserve order.
    final seen = <String>{};
    final out = <String>[];
    for (final n in names) {
      final key = n.toLowerCase();
      if (seen.add(key)) out.add(n);
    }
    if (out.isEmpty) return null;
    return out.join(', ');
  }

  String? _namedList(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final names = <String>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final n = _clean('${item['name'] ?? ''}');
      if (n.isNotEmpty) names.add(n);
    }
    if (names.isEmpty) return null;
    return names.join(', ');
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    try {
      final response = await http
          .get(
            uri,
            headers: {
              HttpHeaders.authorizationHeader: 'Bearer $accessToken',
              HttpHeaders.acceptHeader: 'application/json',
              HttpHeaders.userAgentHeader: _ua,
            },
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _clean(String raw) =>
      _withoutTranslation(raw.replaceAll(RegExp(r'\s+'), ' ').trim());

  /// Genius appends a Latin translation: «Холода (Cold)», «#ЗАЦВ (ZATSV)».
  static String _withoutTranslation(String value) {
    final cleaned = value.replaceAllMapped(RegExp(r'\s*\(([^)]*)\)'), (match) {
      final inner = (match.group(1) ?? '').trim();
      if (!_isParenTranslation(value, inner)) return match.group(0)!;
      return '';
    });
    return cleaned.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  static bool _isParenTranslation(String whole, String inner) {
    if (inner.isEmpty || _hasCyrillic(inner) || !_hasLatin(inner)) return false;
    if (_isQualifier(inner)) return false;
    final without = whole.replaceFirst('($inner)', '');
    return _hasCyrillic(without);
  }

  static bool _isQualifier(String inner) {
    final text = inner.toLowerCase().trim();
    if (RegExp(r'^(feat\.?|ft\.?|featuring|prod\.?|produced by|with)\b')
        .hasMatch(text)) {
      return true;
    }
    const words = {
      'remix',
      'rmx',
      'live',
      'acoustic',
      'deluxe',
      'remaster',
      'remastered',
      'instrumental',
      'demo',
      'bonus',
      'edit',
      'version',
      'mix',
      'original',
      'cover',
      'single',
      'ep',
      'explicit',
      'clean',
      'intro',
      'outro',
      'interlude',
      'skit',
      'extended',
      'radio',
      'club',
      'dub',
      'vip',
      'bootleg',
      'reprise',
      'session',
      'edition',
      'mono',
      'stereo',
      'slowed',
      'reverb',
      'sped',
      'nightcore',
      'chopped',
      'screwed',
      'karaoke',
      'ost',
    };
    final parts = text
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .split(' ')
        .where((word) => word.isNotEmpty && !RegExp(r'^\d+$').hasMatch(word));
    if (parts.isEmpty) return false;
    return parts.every(words.contains);
  }

  static bool _hasCyrillic(String value) =>
      RegExp(r'[А-Яа-яЁё]').hasMatch(value);

  static bool _hasLatin(String value) => RegExp(r'[A-Za-z]').hasMatch(value);

  static int? _positive(Object? value) {
    int? n;
    if (value is int) {
      n = value;
    } else if (value is num) {
      n = value.toInt();
    } else {
      n = int.tryParse('$value');
    }
    if (n == null || n < 1) return null;
    return n;
  }

  static int? _yearFrom(String raw) {
    final m = RegExp(r'(19|20)\d{2}').firstMatch(raw);
    if (m == null) return null;
    return int.tryParse(m.group(0)!);
  }

  static String? _firstUrl(List<Object?> values) {
    for (final v in values) {
      final s = '${v ?? ''}'.trim();
      if (s.startsWith('http://') || s.startsWith('https://')) {
        if (s.contains('default_cover_image') || s.contains('default_avatar')) {
          continue;
        }
        return s;
      }
    }
    return null;
  }
}
