import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'cloud_auth_session.dart';
import 'oauth_clients.dart';

/// Desktop Yandex OAuth for Disk app folder.
class YandexDiskAuth {
  YandexDiskAuth({String? storageDir}) : _storageDir = storageDir;

  final String? _storageDir;
  http.Client? _client;
  String? _email;
  Timer? _refreshTimer;

  String? get email => _email;
  bool get isSignedIn => _email != null;

  static const _credentialsFileName = 'yandex_disk_credentials.json';
  static const _scope = 'cloud_api:disk.app_folder';

  /// [promptCode] — код со страницы https://oauth.yandex.ru/verification_code
  Future<CloudAuthSession> signIn({
    required Future<String?> Function() promptCode,
  }) =>
      _signInDesktop(promptCode: promptCode);

  Future<String> signInAccount({
    required Future<String?> Function() promptCode,
  }) async {
    final session = await _signInDesktop(promptCode: promptCode);
    return session.email;
  }

  Future<CloudAuthSession?> trySilent() async {
    if (_client != null && _email != null) {
      return CloudAuthSession(client: _client!, email: _email!);
    }
    final stored = await _loadStoredSession();
    if (stored == null) return null;
    try {
      final tokens = await _refresh(stored.refreshToken);
      final client = _BearerClient(
        http.Client(),
        tokens.accessToken,
      );
      _client = client;
      _email = stored.email;
      await _saveStoredSession(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken ?? stored.refreshToken,
        expiresAt: tokens.expiresAt,
        email: stored.email,
      );
      _scheduleRefresh(tokens.expiresAt);
      return CloudAuthSession(client: client, email: stored.email);
    } catch (_) {
      await _clearStoredSession();
      return null;
    }
  }

