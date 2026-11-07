import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';
import '../data/database.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'cloud_sync_client.dart';

typedef CloudSyncProgress = void Function(String message);

class CloudPlaylistSyncResult {
  const CloudPlaylistSyncResult({
    this.uploaded = 0,
    this.downloaded = 0,
    this.removedRemote = 0,
    this.membershipChanged = false,
  });

  final int uploaded;
  final int downloaded;
  final int removedRemote;
  final bool membershipChanged;

  bool get changed =>
      uploaded > 0 ||
      downloaded > 0 ||
      removedRemote > 0 ||
      membershipChanged;
}

class _CloudTrackEntry {
  const _CloudTrackEntry({
    required this.key,
    required this.file,
    required this.artist,
    required this.title,
    this.size,
  });

  final String key;
  final String file;
  final String artist;
  final String title;
  final int? size;

  Map<String, Object?> toJson() => {
        'key': key,
        'file': file,
        'artist': artist,
        'title': title,
        if (size != null) 'size': size,
      };

  static _CloudTrackEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final key = '${map['key'] ?? ''}'.trim();
    if (key.isEmpty) return null;
    final file = '${map['file'] ?? ''}'.trim();
    return _CloudTrackEntry(
      key: key,
      file: file.isEmpty ? cloudRelativePath(key) : file,
      artist: '${map['artist'] ?? ''}',
      title: '${map['title'] ?? ''}',
      size: map['size'] is int ? map['size'] as int : int.tryParse('${map['size']}'),
    );
  }
}

class _CloudManifest {
  const _CloudManifest({
    required this.rev,
    required this.updatedAt,
    required this.tracks,
  });

  final int rev;
  final DateTime updatedAt;
  final List<_CloudTrackEntry> tracks;

  static _CloudManifest empty() => _CloudManifest(
        rev: 0,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        tracks: const [],
      );

  static _CloudManifest parse(Object? raw) {
    if (raw is! Map) return empty();
    final map = Map<String, dynamic>.from(raw);
    final rev = map['rev'] is int
        ? map['rev'] as int
        : int.tryParse('${map['rev']}') ?? 0;
    DateTime updatedAt;
    try {
      updatedAt = DateTime.parse('${map['updatedAt'] ?? ''}').toUtc();
    } catch (_) {
      updatedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    final list = <_CloudTrackEntry>[];
    final tracks = map['tracks'];
    if (tracks is List) {
      for (final item in tracks) {
        final entry = _CloudTrackEntry.tryParse(item);
        if (entry != null) list.add(entry);
      }
    }
    return _CloudManifest(rev: rev, updatedAt: updatedAt, tracks: list);
  }

  Map<String, Object?> toJson() => {
        'rev': rev,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'tracks': [for (final t in tracks) t.toJson()],
      };
}

String cloudFileId(String trackKey) {
  final digest = sha1.convert(utf8.encode(trackKey)).toString();
  return digest;
}

String cloudRelativePath(String trackKey) =>
    '${CloudSyncClient.cloudTracksDir}/${cloudFileId(trackKey)}.mp3';

String cloudAbsolutePath(String relativePath) {
  final clean = relativePath.replaceAll(RegExp(r'^/+'), '');
  return 'app:/$clean';
}

/// Syncs the system «Облако» playlist MP3s via Yandex app folder.
class CloudPlaylistSync {
  CloudPlaylistSync({
    required AppDatabase db,
    required AppPaths paths,
  })  : _db = db,
        _paths = paths;

  final AppDatabase _db;
  final AppPaths _paths;

  static const _localRevKey = 'cloud_playlist_rev';
  static const _dirtyKey = 'cloud_playlist_dirty';

  Future<CloudPlaylistSyncResult> run(
    CloudSyncClient cloud, {
    required bool localDirty,
    CloudSyncProgress? onProgress,
    Map<String, Track> tracksByKey = const {},
  }) async {
    void progress(String msg) => onProgress?.call(msg);

    final cloudId = await _db.ensureCloudPlaylist();
    final localKeys = await _db.getPlaylistTrackKeys(cloudId);
    final localRevRaw = await _db.getSyncMeta(_localRevKey);
    final localRev = int.tryParse(localRevRaw ?? '') ?? 0;

    progress('Облако: чтение манифеста…');
    var remote = _CloudManifest.empty();
    try {
      final text = await cloud.downloadText(
        cloudAbsolutePath(CloudSyncClient.cloudPlaylistManifest),
      );
      remote = _CloudManifest.parse(jsonDecode(text));
    } catch (_) {
      remote = _CloudManifest.empty();
    }

    var uploaded = 0;
    var downloaded = 0;
    var removedRemote = 0;
    var membershipChanged = false;

    if (localDirty) {
      // Local membership is source of truth.
      progress('Облако: выгрузка локального списка…');
      final desired = localKeys.take(Playlist.cloudTrackLimit).toList();
      final remoteByKey = {for (final t in remote.tracks) t.key: t};

      // Delete remote files no longer in local playlist.
      for (final entry in remote.tracks) {
        if (desired.contains(entry.key)) continue;
        try {
          await cloud.deletePath(cloudAbsolutePath(entry.file));
          removedRemote++;
        } catch (_) {}
      }

      final nextTracks = <_CloudTrackEntry>[];
      for (final key in desired) {
        final track = tracksByKey[key];
        final rel = cloudRelativePath(key);
        final localPath = track?.primaryPath;
        if (track != null && localPath != null && localPath.isNotEmpty) {
          final file = File(localPath);
          if (await file.exists()) {
            final already = remoteByKey[key];
            final size = await file.length();
            final needUpload = already == null ||
                already.size == null ||
                already.size != size;
            if (needUpload) {
              progress('Облако: загрузка «${track.displayTitle}»…');
              await cloud.uploadBytes(
                relativePath: rel,
                bytes: Uint8List.fromList(await file.readAsBytes()),
              );
              uploaded++;
            }
            nextTracks.add(
              _CloudTrackEntry(
                key: key,
                file: rel,
                artist: track.artist,
                title: track.title,
                size: size,
              ),
            );
            continue;
          }
        }
        // Keep remote entry if we don't have a local file yet.
        final existing = remoteByKey[key];
        if (existing != null) {
          nextTracks.add(existing);
        }
      }

      final next = _CloudManifest(
        rev: (remote.rev > localRev ? remote.rev : localRev) + 1,
        updatedAt: DateTime.now().toUtc(),
        tracks: nextTracks,
      );
      await cloud.uploadBytes(
        relativePath: CloudSyncClient.cloudPlaylistManifest,
        bytes: Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(next.toJson())),
        ),
      );
      await _db.setSyncMeta(_localRevKey, '${next.rev}');
      await _db.setSyncMeta(_dirtyKey, '0');
      return CloudPlaylistSyncResult(
        uploaded: uploaded,
        downloaded: downloaded,
        removedRemote: removedRemote,
        membershipChanged: false,
      );
    }

