import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';
import '../services/settings_service.dart';
import 'cloud_playlist_sync.dart';
import 'cloud_sync_client.dart';

typedef ArtistPhotosProgress = void Function(String message);

class ArtistPhotosSyncResult {
  const ArtistPhotosSyncResult({
    this.uploaded = 0,
    this.downloaded = 0,
    this.changed = false,
  });

  final int uploaded;
  final int downloaded;
  final bool changed;
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

/// Syncs artist portraits via `fm_artist_photos.json` + `artist_photos/*.jpg`.
class ArtistPhotosSync {
  ArtistPhotosSync({
    required AppPaths paths,
    required SettingsService settings,
  })  : _paths = paths,
        _settings = settings;

  final AppPaths _paths;
  final SettingsService _settings;

  Future<ArtistPhotosSyncResult> run(
    CloudSyncClient cloud, {
    ArtistPhotosProgress? onProgress,
  }) async {
    void progress(String msg) => onProgress?.call(msg);

    progress('Фото: чтение манифеста…');
    final remote = await _downloadManifest(cloud);

    final localPaths = _settings.exportArtistPhotoPaths();
    final localKeys = localPaths.keys.toSet();
    final remoteKeys = remote.keys.toSet();
    final allKeys = {...localKeys, ...remoteKeys};

    var uploaded = 0;
    var downloaded = 0;
    final next = <String, _PhotoEntry>{};
    var manifestDirty = false;

    for (final key in allKeys) {
      final localPath = localPaths[key];
      File? localFile;
      if (localPath != null && localPath.isNotEmpty) {
        final candidate = File(localPath);
        if (await candidate.exists()) localFile = candidate;
      }
      final hasLocal = localFile != null;
      final localManual =
          hasLocal ? _settings.isArtistPhotoManual(key) : false;
      var localUpdated = 0;
      if (localFile != null) {
        localUpdated = _settings.artistPhotoUpdatedAtMs(key) ??
            (await localFile.lastModified()).toUtc().millisecondsSinceEpoch;
      }
      final remoteEntry = remote[key];

      if (localFile != null && remoteEntry == null) {
        progress('Фото: выгрузка «$key»…');
        final rel = await _uploadLocal(cloud, key, localFile);
        next[key] = _PhotoEntry(
          file: rel,
          manual: localManual,
          updatedAtMs: localUpdated,
        );
        uploaded++;
        manifestDirty = true;
        continue;
      }

      if (localFile == null && remoteEntry != null) {
        progress('Фото: загрузка «$key»…');
        final ok = await _downloadRemote(cloud, key, remoteEntry);
        if (ok) downloaded++;
        next[key] = remoteEntry;
        continue;
      }

      if (localFile == null || remoteEntry == null) continue;

      // Both sides have a photo.
      final takeRemote = _shouldTakeRemote(
        localManual: localManual,
        localUpdated: localUpdated,
        remote: remoteEntry,
      );
      if (takeRemote) {
        progress('Фото: обновление «$key»…');
        final ok = await _downloadRemote(cloud, key, remoteEntry);
        if (ok) downloaded++;
        next[key] = remoteEntry;
      } else {
        final needUpload = remoteEntry.updatedAtMs < localUpdated ||
            remoteEntry.manual != localManual;
        if (needUpload) {
          progress('Фото: выгрузка «$key»…');
          final rel = await _uploadLocal(cloud, key, localFile);
          next[key] = _PhotoEntry(
            file: rel,
            manual: localManual,
            updatedAtMs: localUpdated,
          );
          uploaded++;
          manifestDirty = true;
        } else {
          next[key] = remoteEntry;
        }
      }
    }

    // Drop remote orphans already handled; prune leftover remote files not in next.
    for (final entry in remote.entries) {
      if (next.containsKey(entry.key)) continue;
      try {
        await cloud.deletePath(cloudAbsolutePath(entry.value.file));
        manifestDirty = true;
      } catch (_) {}
    }

    if (manifestDirty || next.length != remote.length) {
      progress('Фото: запись манифеста…');
      await cloud.uploadBytes(
        relativePath: CloudSyncClient.artistPhotosManifest,
        bytes: Uint8List.fromList(
          utf8.encode(
            const JsonEncoder.withIndent('  ').convert({
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
              'photos': {
                for (final e in next.entries) e.key: e.value.toJson(),
              },
            }),
          ),
        ),
      );
    }

    return ArtistPhotosSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      changed: uploaded > 0 || downloaded > 0,
    );
  }

  Future<Map<String, _PhotoEntry>> _downloadManifest(
    CloudSyncClient cloud,
  ) async {
    try {
      final text = await cloud.downloadText(
        cloudAbsolutePath(CloudSyncClient.artistPhotosManifest),
      );
      final decoded = jsonDecode(text);
      if (decoded is! Map) return {};
      final photos = decoded['photos'];
      if (photos is! Map) return {};
      final out = <String, _PhotoEntry>{};
      for (final e in photos.entries) {
        final parsed = _PhotoEntry.tryParse(e.value);
        if (parsed == null) continue;
        out['${e.key}'.trim().toLowerCase()] = parsed;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<String> _uploadLocal(
    CloudSyncClient cloud,
    String artistKey,
    File file,
  ) async {
    final hash = sha1.convert(utf8.encode(artistKey)).toString();
    final rel = '${CloudSyncClient.artistPhotosDir}/$hash.jpg';
    await cloud.uploadBytes(
      relativePath: rel,
      bytes: Uint8List.fromList(await file.readAsBytes()),
    );
    return rel;
  }

  Future<bool> _downloadRemote(
    CloudSyncClient cloud,
    String artistKey,
    _PhotoEntry entry,
  ) async {
    try {
      final bytes =
          await cloud.downloadBytes(cloudAbsolutePath(entry.file));
      if (bytes.isEmpty) return false;
      await _paths.ensureDirectories();
      final hash = sha1.convert(utf8.encode(artistKey)).toString();
      final dest = File(p.join(_paths.artistsDir, '$hash.jpg'));
      await dest.writeAsBytes(bytes, flush: true);
      // Prefer display name from key if we only have normalized key.
      await _settings.setArtistPhotoPath(
        artistKey,
        dest.path,
        manual: entry.manual,
        updatedAtMs: entry.updatedAtMs,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Local manual wins over remote auto. Otherwise LWW by updatedAt.
  bool _shouldTakeRemote({
    required bool localManual,
    required int localUpdated,
    required _PhotoEntry remote,
  }) {
    if (localManual && !remote.manual) return false;
    if (!localManual && remote.manual) return true;
    return remote.updatedAtMs > localUpdated;
  }
}
