import 'dart:convert';
import 'dart:io' show HttpException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_sync_client.dart';

/// Yandex Disk app-folder sync storage (`cloud_api:disk.app_folder`).
class YandexDiskClient implements CloudSyncClient {
  YandexDiskClient(this._client);

  final http.Client _client;

  static const _api = 'https://cloud-api.yandex.net/v1/disk';
  static const _root = 'app:/';

  /// Paths already created this session (`app:/artist_photos`, …).
  final Set<String> _ensuredDirs = {};

  @override
  Future<List<CloudSyncFile>> listEventChunks() async {
    final items = await _listAll(_root);
    final out = <CloudSyncFile>[
      for (final item in items)
        if (item.name.startsWith(CloudSyncClient.eventsPrefix))
          CloudSyncFile(id: item.path, name: item.name),
    ];
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  @override
  Future<List<CloudSyncFile>> listPlayCountFiles() async {
    final items = await _listAll(_root);
    return [
      for (final item in items)
        if (item.name.startsWith(CloudSyncClient.playsPrefix))
          CloudSyncFile(id: item.path, name: item.name),
    ];
  }

  @override
  Future<List<CloudSyncFile>> listDir(String relativeDir) async {
    final dir = relativeDir.replaceAll(RegExp(r'^/+|/+$'), '');
    final path = dir.isEmpty ? _root : '$_root$dir';
    final items = await _listAll(path);
    return [
      for (final item in items) CloudSyncFile(id: item.path, name: item.name),
    ];
  }

  @override
  Future<String> downloadText(String id) async {
    final bytes = await downloadBytes(id);
    return utf8.decode(bytes);
  }

  @override
  Future<Uint8List> downloadBytes(String id) async {
    final linkRes = await _client.get(
      Uri.parse('$_api/resources/download').replace(
        queryParameters: {'path': id},
      ),
      headers: _jsonHeaders,
    );
    if (linkRes.statusCode < 200 || linkRes.statusCode >= 300) {
      throw HttpException(
        'Yandex download link HTTP ${linkRes.statusCode}: ${linkRes.body}',
        uri: linkRes.request?.url,
      );
    }
    final decoded = jsonDecode(linkRes.body);
    final href = decoded is Map ? '${decoded['href'] ?? ''}' : '';
    if (href.isEmpty) {
      throw StateError('Yandex: пустая ссылка скачивания');
    }
    final fileRes = await _client.get(Uri.parse(href));
    if (fileRes.statusCode < 200 || fileRes.statusCode >= 300) {
      throw HttpException(
        'Yandex download HTTP ${fileRes.statusCode}',
        uri: fileRes.request?.url,
      );
    }
    return fileRes.bodyBytes;
  }

  @override
  Future<Map<String, Object?>> downloadMeta() async {
    final path = '$_root${CloudSyncClient.metaName}';
    try {
      final text = await downloadText(path);
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return {};
  }

  @override
  Future<void> uploadMeta(Map<String, Object?> meta) async {
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(meta));
    await uploadBytes(
      relativePath: CloudSyncClient.metaName,
      bytes: Uint8List.fromList(bytes),
    );
  }

  @override
  Future<void> uploadEventChunk({
    required String name,
    required String jsonl,
  }) async {
    await uploadBytes(
      relativePath: name,
      bytes: Uint8List.fromList(utf8.encode(jsonl)),
    );
  }

  @override
  Future<void> uploadPlayCounts({
    required String deviceId,
    required Map<String, Object?> payload,
  }) async {
    final name = '${CloudSyncClient.playsPrefix}$deviceId.json';
    await uploadBytes(
      relativePath: name,
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
  }

  @override
  Future<void> uploadBytes({
    required String relativePath,
    required Uint8List bytes,
  }) async {
    final clean = relativePath.replaceAll(RegExp(r'^/+'), '');
    await _ensureParentDirs(clean);
    final path = '$_root$clean';
    final linkRes = await _client.get(
      Uri.parse('$_api/resources/upload').replace(
        queryParameters: {
          'path': path,
          'overwrite': 'true',
        },
      ),
      headers: _jsonHeaders,
    );
    if (linkRes.statusCode < 200 || linkRes.statusCode >= 300) {
      throw HttpException(
        'Yandex upload link HTTP ${linkRes.statusCode}: ${linkRes.body}',
        uri: linkRes.request?.url,
      );
    }
    final decoded = jsonDecode(linkRes.body);
    final href = decoded is Map ? '${decoded['href'] ?? ''}' : '';
    if (href.isEmpty) {
      throw StateError('Yandex: пустая ссылка загрузки');
    }
    final put = await _client.put(
      Uri.parse(href),
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${bytes.length}',
      },
      body: bytes,
    );
    if (put.statusCode < 200 || put.statusCode >= 300) {
      throw HttpException(
        'Yandex upload HTTP ${put.statusCode}: ${put.body}',
        uri: put.request?.url,
      );
    }
  }

  @override
  Future<void> deletePath(String id) async {
    final res = await _client.delete(
      Uri.parse('$_api/resources').replace(
        queryParameters: {
          'path': id,
          'permanently': 'true',
        },
      ),
      headers: _jsonHeaders,
    );
    if (res.statusCode == 404) return;
    if (res.statusCode == 202 ||
        (res.statusCode >= 200 && res.statusCode < 300)) {
      return;
    }
    throw HttpException(
      'Yandex delete HTTP ${res.statusCode}: ${res.body}',
      uri: res.request?.url,
    );
  }

  /// Create parent folders for `artist_photos/x.jpg` → `app:/artist_photos`.
  Future<void> _ensureParentDirs(String relativePath) async {
    final parts = relativePath.split('/');
    if (parts.length < 2) return;
    var built = '';
    for (var i = 0; i < parts.length - 1; i++) {
      final segment = parts[i].trim();
      if (segment.isEmpty) continue;
      built = built.isEmpty ? segment : '$built/$segment';
      await _ensureDir('$_root$built');
    }
  }

  Future<void> _ensureDir(String path) async {
    if (_ensuredDirs.contains(path)) return;
    final res = await _client.put(
      Uri.parse('$_api/resources').replace(
        queryParameters: {'path': path},
      ),
      headers: _jsonHeaders,
    );
    // 201 created, 409 already exists — both OK.
    if (res.statusCode == 201 ||
        res.statusCode == 409 ||
        (res.statusCode >= 200 && res.statusCode < 300)) {
      _ensuredDirs.add(path);
      return;
    }
    throw HttpException(
      'Yandex mkdir HTTP ${res.statusCode}: ${res.body}',
      uri: res.request?.url,
    );
  }

  Future<List<({String name, String path})>> _listAll(String path) async {
    final out = <({String name, String path})>[];
    var offset = 0;
    const limit = 200;
    while (true) {
      final res = await _client.get(
        Uri.parse('$_api/resources').replace(
          queryParameters: {
            'path': path,
            'limit': '$limit',
            'offset': '$offset',
            'fields':
                '_embedded.items.name,_embedded.items.path,_embedded.items.type',
          },
        ),
        headers: _jsonHeaders,
      );
      if (res.statusCode == 404) return out;
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException(
          'Yandex list HTTP ${res.statusCode}: ${res.body}',
          uri: res.request?.url,
        );
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) break;
      final embedded = decoded['_embedded'];
      if (embedded is! Map) break;
      final items = embedded['items'];
      if (items is! List || items.isEmpty) break;
      for (final raw in items) {
        if (raw is! Map) continue;
        final type = '${raw['type'] ?? ''}';
        if (type != 'file') continue;
        final name = '${raw['name'] ?? ''}'.trim();
        final itemPath = '${raw['path'] ?? ''}'.trim();
        if (name.isEmpty || itemPath.isEmpty) continue;
        out.add((name: name, path: itemPath));
      }
      if (items.length < limit) break;
      offset += items.length;
    }
    return out;
  }

  Map<String, String> get _jsonHeaders => const {
        'Accept': 'application/json',
      };
}
