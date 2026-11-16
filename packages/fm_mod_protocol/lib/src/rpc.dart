import 'dart:convert';

import 'constants.dart';

/// JSON-RPC 2.0-ish request over HTTP POST `/rpc`.
class ModRpcRequest {
  const ModRpcRequest({
    required this.id,
    required this.method,
    this.params = const {},
  });

  final String id;
  final String method;
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      };

  static ModRpcRequest? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final id = '${map['id'] ?? ''}';
    final method = '${map['method'] ?? ''}';
    if (id.isEmpty || method.isEmpty) return null;
    final paramsRaw = map['params'];
    final params = paramsRaw is Map
        ? Map<String, dynamic>.from(paramsRaw)
        : <String, dynamic>{};
    return ModRpcRequest(id: id, method: method, params: params);
  }

  String encode() => jsonEncode(toJson());
}

class ModRpcResponse {
  const ModRpcResponse({
    required this.id,
    this.result,
    this.error,
  });

  final String id;
  final Object? result;
  final ModRpcError? error;

  bool get ok => error == null;

  Map<String, dynamic> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        if (error == null) 'result': result,
        if (error != null) 'error': error!.toJson(),
      };

  static ModRpcResponse parse(Object? raw) {
    if (raw is! Map) {
      return const ModRpcResponse(
        id: '',
        error: ModRpcError(code: -32700, message: 'Invalid JSON'),
      );
    }
    final map = Map<String, dynamic>.from(raw);
    final id = '${map['id'] ?? ''}';
    final err = map['error'];
    if (err is Map) {
      return ModRpcResponse(
        id: id,
        error: ModRpcError(
          code: err['code'] is int ? err['code'] as int : -32000,
          message: '${err['message'] ?? 'error'}',
          data: err['data'],
        ),
      );
    }
    return ModRpcResponse(id: id, result: map['result']);
  }

  String encode() => jsonEncode(toJson());
}

class ModRpcError implements Exception {
  const ModRpcError({
    required this.code,
    required this.message,
    this.data,
  });

  final int code;
  final String message;
  final Object? data;

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };

  @override
  String toString() => 'ModRpcError($code): $message';
}

/// Well-known methods (mod → player).
abstract final class ModRpcMethods {
  static const hello = 'hello';
  static const getPaths = 'getPaths';
  static const scanNew = 'scanNew';
  static const importFile = 'importFile';
  static const playTrack = 'playTrack';
  static const playRemote = 'playRemote';
  static const pickLibraryTrack = 'pickLibraryTrack';
  static const replaceTrackAudio = 'replaceTrackAudio';
  static const listTracks = 'listTracks';
  static const applyTrackMetadata = 'applyTrackMetadata';
}

class HelloResult {
  const HelloResult({
    required this.api,
    required this.playerName,
  });

  final int api;
  final String playerName;

  factory HelloResult.fromJson(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    return HelloResult(
      api: map['api'] is int ? map['api'] as int : kFmModApiVersion,
      playerName: '${map['playerName'] ?? 'Freedom Music'}',
    );
  }

  Map<String, dynamic> toJson() => {
        'api': api,
        'playerName': playerName,
      };
}

class PathsResult {
  const PathsResult({
    required this.root,
    required this.musicDir,
    required this.dataDir,
  });

  final String root;
  final String musicDir;
  final String dataDir;

  factory PathsResult.fromJson(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    return PathsResult(
      root: '${map['root'] ?? ''}',
      musicDir: '${map['musicDir'] ?? ''}',
      dataDir: '${map['dataDir'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'root': root,
        'musicDir': musicDir,
        'dataDir': dataDir,
      };
}

class ImportFileResult {
  const ImportFileResult({
    required this.trackKey,
    required this.title,
    required this.artist,
  });

  final String trackKey;
  final String title;
  final String artist;

