import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';
import '../data/track_key.dart';
import '../models/track.dart';
import '../utils/audio_format.dart';

class MetadataDraft {
  MetadataDraft({
    required this.title,
    required this.artist,
    required this.album,
    this.albumArtist,
    this.producer,
    this.note,
    required this.genre,
    this.year,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.lyrics,
    this.verified = false,
    this.coverBytes,
    this.coverMime,
    this.removeCover = false,
  });

  factory MetadataDraft.fromTrack(Track track) {
    return MetadataDraft(
      title: track.title,
      artist: track.artist,
      album: track.album,
      albumArtist: track.albumArtist,
      producer: track.producer,
      note: track.note,
      genre: track.genre,
      year: track.year,
      trackNumber: track.trackNumber,
      trackTotal: track.trackTotal,
      discNumber: track.discNumber,
      lyrics: track.lyrics,
      verified: track.verified,
    );
  }

  String title;
  String artist;
  String album;
  String? albumArtist;
  String? producer;
  String? note;
  String genre;
  int? year;
  int? trackNumber;
  int? trackTotal;
  int? discNumber;
  String? lyrics;

  /// Library-only mark; not written into audio tags.
  bool verified;

  /// New cover to embed (null = keep existing unless [removeCover]).
  Uint8List? coverBytes;
  String? coverMime;
  bool removeCover;
}

class MetadataWriter {
  /// Подменяет аудиофайл: старые файлы удаляются, метаданные [track] сохраняются.
  /// В индексе остаётся ровно один путь.
  static Future<Track> replaceAudioFile({
    required Track track,
    required String pickedPath,
    required AppPaths paths,
  }) async {
    final oldPaths = <String>{
      for (final path in track.filePaths) p.normalize(path),
    }.toList(growable: false);
    if (oldPaths.isEmpty) {
      throw StateError('У трека нет файлов на диске');
    }

    var pickedFile = File(p.normalize(pickedPath));
    if (!await pickedFile.exists()) {
      throw FileSystemException('Файл не найден', pickedFile.path);
    }
    // Скачанный AAC под видом .mp3 ломает updateMetadata — чиним расширение.
    pickedFile = await ensureAudioExtension(pickedFile);
    final picked = p.normalize(pickedFile.path);
    if (oldPaths.any((path) => p.equals(path, picked))) {
      throw StateError('Выбран тот же файл');
    }

    final primaryOld = oldPaths.first;
    // Обложку читаем до перезаписи primary — потом старого файла может не быть.
    final cover = await _coverForReplace(track, primaryOld);

    final workingPath = await _overwritePrimaryAudio(
      picked: picked,
      primaryOld: primaryOld,
      musicDir: paths.musicDir,
    );

    final draft = MetadataDraft.fromTrack(track);
    if (cover != null) {
      draft.coverBytes = cover.bytes;
      draft.coverMime = cover.mime;
    }

    final base = track.copyWith(filePaths: [workingPath]);
    Track tagged;
    try {
      tagged = await write(base, draft, paths: paths);
    } catch (e) {
      // Isolate.run может отдать RemoteError вместо исходного типа.
      final msg = e.toString();
      final parserFailed = e is MetadataParserException ||
          e is NoMetadataParserException ||
          msg.contains('MetadataParserException') ||
          msg.contains('NoMetadataParserException') ||
          msg.contains('No available parser');
      if (!parserFailed) {
        // Откат только нового пути (старые ещё на диске до cleanup ниже).
        if (!oldPaths.any((path) => p.equals(path, workingPath))) {
          await _deleteWithRetries(File(workingPath));
        }
        rethrow;
      }
      // Плеер часто играет raw AAC/ADTS, который теггер не знает —
      // метаданные остаются в БД/кэше обложки.
      tagged = await _applyDraftWithoutFileTags(base, draft, paths: paths);
    }

    // Старые файлы и хвост download — только после успешной подмены.
    await deleteReplacedAudioFiles(
      oldPaths: [...oldPaths, picked],
      keepPaths: [workingPath],
    );

    int? durationMs = track.durationMs;
    try {
      final meta = readMetadata(File(workingPath), getImage: false);
      durationMs = meta.duration?.inMilliseconds ?? durationMs;
    } catch (_) {}

    // Жёстко: старая личность трека + один путь (скан не должен подтянуть дубликаты).
    return track.copyWith(
      filePaths: [workingPath],
      durationMs: durationMs,
      coverPath: tagged.coverPath,
    );
  }

