import 'constants.dart';

/// Contents of `mods/<id>/mod.json`.
class ModManifest {
  const ModManifest({
    required this.id,
    required this.api,
    required this.name,
    required this.exe,
    required this.minPlayerApi,
    required this.directory,
  });

  final String id;
  final int api;
  final String name;
  final String exe;
  final int minPlayerApi;

  /// Absolute path to the mod folder (contains [exe] and mod.json).
  final String directory;

  bool get isCompatible =>
      api == kFmModApiVersion && minPlayerApi <= kFmModApiVersion;

  String get exePath {
    final sep = directory.contains('\\') ? '\\' : '/';
    if (directory.endsWith(sep)) return '$directory$exe';
    return '$directory$sep$exe';
  }

  static ModManifest? tryParse(
    Map<String, dynamic> json, {
    required String directory,
  }) {
    final id = '${json['id'] ?? ''}'.trim();
    final exe = '${json['exe'] ?? ''}'.trim();
    final name = '${json['name'] ?? id}'.trim();
    if (id.isEmpty || exe.isEmpty) return null;
    final api = _asInt(json['api']) ?? 0;
    final minPlayerApi = _asInt(json['minPlayerApi']) ?? 1;
    return ModManifest(
      id: id,
      api: api,
      name: name.isEmpty ? id : name,
      exe: exe,
      minPlayerApi: minPlayerApi,
      directory: directory,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'api': api,
        'name': name,
        'exe': exe,
        'minPlayerApi': minPlayerApi,
      };

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }
}
