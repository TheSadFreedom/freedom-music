import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fm_mod_protocol/fm_mod_protocol.dart';
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';

/// Scans `<playerRoot>/mods/*/mod.json`.
class ModDiscovery extends ChangeNotifier {
  ModDiscovery(this.paths);

  final AppPaths paths;

  final List<ModManifest> _mods = [];
  final List<ModManifest> _incompatible = [];

  List<ModManifest> get mods => List.unmodifiable(_mods);

  /// Present on disk but API mismatch.
  List<ModManifest> get incompatible => List.unmodifiable(_incompatible);

  String get modsDir => p.join(paths.root, kModsDirName);

  Future<void> refresh() async {
    _mods.clear();
    _incompatible.clear();
    final root = Directory(modsDir);
    if (!await root.exists()) {
      notifyListeners();
      return;
    }
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final manifestFile = File(p.join(entity.path, 'mod.json'));
      if (!await manifestFile.exists()) continue;
      try {
        final raw = jsonDecode(await manifestFile.readAsString());
        if (raw is! Map) continue;
        final manifest = ModManifest.tryParse(
          Map<String, dynamic>.from(raw),
          directory: entity.path,
        );
        if (manifest == null) continue;
        final exe = File(manifest.exePath);
        if (!await exe.exists()) continue;
        if (!manifest.isCompatible) {
          _incompatible.add(manifest);
          continue;
        }
        _mods.add(manifest);
      } catch (_) {
        // Skip broken manifests.
      }
    }
    _mods.sort((a, b) => a.id.compareTo(b.id));
    _incompatible.sort((a, b) => a.id.compareTo(b.id));
    notifyListeners();
  }
}