  /// Метаданные только в индекс/кэш обложки — без записи в аудиоконтейнер.
  static Future<Track> _applyDraftWithoutFileTags(
    Track track,
    MetadataDraft draft, {
    required AppPaths paths,
  }) async {
    final title = isBlankMeta(draft.title) ? 'Unknown' : draft.title.trim();
    final artist = storedArtists(draft.artist);
    final album = isBlankMeta(draft.album) ? 'Unknown' : draft.album.trim();
    // Empty genre stays empty — do not coerce to Unknown (shows as filled).
    final genre = isBlankMeta(draft.genre) ? '' : draft.genre.trim();
    final albumArtist = storedPeople(draft.albumArtist);
    final producerNamesOnly = producerNames(draft.producer);
    final producer = producerNamesOnly.isEmpty
        ? null
        : producerNamesOnly.join(', ');
    final noteText = draft.note?.trim() ?? '';
    final note = isBlankMeta(noteText) ? null : noteText;
    final lyrics = draft.lyrics?.trim();
    final newKey = buildTrackKey(
      artist: artist,
      title: title,
      album: album,
      note: note,
    );

    String? coverPath = track.coverPath;
    if (draft.removeCover) {
      await _deleteCovers(paths, track.trackKey);
      await _deleteCovers(paths, newKey);
      coverPath = null;
    } else if (draft.coverBytes != null) {
      await _deleteCovers(paths, track.trackKey);
      await _deleteCovers(paths, newKey);
      coverPath = await _saveCoverCache(
        paths,
        newKey,
        draft.coverBytes!,
        draft.coverMime ?? 'image/jpeg',
      );
    } else if (track.trackKey != newKey && track.coverPath != null) {
      coverPath = await _renameCoverCache(
        paths,
        track.trackKey,
        newKey,
        track.coverPath!,
      );
    }

    return track.copyWith(
      trackKey: newKey,
      title: title,
      artist: artist,
      album: album,
      albumArtist: (albumArtist == null || albumArtist.isEmpty)
          ? null
          : albumArtist,
      producer: (producer == null || producer.isEmpty) ? null : producer,
      note: note,
      genre: genre,
      year: draft.year,
      trackNumber: draft.trackNumber,
      trackTotal: draft.trackTotal,
      discNumber: draft.discNumber,
      lyrics: (lyrics == null || lyrics.isEmpty) ? null : lyrics,
      coverPath: coverPath,
      verified: draft.verified,
    );
  }

  /// Удаляет прежние аудиофайлы после переключения плеера на новый путь.
  static Future<void> deleteReplacedAudioFiles({
    required List<String> oldPaths,
    required List<String> keepPaths,
  }) async {
    for (final path in oldPaths) {
      if (keepPaths.any((keep) => p.equals(keep, path))) continue;
      await _deleteWithRetries(File(path));
    }
  }

  /// Rename in place to `Artist - Title.ext` or `Artist - Title Note.ext`.
  /// Paths outside [musicDir] are left unchanged. Does not move between dirs.
  /// Never invents `_timestamp` names: if the target is taken by another file,
  /// the source keeps its current name; if the target is already ours, the
  /// redundant source is dropped.
  static Future<Track> renameFilesToMetadata(
    Track track, {
    required String musicDir,
  }) async {
    if (track.filePaths.isEmpty) return track;

    final musicRoot = p.normalize(musicDir);
    final stem = fileNameFromMetadata(
      artist: track.displayArtist,
      title: track.displayTitle,
      note: track.displayNote,
    );

    final nextPaths = <String>[];
    var changed = false;

    bool isOurs(String candidate) {
      if (nextPaths.any((x) => p.equals(x, candidate))) return true;
      return track.filePaths.any((x) => p.equals(p.normalize(x), candidate));
    }

    for (final raw in track.filePaths) {
      final path = p.normalize(raw);
      final underMusic =
          p.isWithin(musicRoot, path) || p.equals(path, musicRoot);
      if (!underMusic) {
        if (!nextPaths.any((x) => p.equals(x, path))) nextPaths.add(path);
        continue;
      }

      final targetDir = p.dirname(path);
      final ext = p.extension(path);
      final dest = p.normalize(p.join(targetDir, '$stem$ext'));

      if (p.equals(dest, path)) {
        if (!nextPaths.any((x) => p.equals(x, path))) nextPaths.add(path);
        continue;
      }

      final src = File(path);
      if (!await src.exists()) {
        if (!nextPaths.any((x) => p.equals(x, path))) nextPaths.add(path);
        continue;
      }

      if (await File(dest).exists()) {
        if (isOurs(dest)) {
          // Same track already owns the desired name — drop the duplicate.
          await _deleteWithRetries(src);
          if (!nextPaths.any((x) => p.equals(x, dest))) nextPaths.add(dest);
          changed = true;
        } else {
          // Target taken by another file — keep current name, no stamped copy.
          if (!nextPaths.any((x) => p.equals(x, path))) nextPaths.add(path);
        }
        continue;
      }

      try {
        await src.rename(dest);
      } catch (_) {
        try {
          await src.copy(dest);
          await _deleteWithRetries(src);
        } catch (_) {
          if (!nextPaths.any((x) => p.equals(x, path))) nextPaths.add(path);
          continue;
        }
      }
      if (!nextPaths.any((x) => p.equals(x, dest))) nextPaths.add(dest);
      changed = true;
    }

    if (!changed) return track;
    return track.copyWith(filePaths: nextPaths);
  }

