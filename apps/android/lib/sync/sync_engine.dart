import 'dart:async';
import 'dart:convert';

import '../data/database.dart';
import '../data/track_key.dart';
import '../services/settings_service.dart';
import 'cloud_sync_client.dart';
import 'sync_event.dart';

class SyncResult {
  const SyncResult({
    required this.uploaded,
    required this.downloaded,
    required this.applied,
    this.countsMerged = 0,
  });

  final int uploaded;
  final int downloaded;
  final int applied;
  final int countsMerged;
}

typedef SyncProgress = void Function(String message);

/// Upload local outbox chunks and merge remote Drive events into SQLite.
class SyncEngine {
  SyncEngine({
    required AppDatabase db,
    required SettingsService settings,
  })  : _db = db,
        _settings = settings;

  final AppDatabase _db;
  final SettingsService _settings;

  static const _seenChunksKeyPrefix = 'seen_chunks';
  static const _seededKey = 'local_seeded_v1';
  static const _playsSeededKey = 'plays_seeded_v1';
  static const _uploadBatchSize = 400;
  static const _driveTimeout = Duration(seconds: 90);

  /// Cloud provider id — namespaces seen chunk ids.
  String _providerId = 'yandex';

  String get _seenChunksKey => '${_seenChunksKeyPrefix}_$_providerId';

  Set<String>? _localKeys;
  Map<String, String>? _byFullIdentity;
  Map<String, List<String>>? _byArtistTitle;
  Map<String, List<String>>? _byTitle;
  Map<String, String>? _artistByKey;