    // Pull remote → local.
    if (remote.rev <= localRev && remote.tracks.isEmpty) {
      return const CloudPlaylistSyncResult();
    }

    progress('Облако: применение удалённого списка…');
    final remoteKeys = [
      for (final t in remote.tracks.take(Playlist.cloudTrackLimit)) t.key,
    ];
    final remoteSet = remoteKeys.toSet();
    final localSet = localKeys.toSet();

    // Remove membership for keys not in remote (keep library files).
    for (final key in localKeys) {
      if (remoteSet.contains(key)) continue;
      await _db.removeFromPlaylist(cloudId, key);
      membershipChanged = true;
    }

    final cloudMusicDir = Directory(p.join(_paths.musicDir, 'Cloud'));
    await cloudMusicDir.create(recursive: true);

    final pendingKeys = <String>[];
    for (final entry in remote.tracks.take(Playlist.cloudTrackLimit)) {
      final existing = tracksByKey[entry.key];
      final path = existing?.primaryPath;
      final hasFile = existing != null &&
          path != null &&
          path.isNotEmpty &&
          await File(path).exists();

      if (!hasFile) {
        progress('Облако: скачивание «${entry.title}»…');
        try {
          final bytes = await cloud.downloadBytes(cloudAbsolutePath(entry.file));
          final safeArtist = _safeName(entry.artist);
          final safeTitle = _safeName(entry.title);
          final dest = File(
            p.join(
              cloudMusicDir.path,
              '$safeArtist - $safeTitle (${cloudFileId(entry.key).substring(0, 8)}).mp3',
            ),
          );
          await dest.writeAsBytes(bytes, flush: true);
          downloaded++;
          membershipChanged = true;
          pendingKeys.add(entry.key);
        } catch (e) {
          progress('Облако: не удалось скачать ${entry.key}: $e');
          continue;
        }
      }

      if (!localSet.contains(entry.key) && tracksByKey.containsKey(entry.key)) {
        await _db.addTrackToPlaylist(cloudId, entry.key);
        membershipChanged = true;
      }
    }

    if (pendingKeys.isNotEmpty) {
      await _db.setSyncMeta(
        'cloud_playlist_pending_keys',
        jsonEncode(pendingKeys),
      );
    }

    await _db.setSyncMeta(_localRevKey, '${remote.rev}');
    return CloudPlaylistSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      removedRemote: removedRemote,
      membershipChanged: membershipChanged || downloaded > 0,
    );
  }

  /// After `scanLibrary(newOnly)`, attach pending cloud keys that now exist.
  Future<bool> applyPendingMembership(Map<String, Track> tracksByKey) async {
    final raw = await _db.getSyncMeta('cloud_playlist_pending_keys');
    if (raw == null || raw.isEmpty) return false;
    List<dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      await _db.setSyncMeta('cloud_playlist_pending_keys', '');
      return false;
    }
    final cloudId = await _db.ensureCloudPlaylist();
    final local = (await _db.getPlaylistTrackKeys(cloudId)).toSet();
    var changed = false;
    for (final item in decoded) {
      final key = '$item'.trim();
      if (key.isEmpty || local.contains(key)) continue;
      if (!tracksByKey.containsKey(key)) continue;
      if (local.length >= Playlist.cloudTrackLimit) break;
      await _db.addTrackToPlaylist(cloudId, key);
      local.add(key);
      changed = true;
    }
    await _db.setSyncMeta('cloud_playlist_pending_keys', '');
    return changed;
  }

  static Future<void> markDirty(AppDatabase db) async {
    await db.setSyncMeta(_dirtyKey, '1');
  }

  static Future<bool> isDirty(AppDatabase db) async {
    return (await db.getSyncMeta(_dirtyKey)) == '1';
  }

  static String _safeName(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return 'Unknown';
    text = text.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length > 80) text = text.substring(0, 80).trim();
    return text.isEmpty ? 'Unknown' : text;
  }
}
