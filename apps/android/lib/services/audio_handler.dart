import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'player_service.dart';
import 'storage_access.dart';

const _kArtSize = 320;

/// Bridges [PlayerService] to Android media notification via audio_service.
class FreedomAudioHandler extends BaseAudioHandler with SeekHandler {
  FreedomAudioHandler(this._player);

  final PlayerService _player;
  bool _attached = false;
  String? _lastMediaId;
  Duration? _lastDuration;
  bool _lastPlaying = false;
  Timer? _positionDebounce;
  int _artEpoch = 0;
  Directory? _artDir;

  /// Подключить слушатель плеера только после успешного AudioService.init.
  void attach() {
    if (_attached) return;
    _attached = true;
    _player.addListener(_onPlayerChanged);
    _sync(forceMedia: true);
  }

  void _onPlayerChanged() {
    if (!_attached) return;
    final track = _player.current;
    final mediaId = track?.trackKey;
    final playing = _player.playing;
    final duration = track == null
        ? null
        : (_player.duration ??
            (track.durationMs != null
                ? Duration(milliseconds: track.durationMs!)
                : null));
    final mediaChanged = mediaId != _lastMediaId ||
        duration != _lastDuration ||
        playing != _lastPlaying;
    if (mediaChanged) {
      _positionDebounce?.cancel();
      _sync(forceMedia: true);
      return;
    }
    _positionDebounce?.cancel();
    _positionDebounce = Timer(const Duration(milliseconds: 750), () {
      _sync(forceMedia: false);
    });
  }

  void _sync({required bool forceMedia}) {
    if (!_attached) return;
    try {
      final track = _player.current;
      final playing = _player.playing;
      final position = _player.position;

      final mediaId = track?.trackKey;
      final duration = track == null
          ? null
          : (_player.duration ??
              (track.durationMs != null
                  ? Duration(milliseconds: track.durationMs!)
                  : null));

      if (forceMedia &&
          (mediaId != _lastMediaId || duration != _lastDuration)) {
        _lastMediaId = mediaId;
        _lastDuration = duration;
        // Сначала метаданные без арта — play не ждёт декод.
        mediaItem.add(track == null ? null : _toMediaItem(track));
        if (track != null) {
          unawaited(_publishArt(track));
        }
      }
      _lastPlaying = playing;

      playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.skipToPrevious,
            MediaAction.skipToNext,
            MediaAction.play,
            MediaAction.pause,
          },
          androidCompactActionIndices: const [0, 1, 2],
          processingState: track == null
              ? AudioProcessingState.idle
              : AudioProcessingState.ready,
          playing: playing,
          updatePosition: position,
          bufferedPosition: position,
          speed: 1.0,
        ),
      );
    } catch (e, st) {
      debugPrint('AudioHandler sync failed: $e\n$st');
    }
  }

  Future<void> _publishArt(Track track) async {
    final epoch = ++_artEpoch;
    final key = track.trackKey;
    try {
      final art = await _prepareArt(track);
      if (!_attached || epoch != _artEpoch) return;
      if (_player.current?.trackKey != key) return;
      mediaItem.add(_toMediaItem(track, artUri: art));
    } catch (e, st) {
      debugPrint('AudioHandler art failed: $e\n$st');
    }
  }

  MediaItem _toMediaItem(Track track, {Uri? artUri}) {
    final duration = _player.duration ??
        (track.durationMs != null
            ? Duration(milliseconds: track.durationMs!)
            : null);
    return MediaItem(
      id: track.trackKey,
      title: track.displayTitle.isEmpty ? 'Трек' : track.displayTitle,
      artist: track.displayArtist.isEmpty ? 'Неизвестный' : track.displayArtist,
      album: track.displayAlbum.isEmpty ? 'Freedom Music' : track.displayAlbum,
      duration: duration,
      artUri: artUri,
    );
  }

  Future<Directory> _artCacheDir() async {
    final cached = _artDir;
    if (cached != null) return cached;
    final root = await getTemporaryDirectory();
    final dir = Directory(p.join(root.path, 'media_art'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _artDir = dir;
    return dir;
  }

  String _artFileName(String trackKey) {
    final safe = trackKey.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final clipped = safe.length > 80 ? safe.substring(0, 80) : safe;
    return '$clipped.png';
  }

  /// Ужимает обложку в маленький PNG — Android 15 MediaStyle + без OOM.
  Future<Uri?> _prepareArt(Track track) async {
    final cover = track.coverPath;
    if (cover == null || cover.isEmpty) return null;
    final src = File(cover);
    if (!await src.exists()) return null;

    final length = await src.length();
    if (length <= 0 || length > 20 << 20) return null;

    final dir = await _artCacheDir();
    final out = File(p.join(dir.path, _artFileName(track.trackKey)));
    final srcStat = await src.stat();
    if (await out.exists()) {
      final outStat = await out.stat();
      if (outStat.modified.isAfter(srcStat.modified) &&
          outStat.size > 0 &&
          outStat.size < 2 << 20) {
        return Uri.file(out.path);
      }
    }

    final bytes = await src.readAsBytes();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _kArtSize,
      targetHeight: _kArtSize,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return Uri.file(out.path);
    } finally {
      image.dispose();
    }
  }

  @override
  Future<void> play() => _player.resumePlayback();

  @override
  Future<void> pause() => _player.pausePlayback();

  @override
  Future<void> stop() async {
    await _player.pausePlayback();
    await _player.seek(Duration.zero);
    if (_attached) {
      try {
        await super.stop();
      } catch (e, st) {
        debugPrint('AudioHandler stop failed: $e\n$st');
      }
    }
  }

  @override
  Future<void> skipToNext() => _player.next();

  @override
  Future<void> skipToPrevious() => _player.previous();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> onTaskRemoved() async {}

  void disposeHandler() {
    _positionDebounce?.cancel();
    _artEpoch++;
    if (_attached) {
      _player.removeListener(_onPlayerChanged);
      _attached = false;
    }
  }
}

Future<FreedomAudioHandler> initAudioHandler(PlayerService player) async {
  final handler = FreedomAudioHandler(player);

  if (!Platform.isAndroid) {
    return handler;
  }

  final canNotify = await StorageAccess.hasNotifications();
  if (!canNotify) {
    debugPrint('AudioService skipped: no notification permission');
    return handler;
  }

  try {
    final bound = await AudioService.init(
      builder: () => handler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.freedommusic.player',
        androidNotificationChannelName: 'Freedom Music',
        androidNotificationChannelDescription: 'Управление воспроизведением',
        androidNotificationIcon: 'mipmap/ic_launcher',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: true,
        androidNotificationClickStartsActivity: true,
        androidShowNotificationBadge: false,
        artDownscaleWidth: _kArtSize,
        artDownscaleHeight: _kArtSize,
        fastForwardInterval: Duration(seconds: 10),
        rewindInterval: Duration(seconds: 10),
      ),
    );
    bound.attach();
    return bound;
  } catch (e, st) {
    debugPrint('AudioService init failed: $e\n$st');
    return handler;
  }
}
