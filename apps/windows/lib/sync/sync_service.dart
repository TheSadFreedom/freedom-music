import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../data/track_key.dart';
import '../services/settings_service.dart';
import 'google_drive_auth.dart';
import 'google_drive_client.dart';
import 'sync_engine.dart';
import 'sync_event.dart';

/// Orchestrates Google Drive sync and exposes status for Settings.
class SyncService extends ChangeNotifier {
  SyncService({
    required AppDatabase db,
    required SettingsService settings,
    String? authStorageDir,
  })  : _db = db,
        _settings = settings,
        _engine = SyncEngine(db: db, settings: settings),
        _auth = GoogleDriveAuth(storageDir: authStorageDir);

  final AppDatabase _db;
  final SettingsService _settings;
  final SyncEngine _engine;
  final GoogleDriveAuth _auth;
  final _uuid = const Uuid();

  static const _autoSyncDelay = Duration(seconds: 2);

  DriveAuthSession? _session;
  bool _busy = false;
  String? _message;
  DateTime? _lastSyncAt;
  bool _libraryNeedsReload = false;
  bool _needsDriveConsent = false;
  Timer? _autoSyncTimer;
  bool _autoSyncQueued = false;
  bool _shuttingDown = false;

  bool get busy => _busy;
  bool get isSignedIn => _session != null || _auth.isSignedIn;
  bool get hasDriveAccess => _session != null;
  bool get needsDriveConsent => _needsDriveConsent;
  String? get email => _session?.email ?? _auth.email;
  String? get message => _message;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get libraryNeedsReload => _libraryNeedsReload;

  void clearLibraryNeedsReload() => _libraryNeedsReload = false;

  Future<void> tryRestoreSession() async {
    final session = await _auth.trySilent();
    if (session == null) {
      if (_auth.isSignedIn) {
        _needsDriveConsent = true;
        notifyListeners();
      }
      return;
    }
    _session = session;
    _needsDriveConsent = false;
    notifyListeners();
  }

  /// Account sign-in. On Android Drive consent may need a second tap.
  Future<void> signIn() async {
    _busy = true;
    _message = 'Вход в Google…';
    notifyListeners();
    try {
      final email = await _auth.signInAccount();
      _message = 'Проверка доступа к Drive…';
      notifyListeners();
      final session = await _auth.authorizeDrive(interactive: false);
      if (session != null) {
        _session = session;
        _needsDriveConsent = false;
        _message = 'Вход выполнен: ${session.email}';
        return;
      }
      _needsDriveConsent = true;
      _message =
          'Аккаунт $email. Нажмите «Разрешить Drive», чтобы открыть доступ.';
    } catch (e) {
      final text = '$e';
      if (text.contains('canceled') || text.contains('Cancelled')) {
        _message =
            'Вход отменён. Если окно закрылось само — добавьте SHA-1 '
            'release-ключа в Android OAuth client (Google Cloud).';
      } else {
        _message = 'Ошибка входа: $e';
      }
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Must be called from a fresh user gesture (button/dialog).
  Future<void> grantDriveAccess() async {
    _busy = true;
    _message = 'Запрос доступа к Drive…';
    notifyListeners();
    try {
      final session = await _auth.authorizeDrive(interactive: true);
      if (session == null) {
        _needsDriveConsent = true;
        _message = 'Доступ к Drive не получен';
        throw StateError(_message!);
      }
      _session = session;
      _needsDriveConsent = false;
      _message = 'Доступ к Drive разрешён: ${session.email}';
    } catch (e) {
      _message = 'Ошибка доступа к Drive: $e';
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    final session = _session;
    _session = null;
    _needsDriveConsent = false;
    _busy = false;
    _message = 'Вы вышли из Google';
    notifyListeners();
    try {
      await _auth.signOut();
    } catch (_) {}
    try {
      session?.client.close();
    } catch (_) {}
  }

  /// Stop scheduling / starting sync — in-flight run may finish, but quit
  /// does not wait for it.
  void cancelPendingWork() {
    _shuttingDown = true;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    _autoSyncQueued = false;
  }

  /// [interactive]: if false (auto-sync), never opens the sign-in UI.
  Future<void> syncNow({bool interactive = true}) async {
    if (_shuttingDown) return;
    if (_busy) {
      if (!interactive) _autoSyncQueued = true;
      return;
    }

    var session = _session;
    session ??= await _auth.trySilent();
    if (session == null) {
      if (!interactive) return;
      if (_auth.isSignedIn || _needsDriveConsent) {
        _message =
            'Сначала разрешите доступ к Drive кнопкой «Разрешить Drive»';
        notifyListeners();
        return;
      }
      try {
        await signIn();
      } catch (e) {
        _message = 'Ошибка синка: $e';
        notifyListeners();
        return;
      }
      session = _session;
      if (session == null) {
        _message =
            'Сначала разрешите доступ к Drive кнопкой «Разрешить Drive»';
        notifyListeners();
        return;
      }
    }
    _session = session;

    _busy = true;
    _message = 'Синхронизация…';
    notifyListeners();
    try {
      // Push current settings flags each sync (LWW).
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

      final drive = GoogleDriveClient(session.client);
      final result = await _engine.run(
        drive,
        onProgress: (msg) {
          _message = msg;
          notifyListeners();
        },
      );
      _lastSyncAt = DateTime.now();
      await _db.setSyncMeta(
        'last_sync_at',
        _lastSyncAt!.toUtc().toIso8601String(),
      );
      _libraryNeedsReload =
          result.applied > 0 || result.uploaded > 0 || result.countsMerged > 0;
      _message =
          'Готово: ↑${result.uploaded} ↓${result.downloaded} '
          'применено ${result.applied}'
          '${result.countsMerged > 0 ? ', счётчики +${result.countsMerged}' : ''}';
    } catch (e) {
      _message = 'Ошибка синка: $e';
      // Don't rethrow — UI already shows message; avoids "hanging" feel after cancel.
    } finally {
      _busy = false;
      notifyListeners();
      if (_autoSyncQueued) {
        _autoSyncQueued = false;
        _scheduleAutoSync();
      }
    }
  }

  /// Debounced background sync after local outbox changes.
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
