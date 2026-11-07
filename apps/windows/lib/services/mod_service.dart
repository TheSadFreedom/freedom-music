import 'package:flutter/foundation.dart';
import 'package:fm_mod_protocol/fm_mod_protocol.dart';

import '../data/app_paths.dart';
import 'library_service.dart';
import 'mod_discovery.dart';
import 'mod_host_server.dart';
import 'mod_launcher.dart';
import 'player_service.dart';

/// Player-side mod host: discovery + IPC + launch.
class ModService extends ChangeNotifier {
  ModService({
    required AppPaths paths,
    required LibraryService library,
    required PlayerService player,
  }) : discovery = ModDiscovery(paths) {
    host = ModHostServer(
      paths: paths,
      library: library,
      player: player,
    );
    launcher = ModLauncher(host);
    discovery.addListener(_onDiscovery);
  }

  final ModDiscovery discovery;
  late final ModHostServer host;
  late final ModLauncher launcher;

  List<ModManifest> get mods => discovery.mods;
  bool get hasMods => mods.isNotEmpty;

  Future<void> init() async {
    await discovery.refresh();
    await _ensureHost();
  }

  Future<void> refresh() async {
    await discovery.refresh();
    await _ensureHost();
  }

  Future<void> openMod(ModManifest mod) async {
    await _ensureHost();
    await launcher.open(mod);
  }

  Future<void> _ensureHost() async {
    if (!hasMods) return;
    await host.start();
  }

  void _onDiscovery() {
    notifyListeners();
  }

  @override
  void dispose() {
    discovery.removeListener(_onDiscovery);
    discovery.dispose();
    launcher.dispose();
    super.dispose();
  }
}
