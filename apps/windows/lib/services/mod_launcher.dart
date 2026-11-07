import 'dart:async';
import 'dart:io';

import 'package:fm_mod_protocol/fm_mod_protocol.dart';

import 'mod_host_server.dart';

/// Starts / reuses a sidecar mod process.
class ModLauncher {
  ModLauncher(this.host);

  final ModHostServer host;

  final Map<String, Process> _processes = {};

  Future<void> open(ModManifest mod) async {
    if (!host.isRunning) {
      await host.start();
    }
    final existing = _processes[mod.id];
    if (existing != null) {
      // Still tracked = still running (removed on exit).
      return;
    }

    final exe = File(mod.exePath);
    if (!await exe.exists()) {
      throw StateError('Mod exe missing: ${mod.exePath}');
    }

    final process = await Process.start(
      exe.path,
      [
        '--host=${InternetAddress.loopbackIPv4.address}',
        '--port=${host.port}',
        '--token=${host.token}',
      ],
      workingDirectory: mod.directory,
    );
    _processes[mod.id] = process;
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((_) {
        _processes.remove(mod.id);
      }),
    );
  }

  Future<void> dispose() async {
    for (final process in _processes.values) {
      process.kill();
    }
    _processes.clear();
    await host.stop();
  }
}
