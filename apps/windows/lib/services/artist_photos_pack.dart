import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';
import 'settings_service.dart';

class ArtistPhotosPackResult {
  const ArtistPhotosPackResult({
    required this.message,
    this.path,
    this.exported = 0,
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
  });

  final String message;
  final String? path;
  final int exported;
  final int added;
  final int updated;
  final int skipped;
}

class _PhotoEntry {
  const _PhotoEntry({
    required this.file,
    required this.manual,
    required this.updatedAtMs,
  });

  final String file;
  final bool manual;
  final int updatedAtMs;

  Map<String, Object?> toJson() => {
        'file': file,
        'manual': manual,
        'updatedAt': updatedAtMs,
      };

  static _PhotoEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final file = '${map['file'] ?? ''}'.trim();
    if (file.isEmpty) return null;
    final updated = map['updatedAt'];
    final updatedAtMs = updated is int
        ? updated
        : updated is num
            ? updated.toInt()
            : int.tryParse('$updated') ?? 0;
    return _PhotoEntry(
      file: file,
      manual: map['manual'] == true,
      updatedAtMs: updatedAtMs,
    );
  }
}

/// Manual ZIP pack of artist portraits (`fm_artist_photos.json` + JPGs).
class ArtistPhotosPack {
  ArtistPhotosPack({
    required this._paths,
    required this._settings,
  });

  static const manifestName = 'fm_artist_photos.json';
  static const photosDir = 'artist_photos';

  final AppPaths _paths;
  final SettingsService _settings;

  Future<ArtistPhotosPackResult> exportToFile(String destPath) async {
    await _paths.ensureDirectories();
    final archive = Archive();
    final photos = <String, Map<String, Object?>>{};
    var exported = 0;

    for (final entry in _settings.exportArtistPhotoPaths().entries) {
      final key = entry.key.trim().toLowerCase();
      if (key.isEmpty) continue;
      final src = File(entry.value);
      if (!await src.exists()) continue;

      final hash = sha1.convert(utf8.encode(key)).toString();
      final rel = '$photosDir/$hash.jpg';
      final bytes = await src.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));

      final manual = _settings.isArtistPhotoManual(key);
      final updated = _settings.artistPhotoUpdatedAtMs(key) ??
          (await src.lastModified()).toUtc().millisecondsSinceEpoch;
      photos[key] = _PhotoEntry(
        file: rel,
        manual: manual,
        updatedAtMs: updated,
      ).toJson();
      exported++;
    }

    final manifestBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'photos': photos,
      }),
    );
    archive.addFile(
      ArchiveFile(manifestName, manifestBytes.length, manifestBytes),
    );

    final encoded = ZipEncoder().encodeBytes(archive);
    final out = File(destPath);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(encoded, flush: true);

    return ArtistPhotosPackResult(
      path: destPath,
      exported: exported,
      message: exported == 0
          ? 'Нет фото для экспорта.'
          : 'Экспортировано фото: $exported.',
    );
  }

  Future<ArtistPhotosPackResult> importFromFile(String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    return importFromBytes(Uint8List.fromList(bytes));
  }

  Future<ArtistPhotosPackResult> importFromBytes(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifestFile = _findFile(archive, manifestName);
    if (manifestFile == null) {
      throw StateError('В архиве нет $manifestName');
    }
    final decoded = jsonDecode(utf8.decode(manifestFile.readBytes()!));
    if (decoded is! Map) {
      throw StateError('Некорректный манифест');
    }
    final photosRaw = decoded['photos'];
    if (photosRaw is! Map) {
      throw StateError('В манифесте нет photos');
    }

    await _paths.ensureDirectories();
    final localPaths = _settings.exportArtistPhotoPaths();
    var added = 0;
    var updated = 0;
    var skipped = 0;

    for (final raw in photosRaw.entries) {
      final key = '${raw.key}'.trim().toLowerCase();
      if (key.isEmpty) continue;
      final packEntry = _PhotoEntry.tryParse(raw.value);
      if (packEntry == null) continue;

      final packBytes = _readArchiveBytes(archive, packEntry.file);
      if (packBytes == null || packBytes.isEmpty) {
        skipped++;
        continue;
      }

      final localPath = localPaths[key];
      File? localFile;
      if (localPath != null && localPath.isNotEmpty) {
        final candidate = File(localPath);
        if (await candidate.exists()) localFile = candidate;
      }

      if (localFile == null) {
        await _writeLocal(key, packEntry, packBytes);
        added++;
        continue;
      }

      final localManual = _settings.isArtistPhotoManual(key);
      final localUpdated = _settings.artistPhotoUpdatedAtMs(key) ??
          (await localFile.lastModified()).toUtc().millisecondsSinceEpoch;
      final takePack = _shouldTakePack(
        localManual: localManual,
        localUpdated: localUpdated,
        pack: packEntry,
      );
      if (!takePack) {
        skipped++;
        continue;
      }
      await _writeLocal(key, packEntry, packBytes);
      updated++;
    }

    final parts = <String>[];
    if (added > 0) parts.add('добавлено $added');
    if (updated > 0) parts.add('обновлено $updated');
    if (skipped > 0) parts.add('пропущено $skipped');
    return ArtistPhotosPackResult(
      added: added,
      updated: updated,
      skipped: skipped,
      message: parts.isEmpty
          ? 'В пакете нет применимых фото.'
          : 'Импорт: ${parts.join(', ')}.',
    );
  }

  Future<void> _writeLocal(
    String artistKey,
    _PhotoEntry entry,
    List<int> bytes,
  ) async {
    final hash = sha1.convert(utf8.encode(artistKey)).toString();
    final dest = File(p.join(_paths.artistsDir, '$hash.jpg'));
    await dest.writeAsBytes(bytes, flush: true);
    await _settings.setArtistPhotoPath(
      artistKey,
      dest.path,
      manual: entry.manual,
      updatedAtMs: entry.updatedAtMs,
    );
  }

  /// Local manual wins over pack auto. Otherwise LWW by updatedAt.
  bool _shouldTakePack({
    required bool localManual,
    required int localUpdated,
    required _PhotoEntry pack,
  }) {
    if (localManual && !pack.manual) return false;
    if (!localManual && pack.manual) return true;
    return pack.updatedAtMs > localUpdated;
  }

  ArchiveFile? _findFile(Archive archive, String name) {
    final needle = name.replaceAll('\\', '/').toLowerCase();
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final n = f.name.replaceAll('\\', '/').toLowerCase();
      if (n == needle || n.endsWith('/$needle')) return f;
    }
    return null;
  }

  List<int>? _readArchiveBytes(Archive archive, String relativePath) {
    final file = _findFile(archive, relativePath);
    if (file == null) return null;
    return file.readBytes();
  }
}
