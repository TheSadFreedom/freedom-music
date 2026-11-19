import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

class WatchlistStore {
  WatchlistStore(this.file);

  final File file;

  static WatchlistStore inDataDir(String dataDir) {
    final dir = Directory(p.join(dataDir, 'mods', 'new_releases'));
    return WatchlistStore(File(p.join(dir.path, 'watchlist.json')));
  }

  Future<List<WatchedArtist>> load() async {
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return [];
      final list = raw['artists'];
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is Map)
            WatchedArtist.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<WatchedArtist> artists) async {
    await file.parent.create(recursive: true);
    final payload = {
      'version': 1,
      'artists': [for (final a in artists) a.toJson()],
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }
}
