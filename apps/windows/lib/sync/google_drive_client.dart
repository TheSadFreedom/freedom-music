import 'dart:convert';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

/// Thin Drive appDataFolder helper for Freedom Music sync chunks.
class GoogleDriveClient {
  GoogleDriveClient(http.Client client) : _api = drive.DriveApi(client);

  final drive.DriveApi _api;

  static const appData = 'appDataFolder';
  static const eventsPrefix = 'fm_events_';
  static const playsPrefix = 'fm_plays_';
  static const metaName = 'fm_sync_meta.json';

  Future<List<drive.File>> listEventChunks() async {
    final out = <drive.File>[];
    String? pageToken;
    do {
      final page = await _api.files.list(
        spaces: appData,
        q: "name contains '$eventsPrefix' and trashed = false",
        $fields: 'nextPageToken, files(id, name, modifiedTime, size)',
        pageToken: pageToken,
        pageSize: 100,
      );
      out.addAll(page.files ?? const []);
      pageToken = page.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    out.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
    return out;
  }

  Future<String> downloadText(String fileId) async {
    final media = await _api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<Map<String, Object?>> downloadMeta() async {
    final existing = await _findByName(metaName);
    if (existing?.id == null) return {};
    final text = await downloadText(existing!.id!);
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
    return {};
  }

  Future<void> uploadMeta(Map<String, Object?> meta) async {
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(meta));
    await _upsertBytes(name: metaName, bytes: Uint8List.fromList(bytes));
  }

  Future<void> uploadEventChunk({
    required String name,
    required String jsonl,
  }) async {
    final bytes = utf8.encode(jsonl);
    await _upsertBytes(name: name, bytes: Uint8List.fromList(bytes));
  }

  /// Absolute play-count snapshot for one device (upserted every sync).
  Future<void> uploadPlayCounts({
    required String deviceId,
    required Map<String, Object?> payload,
  }) async {
    final name = '$playsPrefix$deviceId.json';
    final bytes = utf8.encode(jsonEncode(payload));
    await _upsertBytes(name: name, bytes: Uint8List.fromList(bytes));
  }

  Future<List<drive.File>> listPlayCountFiles() async {
    final out = <drive.File>[];
    String? pageToken;
    do {
      final page = await _api.files.list(
        spaces: appData,
        q: "name contains '$playsPrefix' and trashed = false",
        $fields: 'nextPageToken, files(id, name, modifiedTime)',
        pageToken: pageToken,
        pageSize: 100,
      );
      out.addAll(page.files ?? const []);
      pageToken = page.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return out;
  }

  Future<drive.File?> _findByName(String name) async {
    final page = await _api.files.list(
      spaces: appData,
      q: "name = '$name' and trashed = false",
      $fields: 'files(id, name)',
      pageSize: 1,
    );
    final files = page.files;
    if (files == null || files.isEmpty) return null;
    return files.first;
  }

  Future<void> _upsertBytes({
    required String name,
    required Uint8List bytes,
  }) async {
    final existing = await _findByName(name);
    final media = drive.Media(Stream.value(bytes), bytes.length);
    if (existing?.id != null) {
      await _api.files.update(
        drive.File()..name = name,
        existing!.id!,
        uploadMedia: media,
      );
      return;
    }
    await _api.files.create(
      drive.File()
        ..name = name
        ..parents = [appData],
      uploadMedia: media,
    );
  }
}
