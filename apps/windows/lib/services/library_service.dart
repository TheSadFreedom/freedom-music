import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';
import '../data/database.dart';
import '../data/track_key.dart';
import '../models/artist_release.dart';
import '../models/catalog_search.dart';
import '../models/playlist.dart';
import '../models/playlist_mosaic.dart';
import '../models/track.dart';
import '../utils/lyrics_format.dart';
import 'backup_service.dart';
import 'lyrics_service.dart';
import 'metadata_writer.dart';
import 'scanner_service.dart';
import 'settings_service.dart';
import '../sync/sync_service.dart';

class JobLogField {
  const JobLogField(this.label, this.value);

  final String label;
  final String value;
}

class JobLogEntry {
  const JobLogEntry({
    required this.artist,
    required this.title,
    required this.fields,
    required this.ok,
    required this.at,
    this.error,
  });

  final String artist;
  final String title;
  final List<JobLogField> fields;
  final bool ok;
  final DateTime at;
  final String? error;

  String get summary {
    final who = '$artist — $title';
    if (!ok) return '$who: ${error ?? 'не записалось'}';
    if (fields.isEmpty) return who;
    return '$who: ${fields.map((field) => '${field.label} ${field.value}').join(', ')}';
  }
}

class LibraryService extends ChangeNotifier {
  LibraryService({
    required AppPaths paths,
    required AppDatabase db,
    required SettingsService settings,
    SyncService? sync,
  })  : _paths = paths,
        _db = db,
        _settings = settings,
        _sync = sync,
        _scanner = ScannerService(paths: paths, db: db),
        _lyrics = LyricsService(),
        _backup = BackupService(paths: paths, db: db, settings: settings);

  final AppPaths _paths;
  final AppDatabase _db;
  final SettingsService _settings;
  SyncService? _sync;

  /// Wired after both services exist (circular create order).
  void attachSync(SyncService sync) => _sync = sync;

  /// Bumps when play counts change (local play or Drive sync) so chart reloads.
  int _playStatsEpoch = 0;
  int get playStatsEpoch => _playStatsEpoch;

  void bumpPlayStats() {
    _playStatsEpoch++;
    notifyListeners();
  }
  final ScannerService _scanner;

  /// Плеер освобождает открытые файлы перед записью тегов (Windows rename).
  Future<T> Function<T>(
    Iterable<String> paths,
    Future<T> Function() action, {
    void Function(T result)? beforeRelock,
  })?
  unlockAudioForWrite;
  final LyricsService _lyrics;
  final BackupService _backup;

  final Set<String> _lyricsFetching = {};
  final Set<String> _lyricsMisses = {};

  /// Текст, найденный из плеера: только показ в сессии, без тегов и БД.
  final Map<String, String> _lyricsSession = {};

  bool isFetchingLyrics(String trackKey) => _lyricsFetching.contains(trackKey);

  bool lyricsLookupFailed(String trackKey) => _lyricsMisses.contains(trackKey);

  List<Track> _tracks = [];
  List<Playlist> _playlists = [];
  Map<int, List<String>> _mosaicCache = {};
  final Map<String, String> _trackKeyAlias = {};

  /// normalizeTag(alias) → artist-card display name.
  Map<String, String> _aliasToCard = {};

  /// normalizeTag(card) → other names that open the same artist card.
  Map<String, List<String>> _aliasLabelsByCard = {};

  /// normalizeTag(alias) → producer-card display name.
  Map<String, String> _producerAliasToCard = {};

  /// normalizeTag(card) → other names that open the same producer card.
  Map<String, List<String>> _producerAliasLabelsByCard = {};
  _CatalogIndex? _catalogIndex;
  String? _catalogQuery;
  CatalogSearch? _catalogHit;
  bool _loading = true;
  bool _scanning = false;
  ScanProgress? _scanProgress;
  String? _lastScanMessage;
  String? _error;
  final List<JobLogEntry> _jobLog = [];

  AppPaths get paths => _paths;
  List<Track> get tracks => _tracks;

  List<Track>? _catalogCache;
  Map<String, List<Track>>? _genreCache;
  Map<String, List<Track>>? _artistCache;
  Map<String, List<Track>>? _producerCache;
  List<ReleaseCalendarSection>? _calendarCache;

  void _dropSlices() {
    _catalogCache = null;
    _genreCache = null;
    _artistCache = null;
    _producerCache = null;
    _calendarCache = null;
  }

  void _ensureTrackSlices() {
    if (_catalogCache != null) return;
    final catalog = <Track>[];
    final genre = <String, List<Track>>{};
    final artist = <String, List<Track>>{};
    final artistLabels = <String, String>{};
    final producer = <String, List<Track>>{};
    final producerLabels = <String, String>{};

    for (final track in _tracks) {
      catalog.add(track);
      final name = track.displayGenre;
      if (name.isNotEmpty) {
        genre.putIfAbsent(name, () => []).add(track);
      }
      _putArtist(track, artist, artistLabels);
      for (final raw in producerNames(track.producer)) {
        final card = producerCardName(raw);
        final label = producerLabels.putIfAbsent(card.toLowerCase(), () => card);
        final list = producer.putIfAbsent(label, () => []);
        if (!list.any((existing) => existing.trackKey == track.trackKey)) {
          list.add(track);
        }
      }
    }

    _catalogCache = catalog;
    _genreCache = _sortedTrackMap(genre);
    _artistCache = _sortedTrackMap(artist);
    _producerCache = _sortedTrackMap(producer);
  }

  void _putArtist(
    Track track,
    Map<String, List<Track>> map,
    Map<String, String> labels,
  ) {
    for (final raw in track.artists) {
      final card = artistCardName(raw);
      final label = labels.putIfAbsent(card.toLowerCase(), () => card);
      final list = map.putIfAbsent(label, () => []);
      if (!list.any((existing) => existing.trackKey == track.trackKey)) {
        list.add(track);
      }
    }
  }

  Map<String, List<Track>> _sortedTrackMap(Map<String, List<Track>> map) {
    final keys = map.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return {for (final key in keys) key: map[key]!};
  }

  /// Full library for main screens, random stream, artists, charts.
  List<Track> get catalogTracks {
    _ensureTrackSlices();
    return _catalogCache!;
  }