  Future<SyncResult> run(
    CloudSyncClient drive, {
    SyncProgress? onProgress,
    String providerId = 'yandex',
  }) async {
    void progress(String msg) => onProgress?.call(msg);
    _providerId = providerId.trim().isEmpty ? 'yandex' : providerId.trim();

    // Library may have changed since last sync on this service instance.
    _localKeys = null;
    _byFullIdentity = null;
    _byArtistTitle = null;
    _byTitle = null;
    _artistByKey = null;

    final deviceId = await _db.getOrCreateDeviceId();
    progress('Подготовка локальных данных…');
    await _seedLocalIfNeeded(deviceId);
    if (_settings.syncPlays) {
      progress('Подготовка истории прослушиваний…');
      await _seedPlaysIfNeeded(deviceId);
    }

    final pending = await _db.pendingSyncEvents();
    final uploadable = [
      for (final e in pending)
        if (_allowsType(e.type)) e,
    ];
    var uploaded = 0;
    if (uploadable.isNotEmpty) {
      for (var i = 0; i < uploadable.length; i += _uploadBatchSize) {
        final slice = uploadable.sublist(
          i,
          (i + _uploadBatchSize).clamp(0, uploadable.length),
        );
        final name =
            '${CloudSyncClient.eventsPrefix}${deviceId.substring(0, 8)}_'
            '${DateTime.now().toUtc().millisecondsSinceEpoch}_$i.jsonl';
        progress(
          'Выгрузка ${i + 1}–${i + slice.length} из ${uploadable.length}…',
        );
        final body = slice.map((e) => e.toJsonLine()).join('\n');
        await _timeout(
          drive.uploadEventChunk(name: name, jsonl: body),
          'upload $name',
        );
        await _db.markSyncEventsUploaded(slice.map((e) => e.id));
        uploaded += slice.length;
        await _markChunkSeen(name);
      }
    }

    if (_settings.syncPlays) {
      progress('Выгрузка счётчиков прослушиваний…');
      await _uploadPlayCountsSnapshot(drive, deviceId);
    }

    progress('Проверка облака…');
    final seen = await _seenChunks();
    final chunks = await _timeout(drive.listEventChunks(), 'list chunks');
    var downloaded = 0;
    var applied = 0;
    for (final file in chunks) {
      final name = file.name;
      final id = file.id;
      if (seen.contains(name)) continue;
      progress('Загрузка $name…');
      final text = await _timeout(drive.downloadText(id), 'download $name');
      downloaded++;
      final events = <SyncEvent>[
        for (final line in const LineSplitter().convert(text))
          if (SyncEvent.tryParseLine(line) case final e?) e,
      ];
      final n = await _applyEvents(events, progress: progress);
      applied += n;
      await _markChunkSeen(name);
    }

    var countsMerged = 0;
    if (_settings.syncPlays) {
      progress('Слияние счётчиков прослушиваний…');
      countsMerged = await _pullPlayCountsSnapshots(
        drive,
        progress: progress,
      );
      applied += countsMerged;
    }

    progress('Обновление статуса…');
    await _timeout(
      drive.uploadMeta({
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'deviceId': deviceId,
        'provider': _providerId,
        'uploaded': uploaded,
        'downloaded': downloaded,
        'applied': applied,
        'countsMerged': countsMerged,
      }),
      'upload meta',
    );

    return SyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      applied: applied,
      countsMerged: countsMerged,
    );
  }

  Future<T> _timeout<T>(Future<T> future, String label) {
    return future.timeout(
      _driveTimeout,
      onTimeout: () => throw TimeoutException(
        'Таймаут Drive ($label). Проверьте сеть/VPN и повторите.',
      ),
    );
  }

  bool _allowsType(String type) {
    switch (type) {
      case SyncEvent.playRecorded:
      case SyncEvent.playCountsMerge:
        return _settings.syncPlays;
      case SyncEvent.artistAlias:
      case SyncEvent.producerAlias:
        return _settings.syncAliases;
      case SyncEvent.playlistUpsert:
        return _settings.syncPlaylists;
      case SyncEvent.settingsFlags:
        return true;
      default:
        return true;
    }
  }

  Future<void> _seedLocalIfNeeded(String deviceId) async {
    final seeded = await _db.getSyncMeta(_seededKey);
    if (seeded == '1') return;

    final events = <SyncEvent>[];
    if (_settings.syncPlaylists) {
      final playlists = await _db.getPlaylists();
      for (final pl in playlists) {
        if (pl.isSystem) continue;
        events.add(
          await _db.buildPlaylistUpsertEvent(
            playlistId: pl.id,
            deviceId: deviceId,
          ),
        );
      }
    }

    if (_settings.syncAliases) {
      for (final row in await _db.getArtistAliases()) {
        events.add(
          SyncEvent(
            id: 'alias_artist_${row.fromNorm}',
            deviceId: deviceId,
            at: DateTime.now().toUtc(),
            type: SyncEvent.artistAlias,
            payload: {
              'fromDisplay': row.fromDisplay,
              'toDisplay': row.toDisplay,
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
            },
          ),
        );
      }
      for (final row in await _db.getProducerAliases()) {
        events.add(
          SyncEvent(
            id: 'alias_producer_${row.fromNorm}',
            deviceId: deviceId,
            at: DateTime.now().toUtc(),
            type: SyncEvent.producerAlias,
            payload: {
              'fromDisplay': row.fromDisplay,
              'toDisplay': row.toDisplay,
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
            },
          ),
        );
      }
    }

    final flags = _settings.exportSettingsFlags();
    events.add(
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

    await _db.enqueueSyncEvents(events);
    await _db.setSyncMeta(_seededKey, '1');
  }

  Future<void> _seedPlaysIfNeeded(String deviceId) async {
    final seeded = await _db.getSyncMeta(_playsSeededKey);
    if (seeded == '1') return;

    final identities = {
      for (final t in await _db.getAllTrackIdentities()) t.trackKey: t,
    };
    final plays = await _db.getAllPlayEvents();
    final events = <SyncEvent>[
      for (final e in plays)
        SyncEvent(
          id: 'play_${e.trackKey}_${e.playedAt}',
          deviceId: deviceId,
          at: DateTime.fromMillisecondsSinceEpoch(e.playedAt).toUtc(),
          type: SyncEvent.playRecorded,
          payload: {
            'trackKey': e.trackKey,
            'playedAt': e.playedAt,
            if (identities[e.trackKey] case final id?) ...{
              'artist': id.artist,
              'title': id.title,
              if (id.note != null && id.note!.trim().isNotEmpty) 'note': id.note,
            },
          },
        ),
    ];
    await _db.enqueueSyncEvents(events);
    await _db.setSyncMeta(_playsSeededKey, '1');
  }

  /// Upsert absolute counts for this device. Pulled every sync on all devices.
  Future<void> _uploadPlayCountsSnapshot(
    CloudSyncClient drive,
    String deviceId,
  ) async {
    final rows = await _db.getPlayCountsWithIdentity();
    await _timeout(
      drive.uploadPlayCounts(
        deviceId: deviceId,
        payload: {
          'deviceId': deviceId,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'entries': [
            for (final r in rows)
              {
                'trackKey': r.trackKey,
                'count': r.count,
                if (r.artist != null) 'artist': r.artist,
                if (r.title != null) 'title': r.title,
                if (r.note != null && r.note!.trim().isNotEmpty) 'note': r.note,
              },
          ],
        },
      ),
      'upload play counts',
    );
  }

  Future<int> _pullPlayCountsSnapshots(
    CloudSyncClient drive, {
    SyncProgress? progress,
  }) async {
    final files = await _timeout(
      drive.listPlayCountFiles(),
      'list play counts',
    );
    if (files.isEmpty) return 0;
    await _ensureIdentityIndex();
    var applied = 0;
    for (final file in files) {
      final id = file.id;
      final name = file.name;
      progress?.call('Счётчики: $name…');
      final text = await _timeout(drive.downloadText(id), 'download $name');
      final decoded = jsonDecode(text);
      if (decoded is! Map) continue;
      final payload = decoded.map((k, v) => MapEntry(k.toString(), v));
      applied += await _mergePlayCountEntries(payload['entries']);
    }
    return applied;
  }

  Future<int> _mergePlayCountEntries(Object? raw) async {
    if (raw is! List || raw.isEmpty) return 0;
    var changed = 0;
    var skipped = 0;
    for (final item in raw) {
      if (item is! Map) continue;
      final map = item.map((k, v) => MapEntry(k.toString(), v));
      final count = _parseInt(map['count']);
      if (count == null || count <= 0) continue;
      final key = _resolveTrackKey(map);
      if (key == null || key.isEmpty) {
        skipped++;
        continue;
      }
      changed += await _db.ensureMinPlayCount(key, count);
    }
    if (skipped > 0) {
      // ignore: avoid_print
      print('sync: skipped $skipped play-count rows (no local track match)');
    }
    return changed;
  }

  Future<int> _applyEvents(
    List<SyncEvent> events, {
    SyncProgress? progress,
  }) async {
    if (events.isEmpty) return 0;
    final already = await _db.syncAppliedIdsAmong(events.map((e) => e.id));
    final fresh = [
      for (final e in events)
        if (!already.contains(e.id)) e,
    ];
    if (fresh.isEmpty) {
      await _db.markSyncAppliedMany(events.map((e) => e.id));
      return 0;
    }

    await _ensureIdentityIndex();

    var applied = 0;
    final playBatch = <({String trackKey, int playedAt, String id})>[];

    Future<void> flushPlays() async {
      if (playBatch.isEmpty) return;
      progress?.call('Применение прослушиваний (${playBatch.length})…');
      final pairs = [
        for (final e in playBatch)
          (trackKey: e.trackKey, playedAt: e.playedAt),
      ];
      final existing = await _db.playEventKeysAmong(pairs);
      final toInsert = <({String trackKey, int playedAt})>[
        for (final e in playBatch)
          if (!existing.contains('${e.trackKey}|${e.playedAt}'))
            (trackKey: e.trackKey, playedAt: e.playedAt),
      ];
      await _db.recordPlaysBatch(toInsert);
      await _db.markSyncAppliedMany(playBatch.map((e) => e.id));
      applied += toInsert.length;
      playBatch.clear();
    }

    for (final event in fresh) {
      if (!_allowsType(event.type)) {
        // Category disabled locally — consume without applying.
        if (_isKnownEventType(event.type)) {
          await _db.markSyncApplied(event.id);
        }
        continue;
      }
      if (event.type == SyncEvent.playRecorded) {
        final playedAt = _parseInt(event.payload['playedAt']);
        final trackKey = _resolveTrackKey(event.payload);
        if (trackKey == null || trackKey.isEmpty || playedAt == null) {
          await _db.markSyncApplied(event.id);
          continue;
        }
        playBatch.add((trackKey: trackKey, playedAt: playedAt, id: event.id));
        if (playBatch.length >= 400) await flushPlays();
        continue;
      }

      await flushPlays();
      final ok = await _applyOther(event, progress: progress);
      if (ok) {
        await _db.markSyncApplied(event.id);
        applied++;
      } else if (_isKnownEventType(event.type)) {
        // Known but no-op (stale playlist, empty alias) — still consume.
        await _db.markSyncApplied(event.id);
      }
      // Unknown types stay unapplied so newer clients can handle them.
    }
    await flushPlays();
    return applied;
  }

  static bool _isKnownEventType(String type) =>
      type == SyncEvent.playlistUpsert ||
      type == SyncEvent.playRecorded ||
      type == SyncEvent.playCountsMerge ||
      type == SyncEvent.artistAlias ||
      type == SyncEvent.producerAlias ||
      type == SyncEvent.settingsFlags;

  Future<bool> _applyOther(
    SyncEvent event, {
    SyncProgress? progress,
  }) async {
    switch (event.type) {
      case SyncEvent.playlistUpsert:
        return _db.applyPlaylistUpsertPayload(event.payload);
      case SyncEvent.playCountsMerge:
        return _applyPlayCountsMerge(event.payload, progress: progress);
      case SyncEvent.artistAlias:
        final from = event.payload['fromDisplay'] as String?;
        final to = event.payload['toDisplay'] as String?;
        if (from == null || to == null) return false;
        if (normalizeTag(from).isEmpty || normalizeTag(to).isEmpty) {
          return false;
        }
        await _db.upsertArtistAlias(fromDisplay: from, toDisplay: to);
        return true;
      case SyncEvent.producerAlias:
        final from = event.payload['fromDisplay'] as String?;
        final to = event.payload['toDisplay'] as String?;
        if (from == null || to == null) return false;
        if (normalizeTag(from).isEmpty || normalizeTag(to).isEmpty) {
          return false;
        }
        await _db.upsertProducerAlias(fromDisplay: from, toDisplay: to);
        return true;
      case SyncEvent.settingsFlags:
        await _settings.importSettingsFlags(
          Map<String, dynamic>.from(event.payload),
        );
        return true;
      default:
        return false;
    }
  }

  Future<bool> _applyPlayCountsMerge(
    Map<String, Object?> payload, {
    SyncProgress? progress,
  }) async {
    final raw = payload['entries'];
    if (raw is! List || raw.isEmpty) return false;
    progress?.call('Слияние счётчиков (${raw.length})…');
    final changed = await _mergePlayCountEntries(raw);
    return changed > 0;
  }

  Future<void> _ensureIdentityIndex() async {
    if (_localKeys != null) return;
    final rows = await _db.getAllTrackIdentities();
    final keys = <String>{};
    final byFull = <String, String>{};
    final bySoft = <String, List<String>>{};
    final byTitle = <String, List<String>>{};
    final artistByKey = <String, String>{};
    for (final t in rows) {
      keys.add(t.trackKey);
      artistByKey[t.trackKey] = t.artist;
      final full = _fullIdentityKey(t.artist, t.title, t.note);
      byFull[full] = t.trackKey;
      final soft = _softIdentityKey(t.artist, t.title);
      (bySoft[soft] ??= []).add(t.trackKey);
      final titleKey = normalizeTag(t.title);
      if (titleKey.isNotEmpty) {
        (byTitle[titleKey] ??= []).add(t.trackKey);
      }
    }
    _localKeys = keys;
    _byFullIdentity = byFull;
    _byArtistTitle = bySoft;
    _byTitle = byTitle;
    _artistByKey = artistByKey;
  }

  /// Resolve only to a key that exists in the local library (metadata only).
  String? _resolveTrackKey(Map<String, Object?> payload) {
    final remoteKey = payload['trackKey'] as String?;
    final artist = payload['artist'] as String?;
    final title = payload['title'] as String?;
    final note = payload['note'] as String?;

    final localKeys = _localKeys;
    bool isLocal(String? key) =>
        key != null &&
        key.isNotEmpty &&
        localKeys != null &&
        localKeys.contains(key);

    if (isLocal(remoteKey)) return remoteKey;

    if (artist != null && title != null) {
      final built = buildTrackKey(artist: artist, title: title, note: note);
      if (isLocal(built)) return built;

      final full = _fullIdentityKey(artist, title, note);
      final byFull = _byFullIdentity?[full];
      if (isLocal(byFull)) return byFull;

      // Same artists+title, note may differ between devices — still one track.
      final soft = _softIdentityKey(artist, title);
      final candidates = _byArtistTitle?[soft];
      if (candidates != null) {
        final local = [for (final k in candidates) if (isLocal(k)) k];
        if (local.isNotEmpty) {
          if (local.length == 1) return local.first;
          final want = buildTrackKey(artist: artist, title: title, note: note);
          if (local.contains(want)) return want;
          final blank = buildTrackKey(artist: artist, title: title);
          if (local.contains(blank)) return blank;
          return local.first;
        }
      }

      // Artist tag drift: "NEXTIME" vs "NEXTIME, Даник" — same title +
      // overlapping artist set, unique hit.
      final titleKey = normalizeTag(title);
      final titleHits = _byTitle?[titleKey];
      if (titleHits != null && titleHits.isNotEmpty) {
        final remoteArtists = normalizeArtistsForKey(artist)
            .split(',')
            .where((e) => e.isNotEmpty)
            .toSet();
        final matched = <String>[];
        for (final key in titleHits) {
          if (!isLocal(key)) continue;
          final localArtist = _artistByKey?[key];
          if (localArtist == null) continue;
          final localArtists = normalizeArtistsForKey(localArtist)
              .split(',')
              .where((e) => e.isNotEmpty)
              .toSet();
          if (remoteArtists.intersection(localArtists).isNotEmpty) {
            matched.add(key);
          }
        }
        if (matched.length == 1) return matched.first;
      }
    }

    return null;
  }

  static String _fullIdentityKey(String artist, String title, String? note) {
    final parts = [
      normalizeArtistsForKey(artist),
      normalizeTag(title),
    ];
    final label = metaFieldText(note);
    if (label.isNotEmpty) parts.add(normalizeTag(label));
    return parts.join('|');
  }

  static String _softIdentityKey(String artist, String title) =>
      '${normalizeArtistsForKey(artist)}|${normalizeTag(title)}';

  static int? _parseInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.round();
    return int.tryParse('$raw');
  }

  Future<Set<String>> _seenChunks() async {
    var raw = await _db.getSyncMeta(_seenChunksKey);
    // Migrate legacy unscoped key once.
    if (raw == null || raw.isEmpty) {
      raw = await _db.getSyncMeta('seen_chunks');
      if (raw != null && raw.isNotEmpty) {
        await _db.setSyncMeta(_seenChunksKey, raw);
      }
    }
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return {for (final e in decoded) if (e is String) e};
      }
    } catch (_) {}
    return {};
  }

  Future<void> _markChunkSeen(String name) async {
    final seen = await _seenChunks()..add(name);
    await _db.setSyncMeta(_seenChunksKey, jsonEncode(seen.toList()..sort()));
  }
}
