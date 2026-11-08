import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/equalizer_state.dart';

class SettingsService extends ChangeNotifier {
  SettingsService(this._prefs);

  final SharedPreferences _prefs;

  static const _scanOnStartupKey = 'scan_on_startup';
  static const _playOnStartupKey = 'play_on_startup';
  static const _autoFillMetaKey = 'auto_fill_empty_metadata';
  static const _playerVolumeKey = 'player_volume';
  static const _playerVolumeBeforeMuteKey = 'player_volume_before_mute';
  static const _crossfadeSecondsKey = 'crossfade_seconds';
  static const _equalizerKey = 'equalizer_v1';
  static const _playbackQueueKey = 'playback_queue_keys';
  static const _playbackIndexKey = 'playback_index';
  static const _playbackPositionKey = 'playback_position_ms';
  static const _playbackShuffleKey = 'playback_shuffle';
  static const _playbackRepeatKey = 'playback_repeat';
  static const _artistTagsRestoredKey = 'artist_tags_restored_v1';
  static const _trackKeysRemigratedKey = 'track_keys_remigrated_v1';
  static const _artistPhotoPrefix = 'artist_photo_';
  static const _artistPhotoManualPrefix = 'artist_photo_manual_';
  static const _artistPhotoUpdatedPrefix = 'artist_photo_updated_';
  static const _releaseCoverPrefix = 'release_cover_';
  static const _syncPlaysKey = 'sync_plays';
  static const _syncAliasesKey = 'sync_aliases';
  static const _syncPlaylistsKey = 'sync_playlists';
  static const _syncCloudPlaylistKey = 'sync_cloud_playlist';
  static Future<SettingsService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsService(prefs);
  }

  bool get artistTagsRestored =>
      _prefs.getBool(_artistTagsRestoredKey) ?? false;

  Future<void> setArtistTagsRestored() async {
    await _prefs.setBool(_artistTagsRestoredKey, true);
  }

  /// One-shot track_key remigrate; skip O(N) walk on later launches.
  bool get trackKeysRemigrated =>
      _prefs.getBool(_trackKeysRemigratedKey) ?? false;

  Future<void> setTrackKeysRemigrated() async {
    await _prefs.setBool(_trackKeysRemigratedKey, true);
  }

  bool get scanOnStartup => _prefs.getBool(_scanOnStartupKey) ?? false;

  Future<void> setScanOnStartup(bool value) async {
    await _prefs.setBool(_scanOnStartupKey, value);
    notifyListeners();
  }

  /// Resume the last track on launch, or start a random stream when there
  /// was no queue.
  bool get playOnStartup => _prefs.getBool(_playOnStartupKey) ?? false;

  Future<void> setPlayOnStartup(bool value) async {
    await _prefs.setBool(_playOnStartupKey, value);
    notifyListeners();
  }

  /// Fill empty album/genre/year from the internet when new tracks are scanned.
  bool get autoFillEmptyMetadata =>
      _prefs.getBool(_autoFillMetaKey) ?? true;

  Future<void> setAutoFillEmptyMetadata(bool value) async {
    await _prefs.setBool(_autoFillMetaKey, value);
    notifyListeners();
  }

  /// Yandex sync: play history + count snapshots.
  bool get syncPlays => _prefs.getBool(_syncPlaysKey) ?? true;

  Future<void> setSyncPlays(bool value) async {
    await _prefs.setBool(_syncPlaysKey, value);
    notifyListeners();
  }

  /// Yandex sync: artist/producer card merges.
  bool get syncAliases => _prefs.getBool(_syncAliasesKey) ?? true;

  Future<void> setSyncAliases(bool value) async {
    await _prefs.setBool(_syncAliasesKey, value);
    notifyListeners();
  }

  /// Yandex sync: user playlists.
  bool get syncPlaylists => _prefs.getBool(_syncPlaylistsKey) ?? true;

  Future<void> setSyncPlaylists(bool value) async {
    await _prefs.setBool(_syncPlaylistsKey, value);
    notifyListeners();
  }

  /// Yandex sync + UI for system «Облако» playlist.
  bool get syncCloudPlaylist => _prefs.getBool(_syncCloudPlaylistKey) ?? true;

  Future<void> setSyncCloudPlaylist(bool value) async {
    await _prefs.setBool(_syncCloudPlaylistKey, value);
    notifyListeners();
  }

  /// Last playback volume (0..1), restored on launch.
  double get playerVolume =>
      (_prefs.getDouble(_playerVolumeKey) ?? 1.0).clamp(0.0, 1.0);

  double get playerVolumeBeforeMute =>
      (_prefs.getDouble(_playerVolumeBeforeMuteKey) ?? playerVolume)
          .clamp(0.0, 1.0);

  Future<void> setPlayerVolume(double volume, {double? beforeMute}) async {
    await _prefs.setDouble(_playerVolumeKey, volume.clamp(0.0, 1.0));
    if (beforeMute != null) {
      await _prefs.setDouble(
        _playerVolumeBeforeMuteKey,
        beforeMute.clamp(0.0, 1.0),
      );
    }
  }

  /// Crossfade length in seconds (0 = off).
  int get crossfadeSeconds =>
      (_prefs.getInt(_crossfadeSecondsKey) ?? 3).clamp(0, 12);

  Future<void> setCrossfadeSeconds(int seconds) async {
    await _prefs.setInt(_crossfadeSecondsKey, seconds.clamp(0, 12));
    notifyListeners();
  }

  EqualizerState get equalizer {
    final raw = _prefs.getString(_equalizerKey);
    if (raw == null || raw.isEmpty) return EqualizerState.flat();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return EqualizerState.fromJson(Map<String, Object?>.from(decoded));
      }
    } catch (_) {}
    return EqualizerState.flat();
  }

  Future<void> setEqualizer(EqualizerState state) async {
    await _prefs.setString(_equalizerKey, jsonEncode(state.toJson()));
  }

  List<String> get playbackQueueKeys =>
      _prefs.getStringList(_playbackQueueKey) ?? const [];

  int get playbackIndex => _prefs.getInt(_playbackIndexKey) ?? 0;

  int get playbackPositionMs => _prefs.getInt(_playbackPositionKey) ?? 0;

  bool get playbackShuffle => _prefs.getBool(_playbackShuffleKey) ?? true;

  String get playbackRepeat => _prefs.getString(_playbackRepeatKey) ?? 'off';

  Future<void> savePlaybackSession({
    required List<String> queueKeys,
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeat,
  }) async {
    // Skip unchanged keys — full queue rewrite is the expensive part on quit.
    final writes = <Future<bool>>[];
    final prevKeys = playbackQueueKeys;
    if (prevKeys.length != queueKeys.length ||
        !listEquals(prevKeys, queueKeys)) {
      writes.add(_prefs.setStringList(_playbackQueueKey, queueKeys));
    }
    if (playbackIndex != index) {
      writes.add(_prefs.setInt(_playbackIndexKey, index));
    }
    if (playbackPositionMs != positionMs) {
      writes.add(_prefs.setInt(_playbackPositionKey, positionMs));
    }
    if (playbackShuffle != shuffle) {
      writes.add(_prefs.setBool(_playbackShuffleKey, shuffle));
    }
    if (playbackRepeat != repeat) {
      writes.add(_prefs.setString(_playbackRepeatKey, repeat));
    }
    if (writes.isEmpty) return;
    await Future.wait(writes);
  }

  Future<void> clearPlaybackSession() async {
    await _prefs.remove(_playbackQueueKey);
    await _prefs.remove(_playbackIndexKey);
    await _prefs.remove(_playbackPositionKey);
  }

  String _artistKey(String name) =>
      '$_artistPhotoPrefix${name.trim().toLowerCase()}';

  String _artistManualKey(String name) =>
      '$_artistPhotoManualPrefix${name.trim().toLowerCase()}';

  String _artistUpdatedKey(String name) =>
      '$_artistPhotoUpdatedPrefix${name.trim().toLowerCase()}';

  /// Custom artist photo path, if set.
  String? artistPhotoPath(String artistName) {
    final path = _prefs.getString(_artistKey(artistName));
    if (path == null || path.isEmpty) return null;
    return path;
  }

  /// True when the user picked the photo manually (skip auto-refresh).
  bool isArtistPhotoManual(String artistName) =>
      _prefs.getBool(_artistManualKey(artistName)) ?? false;

  /// UTC ms when the local portrait was last set (for pack merge LWW).
  int? artistPhotoUpdatedAtMs(String artistName) =>
      _prefs.getInt(_artistUpdatedKey(artistName));

  Future<void> setArtistPhotoPath(
    String artistName,
    String? path, {
    bool? manual,
    int? updatedAtMs,
  }) async {
    final key = _artistKey(artistName);
    final manualKey = _artistManualKey(artistName);
    final updatedKey = _artistUpdatedKey(artistName);
    if (path == null || path.isEmpty) {
      await _prefs.remove(key);
      await _prefs.remove(manualKey);
      await _prefs.remove(updatedKey);
    } else {
      await _prefs.setString(key, path);
      if (manual != null) {
        await _prefs.setBool(manualKey, manual);
      }
      await _prefs.setInt(
        updatedKey,
        updatedAtMs ?? DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    }
    notifyListeners();
  }

  /// Track whose cover is shown for this album, EP, or single.
  String? releaseCoverTrackKey(String releaseKey) {
    final key = _prefs.getString('$_releaseCoverPrefix$releaseKey');
    if (key == null || key.isEmpty) return null;
    return key;
  }

  Future<void> setReleaseCoverTrackKey(String releaseKey, String trackKey) async {
    await _prefs.setString('$_releaseCoverPrefix$releaseKey', trackKey);
    notifyListeners();
  }

  /// Release key → track whose cover is shown for that album, EP, or single.
  Map<String, String> exportReleaseCovers() {
    final out = <String, String>{};
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith(_releaseCoverPrefix)) continue;
      final trackKey = _prefs.get(key);
      if (trackKey is! String || trackKey.isEmpty) continue;
      out[key.substring(_releaseCoverPrefix.length)] = trackKey;
    }
    return out;
  }

  Future<void> replaceReleaseCovers(Map<String, String> covers) async {
    for (final key in _prefs.getKeys().toList()) {
      if (key.startsWith(_releaseCoverPrefix)) {
        await _prefs.remove(key);
      }
    }
    for (final entry in covers.entries) {
      if (entry.key.isEmpty || entry.value.isEmpty) continue;
      await _prefs.setString('$_releaseCoverPrefix${entry.key}', entry.value);
    }
    notifyListeners();
  }

  /// Previous chart ranks: `trackKey -> 1-based rank`.
  Map<String, int> chartSnapshot(String periodKey) {
    final raw = _prefs.getStringList('chart_snap_$periodKey') ?? const [];
    final map = <String, int>{};
    for (final line in raw) {
      final i = line.lastIndexOf('|');
      if (i <= 0) continue;
      final key = line.substring(0, i);
      final rank = int.tryParse(line.substring(i + 1));
      if (rank != null) map[key] = rank;
    }
    return map;
  }

  Future<void> saveChartSnapshot(
    String periodKey,
    Map<String, int> ranks,
  ) async {
    final lines = [
      for (final e in ranks.entries) '${e.key}|${e.value}',
    ];
    await _prefs.setStringList('chart_snap_$periodKey', lines);
  }

  /// Artist key (lowercase name) -> absolute photo path.
  Map<String, String> exportArtistPhotoPaths() {
    final out = <String, String>{};
    for (final key in _prefs.getKeys()) {
      // `_artistPhotoManualPrefix` also starts with `_artistPhotoPrefix`;
      // those keys store bools and must not be read via getString.
      if (!key.startsWith(_artistPhotoPrefix)) continue;
      if (key.startsWith(_artistPhotoManualPrefix)) continue;
      final path = _prefs.get(key);
      if (path is! String || path.isEmpty) continue;
      out[key.substring(_artistPhotoPrefix.length)] = path;
    }
    return out;
  }

  Future<void> replaceArtistPhotoPaths(Map<String, String> artistToPath) async {
    for (final key in _prefs.getKeys().toList()) {
      if (key.startsWith(_artistPhotoPrefix) ||
          key.startsWith(_artistPhotoManualPrefix)) {
        await _prefs.remove(key);
      }
    }
    for (final e in artistToPath.entries) {
      if (e.value.isEmpty) continue;
      await _prefs.setString('$_artistPhotoPrefix${e.key}', e.value);
      // Imported photos are treated as manual so auto-refresh won't overwrite.
      await _prefs.setBool('$_artistPhotoManualPrefix${e.key}', true);
    }
    notifyListeners();
  }

  /// periodKey -> raw snapshot lines `trackKey|rank`.
  Map<String, List<String>> exportChartSnapshots() {
    final out = <String, List<String>>{};
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith('chart_snap_')) continue;
      final period = key.substring('chart_snap_'.length);
      final raw = _prefs.get(key);
      if (raw is List) {
        out[period] = [for (final line in raw) line.toString()];
      }
    }
    return out;
  }

  Future<void> replaceChartSnapshots(Map<String, List<String>> snaps) async {
    for (final key in _prefs.getKeys().toList()) {
      if (key.startsWith('chart_snap_')) {
        await _prefs.remove(key);
      }
    }
    for (final e in snaps.entries) {
      await _prefs.setStringList('chart_snap_${e.key}', e.value);
    }
    notifyListeners();
  }

  Map<String, bool> exportSettingsFlags() => {
        'scanOnStartup': scanOnStartup,
        'playOnStartup': playOnStartup,
        'autoFillEmptyMetadata': autoFillEmptyMetadata,
      };

  Future<void> importSettingsFlags(Map<String, dynamic> flags) async {
    final scan = flags['scanOnStartup'];
    if (scan is bool) await setScanOnStartup(scan);
    final play = flags['playOnStartup'];
    if (play is bool) await setPlayOnStartup(play);
    final fill = flags['autoFillEmptyMetadata'];
    if (fill is bool) await setAutoFillEmptyMetadata(fill);
  }
}
