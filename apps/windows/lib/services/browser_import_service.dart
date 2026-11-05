import 'dart:io';

import 'package:path/path.dart' as p;

import '../browser/browser_hit.dart';
import '../browser/browser_source.dart';
import '../data/app_paths.dart';
import '../models/track.dart';
import '../utils/audio_format.dart';
import 'library_service.dart';
import 'metadata_writer.dart';
import 'player_service.dart';

/// Скачивает трек из источника браузера в `music/` и запускает скан.
class BrowserImportService {
  BrowserImportService({
    required this.paths,
    required this.library,
  });

  final AppPaths paths;
  final LibraryService library;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  /// Скачивает файл, проставляет теги из [hit], сканирует библиотеку.
  /// Возвращает трек из библиотеки (если скан его подхватил).
  Future<Track?> download(
    BrowserSource source,
    BrowserHit hit, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final dest = await downloadToFile(
      source,
      hit,
      onProgress: onProgress,
    );
    await _applyHitTags(dest, hit);
    await library.scanLibrary(newOnly: true);

    final normalized = p.normalize(dest.path);
    for (final track in library.tracks) {
      if (track.filePaths.any((f) => p.normalize(f) == normalized)) {
        return track;
      }
    }
    return null;
  }

  /// Скачивает [hit] и подменяет аудио у [target], сохраняя старые метаданные.
  Future<Track> replaceLibraryTrack({
    required BrowserSource source,
    required BrowserHit hit,
    required Track target,
    required PlayerService player,
    void Function(int received, int? total)? onProgress,
  }) async {
    final downloaded = await downloadToFile(
      source,
      hit,
      onProgress: onProgress,
    );
    final oldKey = target.trackKey;
    final oldPaths = List<String>.from(target.filePaths);
    final unlockPaths = [...oldPaths, downloaded.path];
    try {
      // Один unlock: сначала пишем, в beforeRelock подставляем новый путь в очередь,
      // потом finally плеера открывает уже новый файл (не старый).
      final prevUnlock = library.unlockAudioForWrite;
      late final Track updated;
      try {
        library.unlockAudioForWrite = null;
        updated = await player.whileAudioUnlocked(
          unlockPaths,
          () => library.replaceTrackAudioFile(target, downloaded.path),
          beforeRelock: (track) {
            player.syncTrack(track, oldTrackKey: oldKey);
          },
        );
      } finally {
        library.unlockAudioForWrite = prevUnlock;
      }
      // Если трек не держали — finally не переоткрывал; догрузим очередь/плеер.
      await player.syncTrackAfterFileReplace(updated, oldTrackKey: oldKey);
      await MetadataWriter.deleteReplacedAudioFiles(
        oldPaths: oldPaths,
        keepPaths: updated.filePaths,
      );
      // Исходник мог остаться, если replace сделал copy.
      if (await downloaded.exists()) {
        final keep = updated.filePaths.map(p.normalize).toSet();
        if (!keep.contains(p.normalize(downloaded.path))) {
          try {
            await downloaded.delete();
          } catch (_) {}
        }
      }
      return updated;
    } catch (e) {
      try {
        if (await downloaded.exists()) await downloaded.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Только HTTP → файл (без тегов hit и без скана).
  Future<File> downloadToFile(
    BrowserSource source,
    BrowserHit hit, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final downloadUri = await source.resolveDownload(hit);
    await paths.ensureDirectories();
    final dir = Directory(
      p.join(paths.musicDir, 'Browser', _safeSegment(source.name)),
    );
    await dir.create(recursive: true);

    final ext = _extensionOf(downloadUri);
    final base = _fileBase(hit);
    var dest = File(p.join(dir.path, '$base$ext'));
    if (await dest.exists()) {
      dest = File(
        p.join(dir.path, '${base}_${hit.id}$ext'),
      );
    }

    final client = HttpClient()
      ..userAgent = _ua
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 60);
    try {
      final request = await client.getUrl(downloadUri);
      request.headers.set(HttpHeaders.userAgentHeader, _ua);
      request.headers.set(HttpHeaders.refererHeader, source.referer);
      final origin = Uri.tryParse(source.referer);
      if (origin != null && origin.hasScheme && origin.host.isNotEmpty) {
        request.headers.set(
          'Origin',
          '${origin.scheme}://${origin.host}',
        );
      }
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Скачивание HTTP ${response.statusCode}',
          uri: downloadUri,
        );
      }
      final total = response.contentLength >= 0 ? response.contentLength : null;
      final sink = dest.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      if (received < 1024) {
        try {
          await dest.delete();
        } catch (_) {}
        throw StateError('Файл слишком маленький — ссылка могла истечь');
      }
    } finally {
      client.close(force: true);
    }
    // URL часто врёт (.mp3), а в теле AAC/M4A — поправим расширение.
    return ensureAudioExtension(dest);
  }

  Future<void> _applyHitTags(File dest, BrowserHit hit) async {
    try {
      final stub = Track(
        trackKey: 'browser-import',
        title: hit.title,
        artist: hit.artist,
        album: hit.subtitle?.trim().isNotEmpty == true
            ? hit.subtitle!.trim()
            : 'Unknown',
        genre: 'Unknown',
        filePaths: [dest.path],
      );
      await MetadataWriter.write(
        stub,
        MetadataDraft(
          title: hit.title,
          artist: hit.artist,
          album: stub.album,
          genre: 'Unknown',
        ),
        paths: paths,
      );
    } catch (_) {
      // Теги опциональны — файл всё равно попадёт в библиотеку.
    }
  }

  static String _fileBase(BrowserHit hit) {
    final artist = _safeSegment(hit.artist);
    final title = _safeSegment(hit.title);
    final name = '$artist - $title';
    if (name.length <= 120) return name;
    return name.substring(0, 120).trim();
  }

  static String _safeSegment(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return 'Unknown';
    text = text.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    while (text.endsWith('.') || text.endsWith(' ')) {
      text = text.substring(0, text.length - 1).trimRight();
    }
    return text.isEmpty ? 'Unknown' : text;
  }

  static String _extensionOf(Uri uri) {
    final pathExt = p.extension(uri.path).toLowerCase();
    if (pathExt == '.mp3' ||
        pathExt == '.flac' ||
        pathExt == '.ogg' ||
        pathExt == '.wav' ||
        pathExt == '.m4a') {
      return pathExt;
    }
    final name = uri.queryParameters['filename'] ?? '';
    final fromQuery = p.extension(name).toLowerCase();
    if (fromQuery.isNotEmpty) return fromQuery;
    return '.mp3';
  }
}
