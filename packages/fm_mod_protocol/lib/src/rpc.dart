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