  Future<void> signOut() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
    _email = null;
    await _clearStoredSession();
  }

  /// Fixed redirect for Yandex apps that only allow verification_code.
  static const redirectUri = 'https://oauth.yandex.ru/verification_code';

  Future<CloudAuthSession> _signInDesktop({
    required Future<String?> Function() promptCode,
  }) async {
    final creds = await _loadDesktopCredentials();
    final httpClient = http.Client();

    final authUrl = Uri.https('oauth.yandex.ru', '/authorize', {
      'response_type': 'code',
      'client_id': creds.clientId,
      'redirect_uri': redirectUri,
      'scope': _scope,
      'force_confirm': 'yes',
    });

    final launched = await launchUrl(
      authUrl,
      mode: LaunchMode.platformDefault,
    );
    if (!launched) {
      httpClient.close();
      throw StateError('Не удалось открыть браузер для входа Яндекс');
    }

    final rawCode = await promptCode();
    final code = rawCode?.trim() ?? '';
    if (code.isEmpty) {
      httpClient.close();
      throw StateError('Вход отменён: код не введён');
    }

    final tokens = await _exchangeCode(
      httpClient: httpClient,
      code: code,
      redirectUri: redirectUri,
      clientId: creds.clientId,
      clientSecret: creds.clientSecret,
    );
    final email = await _resolveEmail(httpClient, tokens.accessToken);
    final client = _BearerClient(httpClient, tokens.accessToken);
    _client = client;
    _email = email;
    await _saveStoredSession(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken ?? '',
      expiresAt: tokens.expiresAt,
      email: email,
    );
    _scheduleRefresh(tokens.expiresAt);
    return CloudAuthSession(client: client, email: email);
  }

  Future<({String accessToken, String? refreshToken, DateTime expiresAt})>
      _exchangeCode({
    required http.Client httpClient,
    required String code,
    required String redirectUri,
    required String clientId,
    required String clientSecret,
  }) async {
    final res = await httpClient.post(
      Uri.https('oauth.yandex.ru', '/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirectUri,
      },
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Yandex token HTTP ${res.statusCode}: ${res.body}');
    }
    return _parseTokenResponse(res.body);
  }

  Future<({String accessToken, String? refreshToken, DateTime expiresAt})>
      _refresh(String refreshToken) async {
    final creds = await _loadDesktopCredentials();
    final httpClient = http.Client();
    try {
      final res = await httpClient.post(
        Uri.https('oauth.yandex.ru', '/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': creds.clientId,
          'client_secret': creds.clientSecret,
        },
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('Yandex refresh HTTP ${res.statusCode}: ${res.body}');
      }
      return _parseTokenResponse(res.body);
    } finally {
      httpClient.close();
    }
  }

  ({String accessToken, String? refreshToken, DateTime expiresAt})
      _parseTokenResponse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw StateError('Yandex token: неожиданный JSON');
    }
    final access = '${decoded['access_token'] ?? ''}'.trim();
    if (access.isEmpty) {
      throw StateError('Yandex token: нет access_token');
    }
    final refresh = '${decoded['refresh_token'] ?? ''}'.trim();
    final expiresIn = decoded['expires_in'];
    final seconds = expiresIn is int
        ? expiresIn
        : int.tryParse('$expiresIn') ?? 3600;
    return (
      accessToken: access,
      refreshToken: refresh.isEmpty ? null : refresh,
      expiresAt: DateTime.now().toUtc().add(Duration(seconds: seconds)),
    );
  }

  Future<String> _resolveEmail(http.Client client, String accessToken) async {
    try {
      final res = await client.get(
        Uri.https('login.yandex.ru', '/info', {'format': 'json'}),
        headers: {'Authorization': 'OAuth $accessToken'},
      );
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body);
        if (json is Map) {
          for (final key in ['default_email', 'email', 'login']) {
            final value = '${json[key] ?? ''}'.trim();
            if (value.isNotEmpty) return value;
          }
        }
      }
    } catch (_) {}
    return 'yandex-user';
  }

  void _scheduleRefresh(DateTime expiresAt) {
    _refreshTimer?.cancel();
    final when = expiresAt.subtract(const Duration(minutes: 5));
    final delay = when.difference(DateTime.now().toUtc());
    if (delay <= Duration.zero) {
      unawaited(_refreshInPlace());
      return;
    }
    _refreshTimer = Timer(delay, () => unawaited(_refreshInPlace()));
  }

  Future<void> _refreshInPlace() async {
    final stored = await _loadStoredSession();
    if (stored == null) return;
    try {
      final tokens = await _refresh(stored.refreshToken);
      final inner = http.Client();
      final client = _BearerClient(inner, tokens.accessToken);
      try {
        _client?.close();
      } catch (_) {}
      _client = client;
      await _saveStoredSession(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken ?? stored.refreshToken,
        expiresAt: tokens.expiresAt,
        email: stored.email,
      );
      _scheduleRefresh(tokens.expiresAt);
    } catch (_) {}
  }

  Future<File> _credentialsFile() async {
    final dir = await _resolveStorageDir();
    await Directory(dir).create(recursive: true);
    return File(p.join(dir, _credentialsFileName));
  }

  Future<String> _resolveStorageDir() async {
    final configured = _storageDir?.trim() ?? '';
    if (configured.isNotEmpty) {
      return configured;
    }
    final exeDir = File(Platform.resolvedExecutable).parent;
    var dir = exeDir;
    for (var i = 0; i < 10; i++) {
      if (await File(p.join(dir.path, 'pubspec.yaml')).exists()) {
        return p.join(dir.path, 'data');
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return p.join(exeDir.path, 'data');
  }

  Future<void> _saveStoredSession({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
    required String email,
  }) async {
    if (refreshToken.isEmpty) return;
    final file = await _credentialsFile();
    final payload = {
      'email': email,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'expiresAt': expiresAt.toIso8601String(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
  }

  Future<({String refreshToken, String email})?> _loadStoredSession() async {
    try {
      final file = await _credentialsFile();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final email = '${decoded['email'] ?? ''}'.trim();
      final refresh = '${decoded['refreshToken'] ?? ''}'.trim();
      if (email.isEmpty || refresh.isEmpty) return null;
      return (refreshToken: refresh, email: email);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearStoredSession() async {
    try {
      final file = await _credentialsFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<({String clientId, String clientSecret})>
      _loadDesktopCredentials() async {
    const fileName = 'yandex_oauth.desktop.json';
    final seen = <String>{};
    final candidates = <String>[];

    void add(String path) {
      final n = p.normalize(path);
      if (seen.add(n)) candidates.add(n);
    }

    for (final root in [
      p.dirname(Platform.resolvedExecutable),
      Directory.current.path,
    ]) {
      var dir = root;
      for (var i = 0; i < 10; i++) {
        add(p.join(dir, 'secrets', fileName));
        add(p.join(dir, fileName));
        final parent = p.dirname(dir);
        if (parent == dir) break;
        dir = parent;
      }
    }

    for (final path in candidates) {
      final file = File(path);
      if (!await file.exists()) continue;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) continue;
      Map raw = json;
      final installed = json['installed'];
      if (installed is Map) raw = installed;
      final id = '${raw['client_id'] ?? ''}'.trim();
      final secret = '${raw['client_secret'] ?? ''}'.trim();
      if (id.isNotEmpty && secret.isNotEmpty) {
        return (clientId: id, clientSecret: secret);
      }
      if (secret.isNotEmpty &&
          OAuthClients.yandexClientId != 'YOUR_YANDEX_CLIENT_ID') {
        return (
          clientId: OAuthClients.yandexClientId,
          clientSecret: secret,
        );
      }
    }
    throw StateError(
      'Нет Yandex OAuth: положите secrets/yandex_oauth.desktop.json '
      'с client_id и client_secret (см. secrets.example/).',
    );
  }
}

class _BearerClient extends http.BaseClient {
  _BearerClient(this._inner, this._token);

  final http.Client _inner;
  final String _token;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final host = request.url.host;
    if (host.endsWith('yandex.net') ||
        host.endsWith('yandex.ru') ||
        host.endsWith('yandex.com')) {
      request.headers.putIfAbsent('Authorization', () => 'OAuth $_token');
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