  factory ImportFileResult.fromJson(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    return ImportFileResult(
      trackKey: '${map['trackKey'] ?? ''}',
      title: '${map['title'] ?? ''}',
      artist: '${map['artist'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'trackKey': trackKey,
        'title': title,
        'artist': artist,
      };
}

class PickedTrackResult {
  const PickedTrackResult({
    required this.trackKey,
    required this.title,
    required this.artist,
  });

  final String trackKey;
  final String title;
  final String artist;

  factory PickedTrackResult.fromJson(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    return PickedTrackResult(
      trackKey: '${map['trackKey'] ?? ''}',
      title: '${map['title'] ?? ''}',
      artist: '${map['artist'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'trackKey': trackKey,
        'title': title,
        'artist': artist,
      };
}

/// Library track snapshot for metadata mods.
class TrackListItem {
  const TrackListItem({
    required this.trackKey,
    required this.title,
    required this.artist,
    required this.album,
    this.albumArtist,
    this.producer,
    this.note,
    this.genre = '',
    this.year,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.lyrics,
    this.coverPath,
    this.verified = false,
  });

  final String trackKey;
  final String title;
  final String artist;
  final String album;
  final String? albumArtist;
  final String? producer;
  final String? note;
  final String genre;
  final int? year;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final String? lyrics;
  final String? coverPath;
  final bool verified;

  factory TrackListItem.fromJson(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    return TrackListItem(
      trackKey: '${map['trackKey'] ?? ''}',
      title: '${map['title'] ?? ''}',
      artist: '${map['artist'] ?? ''}',
      album: '${map['album'] ?? ''}',
      albumArtist: _nullableString(map['albumArtist']),
      producer: _nullableString(map['producer']),
      note: _nullableString(map['note']),
      genre: '${map['genre'] ?? ''}',
      year: _asInt(map['year']),
      trackNumber: _asInt(map['trackNumber']),
      trackTotal: _asInt(map['trackTotal']),
      discNumber: _asInt(map['discNumber']),
      lyrics: _nullableString(map['lyrics']),
      coverPath: _nullableString(map['coverPath']),
      verified: map['verified'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'trackKey': trackKey,
        'title': title,
        'artist': artist,
        'album': album,
        if (albumArtist != null) 'albumArtist': albumArtist,
        if (producer != null) 'producer': producer,
        if (note != null) 'note': note,
        'genre': genre,
        if (year != null) 'year': year,
        if (trackNumber != null) 'trackNumber': trackNumber,
        if (trackTotal != null) 'trackTotal': trackTotal,
        if (discNumber != null) 'discNumber': discNumber,
        if (lyrics != null) 'lyrics': lyrics,
        if (coverPath != null) 'coverPath': coverPath,
        'verified': verified,
      };

  static String? _nullableString(Object? value) {
    final s = '${value ?? ''}'.trim();
    return s.isEmpty ? null : s;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }
}

class TrackListResult {
  const TrackListResult({required this.tracks});

  final List<TrackListItem> tracks;

  factory TrackListResult.fromJson(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    final list = map['tracks'];
    final tracks = <TrackListItem>[];
    if (list is List) {
      for (final item in list) {
        tracks.add(TrackListItem.fromJson(item));
      }
    }
    return TrackListResult(tracks: tracks);
  }

  Map<String, dynamic> toJson() => {
        'tracks': [for (final t in tracks) t.toJson()],
      };
}

class ApplyTrackMetadataResult {
  const ApplyTrackMetadataResult({
    required this.trackKey,
    required this.title,
    required this.artist,
  });

  final String trackKey;
  final String title;
  final String artist;

  factory ApplyTrackMetadataResult.fromJson(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    return ApplyTrackMetadataResult(
      trackKey: '${map['trackKey'] ?? ''}',
      title: '${map['title'] ?? ''}',
      artist: '${map['artist'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'trackKey': trackKey,
        'title': title,
        'artist': artist,
      };
}