  /// Named releases for the calendar. Rebuilt only when slices drop.
  List<ReleaseCalendarSection> releaseCalendar() {
    final cached = _calendarCache;
    if (cached != null) return cached;
    final sections = buildReleaseCalendar(
      catalogTracks,
      cardName: artistCardName,
    );
    _calendarCache = sections;
    return sections;
  }
  List<Playlist> get playlists {
    if (_settings.syncCloudPlaylist) return _playlists;
    return [for (final p in _playlists) if (!p.isCloud) p];
  }
  bool get loading => _loading;
  bool get scanning => _scanning;
  ScanProgress? get scanProgress => _scanProgress;
  String? get lastScanMessage => _lastScanMessage;
  List<JobLogEntry> get jobLog => List.unmodifiable(_jobLog);
  /// Progress ticks for settings. Other screens do not listen to this.
  final jobUi = _JobUi();
  DateTime _jobPaintAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _paintJob({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_jobPaintAt) < const Duration(milliseconds: 400)) {
      return;
    }
    _jobPaintAt = now;
    jobUi.ping();
  }

  String? get error => _error;
  bool get isEmpty => _tracks.isEmpty;

  Future<void>? _warmSecondaryFuture;
  bool _shuttingDown = false;

  /// Cancel scan / warm / auto-sync so quit is not blocked by background work.
  void requestShutdown() {
    _shuttingDown = true;
    cancelScan();
    _sync?.cancelPendingWork();
  }

  Future<void> init() async {
    _loading = true;
    notifyListeners();
    try {
      if (!_settings.trackKeysRemigrated) {
        final remapped = await _db.remigrateTrackKeysToArtistTitle();
        if (remapped > 0) {
          await _settings.replaceChartSnapshots({});
        }
        await _settings.setTrackKeysRemigrated();
      }
      if (!_settings.artistTagsRestored) {
        final restored = await _scanner.restoreOriginalArtistTags();
        if (restored > 0) {
          await _settings.replaceChartSnapshots({});
        }
        await _settings.setArtistTagsRestored();
      }
      // Fast path only — membership / meta / mosaics warm after first UI frame.
      // Startup scan is deferred from splash (see main._load).
      await reload(warm: false);
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Loads tracks and playlists for UI.
  ///
  /// When [warm] is true (default), also rebuilds system playlist membership,
  /// meta playlists and mosaics. Startup uses `warm: false` and calls
  /// [warmSecondary] after the first frame.
  Future<void> reload({bool warm = true}) async {
    await _db.ensureTrashPlaylist();
    await _db.ensureNewPlaylist();
    if (_settings.syncCloudPlaylist) {
      await _db.ensureCloudPlaylist();
    }
    _tracks = await _db.getAllTracks();
    _trackKeyAlias.clear();
    _playlists = await _db.getPlaylists();
    await _loadArtistAliases();
    _invalidateSearch();
    _error = null;
    notifyListeners();
    if (warm) await warmSecondary();
  }

  /// After Yandex artist-photo sync.
  void notifyPhotosChanged() => notifyListeners();

  /// Rebuilds Корзина/Новинки membership, meta playlists and cover mosaics.
  /// Safe to call concurrently — overlapping callers share one future.
  Future<void> warmSecondary() async {
    if (_shuttingDown) return;
    final inflight = _warmSecondaryFuture;
    if (inflight != null) return inflight;
    final done = _warmSecondaryWork();
    _warmSecondaryFuture = done;
    try {
      await done;
    } finally {
      if (identical(_warmSecondaryFuture, done)) {
        _warmSecondaryFuture = null;
      }
    }
  }

  Future<void> _warmSecondaryWork() async {
    if (_shuttingDown) return;
    await _db.syncTrashPlaylistMembership();
    if (_shuttingDown) return;
    await _db.syncNewPlaylistMembership();
    if (_shuttingDown) return;
    await _db.removeMetaCatalogPlaylists();
    if (_shuttingDown) return;
    _playlists = await _db.getPlaylists();
    await _refreshMosaics();
    if (_shuttingDown) return;
    notifyListeners();
  }

  Future<void> _loadArtistAliases() async {
    final artist = _aliasIndex(await _db.getArtistAliases());
    _aliasToCard = artist.toCard;
    _aliasLabelsByCard = artist.labels;
    final producer = _aliasIndex(await _db.getProducerAliases());
    _producerAliasToCard = producer.toCard;
    _producerAliasLabelsByCard = producer.labels;
  }

  ({Map<String, String> toCard, Map<String, List<String>> labels}) _aliasIndex(
    List<ArtistAlias> rows,
  ) {
    final toCard = <String, String>{};
    final labels = <String, List<String>>{};
    for (final row in rows) {
      final card = row.toDisplay.trim();
      if (card.isEmpty) continue;
      toCard[row.fromNorm] = card;
      final bucket = labels.putIfAbsent(normalizeTag(card), () => []);
      final from = row.fromDisplay.trim();
      if (from.isNotEmpty &&
          normalizeTag(from) != normalizeTag(card) &&
          !bucket.any((n) => normalizeTag(n) == normalizeTag(from))) {
        bucket.add(from);
      }
    }
    return (toCard: toCard, labels: labels);
  }

  String _cardName(String name, Map<String, String> toCard) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return trimmed;
    return toCard[normalizeTag(trimmed)] ?? trimmed;
  }

  /// Name shown on the artist card. Track tags are not rewritten.
  String artistCardName(String artistName) => _cardName(artistName, _aliasToCard);

  /// Name shown on the producer card. Track tags are not rewritten.
  String producerCardName(String producerName) =>
      _cardName(producerName, _producerAliasToCard);

  List<String> aliasLabelsForCard(String cardName) {
    return _aliasLabelsByCard[normalizeTag(cardName)] ?? const [];
  }

  List<String> producerAliasLabelsForCard(String cardName) {
    return _producerAliasLabelsByCard[normalizeTag(cardName)] ?? const [];
  }

  bool artistCardMatchesQuery(String cardName, String query) {
    return _cardMatchesQuery(cardName, query, aliasLabelsForCard(cardName));
  }

  bool producerCardMatchesQuery(String cardName, String query) {
    return _cardMatchesQuery(
      cardName,
      query,
      producerAliasLabelsForCard(cardName),
    );
  }

  bool _cardMatchesQuery(String cardName, String query, List<String> aliases) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (cardName.toLowerCase().contains(q)) return true;
    for (final alias in aliases) {
      if (alias.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  bool trackMatchesQuery(Track track, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final hay = track.searchableText;
    if (tokens.every(hay.contains)) return true;
    // Alias card names are short; only scan them when the file text missed.
    final extra = StringBuffer();
    final names = <String>[
      ...track.artists,
      ...splitArtists(track.albumArtist),
    ];
    for (final name in names) {
      final card = artistCardName(name);
      extra.write(' ');
      extra.write(card.toLowerCase());
      for (final alias in aliasLabelsForCard(card)) {
        extra.write(' ');
        extra.write(alias.toLowerCase());
      }
    }
    for (final name in producerNames(track.producer)) {
      final card = producerCardName(name);
      extra.write(' ');
      extra.write(card.toLowerCase());
      for (final alias in producerAliasLabelsForCard(card)) {
        extra.write(' ');
        extra.write(alias.toLowerCase());
      }
    }
    final more = extra.toString();
    return tokens.every((t) => hay.contains(t) || more.contains(t));
  }

  Playlist? get trashPlaylist {
    for (final pl in _playlists) {
      if (pl.isTrash) return pl;
    }
    return null;
  }

  Timer? _playlistRefreshTimer;

  Future<void> _refreshPlaylistsAfterMutation() async {
    _playlists = await _db.getPlaylists();
  }

  /// Schedule a cheap playlist COUNT refresh without mosaic rebuild.
  void _schedulePlaylistRefresh() {
    _playlistRefreshTimer?.cancel();
    _playlistRefreshTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(() async {
        await _refreshPlaylistsAfterMutation();
        notifyListeners();
      }());
    });
  }

  void _bumpPlaylistCount(int playlistId, int delta) {
    if (delta == 0) return;
    _playlists = [
      for (final pl in _playlists)
        if (pl.id == playlistId)
          pl.copyWith(
            trackCount: (pl.trackCount + delta).clamp(0, 1 << 30),
            updatedAt: DateTime.now(),
          )
        else
          pl,
    ];
  }

  void _invalidateMosaicsFor(Set<int> playlistIds) {
    if (playlistIds.isEmpty) return;
    for (final id in playlistIds) {
      _mosaicCache.remove(id);
      _playlistMosaicSig.remove(id);
    }
  }

  /// Instant UI after playlist membership change: local counts + notify;
  /// full COUNT refresh later, without mosaic rebuild.
  void _finishPlaylistMutation({required Set<int> touchedPlaylistIds}) {
    _invalidateMosaicsFor(touchedPlaylistIds);
    _invalidateSearch();
    notifyListeners();
    _schedulePlaylistRefresh();
  }

  Track? _rawTrackByKey(String trackKey) {
    for (final track in _tracks) {
      if (track.trackKey == trackKey) return track;
    }
    return null;
  }

  /// Soft-delete: hide everywhere, keep files, put into Корзина.
  Future<void> moveToTrash(String trackKey) async {
    final existing = _rawTrackByKey(trackKey);
    if (existing != null && existing.isTrashed) return;

    final trash = trashPlaylist;
    final containing = await _db.playlistIdsContainingTrack(trackKey);
    final touched = <int>{
      ...containing.where((id) => trash == null || id != trash.id),
      if (trash != null) trash.id,
    };

    await _db.moveTrackToTrash(trackKey);
    final track = _rawTrackByKey(trackKey);
    if (track != null) {
      _replaceTrack(trackKey, track.copyWith(trashedAt: DateTime.now()));
    }
    for (final id in containing) {
      if (trash != null && id == trash.id) continue;
      _bumpPlaylistCount(id, -1);
    }
    if (trash != null) _bumpPlaylistCount(trash.id, 1);
    _finishPlaylistMutation(touchedPlaylistIds: touched);
  }

  Future<void> restoreFromTrash(String trackKey) async {
    final trash = trashPlaylist;
    await _db.restoreTrackFromTrash(trackKey);
    final track = _rawTrackByKey(trackKey);
    if (track != null) {
      _replaceTrack(trackKey, track.copyWith(trashedAt: null));
    }
    if (trash != null) _bumpPlaylistCount(trash.id, -1);
    _finishPlaylistMutation(
      touchedPlaylistIds: {if (trash != null) trash.id},
    );
  }

  /// Permanently delete track files from disk and remove from the library.
  Future<void> deleteTrackPermanently(String trackKey) async {
    final containing = await _db.playlistIdsContainingTrack(trackKey);
    final live = _rawTrackByKey(trackKey);
    final filePaths = live?.filePaths ?? const <String>[];
    final coverPath = live?.coverPath;

    final meta = await _db.deleteTrackPermanently(trackKey);
    _tracks = [
      for (final track in _tracks)
        if (track.trackKey != trackKey) track,
    ];
    _dropSlices();
    for (final id in containing) {
      _bumpPlaylistCount(id, -1);
    }
    _finishPlaylistMutation(touchedPlaylistIds: containing);

    final paths = meta.filePaths.isNotEmpty ? meta.filePaths : filePaths;
    final cover = meta.coverPath ?? coverPath;
    unawaited(_deleteTrackFiles(
      trackKey: trackKey,
      filePaths: paths,
      coverPath: cover,
    ));
  }

  /// Permanently delete every track currently in trash. Returns deleted keys.
  Future<List<String>> emptyTrash() async {
    final purged = await _db.purgeAllTrashedTracks();
    if (purged.trackKeys.isEmpty) return const [];

    final remove = purged.trackKeys.toSet();
    _tracks = [
      for (final track in _tracks)
        if (!remove.contains(track.trackKey)) track,
    ];
    _dropSlices();
    final trash = trashPlaylist;
    if (trash != null) {
      _bumpPlaylistCount(trash.id, -trash.trackCount);
    }
    _finishPlaylistMutation(
      touchedPlaylistIds: {if (trash != null) trash.id},
    );

    unawaited(_deletePurgedFiles(
      trackKeys: purged.trackKeys,
      filePaths: purged.filePaths,
      coverPaths: purged.coverPaths,
    ));
    return purged.trackKeys;
  }

  Future<void> _deleteTrackFiles({
    required String trackKey,
    required List<String> filePaths,
    String? coverPath,
  }) async {
    for (final path in filePaths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    if (coverPath != null) {
      try {
        final cover = File(coverPath);
        if (await cover.exists()) await cover.delete();
      } catch (_) {}
    }
    try {
      await MetadataWriter.deleteCovers(_paths, trackKey);
    } catch (_) {}
  }

  Future<void> _deletePurgedFiles({
    required List<String> trackKeys,
    required List<String> filePaths,
    required List<String> coverPaths,
  }) async {
    final allPaths = <String>[...filePaths, ...coverPaths];
    const concurrency = 8;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= allPaths.length) return;
        try {
          final file = File(allPaths[i]);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }

    await Future.wait([
      for (var w = 0; w < concurrency; w++) worker(),
    ]);
    for (final key in trackKeys) {
      try {
        await MetadataWriter.deleteCovers(_paths, key);
      } catch (_) {}
    }
  }

  bool _cancelFill = false;

  void cancelScan() {
    if (!_scanning) return;
    _cancelFill = true;
    _scanner.requestCancel();
    _paintJob(force: true);
  }

  Future<void> scanLibrary({bool force = false, bool newOnly = false}) async {
    // Ждём текущий скан — иначе импорт из мода тихо пропускает файл.
    final waitedFrom = DateTime.now();
    while (_scanning) {
      if (DateTime.now().difference(waitedFrom) > const Duration(minutes: 3)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _scanning = true;
    _cancelFill = false;
    _scanProgress = null;
    _lastScanMessage = null;
    _jobLog.clear();
    _paintJob(force: true);

    try {
      final result = await _scanner.scan(
        force: force,
        newOnly: newOnly,
        onProgress: (p) {
          _scanProgress = p;
          _paintJob();
        },
      );

      await reload();
      final modeLabel = force
          ? 'Полный перескан. '
          : newOnly
              ? 'Только новые файлы. '
              : '';
      if (result.cancelled) {
        _lastScanMessage =
            '$modeLabel'
            'Сканирование остановлено. '
            'Успели: новых ${result.added}, обновлено ${result.updated}, '
            'без изменений ${result.skipped}.';
      } else {
        _lastScanMessage =
            '$modeLabel'
            'Файлов: ${result.totalFiles}. '
            'Новых: ${result.added}, обновлено: ${result.updated}, '
            'без изменений: ${result.skipped}, удалено: ${result.removed}.';
      }
    } catch (e) {
      _error = e.toString();
      _lastScanMessage = 'Ошибка сканирования: $e';
    } finally {
      _scanning = false;
      _cancelFill = false;
      _scanProgress = null;
      _paintJob(force: true);
    }
  }

  /// Rewrite titles and albums that end with a feat. or prod credit.
  Future<void> fixTitleCredits({
    void Function(Track updated, String oldTrackKey)? onUpdated,
  }) async {
    if (_scanning) return;
    _scanning = true;
    _cancelFill = false;
    _scanProgress = null;
    _lastScanMessage = null;
    _jobLog.clear();
    _paintJob(force: true);

    try {
      final tracks = await _db.getAllTracks(includeTrashed: true);
      final total = tracks.length;
      var changed = 0;
      var checked = 0;
      for (final track in tracks) {
        if (_cancelFill) break;
        checked++;
        final title = stripTrailingCredit(track.title);
        final album = stripTrailingCredit(track.album);
        final newTitle = title.isEmpty || title == track.title.trim()
            ? null
            : title;
        final newAlbum = album.isEmpty || album == track.album.trim()
            ? null
            : album;
        _scanProgress = ScanProgress(
          processed: checked,
          total: total,
          added: changed,
          updated: 0,
          skipped: checked - changed,
          currentFile: '${track.displayArtist} — ${track.displayTitle}',
        );
        if (newTitle == null && newAlbum == null) {
          if (checked == total || checked % 200 == 0) {
            _paintJob();
            await Future<void>.delayed(Duration.zero);
          }
          continue;
        }
        final draft = MetadataDraft.fromTrack(track);
        if (newTitle != null) draft.title = newTitle;
        if (newAlbum != null) draft.album = newAlbum;
        try {
          final updated = await saveTrackMetadata(
            track,
            draft,
            refreshLibrary: false,
            notify: false,
          );
          onUpdated?.call(updated, track.trackKey);
          _pushJobLog(
            JobLogEntry(
              artist: track.displayArtist,
              title: newTitle ?? track.displayTitle,
              fields: [
                if (newTitle != null) JobLogField('Название', newTitle),
                if (newAlbum != null) JobLogField('Альбом', newAlbum),
              ],
              ok: true,
              at: DateTime.now(),
            ),
          );
          changed++;
        } catch (e, st) {
          debugPrint('title fix ${track.trackKey}: $e\n$st');
          _pushJobLog(
            JobLogEntry(
              artist: track.displayArtist,
              title: track.displayTitle,
              fields: const [],
              ok: false,
              at: DateTime.now(),
              error: '$e',
            ),
          );
        }
        _paintJob(force: true);
        await Future<void>.delayed(Duration.zero);
      }
      await reload();
      if (_cancelFill) {
        _lastScanMessage = 'Правка названий остановлена. Исправлено: $changed.';
      } else if (changed == 0) {
        _lastScanMessage = 'Лишних feat. и prod в названиях нет.';
      } else {
        _lastScanMessage = 'Исправлено названий: $changed.';
      }
    } catch (e) {
      _error = e.toString();
      _lastScanMessage = 'Ошибка правки названий: $e';
    } finally {
      _scanning = false;
      _cancelFill = false;
      _scanProgress = null;
      _paintJob(force: true);
    }
  }

  void _pushJobLog(JobLogEntry entry) {
    _jobLog.add(entry);
    if (_jobLog.length > 80) {
      _jobLog.removeRange(0, _jobLog.length - 80);
    }
  }

  Map<String, List<Track>> tracksByGenre() {
    _ensureTrackSlices();
    return _genreCache!;
  }

  /// One track can appear under several artists ("A, B" → A and B).
  Map<String, List<Track>> tracksByArtist() {
    _ensureTrackSlices();
    return _artistCache!;
  }

  Map<String, List<Track>> tracksByProducer() {
    _ensureTrackSlices();
    return _producerCache!;
  }

  /// Tracks whose producer tag is empty. They have no producer card.
  List<Track> tracksWithoutProducer() {
    final list = _tracks
        .where((track) => producerNames(track.producer).isEmpty)
        .toList();
    list.sort((a, b) {
      final byArtist = a.displayArtist.toLowerCase().compareTo(
            b.displayArtist.toLowerCase(),
          );
      if (byArtist != 0) return byArtist;
      return a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase());
    });
    return list;
  }

  Future<List<ChartEntry>> chart(ChartPeriod period) {
    return _db.getChart(library: _tracks, period: period);
  }

  Future<Map<String, int>> playCountsAllTime() => _db.getPlayCountsAllTime();

  Future<Map<String, int>> listenMsAllTime() => _db.getListenMsAllTime();

  List<Track> search(String query) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    return _tracks.where((t) => trackMatchesQuery(t, q)).toList();
  }

  /// Home search: each list is empty when nothing in that category matched.
  ///
  /// The catalog is indexed once per library change. A keystroke only scans
  /// those prepared strings. Lyrics are checked for words of 3+ letters, so a
  /// single character does not walk every lyric.
  CatalogSearch searchCatalog(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return CatalogSearch.empty;
    if (normalized == _catalogQuery && _catalogHit != null && _catalogIndex != null) {
      return _catalogHit!;
    }

    final tokens = normalized
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    final index = _ensureCatalogIndex();
    final tracks = <Track>[];
    for (final row in index.tracks) {
      if (_rowHits(row.meta, row.lyrics, tokens)) tracks.add(row.track);
    }
    final artists = <SearchPerson>[
      for (final row in index.artists)
        if (_hayHits(row.hay, tokens))
          SearchPerson(name: row.name, trackCount: row.trackCount),
    ];
    final producers = <SearchPerson>[
      for (final row in index.producers)
        if (_hayHits(row.hay, tokens))
          SearchPerson(name: row.name, trackCount: row.trackCount),
    ];
    final albums = <SearchAlbum>[
      for (final row in index.albums)
        if (_hayHits(row.hay, tokens)) row.album,
    ];
    final playlists = <Playlist>[
      for (final row in index.playlists)
        if (_hayHits(row.hay, tokens)) row.playlist,
    ];
    final hit = CatalogSearch(
      tracks: tracks,
      artists: artists,
      producers: producers,
      albums: albums,
      playlists: playlists,
    );
    _catalogQuery = normalized;
    _catalogHit = hit;
    return hit;
  }

  void _invalidateSearch() {
    _catalogIndex = null;
    _catalogQuery = null;
    _catalogHit = null;
    _dropSlices();
  }

  _CatalogIndex _ensureCatalogIndex() {
    final cached = _catalogIndex;
    if (cached != null) return cached;

    final artistCounts = <String, int>{};
    final artistLabels = <String, String>{};
    final producerCounts = <String, int>{};
    final producerLabels = <String, String>{};
    final albumGroups = <String, List<Track>>{};
    final albumTitle = <String, String>{};
    final albumArtist = <String, String>{};
    final tracks = <_IxTrack>[];

    for (final track in _tracks) {
      final lyrics = track.lyrics?.trim();
      tracks.add(
        _IxTrack(
          track,
          _metaHay(track),
          lyrics == null || lyrics.isEmpty ? '' : lyrics.toLowerCase(),
        ),
      );
      _tallyPeople(track.artists, artistCounts, artistLabels);
      _tallyPeople(
        producerNames(track.producer),
        producerCounts,
        producerLabels,
        cardOf: producerCardName,
      );

      final album = track.displayAlbum.trim();
      if (album.isEmpty || album.toLowerCase() == 'unknown') continue;
      final artist = (track.albumArtist != null &&
              track.albumArtist!.trim().isNotEmpty)
          ? track.albumArtist!.trim()
          : track.displayArtist;
      final key = '${artist.toLowerCase()}\u0001${album.toLowerCase()}';
      albumGroups.putIfAbsent(key, () => []).add(track);
      albumTitle.putIfAbsent(key, () => album);
      albumArtist.putIfAbsent(key, () => artist);
    }

    final albums = <_IxAlbum>[];
    for (final entry in albumGroups.entries) {
      final list = entry.value;
      list.sort((a, b) {
        final byNumber = (a.trackNumber ?? 9999).compareTo(b.trackNumber ?? 9999);
        if (byNumber != 0) return byNumber;
        return a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase());
      });
      final title = albumTitle[entry.key]!;
      final artist = albumArtist[entry.key]!;
      final years = list.map((t) => t.year).whereType<int>();
      String? cover;
      for (final track in list) {
        final path = track.coverPath;
        if (path != null && path.isNotEmpty) {
          cover = path;
          break;
        }
      }
      int? year;
      for (final value in years) {
        if (year == null || value > year) year = value;
      }
      albums.add(
        _IxAlbum(
          SearchAlbum(
            artist: artist,
            release: ArtistRelease(
              title: title,
              tracks: list,
              kind: releaseKindForTracks(list),
              year: year,
              coverPath: cover,
            ),
          ),
          _albumHay(title, artist),
        ),
      );
    }
    albums.sort((a, b) {
      final byTitle = a.album.release.title.toLowerCase().compareTo(
            b.album.release.title.toLowerCase(),
          );
      if (byTitle != 0) return byTitle;
      return a.album.artist.toLowerCase().compareTo(b.album.artist.toLowerCase());
    });

    final playlists = [
      for (final playlist in _playlists)
        _IxPlaylist(playlist, playlist.name.toLowerCase()),
    ]..sort(
        (a, b) => a.hay.compareTo(b.hay),
      );

    final built = _CatalogIndex(
      tracks: tracks,
      artists: _indexedPeople(artistCounts, artistLabels),
      producers: _indexedPeople(
        producerCounts,
        producerLabels,
        producer: true,
      ),
      albums: albums,
      playlists: playlists,
    );
    _catalogIndex = built;
    return built;
  }

  void _tallyPeople(
    List<String> names,
    Map<String, int> counts,
    Map<String, String> labels, {
    String Function(String name)? cardOf,
  }) {
    final resolve = cardOf ?? artistCardName;
    final seen = <String>{};
    for (final rawName in names) {
      final card = resolve(rawName);
      final key = card.toLowerCase();
      if (key.isEmpty || key == 'unknown' || !seen.add(key)) continue;
      counts[key] = (counts[key] ?? 0) + 1;
      labels.putIfAbsent(key, () => card);
    }
  }

  List<_IxPerson> _indexedPeople(
    Map<String, int> counts,
    Map<String, String> labels, {
    bool producer = false,
  }) {
    final people = [
      for (final entry in counts.entries)
        _IxPerson(
          labels[entry.key] ?? entry.key,
          _personHay(labels[entry.key] ?? entry.key, producer: producer),
          entry.value,
        ),
    ]..sort((a, b) => a.hay.compareTo(b.hay));
    return people;
  }

  String _personHay(String card, {bool producer = false}) {
    final buf = StringBuffer(card.toLowerCase());
    final aliases = producer
        ? producerAliasLabelsForCard(card)
        : aliasLabelsForCard(card);
    for (final alias in aliases) {
      buf.write(' ');
      buf.write(alias.toLowerCase());
    }
    return buf.toString();
  }

  String _albumHay(String title, String artist) {
    final buf = StringBuffer()
      ..write(title.toLowerCase())
      ..write(' ')
      ..write(artist.toLowerCase());
    if (artist.trim().isEmpty) return buf.toString();
    for (final name in splitArtists(artist)) {
      final card = artistCardName(name);
      buf.write(' ');
      buf.write(card.toLowerCase());
      for (final alias in aliasLabelsForCard(card)) {
        buf.write(' ');
        buf.write(alias.toLowerCase());
      }
    }
    return buf.toString();
  }

  String _metaHay(Track track) {
    final buf = StringBuffer();
    void add(String? value) {
      if (isBlankMeta(value)) return;
      buf
        ..write(value)
        ..write(' ');
    }

    add(track.title);
    add(track.artist);
    add(track.albumArtist);
    add(track.producer);
    add(track.album);
    add(track.genre);
    if (track.year != null) add('${track.year}');
    for (final path in track.filePaths) {
      add(p.basenameWithoutExtension(path));
    }

    final seen = <String>{};
    void addName(
      String raw,
      String Function(String) cardOf,
      List<String> Function(String) aliasesOf,
    ) {
      final card = cardOf(raw);
      final key = card.toLowerCase();
      if (key.isEmpty || key == 'unknown' || !seen.add(key)) return;
      add(card);
      for (final alias in aliasesOf(card)) {
        add(alias);
      }
    }

    for (final name in track.artists) {
      addName(name, artistCardName, aliasLabelsForCard);
    }
    final albumArtist = track.albumArtist;
    if (albumArtist != null && albumArtist.trim().isNotEmpty) {
      for (final name in splitArtists(albumArtist)) {
        addName(name, artistCardName, aliasLabelsForCard);
      }
    }
    for (final name in producerNames(track.producer)) {
      addName(name, producerCardName, producerAliasLabelsForCard);
    }
    return buf.toString().toLowerCase();
  }

  bool _hayHits(String hay, List<String> tokens) {
    for (final token in tokens) {
      if (!hay.contains(token)) return false;
    }
    return true;
  }

  bool _rowHits(String meta, String lyrics, List<String> tokens) {
    for (final token in tokens) {
      if (meta.contains(token)) continue;
      if (token.length >= 3 && lyrics.isNotEmpty && lyrics.contains(token)) {
        continue;
      }
      return false;
    }
    return true;
  }

  Future<void> recordPlay(String trackKey) async {
    final at = DateTime.now();
    await _db.recordPlay(trackKey, at: at);
    await _sync?.enqueuePlay(trackKey, at: at);
    _playStatsEpoch++;
  }

  Future<void> addListenMs(String trackKey, int ms) =>
      _db.addListenMs(trackKey, ms);

  /// Если в файле нет текста — ищет в сети и показывает в сессии.
  /// Не пишет в теги и не пишет в БД (в отличие от job «Ищем текст»).
  Future<Track?> ensureRemoteLyrics(Track track) async {
    final key = track.trackKey;
    if (hasLyrics(track.lyrics)) return null;
    final session = _lyricsSession[key];
    if (session != null && hasLyrics(session)) {
      return _withSessionLyrics(trackByKey(key) ?? track);
    }
    final cached = trackByKey(key);
    if (cached != null && hasLyrics(cached.lyrics)) return cached;
    if (_lyricsMisses.contains(key) || _lyricsFetching.contains(key)) {
      return null;
    }

    _lyricsFetching.add(key);
    notifyListeners();
    try {
      final text = await _lyrics.fetchForTrack(track);
      if (text == null || !hasLyrics(text)) {
        _lyricsMisses.add(key);
        return null;
      }
      _lyricsSession[key] = text;
      _lyricsMisses.remove(key);
      return _withSessionLyrics(trackByKey(key) ?? track);
    } catch (e, st) {
      debugPrint('lyrics lookup $key: $e\n$st');
      _lyricsMisses.add(key);
      return null;
    } finally {
      _lyricsFetching.remove(key);
      notifyListeners();
    }
  }

  Track _withSessionLyrics(Track track) {
    if (hasLyrics(track.lyrics)) return track;
    final text = _lyricsSession[track.trackKey];
    if (text == null || !hasLyrics(text)) return track;
    return track.copyWith(lyrics: text);
  }

  Track? trackByKey(String trackKey) {
    for (final t in _tracks) {
      if (t.trackKey == trackKey) return _withSessionLyrics(t);
    }
    return null;
  }

  /// The library copy of [track] after a metadata edit, including a new key.
  Track resolveTrack(Track track) {
    final byKey = trackByKey(track.trackKey);
    if (byKey != null) return byKey;
    final path = track.primaryPath;
    if (path == null) return _withSessionLyrics(track);
    for (final candidate in _tracks) {
      if (candidate.filePaths.contains(path)) {
        return _withSessionLyrics(candidate);
      }
    }
    return _withSessionLyrics(track);
  }

  Future<void> _evictCover(String? path) async {
    if (path == null || path.isEmpty) return;
    forgetCoverFingerprint(path);
    try {
      await FileImage(File(path)).evict();
    } catch (_) {}
  }

  void _replaceTrack(String oldKey, Track updated) {
    final next = <Track>[];
    var placed = false;
    for (final track in _tracks) {
      if (track.trackKey == oldKey || track.trackKey == updated.trackKey) {
        if (!placed) {
          next.add(updated);
          placed = true;
        }
        continue;
      }
      next.add(track);
    }
    if (!placed) next.add(updated);
    _tracks = next;
    _dropSlices();
    if (oldKey == updated.trackKey) return;
    _trackKeyAlias[oldKey] = updated.trackKey;
    final rewired = <String, String>{};
    for (final entry in _trackKeyAlias.entries) {
      rewired[entry.key] =
          entry.value == oldKey ? updated.trackKey : entry.value;
    }
    _trackKeyAlias
      ..clear()
      ..addAll(rewired);
  }

  /// Play count after a metadata edit changed the track key.
  int playCountFor(Map<String, int> counts, String trackKey) {
    final direct = counts[trackKey];
    if (direct != null) return direct;
    var best = 0;
    var found = false;
    for (final entry in _trackKeyAlias.entries) {
      if (entry.value != trackKey) continue;
      final value = counts[entry.key];
      if (value == null) continue;
      found = true;
      if (value > best) best = value;
    }
    return found ? best : 0;
  }

  /// One UI refresh after a track edit or a finished album batch.
  ///
  /// The editor covers the shell, so a notify during the save can miss the
  /// page underneath. A second notify after the next frame reaches it once
  /// the editor has closed.
  Future<void> publishMetadata() async {
    await _refreshMosaics();
    _invalidateSearch();
    notifyListeners();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });
  }

  /// Set [refreshLibrary] to false during batch autofill — publishing the
  /// library after every file rebuilds every open screen.
  Future<Track> saveTrackMetadata(
    Track track,
    MetadataDraft draft, {
    bool refreshLibrary = true,
    bool notify = true,
  }) async {
    Future<Track> write() async {
      final oldKey = track.trackKey;
      final updated = await MetadataWriter.write(
        track,
        draft,
        paths: _paths,
      );
      await _db.applyMetadataEdit(oldTrackKey: oldKey, updated: updated);
      await _evictCover(track.coverPath);
      await _evictCover(updated.coverPath);
      _replaceTrack(oldKey, updated);
      if (refreshLibrary) {
        await publishMetadata();
      } else if (notify) {
        _invalidateSearch();
        notifyListeners();
      }
      return updated;
    }

    final unlock = unlockAudioForWrite;
    if (unlock == null) return write();
    return unlock(track.filePaths, write);
  }

  /// Подменяет аудиофайл: старые файлы с диска убираются, метаданные те же,
  /// в БД остаётся один путь.
  Future<Track> replaceTrackAudioFile(Track track, String pickedPath) async {
    final oldKey = track.trackKey;
    final oldPaths = [
      for (final path in track.filePaths) path,
      pickedPath,
    ];

    Future<Track> replace() async {
      final updated = await MetadataWriter.replaceAudioFile(
        track: track,
        pickedPath: pickedPath,
        paths: _paths,
      );
      // Ещё раз подчистить на случай, если плеер держал файл во время replace.
      await MetadataWriter.deleteReplacedAudioFiles(
        oldPaths: oldPaths,
        keepPaths: updated.filePaths,
      );
      await _db.applyMetadataEdit(oldTrackKey: oldKey, updated: updated);
      await _evictCover(track.coverPath);
      await _evictCover(updated.coverPath);
      _replaceTrack(oldKey, updated);
      await publishMetadata();
      return updated;
    }

    final unlock = unlockAudioForWrite;
    // Снимаем lock и со старого, и с выбранного пути (если он уже в music).
    if (unlock == null) return replace();
    return unlock(oldPaths, replace);
  }

  Future<int> createPlaylist(String name) async {
    final id = await _db.createPlaylist(name);
    await _sync?.enqueuePlaylistChange(id);
    await reload();
    return id;
  }

  Playlist? playlistById(int id) {
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> renamePlaylist(int id, String name) async {
    final pl = playlistById(id);
    if (pl == null || pl.isSystem) return;
    await _db.renamePlaylist(id, name);
    await _sync?.enqueuePlaylistChange(id);
    await reload();
  }

  Future<void> deletePlaylist(int id) async {
    final pl = playlistById(id);
    if (pl == null || pl.isSystem) return;
    await _db.deletePlaylist(id);
    await _sync?.enqueuePlaylistChange(id, deleted: true);
    await reload();
  }

  /// Moves every track from a user playlist into another, then deletes the source.
  Future<void> movePlaylistTracks({
    required int fromId,
    required int toId,
  }) async {
    final source = playlistById(fromId);
    final target = playlistById(toId);
    if (source == null || target == null) return;
    if (source.isSystem || target.isSystem || source.id == target.id) return;
    await _db.movePlaylistTracks(fromId: fromId, toId: toId);
    await _sync?.enqueuePlaylistChange(fromId, deleted: true);
    await _sync?.enqueuePlaylistChange(toId);
    await reload();
  }

  Future<void> setPlaylistDescription(int id, String? description) async {
    await _db.updatePlaylistMeta(
      id: id,
      description: description ?? '',
      clearDescription: description == null || description.trim().isEmpty,
    );
    await _sync?.enqueuePlaylistChange(id);
    await reload();
  }

  Future<void> setPlaylistCover(int id, Uint8List bytes) async {
    await _paths.ensureDirectories();
    final hash = sha1.convert(utf8.encode('playlist_$id')).toString();
    final file = File(p.join(_paths.playlistsDir, '$hash.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    await _db.updatePlaylistMeta(id: id, coverPath: file.path);
    await reload();
  }

  Future<void> clearPlaylistCover(int id) async {
    await _db.updatePlaylistMeta(id: id, clearCover: true);
    await reload();
  }

  /// Custom artist photo, or null to fall back to album art.
  String? artistPhotoPath(String artistName) {
    final custom = _settings.artistPhotoPath(artistName);
    if (custom != null && File(custom).existsSync()) return custom;
    return null;
  }

  Future<void> setArtistPhoto(
    String artistName,
    Uint8List bytes, {
    bool manual = true,
    bool notify = true,
  }) async {
    await _paths.ensureDirectories();
    final hash =
        sha1.convert(utf8.encode(artistName.trim().toLowerCase())).toString();
    final file = File(p.join(_paths.artistsDir, '$hash.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    await _settings.setArtistPhotoPath(artistName, file.path, manual: manual);
    if (notify) notifyListeners();
  }

  Future<void> clearArtistPhoto(String artistName) async {
    await _settings.setArtistPhotoPath(artistName, null);
    notifyListeners();
  }

  String? releaseCoverTrackKey(ArtistRelease release) {
    return _settings.releaseCoverTrackKey(releaseCoverKey(release));
  }

  /// Chosen track cover for an album, EP, or single. Falls back to the first cover.
  String? releaseCover(ArtistRelease release) {
    final preferred = _settings.releaseCoverTrackKey(releaseCoverKey(release));
    final chosen = coverFromTracks(
      release.tracks,
      preferredTrackKey: preferred,
    );
    if (chosen != null && File(chosen).existsSync()) return chosen;
    for (final track in release.tracks) {
      final path = track.coverPath;
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        return path;
      }
    }
    return chosen;
  }

  Future<void> setReleaseCover(ArtistRelease release, String trackKey) async {
    await _settings.setReleaseCoverTrackKey(releaseCoverKey(release), trackKey);
    notifyListeners();
  }

  /// Merge [from] into [into] in the library index (MP3 tags are not rewritten).
  Future<void> mergeArtists({
    required String into,
    required String from,
  }) async {
    final a = into.trim();
    final b = from.trim();
    if (a.isEmpty || b.isEmpty) return;
    if (a.toLowerCase() == b.toLowerCase()) return;

    await _db.upsertArtistAlias(fromDisplay: b, toDisplay: a);
    await _sync?.enqueueArtistAlias(fromDisplay: b, toDisplay: a);
    await _movePersonPhoto(from: b, into: a);
    await reload();
  }

  /// Merge [from] into [into] on the producer card. MP3 tags stay as written.
  Future<void> mergeProducers({
    required String into,
    required String from,
  }) async {
    final a = into.trim();
    final b = from.trim();
    if (a.isEmpty || b.isEmpty) return;
    if (a.toLowerCase() == b.toLowerCase()) return;

    await _db.upsertProducerAlias(fromDisplay: b, toDisplay: a);
    await _sync?.enqueueProducerAlias(fromDisplay: b, toDisplay: a);
    await _movePersonPhoto(from: b, into: a);
    await reload();
  }

  Future<void> _movePersonPhoto({
    required String from,
    required String into,
  }) async {
    final fromPhoto = _settings.artistPhotoPath(from);
    final intoPhoto = _settings.artistPhotoPath(into);
    if (intoPhoto == null && fromPhoto != null) {
      await _settings.setArtistPhotoPath(
        into,
        fromPhoto,
        manual: _settings.isArtistPhotoManual(from),
      );
    }
    await _settings.setArtistPhotoPath(from, null);
  }

  @override
  void dispose() {
    _playlistRefreshTimer?.cancel();
    jobUi.dispose();
    super.dispose();
  }

  /// Stable random covers for a user playlist that has no chosen cover.
  List<String> playlistMosaic(int playlistId) =>
      _mosaicCache[playlistId] ?? const [];

  /// Covers for a genre card. One path, or four cells.
  List<String> genreMosaic(String genre) =>
      _genreMosaicCache[genre] ?? const [];

  final Map<String, List<String>> _genreMosaicCache = {};
  final Map<int, String> _playlistMosaicSig = {};
  final Map<String, String> _genreMosaicSig = {};

  String _coverSetSig(Iterable<String?> paths) {
    final buf = StringBuffer();
    for (final path in paths) {
      if (path == null || path.isEmpty) continue;
      buf
        ..write(path)
        ..write('#')
        ..write(cachedCoverFingerprint(path) ?? '?')
        ..write('\u0001');
    }
    return buf.toString();
  }

  Future<void> _refreshMosaics() async {
    final next = <int, List<String>>{};
    final nextPlaylistSig = <int, String>{};
    final byKey = {for (final track in _tracks) track.trackKey: track};
    var stepped = 0;
    for (final playlist in _playlists) {
      if (playlist.isSystem) continue;
      final cover = playlist.coverPath;
      if (cover != null && cover.isNotEmpty) continue;
      final keys = await _db.getPlaylistTrackKeys(playlist.id);
      final covers = [
        for (final key in keys) byKey[key]?.coverPath,
      ];
      final known = _coverSetSig(covers);
      final previous = _mosaicCache[playlist.id];
      if (!known.contains('?') &&
          known == _playlistMosaicSig[playlist.id] &&
          previous != null) {
        next[playlist.id] = previous;
        nextPlaylistSig[playlist.id] = known;
      } else {
        next[playlist.id] = pickPlaylistMosaic(
          covers,
          seed: playlist.id,
          identity: coverFingerprint,
        );
        nextPlaylistSig[playlist.id] = _coverSetSig(covers);
        stepped++;
        if (stepped % 8 == 0) await Future<void>.delayed(Duration.zero);
      }
    }
    _mosaicCache = next;
    _playlistMosaicSig
      ..clear()
      ..addAll(nextPlaylistSig);

    final byGenre = <String, List<String?>>{};
    var walked = 0;
    for (final track in _tracks) {
      final genre = track.displayGenre;
      if (genre.isEmpty) continue;
      byGenre.putIfAbsent(genre, () => []).add(track.coverPath);
      walked++;
      if (walked % 400 == 0) await Future<void>.delayed(Duration.zero);
    }
    final genres = <String, List<String>>{};
    final nextGenreSig = <String, String>{};
    for (final entry in byGenre.entries) {
      final known = _coverSetSig(entry.value);
      final previous = _genreMosaicCache[entry.key];
      if (!known.contains('?') &&
          known == _genreMosaicSig[entry.key] &&
          previous != null) {
        genres[entry.key] = previous;
        nextGenreSig[entry.key] = known;
        continue;
      }
      genres[entry.key] = pickPlaylistMosaic(
        entry.value,
        seed: stableSeed(entry.key),
        identity: coverFingerprint,
      );
      nextGenreSig[entry.key] = _coverSetSig(entry.value);
      stepped++;
      if (stepped % 8 == 0) await Future<void>.delayed(Duration.zero);
    }
    _genreMosaicCache
      ..clear()
      ..addAll(genres);
    _genreMosaicSig
      ..clear()
      ..addAll(nextGenreSig);
  }

  Future<List<Track>> playlistTracks(int id) async {
    return _db.getPlaylistTracks(id);
  }

  /// Result of [addToPlaylist] / cloud helpers.
  /// `already` = already in playlist; `limit` = cloud cap; `ok` = added.
  static const addOk = 'ok';
  static const addAlready = 'already';
  static const addLimit = 'limit';
  static const addDenied = 'denied';

  /// Returns [addOk], [addAlready], [addLimit], or [addDenied].
  Future<String> addToPlaylist(int playlistId, String trackKey) async {
    final pl = playlistById(playlistId);
    if (pl == null) return addDenied;
    if (pl.isSystem && !pl.allowsManualTracks) return addDenied;
    if (pl.isCloud && pl.trackCount >= Playlist.cloudTrackLimit) {
      return addLimit;
    }
    final added = await _db.addTrackToPlaylist(playlistId, trackKey);
    if (!added) return addAlready;
    if (!pl.isCloud) {
      await _sync?.enqueuePlaylistChange(playlistId);
    } else {
      _sync?.markCloudPlaylistDirty();
    }
    _bumpPlaylistCount(playlistId, 1);
    _finishPlaylistMutation(touchedPlaylistIds: {playlistId});
    return addOk;
  }

  Future<void> removeFromPlaylist(int playlistId, String trackKey) async {
    final pl = playlistById(playlistId);
    await _db.removeFromPlaylist(playlistId, trackKey);
    if (pl != null && pl.isCloud) {
      _sync?.markCloudPlaylistDirty();
    } else {
      await _sync?.enqueuePlaylistChange(playlistId);
    }
    _bumpPlaylistCount(playlistId, -1);
    _finishPlaylistMutation(touchedPlaylistIds: {playlistId});
  }

  Playlist? get cloudPlaylist {
    if (!_settings.syncCloudPlaylist) return null;
    for (final p in _playlists) {
      if (p.isCloud) return p;
    }
    return null;
  }

  Future<void> clearPlayCounts() async {
    await _db.clearPlayEvents();
    await _settings.replaceChartSnapshots(const {});
    notifyListeners();
  }

  Future<BackupResult> exportAppData(String destPath) {
    return _backup.exportToFile(destPath);
  }

  Future<BackupResult> importAppData(String sourcePath) async {
    final result = await _backup.importFromFile(sourcePath);
    await reload();
    notifyListeners();
    return result;
  }
}

class _CatalogIndex {
  const _CatalogIndex({
    required this.tracks,
    required this.artists,
    required this.producers,
    required this.albums,
    required this.playlists,
  });

  final List<_IxTrack> tracks;
  final List<_IxPerson> artists;
  final List<_IxPerson> producers;
  final List<_IxAlbum> albums;
  final List<_IxPlaylist> playlists;
}

class _IxTrack {
  const _IxTrack(this.track, this.meta, this.lyrics);

  final Track track;
  final String meta;
  final String lyrics;
}

class _IxPerson {
  const _IxPerson(this.name, this.hay, this.trackCount);

  final String name;
  final String hay;
  final int trackCount;
}

class _IxAlbum {
  const _IxAlbum(this.album, this.hay);

  final SearchAlbum album;
  final String hay;
}

class _IxPlaylist {
  const _IxPlaylist(this.playlist, this.hay);

  final Playlist playlist;
  final String hay;
}

class _JobUi extends ChangeNotifier {
  void ping() => notifyListeners();
}
