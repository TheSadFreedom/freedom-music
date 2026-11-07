import 'dart:typed_data';

/// Cloud file listing entry used by [SyncEngine].
class CloudSyncFile {
  const CloudSyncFile({required this.id, required this.name});

  /// Provider-specific id (Drive file id, or Yandex path).
  final String id;
  final String name;
}

/// Shared sync storage API (Yandex Disk app folder).
abstract class CloudSyncClient {
  static const eventsPrefix = 'fm_events_';
  static const playsPrefix = 'fm_plays_';
  static const metaName = 'fm_sync_meta.json';
  static const cloudPlaylistManifest = 'fm_cloud_playlist.json';
  static const cloudTracksDir = 'cloud_tracks';
  static const artistPhotosManifest = 'fm_artist_photos.json';
  static const artistPhotosDir = 'artist_photos';

  Future<List<CloudSyncFile>> listEventChunks();

  Future<List<CloudSyncFile>> listPlayCountFiles();

  Future<String> downloadText(String id);

  Future<Map<String, Object?>> downloadMeta();

  Future<void> uploadMeta(Map<String, Object?> meta);

  Future<void> uploadEventChunk({
    required String name,
    required String jsonl,
  });

  Future<void> uploadPlayCounts({
    required String deviceId,
    required Map<String, Object?> payload,
  });

  /// Upload raw bytes to `app:/[relativePath]` (e.g. `cloud_tracks/ab.mp3`).
  Future<void> uploadBytes({
    required String relativePath,
    required Uint8List bytes,
  });

  /// Download raw bytes by provider path/id.
  Future<Uint8List> downloadBytes(String id);

  /// Delete file by provider path/id. Missing file is OK.
  Future<void> deletePath(String id);

  /// List files under `app:/[relativeDir]/` (non-recursive).
  Future<List<CloudSyncFile>> listDir(String relativeDir);
}
