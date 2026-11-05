import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// media_kit в debug пишет NativeReferenceHolder в %TEMP%.
/// Если запись туда падает (errno 5), `add()` ждёт Completer вечно —
/// трек висит в плеере на 0:00 без звука.
///
/// Не трогаем [Directory.systemTemp] до проверки: он кэширует путь.
void ensureWritableTemp(String fallbackDir) {
  if (!Platform.isWindows) return;

  for (final key in const ['TEMP', 'TMP']) {
    final value = Platform.environment[key]?.trim();
    if (value != null && value.isNotEmpty && _probeWrite(value)) {
      return;
    }
  }

  final dir = Directory(fallbackDir);
  try {
    dir.createSync(recursive: true);
  } catch (e) {
    debugPrint('ensureWritableTemp: cannot create $fallbackDir: $e');
    return;
  }
  if (!_probeWrite(dir.path)) {
    debugPrint('ensureWritableTemp: fallback not writable: ${dir.path}');
    return;
  }

  if (_setEnv('TEMP', dir.path) && _setEnv('TMP', dir.path)) {
    debugPrint('ensureWritableTemp: using ${dir.path}');
  }
}

bool _probeWrite(String dirPath) {
  final probe = File(
    p.join(dirPath, 'freedom_music_temp_probe_$pid.tmp'),
  );
  try {
    probe.writeAsStringSync('ok', flush: true);
    probe.deleteSync();
    return true;
  } catch (_) {
    try {
      if (probe.existsSync()) probe.deleteSync();
    } catch (_) {}
    return false;
  }
}

typedef _SetEnvironmentVariableWNative = Int32 Function(
  Pointer<Utf16> name,
  Pointer<Utf16> value,
);
typedef _SetEnvironmentVariableWDart = int Function(
  Pointer<Utf16> name,
  Pointer<Utf16> value,
);

bool _setEnv(String name, String value) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final set = kernel32.lookupFunction<_SetEnvironmentVariableWNative,
        _SetEnvironmentVariableWDart>('SetEnvironmentVariableW');
    final n = name.toNativeUtf16();
    final v = value.toNativeUtf16();
    try {
      return set(n, v) != 0;
    } finally {
      malloc.free(n);
      malloc.free(v);
    }
  } catch (e) {
    debugPrint('SetEnvironmentVariableW failed: $e');
    return false;
  }
}