  /// Safe basename (no extension): `Artist - Title` or `Artist - Title Note`.
  static String fileNameFromMetadata({
    required String artist,
    required String title,
    String? note,
  }) {
    final a = artist.trim();
    final t = title.trim();
    final n = note?.trim() ?? '';
    final hasNote = n.isNotEmpty && !isBlankMeta(n);
    final base = a.isEmpty
        ? (t.isEmpty ? 'Unknown' : t)
        : (t.isEmpty ? a : '$a - $t');
    final raw = hasNote ? '$base $n' : base;
    return sanitizeFileName(raw);
  }

  /// Strip characters illegal on Windows and trim trailing dots/spaces.
  static String sanitizeFileName(String raw) {
    var s = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) return 'Unknown';
    if (s.length > 180) {
      s = s.substring(0, 180).replaceAll(RegExp(r'[. ]+$'), '');
      if (s.isEmpty) return 'Unknown';
    }
    return s;
  }

  /// Кладёт [picked] на место primary (то же имя) или рядом при другом расширении.
  /// Удаление старых путей — снаружи, после записи метаданных.
  static Future<String> _overwritePrimaryAudio({
    required String picked,
    required String primaryOld,
    required String musicDir,
  }) async {
    final src = File(picked);
    final oldNorm = p.normalize(primaryOld);
    final pickedNorm = p.normalize(picked);
    if (p.equals(pickedNorm, oldNorm)) return oldNorm;

    final musicRoot = p.normalize(musicDir);
    final destDir = p.isWithin(musicRoot, oldNorm)
        ? p.dirname(oldNorm)
        : musicRoot;
    await Directory(destDir).create(recursive: true);

    final oldExt = p.extension(oldNorm).toLowerCase();
    final newExt = p.extension(pickedNorm).toLowerCase();
    final safeExt = newExt.isEmpty ? '.mp3' : newExt;

    if (oldExt == safeExt) {
      final staging = File(
        p.join(
          destDir,
          '${p.basenameWithoutExtension(oldNorm)}.fmreplace$safeExt',
        ),
      );
      if (await staging.exists()) {
        await _deleteWithRetries(staging);
      }
      try {
        await src.rename(staging.path);
      } catch (_) {
        await src.copy(staging.path);
        try {
          await src.delete();
        } catch (_) {}
      }

      final dest = File(oldNorm);
      if (await dest.exists()) {
        final removed = await _deleteWithRetries(dest);
        if (!removed) {
          try {
            await staging.delete();
          } catch (_) {}
          throw FileSystemException(
            'Не удалось удалить старый файл для замены',
            oldNorm,
          );
        }
      }
      await staging.rename(oldNorm);
      return oldNorm;
    }

    // Другое расширение — новый файл рядом со старым именем.
    var dest = p.join(
      destDir,
      '${p.basenameWithoutExtension(oldNorm)}$safeExt',
    );
    dest = p.normalize(dest);
    if (p.equals(dest, oldNorm) || await File(dest).exists()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      dest = p.normalize(
        p.join(
          destDir,
          '${p.basenameWithoutExtension(oldNorm)}_$stamp$safeExt',
        ),
      );
    }
    try {
      await src.rename(dest);
    } catch (_) {
      await src.copy(dest);
      try {
        await src.delete();
      } catch (_) {}
    }
    return dest;
  }

  static Future<bool> _deleteWithRetries(File file) async {
    for (var i = 0; i < 10; i++) {
      try {
        if (!await file.exists()) return true;
        await file.delete();
        return true;
      } catch (_) {
        await Future<void>.delayed(Duration(milliseconds: 60 * (i + 1)));
      }
    }
    try {
      return !await file.exists();
    } catch (_) {
      return false;
    }
  }

  static Future<({Uint8List bytes, String mime})?> _coverForReplace(
    Track track,
    String oldPath,
  ) async {
    final cached = track.coverPath;
    if (cached != null && cached.isNotEmpty) {
      final file = File(cached);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          return (bytes: bytes, mime: _mimeFromCoverPath(cached, bytes));
        }
      }
    }
    try {
      final meta = readMetadata(File(oldPath), getImage: true);
      if (meta.pictures.isEmpty) return null;
      final picture = meta.pictures.first;
      if (picture.bytes.isEmpty) return null;
      return (
        bytes: picture.bytes,
        mime: picture.mimetype.isEmpty ? 'image/jpeg' : picture.mimetype,
      );
    } catch (_) {
      return null;
    }
  }

  static String _mimeFromCoverPath(String path, Uint8List bytes) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      '.jpg' || '.jpeg' => 'image/jpeg',
      _ => bytes.length >= 8 &&
              bytes[0] == 0x89 &&
              bytes[1] == 0x50 &&
              bytes[2] == 0x4E &&
              bytes[3] == 0x47
          ? 'image/png'
          : 'image/jpeg',
    };
  }

  /// Writes tags into every file of [track] and returns the updated Track
  /// (new trackKey if identity fields changed).
  static Future<Track> write(
    Track track,
    MetadataDraft draft, {
    required AppPaths paths,
  }) async {
    final filePaths = track.filePaths;
    if (filePaths.isEmpty) {
      throw StateError('У трека нет файлов на диске');
    }

    final title = isBlankMeta(draft.title) ? 'Unknown' : draft.title.trim();
    final artist = storedArtists(draft.artist);
    final album = isBlankMeta(draft.album) ? 'Unknown' : draft.album.trim();
    // Empty genre stays empty — Unknown would look «filled» after clear+save.
    final genre = isBlankMeta(draft.genre) ? '' : draft.genre.trim();
    final albumArtist = storedPeople(draft.albumArtist);
    final producerNamesOnly = producerNames(draft.producer);
    final producer = producerNamesOnly.isEmpty
        ? null
        : producerNamesOnly.join(', ');
    final noteText = draft.note?.trim() ?? '';
    final note = isBlankMeta(noteText) ? null : noteText;
    final lyrics = draft.lyrics?.trim();
    final year = draft.year;
    final trackNumber = draft.trackNumber;
    final trackTotal = draft.trackTotal;
    final discNumber = draft.discNumber;

    Picture? coverPicture;
    if (draft.coverBytes != null && draft.coverBytes!.isNotEmpty) {
      final mime = draft.coverMime ?? 'image/jpeg';
      coverPicture = Picture(draft.coverBytes!, mime, PictureType.coverFront);
    }

    for (final path in filePaths) {
      final file = File(path);
      if (!await file.exists()) {
        throw FileSystemException('Файл не найден', path);
      }
      await _writeFile(
        file,
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        producer: (producer == null || producer.isEmpty) ? null : producer,
        note: note,
        genre: genre,
        year: year,
        trackNumber: trackNumber,
        trackTotal: trackTotal,
        discNumber: discNumber,
        lyrics: lyrics,
        cover: coverPicture,
        removeCover: draft.removeCover,
      );
    }

    final newKey = buildTrackKey(
      artist: artist,
      title: title,
      album: album,
      note: note,
    );

    String? coverPath = track.coverPath;
    if (draft.removeCover) {
      await _deleteCovers(paths, track.trackKey);
      await _deleteCovers(paths, newKey);
      coverPath = null;
    } else if (draft.coverBytes != null) {
      await _deleteCovers(paths, track.trackKey);
      await _deleteCovers(paths, newKey);
      coverPath = await _saveCoverCache(
        paths,
        newKey,
        draft.coverBytes!,
        draft.coverMime ?? 'image/jpeg',
      );
    } else if (track.trackKey != newKey && track.coverPath != null) {
      // Move cached cover to new key name.
      coverPath = await _renameCoverCache(
        paths,
        track.trackKey,
        newKey,
        track.coverPath!,
      );
    }

    return track.copyWith(
      trackKey: newKey,
      title: title,
      artist: artist,
      album: album,
      albumArtist: (albumArtist == null || albumArtist.isEmpty)
          ? null
          : albumArtist,
      producer: (producer == null || producer.isEmpty) ? null : producer,
      note: note,
      genre: genre,
      year: year,
      trackNumber: trackNumber,
      trackTotal: trackTotal,
      discNumber: discNumber,
      lyrics: (lyrics == null || lyrics.isEmpty) ? null : lyrics,
      coverPath: coverPath,
      verified: draft.verified,
    );
  }

  static Future<void> _writeFile(
    File file, {
    required String title,
    required String artist,
    required String album,
    required String? albumArtist,
    required String? producer,
    required String? note,
    required String genre,
    required int? year,
    required int? trackNumber,
    required int? trackTotal,
    required int? discNumber,
    required String? lyrics,
    required Picture? cover,
    required bool removeCover,
  }) async {
    // Writer loads the whole audio file into RAM (package limitation).
    // Run in a short-lived isolate so that buffer is released after each file.
    final path = file.path;
    final coverBytes = cover?.bytes;
    final coverMime = cover?.mimetype;
    // Хвост от прошлой неудачной записи (Access Denied на rename).
    final staleTmp = File('$path.tmp');
    if (await staleTmp.exists()) {
      try {
        await staleTmp.delete();
      } catch (_) {}
    }
    await Isolate.run(() {
      updateMetadata(File(path), (tag) {
        final keptPictures = _picturesOf(tag);
        tag.setTitle(title);
        tag.setArtist(artist);
        tag.setAlbum(album);
        // ID3: empty genres alone is not enough — contentType (TCON) must
        // be cleared or the writer writes the old genre back.
        final blankGenre = isBlankMeta(genre);
        final genreParts = splitGenres(genre);
        tag.setGenres(blankGenre || genreParts.isEmpty ? <String>[] : genreParts);
        if (tag is Mp3Metadata && blankGenre) {
          tag.contentType = null;
        }
        tag.setYear(year != null ? DateTime(year) : null);
        tag.setTrackNumber(trackNumber);
        tag.setTrackTotal(trackTotal);
        tag.setCD(discNumber, null);
        tag.setLyrics(lyrics);

        if (tag is Mp3Metadata) {
          // TPE2 — album artist (audio_metadata_reader does not expose setAlbumArtist).
          tag.bandOrOrchestra = albumArtist;
        } else if (tag is VorbisMetadata) {
          tag.albumArtist = (albumArtist == null || albumArtist.isEmpty)
              ? <String>[]
              : <String>[albumArtist];
          tag.producer = (producer == null || producer.isEmpty)
              ? []
              : [producer];
          // Same place Mp3tag uses: Vorbis COMMENT (not a custom NOTE).
          final label = note?.trim() ?? '';
          tag.unknowns.remove('NOTE');
          tag.comment = isBlankMeta(label) ? <String>[] : <String>[label];
        } else if (tag is ApeMetadata) {
          tag.albumArtist = albumArtist;
          final label = note?.trim() ?? '';
          tag.comment = isBlankMeta(label) ? null : label;
        }

        if (removeCover) {
          tag.setPictures([]);
        } else if (coverBytes != null && coverBytes.isNotEmpty) {
          tag.setPictures([
            Picture(
              coverBytes,
              coverMime ?? 'image/jpeg',
              PictureType.coverFront,
            ),
          ]);
        } else {
          // Metadata fill only writes text fields. Put the original pictures
          // back so the rewrite cannot replace or drop the cover.
          tag.setPictures(keptPictures);
        }
      });
      // Package writes ID3v2.4 and drops TXXX/COMM/TIPL — restore Mp3tag fields,
      // then rewrite the tag as ID3v2.3 (IPLS + COMM).
      writeMp3SideFrames(path, producer: producer, note: note);
      rewriteId3AsV23(path);
    });
  }

  static Future<String> _saveCoverCache(
    AppPaths paths,
    String trackKey,
    Uint8List bytes,
    String mime,
  ) async {
    await paths.ensureDirectories();
    final ext = mime.contains('png')
        ? '.png'
        : mime.contains('webp')
        ? '.webp'
        : '.jpg';
    final out = File(p.join(paths.coversDir, '$trackKey$ext'));
    await out.writeAsBytes(bytes, flush: true);
    return out.path;
  }

  static Future<void> deleteCovers(AppPaths paths, String trackKey) =>
      _deleteCovers(paths, trackKey);

  static Future<void> _deleteCovers(AppPaths paths, String trackKey) async {
    for (final ext in ['.jpg', '.jpeg', '.png', '.webp']) {
      final f = File(p.join(paths.coversDir, '$trackKey$ext'));
      if (await f.exists()) {
        await f.delete();
      }
    }
  }

  static Future<String?> _renameCoverCache(
    AppPaths paths,
    String oldKey,
    String newKey,
    String oldPath,
  ) async {
    final oldFile = File(oldPath);
    if (!await oldFile.exists()) return null;
    final ext = p.extension(oldPath);
    final newPath = p.join(paths.coversDir, '$newKey$ext');
    if (p.equals(oldPath, newPath)) return oldPath;
    await oldFile.copy(newPath);
    try {
      await oldFile.delete();
    } catch (_) {}
    return newPath;
  }
}

