import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../data/track_key.dart';
import '../models/track.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import 'cloud_auth_session.dart';
import 'artist_photos_sync.dart';
import 'cloud_playlist_sync.dart';
import 'sync_engine.dart';
import 'sync_event.dart';
import 'yandex_disk_auth.dart';
import 'yandex_disk_client.dart';

/// Orchestrates Yandex Disk sync and exposes status for Settings.
class SyncService extends ChangeNotifier {
  SyncService({
    required AppDatabase db,
    required SettingsService settings,
    String? authStorageDir,
  })  : _db = db,
        _settings = settings,
        _engine = SyncEngine(db: db, settings: settings),
        _auth = YandexDiskAuth(storageDir: authStorageDir);

  final AppDatabase _db;
  final SettingsService _settings;
  final SyncEngine _engine;
  final YandexDiskAuth _auth;
  final _uuid = const Uuid();

  static const _autoSyncDelay = Duration(seconds: 2);
  static const providerId = 'yandex';
  static const providerLabel = 'Яндекс.Диск';

  CloudAuthSession? _session;
  LibraryService? _library;
  bool _busy = false;
  String? _message;
  DateTime? _lastSyncAt;
  bool _libraryNeedsReload = false;
  bool _cloudDirty = false;
  Timer? _autoSyncTimer;
  bool _autoSyncQueued = false;
  bool _shuttingDown = false;

  void attachLibrary(LibraryService library) {
    _library = library;
  }

  void markCloudPlaylistDirty() {
    _cloudDirty = true;
    unawaited(CloudPlaylistSync.markDirty(_db));
    _scheduleAutoSync();
  }

  bool get busy => _busy;
  bool get isSignedIn => _session != null || _auth.isSignedIn;
  bool get hasCloudAccess => _session != null;
  /// Deprecated alias for UI that still checks Drive naming.
  bool get hasDriveAccess => hasCloudAccess;
  bool get needsDriveConsent => false;
  String? get email => _session?.email ?? _auth.email;
  String? get message => _message;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get libraryNeedsReload => _libraryNeedsReload;

  void clearLibraryNeedsReload() => _libraryNeedsReload = false;

  Future<void> tryRestoreSession() async {
    final session = await _auth.trySilent();
    _session = session;
    notifyListeners();
  }

