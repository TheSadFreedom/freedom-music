import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:fm_mod_protocol/fm_mod_protocol.dart';
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';
import '../models/track.dart';
import '../navigation/app_navigator.dart';
import '../services/metadata_writer.dart';
import '../widgets/library_track_picker.dart';
import 'library_service.dart';
import 'player_service.dart';

typedef PickLibraryTrackFn = Future<Track?> Function();

/// Loopback JSON-RPC host for sidecar mods.
class ModHostServer {
  ModHostServer({
    required this.paths,
    required this.library,
    required this.player,
    this.pickLibraryTrack,
  });

  final AppPaths paths;
  final LibraryService library;
  final PlayerService player;

  /// Override for tests; default uses [showLibraryTrackPicker] on root nav.
  final PickLibraryTrackFn? pickLibraryTrack;

  HttpServer? _server;
  Future<void>? _starting;
  String? _token;

  String get token =>
      _token ?? (throw StateError('Mod host not started'));
  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final inFlight = _starting;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = _startLocked();
    _starting = future;
    try {
      await future;
    } finally {
      _starting = null;
    }
  }

  Future<void> _startLocked() async {
    _token ??= _randomToken();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    await server?.close(force: true);
  }

  Future<void> _serve() async {
    final server = _server;
    if (server == null) return;
    await for (final request in server) {
      try {
        await _handle(request);
      } catch (e) {
        try {
          request.response.statusCode = 500;
          request.response.write('$e');
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'OPTIONS') {
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }
    if (request.uri.path != '/rpc' || request.method != 'POST') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final expected = 'Bearer $token';
    if (auth != expected) {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }

    final body = await utf8.decoder.bind(request).join();
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      decoded = null;
    }
    final rpc = ModRpcRequest.tryParse(decoded);
    final response = rpc == null
        ? const ModRpcResponse(
            id: '',
            error: ModRpcError(code: -32700, message: 'Parse error'),
          )
        : await _dispatch(rpc);

    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(response.encode());
    await request.response.close();
  }

  Future<ModRpcResponse> _dispatch(ModRpcRequest rpc) async {
    try {
      final result = await _invoke(rpc.method, rpc.params);
      return ModRpcResponse(id: rpc.id, result: result);
    } on ModRpcError catch (e) {
      return ModRpcResponse(id: rpc.id, error: e);
    } catch (e) {
      return ModRpcResponse(
        id: rpc.id,
        error: ModRpcError(code: -32000, message: '$e'),
      );
    }
  }

  Future<Object?> _invoke(String method, Map<String, dynamic> params) async {
    switch (method) {
      case ModRpcMethods.hello:
        return HelloResult(
          api: kFmModApiVersion,
          playerName: 'Freedom Music',
        ).toJson();
      case ModRpcMethods.getPaths:
        return PathsResult(
          root: paths.root,
          musicDir: paths.musicDir,
          dataDir: paths.dataDir,
        ).toJson();
      case ModRpcMethods.scanNew:
        await library.scanLibrary(newOnly: true);
        return {'ok': true};
      case ModRpcMethods.importFile:
        return (await _importFile(params)).toJson();
      case ModRpcMethods.playTrack:
        await _playTrack(params);
        return {'ok': true};
      case ModRpcMethods.playRemote:
        await _playRemote(params);
        return {'ok': true};
      case ModRpcMethods.pickLibraryTrack:
        final picked = await _pickTrack();
        return picked?.toJson();
      case ModRpcMethods.replaceTrackAudio:
        return (await _replaceTrackAudio(params)).toJson();
      default:
        throw ModRpcError(code: -32601, message: 'Method not found: $method');
    }
  }

  Future<ImportFileResult> _importFile(Map<String, dynamic> params) async {
    final path = '${params['path'] ?? ''}'.trim();
    final title = '${params['title'] ?? ''}'.trim();
    final artist = '${params['artist'] ?? ''}'.trim();
    final album = '${params['album'] ?? ''}'.trim();
    if (path.isEmpty) {
      throw const ModRpcError(code: -32602, message: 'path required');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw ModRpcError(code: -32004, message: 'File not found: $path');
    }

    final t = title.isEmpty ? p.basenameWithoutExtension(path) : title;
    final a = artist.isEmpty ? 'Unknown' : artist;
    final al = album.isEmpty ? 'Unknown' : album;

    try {
      final stub = Track(
        trackKey: 'mod-import',
        title: t,
        artist: a,
        album: al,
        genre: 'Unknown',
        filePaths: [path],
      );
      await MetadataWriter.write(
        stub,
        MetadataDraft(
          title: t,
          artist: a,
          album: al,
          genre: 'Unknown',
        ),
        paths: paths,
      );
    } catch (_) {
      // Tags optional.
    }

    await library.scanLibrary(newOnly: true);
    final normalized = p.normalize(path);
    Track? found;
    for (final track in library.tracks) {
      if (track.filePaths.any((f) => p.normalize(f) == normalized)) {
        found = track;
        break;
      }
    }
    if (found == null) {
      throw const ModRpcError(
        code: -32005,
        message: 'Track not found after scan',
      );
    }
    return ImportFileResult(
      trackKey: found.trackKey,
      title: found.displayTitle,
      artist: found.artist,
    );
  }

  Future<void> _playTrack(Map<String, dynamic> params) async {
    final key = '${params['trackKey'] ?? ''}'.trim();
    if (key.isEmpty) {
      throw const ModRpcError(code: -32602, message: 'trackKey required');
    }
    final track = library.trackByKey(key);
    if (track == null) {
      throw ModRpcError(code: -32004, message: 'Unknown track: $key');
    }
    await player.playTracks([track]);
  }

  Future<void> _playRemote(Map<String, dynamic> params) async {
    final url = '${params['url'] ?? ''}'.trim();
    final title = '${params['title'] ?? 'Превью'}'.trim();
    final artist = '${params['artist'] ?? ''}'.trim();
    if (url.isEmpty) {
      throw const ModRpcError(code: -32602, message: 'url required');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw ModRpcError(code: -32602, message: 'Invalid url: $url');
    }
    Map<String, String>? headers;
    final rawHeaders = params['headers'];
    if (rawHeaders is Map) {
      headers = {
        for (final e in rawHeaders.entries) '${e.key}': '${e.value}',
      };
    }
    await player.playRemote(
      uri,
      title: title.isEmpty ? 'Превью' : title,
      artist: artist.isEmpty ? 'Unknown' : artist,
      httpHeaders: headers,
    );
  }

  Future<PickedTrackResult?> _pickTrack() async {
    final custom = pickLibraryTrack;
    if (custom != null) {
      final track = await custom();
      if (track == null) return null;
      return PickedTrackResult(
        trackKey: track.trackKey,
        title: track.displayTitle,
        artist: track.artist,
      );
    }

    final nav = appNavigatorKey.currentState;
    final ctx = nav?.overlay?.context ?? nav?.context;
    if (ctx == null || !ctx.mounted) {
      throw const ModRpcError(
        code: -32010,
        message: 'Player UI not ready for track picker',
      );
    }
    // Ensure dialog runs on the UI isolate / frame.
    final completer = Completer<Track?>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final track = await showLibraryTrackPicker(
          ctx,
          title: 'Заменить файл трека',
        );
        completer.complete(track);
      } catch (e) {
        completer.completeError(e);
      }
    });
    final track = await completer.future;
    if (track == null) return null;
    return PickedTrackResult(
      trackKey: track.trackKey,
      title: track.displayTitle,
      artist: track.artist,
    );
  }

  Future<ImportFileResult> _replaceTrackAudio(
    Map<String, dynamic> params,
  ) async {
    final key = '${params['trackKey'] ?? ''}'.trim();
    final path = '${params['path'] ?? ''}'.trim();
    if (key.isEmpty || path.isEmpty) {
      throw const ModRpcError(
        code: -32602,
        message: 'trackKey and path required',
      );
    }
    final target = library.trackByKey(key);
    if (target == null) {
      throw ModRpcError(code: -32004, message: 'Unknown track: $key');
    }
    final downloaded = File(path);
    if (!await downloaded.exists()) {
      throw ModRpcError(code: -32004, message: 'File not found: $path');
    }

    final oldKey = target.trackKey;
    final oldPaths = List<String>.from(target.filePaths);
    final unlockPaths = [...oldPaths, downloaded.path];
    final prevUnlock = library.unlockAudioForWrite;
    late final Track updated;
    try {
      library.unlockAudioForWrite = null;
      updated = await player.whileAudioUnlocked(
        unlockPaths,
        () => library.replaceTrackAudioFile(target, downloaded.path),
        beforeRelock: (track) {
          player.syncTrack(track, oldTrackKey: oldKey);
        },
      );
    } finally {
      library.unlockAudioForWrite = prevUnlock;
    }
    await player.syncTrackAfterFileReplace(updated, oldTrackKey: oldKey);
    await MetadataWriter.deleteReplacedAudioFiles(
      oldPaths: [...oldPaths, downloaded.path],
      keepPaths: updated.filePaths,
    );
    return ImportFileResult(
      trackKey: updated.trackKey,
      title: updated.displayTitle,
      artist: updated.artist,
    );
  }

  static String _randomToken() {
    final r = Random.secure();
    final bytes = List<int>.generate(24, (_) => r.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