List<Picture> _picturesOf(Object tag) {
  return switch (tag) {
    Mp3Metadata meta => List<Picture>.from(meta.pictures),
    VorbisMetadata meta => List<Picture>.from(meta.pictures),
    RiffMetadata meta => List<Picture>.from(meta.pictures),
    ApeMetadata meta => List<Picture>.from(meta.pictures),
    Mp4Metadata meta => meta.picture == null ? <Picture>[] : [meta.picture!],
    _ => const <Picture>[],
  };
}

/// Track total from the file tag (TRCK `n/total`, Vorbis TRACKTOTAL, …).
int? readFileTrackTotal(String path) {
  try {
    final meta = readMetadata(File(path), getImage: false);
    final n = meta.trackTotal;
    if (n == null || n < 1) return null;
    return n;
  } catch (_) {
    return null;
  }
}

/// Album artist from the file tag.
///
/// `readMetadata()` for MP3 maps TPE2 into [AudioMetadata.artist] and leaves
/// [AudioMetadata.albumArtist] null — read TPE2 / ALBUMARTIST directly.
String? readFileAlbumArtist(String path) {
  try {
    final tag = readAllMetadata(File(path), getImage: false);
    return switch (tag) {
      Mp3Metadata meta => storedPeople(meta.bandOrOrchestra),
      VorbisMetadata meta => storedPeople(_firstNonEmpty(meta.albumArtist)),
      ApeMetadata meta => storedPeople(meta.albumArtist),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// Track artist (TPE1 / ARTIST), not album artist.
/// Returns null when the lead artist frame is missing so callers can fall back.
String? readFileLeadArtist(String path) {
  try {
    final tag = readAllMetadata(File(path), getImage: false);
    return switch (tag) {
      Mp3Metadata meta => storedPeople(
          meta.leadPerformer ?? meta.originalArtist,
        ),
      VorbisMetadata meta => storedPeople(_firstNonEmpty(meta.artist)),
      ApeMetadata meta => storedPeople(meta.artist),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// Note from `TXXX:NOTE` / Vorbis `NOTE`, with fallback to Comment (`COMM`).
/// Mp3tag and many taggers store the label in Comment, not TXXX:NOTE.
String? readFileNote(String path) {
  try {
    final tag = readAllMetadata(File(path), getImage: false);
    return switch (tag) {
      Mp3Metadata meta => _noteFromMp3(meta),
      VorbisMetadata meta => _vorbisNote(meta),
      ApeMetadata meta => _nonBlankText(meta.comment),
      RiffMetadata meta => _nonBlankText(meta.comment),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

String? _noteFromMp3(Mp3Metadata meta) {
  final txxx = _customText(meta, 'note');
  if (txxx != null) return txxx;
  for (final comment in meta.comments) {
    final text = _nonBlankText(comment.text);
    if (text != null) return text;
  }
  return null;
}

String? _vorbisNote(VorbisMetadata meta) {
  for (final entry in meta.unknowns.entries) {
    if (entry.key.trim().toLowerCase() != 'note') continue;
    final value = _nonBlankText(entry.value);
    if (value != null) return value;
  }
  return _firstNonEmpty(meta.comment);
}

String? _nonBlankText(String? raw) {
  if (raw == null) return null;
  final value = raw.replaceAll('\u0000', '').trim();
  if (isBlankMeta(value)) return null;
  return value;
}

String? _customText(Mp3Metadata meta, String key) {
  for (final entry in meta.customMetadata.entries) {
    if (entry.key.trim().toLowerCase() != key) continue;
    final value = entry.value.replaceAll('\u0000', '').trim();
    if (!isBlankMeta(value)) return value;
  }
  return null;
}

/// Producer from ID3 TIPL/IPLS (Mp3tag), legacy `TXXX:PRODUCER`, or Vorbis.
String? readFileProducer(String path) {
  try {
    final tag = readAllMetadata(File(path), getImage: false);
    return switch (tag) {
      Mp3Metadata meta => _producerFromMp3(meta),
      VorbisMetadata meta => _firstNonEmpty(meta.producer),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

String? _producerFromMp3(Mp3Metadata meta) {
  final direct = _customText(meta, 'producer');
  if (direct != null) return direct;
  for (final entry in meta.customMetadata.entries) {
    final key = entry.key.trim().toLowerCase();
    if (key == 'tipl' || key == 'ipls') {
      final fromList = _producerFromInvolved(entry.value);
      if (fromList != null) return fromList;
    }
  }
  return null;
}

String? _producerFromInvolved(String raw) {
  final parts = raw.split(RegExp(r'[\u0000/]'));
  for (var i = 0; i + 1 < parts.length; i++) {
    if (parts[i].trim().toLowerCase() != 'producer') continue;
    final name = parts[i + 1].trim();
    if (!isBlankMeta(name)) return name;
  }
  return null;
}

String? _firstNonEmpty(List<String> values) {
  for (final value in values) {
    final trimmed = value.replaceAll('\u0000', '').trim();
    if (!isBlankMeta(trimmed)) return trimmed;
  }
  return null;
}

/// Appends Mp3tag-compatible Comment (`COMM`) and producer (`TIPL`) on ID3v2.4.
/// Drops legacy `TXXX:NOTE` / `TXXX:PRODUCER` and any old COMM/TIPL/IPLS.
void writeMp3SideFrames(String path, {String? producer, String? note}) {
  final file = File(path);
  final bytes = file.readAsBytesSync();
  if (bytes.length < 10 ||
      bytes[0] != 0x49 ||
      bytes[1] != 0x44 ||
      bytes[2] != 0x33 ||
      bytes[3] != 4) {
    return;
  }
  final payloadSize = _readSyncSafe(bytes, 6);
  final tagEnd = 10 + payloadSize;
  if (tagEnd <= 10 || tagEnd > bytes.length) return;

  final kept = BytesBuilder(copy: false);
  var offset = 10;
  if ((bytes[5] & 0x40) == 0) {
    while (offset + 10 <= tagEnd) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      if (id.codeUnitAt(0) == 0) break;
      final size = _readSyncSafe(bytes, offset + 4);
      final frameEnd = offset + 10 + size;
      if (size < 0 || frameEnd > tagEnd) {
        kept.add(bytes.sublist(offset, tagEnd));
        offset = tagEnd;
        break;
      }
      final description = id == 'TXXX'
          ? _txxxDescription(bytes, offset + 10, size)?.toLowerCase()
          : null;
      final drop = id == 'COMM' ||
          id == 'TIPL' ||
          id == 'IPLS' ||
          description == 'producer' ||
          description == 'note';
      if (!drop) kept.add(bytes.sublist(offset, frameEnd));
      offset = frameEnd;
    }
  } else {
    kept.add(bytes.sublist(10, tagEnd));
  }

  final frames = BytesBuilder(copy: false)..add(kept.toBytes());
  final producerValue = producer?.trim() ?? '';
  if (!isBlankMeta(producerValue)) {
    final tip = _tiplFrame(producerValue);
    if (tip != null) frames.add(tip);
  }
  final noteValue = note?.trim() ?? '';
  if (!isBlankMeta(noteValue)) {
    frames.add(_commFrame(noteValue));
  }
  final body = frames.toBytes();
  final header = Uint8List.fromList(bytes.sublist(0, 10));
  _writeSyncSafe(header, 6, body.length);
  final out = BytesBuilder(copy: false)
    ..add(header)
    ..add(body)
    ..add(bytes.sublist(tagEnd));
  file.writeAsBytesSync(out.takeBytes());
}

/// Rewrites a leading ID3v2.4 tag as ID3v2.3 (Mp3tag default): non-syncsafe
/// frame sizes, `TIPL` → `IPLS`. No-op if the file is not ID3v2.4.
void rewriteId3AsV23(String path) {
  final file = File(path);
  final bytes = file.readAsBytesSync();
  if (bytes.length < 10 ||
      bytes[0] != 0x49 ||
      bytes[1] != 0x44 ||
      bytes[2] != 0x33 ||
      bytes[3] != 4) {
    return;
  }
  // Extended header — leave untouched (package writer does not emit one).
  if ((bytes[5] & 0x40) != 0) return;

  final payloadSize = _readSyncSafe(bytes, 6);
  final tagEnd = 10 + payloadSize;
  if (tagEnd <= 10 || tagEnd > bytes.length) return;

  final body = BytesBuilder(copy: false);
  var offset = 10;
  while (offset + 10 <= tagEnd) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (id.codeUnitAt(0) == 0) break;
    final size = _readSyncSafe(bytes, offset + 4);
    final flags = bytes.sublist(offset + 8, offset + 10);
    final frameEnd = offset + 10 + size;
    if (size < 0 || frameEnd > tagEnd) break;
    final data = bytes.sublist(offset + 10, frameEnd);
    final outId = id == 'TIPL' ? 'IPLS' : id;
    body
      ..add(utf8.encode(outId))
      ..add(_u32Be(data.length))
      ..add(flags)
      ..add(data);
    offset = frameEnd;
  }

  final payload = body.toBytes();
  final header = Uint8List(10);
  header[0] = 0x49; // I
  header[1] = 0x44; // D
  header[2] = 0x33; // 3
  header[3] = 3; // v2.3
  header[4] = 0;
  header[5] = 0;
  // ID3v2.3 tag size is still sync-safe in the header.
  _writeSyncSafe(header, 6, payload.length);

  final out = BytesBuilder(copy: false)
    ..add(header)
    ..add(payload)
    ..add(bytes.sublist(tagEnd));
  file.writeAsBytesSync(out.takeBytes());
}

String? _txxxDescription(Uint8List data, int start, int size) {
  if (size < 2 || start + size > data.length) return null;
  final encoding = data[start];
  final payload = data.sublist(start + 1, start + size);
  if (encoding == 1 || encoding == 2) {
    for (var i = 0; i + 1 < payload.length; i += 2) {
      if (payload[i] == 0 && payload[i + 1] == 0) {
        return String.fromCharCodes(payload.sublist(0, i)).toLowerCase();
      }
    }
    return null;
  }
  final zero = payload.indexOf(0);
  final bytes = zero < 0 ? payload : payload.sublist(0, zero);
  return utf8.decode(bytes, allowMalformed: true);
}

int _readSyncSafe(Uint8List data, int offset) {
  return ((data[offset] & 0x7F) << 21) |
      ((data[offset + 1] & 0x7F) << 14) |
      ((data[offset + 2] & 0x7F) << 7) |
      (data[offset + 3] & 0x7F);
}

void _writeSyncSafe(Uint8List data, int offset, int value) {
  data[offset] = (value >> 21) & 0x7F;
  data[offset + 1] = (value >> 14) & 0x7F;
  data[offset + 2] = (value >> 7) & 0x7F;
  data[offset + 3] = value & 0x7F;
}

Uint8List _syncSafe(int value) {
  return Uint8List.fromList([
    (value >> 21) & 0x7F,
    (value >> 14) & 0x7F,
    (value >> 7) & 0x7F,
    value & 0x7F,
  ]);
}

Uint8List _u32Be(int value) {
  return Uint8List.fromList([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);
}

Uint8List _id3v24TextFrame(String id, Uint8List payload) {
  return (BytesBuilder(copy: false)
        ..add(utf8.encode(id))
        ..add(_syncSafe(payload.length))
        ..addByte(0)
        ..addByte(0)
        ..add(payload))
      .takeBytes();
}

/// ID3v2.4 `TIPL`: UTF-8 null-separated `producer` / name pairs (Mp3tag).
Uint8List? _tiplFrame(String producer) {
  final names = producerNames(producer);
  if (names.isEmpty) return null;
  final payload = BytesBuilder(copy: false)..addByte(3); // UTF-8
  for (final name in names) {
    payload
      ..add(utf8.encode('producer'))
      ..addByte(0)
      ..add(utf8.encode(name))
      ..addByte(0);
  }
  return _id3v24TextFrame('TIPL', payload.takeBytes());
}

/// ID3v2.4 `COMM`: UTF-8, language `eng`, empty short description (Mp3tag).
Uint8List _commFrame(String value) {
  final payload = BytesBuilder(copy: false)
    ..addByte(3)
    ..add(utf8.encode('eng'))
    ..addByte(0)
    ..add(utf8.encode(value));
  return _id3v24TextFrame('COMM', payload.takeBytes());
}