  Future<void> signIn({
    Future<String?> Function()? promptYandexCode,
  }) async {
    _busy = true;
    _message = 'Вход в Яндекс…';
    notifyListeners();
    try {
      final prompt = promptYandexCode;
      if (prompt == null) {
        throw StateError('Нужен ввод кода подтверждения Яндекс');
      }
      final session = await _auth.signIn(promptCode: prompt);
      _session = session;
      _message = 'Вход выполнен: ${session.email}';
    } catch (e) {
      final text = '$e';
      if (text.contains('canceled') ||
          text.contains('Cancelled') ||
          text.contains('отмен')) {
        _message = 'Вход в Яндекс отменён.';
      } else {
        _message = 'Ошибка входа: $e';
      }
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    final session = _session;
    _session = null;
    _busy = false;
    _message = 'Вы вышли из Яндекс';
    notifyListeners();
    try {
      await _auth.signOut();
    } catch (_) {}
    try {
      session?.client.close();
    } catch (_) {}
  }

  void cancelPendingWork() {
    _shuttingDown = true;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    _autoSyncQueued = false;
  }

  Future<void> syncNow({bool interactive = true}) async {
    if (_shuttingDown) return;
    if (_busy) {
      if (!interactive) _autoSyncQueued = true;
      return;
    }

    var session = _session ?? await _auth.trySilent();
    if (session == null) {
      if (!interactive) return;
      _message = 'Сначала войдите в Яндекс кнопкой «Войти»';
      notifyListeners();
      return;
    }
    _session = session;

    _busy = true;
    _message = 'Синхронизация ($providerLabel)…';
    notifyListeners();
    try {
      final deviceId = await _db.getOrCreateDeviceId();
      final flags = _settings.exportSettingsFlags();
      await _db.enqueueSyncEvent(
        SyncEvent(
          id: 'settings_${deviceId}_${DateTime.now().millisecondsSinceEpoch}',
          deviceId: deviceId,
          at: DateTime.now().toUtc(),
          type: SyncEvent.settingsFlags,
          payload: {
            ...flags,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          },
        ),
      );

      final cloud = YandexDiskClient(session.client);
      final result = await _engine.run(
        cloud,
        providerId: providerId,
        onProgress: (msg) {
          _message = msg;
          notifyListeners();
        },
      );

      var cloudUp = 0;
      var cloudDown = 0;
      var photosUp = 0;
      var photosDown = 0;
      final library = _library;
      if (library != null && _settings.syncCloudPlaylist) {
        final dirty =
            _cloudDirty || await CloudPlaylistSync.isDirty(_db);
        final cloudSync = CloudPlaylistSync(
          db: _db,
          paths: library.paths,
        );
        final byKey = <String, Track>{
          for (final t in library.tracks) t.trackKey: t,
        };
        final cloudResult = await cloudSync.run(
          cloud,
          localDirty: dirty,
          tracksByKey: byKey,
          onProgress: (msg) {
            _message = msg;
            notifyListeners();
          },
        );
        cloudUp = cloudResult.uploaded;
        cloudDown = cloudResult.downloaded;
        _cloudDirty = false;
        if (cloudResult.downloaded > 0) {
          await library.scanLibrary(newOnly: true);
          final applied = await cloudSync.applyPendingMembership({
            for (final t in library.tracks) t.trackKey: t,
          });
          if (applied || cloudResult.membershipChanged) {
            await library.reload();
          }
        } else if (cloudResult.membershipChanged) {
          await library.reload();
        }
        if (cloudResult.changed) {
          _libraryNeedsReload = true;
        }
      } else {
        _cloudDirty = false;
      }

      if (library != null && _settings.syncArtistPhotos) {
        final photoSync = ArtistPhotosSync(
          paths: library.paths,
          settings: _settings,
        );
        final photoResult = await photoSync.run(
          cloud,
          onProgress: (msg) {
            _message = msg;
            notifyListeners();
          },
        );
        photosUp = photoResult.uploaded;
        photosDown = photoResult.downloaded;
        if (photoResult.changed) {
          _libraryNeedsReload = true;
          library.notifyPhotosChanged();
        }
      }

      _lastSyncAt = DateTime.now();
      await _db.setSyncMeta(
        'last_sync_at',
        _lastSyncAt!.toUtc().toIso8601String(),
      );
      _libraryNeedsReload = _libraryNeedsReload ||
          result.applied > 0 ||
          result.uploaded > 0 ||
          result.countsMerged > 0;
      final cloudPart = (cloudUp > 0 || cloudDown > 0)
          ? ', облако ↑$cloudUp ↓$cloudDown'
          : '';
      final photosPart = (photosUp > 0 || photosDown > 0)
          ? ', фото ↑$photosUp ↓$photosDown'
          : '';
      _message =
          'Готово: ↑${result.uploaded} ↓${result.downloaded} '
          'применено ${result.applied}'
          '${result.countsMerged > 0 ? ', счётчики +${result.countsMerged}' : ''}'
          '$cloudPart$photosPart';
    } catch (e) {
      _message = 'Ошибка синка: $e';
    } finally {
      _busy = false;
      notifyListeners();
      if (_autoSyncQueued) {
        _autoSyncQueued = false;
        _scheduleAutoSync();
      }
    }
  }

  void _scheduleAutoSync() {
    if (_shuttingDown) return;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(_autoSyncDelay, () {
      unawaited(syncNow(interactive: false));
    });
  }

  Future<void> enqueuePlaylistChange(int playlistId, {bool deleted = false}) async {
    final pl = await _db.getPlaylist(playlistId, includeDeleted: true);
    if (pl == null || pl.isSystem) return;
    final deviceId = await _db.getOrCreateDeviceId();
    final event = await _db.buildPlaylistUpsertEvent(
      playlistId: playlistId,
      deviceId: deviceId,
      deleted: deleted,
    );
    await _db.enqueueSyncEvent(event);
    _scheduleAutoSync();
  }

  Future<void> enqueuePlay(String trackKey, {DateTime? at}) async {
    final when = at ?? DateTime.now();
    final deviceId = await _db.getOrCreateDeviceId();
    final ms = when.millisecondsSinceEpoch;
    final identity = await _db.getTrackIdentity(trackKey);
    await _db.enqueueSyncEvent(
      SyncEvent(
        id: 'play_${deviceId}_${trackKey}_$ms',
        deviceId: deviceId,
        at: when.toUtc(),
        type: SyncEvent.playRecorded,
        payload: {
          'trackKey': trackKey,
          'playedAt': ms,
          if (identity != null) ...{
            'artist': identity.artist,
            'title': identity.title,
            if (identity.note != null && identity.note!.trim().isNotEmpty)
              'note': identity.note,
          },
        },
      ),
    );
    _scheduleAutoSync();
  }

  Future<void> enqueueArtistAlias({
    required String fromDisplay,
    required String toDisplay,
  }) async {
    final deviceId = await _db.getOrCreateDeviceId();
    final fromNorm = normalizeTag(fromDisplay);
    await _db.enqueueSyncEvent(
      SyncEvent(
        id: _uuid.v4(),
        deviceId: deviceId,
        at: DateTime.now().toUtc(),
        type: SyncEvent.artistAlias,
        payload: {
          'fromDisplay': fromDisplay,
          'toDisplay': toDisplay,
          'fromNorm': fromNorm,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
    _scheduleAutoSync();
  }

  Future<void> enqueueProducerAlias({
    required String fromDisplay,
    required String toDisplay,
  }) async {
    final deviceId = await _db.getOrCreateDeviceId();
    final fromNorm = normalizeTag(fromDisplay);
    await _db.enqueueSyncEvent(
      SyncEvent(
        id: _uuid.v4(),
        deviceId: deviceId,
        at: DateTime.now().toUtc(),
        type: SyncEvent.producerAlias,
        payload: {
          'fromDisplay': fromDisplay,
          'toDisplay': toDisplay,
          'fromNorm': fromNorm,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
    _scheduleAutoSync();
  }

  Future<void> loadLastSyncFromDb() async {
    final raw = await _db.getSyncMeta('last_sync_at');
    if (raw == null || raw.isEmpty) return;
    try {
      _lastSyncAt = DateTime.parse(raw);
      notifyListeners();
    } catch (_) {}
  }
}
