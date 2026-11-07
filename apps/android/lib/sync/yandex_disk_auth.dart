import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cloud_auth_session.dart';
import 'oauth_clients.dart';

/// Yandex OAuth for Disk app folder (Android + shared verification_code flow).
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
  static const redirectUri = 'https://oauth.yandex.ru/verification_code';

  /// [promptCode] — код со страницы verification_code.
  Future<CloudAuthSession> signIn({
    required Future<String?> Function() promptCode,
  }) =>
      _signIn(promptCode: promptCode);

  Future<CloudAuthSession?> trySilent() async {
    if (_client != null && _email != null) {
      return CloudAuthSession(client: _client!, email: _email!);
    }
    final stored = await _loadStoredSession();
    if (stored == null) return null;
    try {
      final tokens = await _refresh(stored.refreshToken);
      final client = _BearerClient(http.Client(), tokens.accessToken);
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

  Future<CloudAuthSession> _signIn({
    required Future<String?> Function() promptCode,
  }) async {
    final creds = await _loadAppCredentials();
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
      mode: LaunchMode.externalApplication,
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
    final creds = await _loadAppCredentials();
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
      final client = _BearerClient(http.Client(), tokens.accessToken);
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
    if (configured.isNotEmpty) return configured;
    final support = await getApplicationSupportDirectory();
    return support.path;
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

  Future<({String clientId, String clientSecret})> _loadAppCredentials() async {
    // 1) Flutter asset (release APK).
    try {
      final raw = await rootBundle.loadString('assets/secrets/yandex_oauth.json');
      final parsed = _parseCredsJson(raw);
      if (parsed != null) return parsed;
    } catch (_) {}

    // 2) Repo secrets/ next to project (dev).
    final seen = <String>{};
    final candidates = <String>[];
    void add(String path) {
      final n = p.normalize(path);
      if (seen.add(n)) candidates.add(n);
    }

    for (final root in [Directory.current.path]) {
      var dir = root;
      for (var i = 0; i < 10; i++) {
        add(p.join(dir, 'secrets', 'yandex_oauth.desktop.json'));
        add(p.join(dir, 'secrets', 'yandex_oauth.json'));
        final parent = p.dirname(dir);
        if (parent == dir) break;
        dir = parent;
      }
    }
    for (final path in candidates) {
      final file = File(path);
      if (!await file.exists()) continue;
      final parsed = _parseCredsJson(await file.readAsString());
      if (parsed != null) return parsed;
    }

    // 3) Public id + secret only if both known via OAuthClients.
    if (OAuthClients.yandexClientId != 'YOUR_YANDEX_CLIENT_ID' &&
        OAuthClients.yandexClientSecret != 'YOUR_YANDEX_CLIENT_SECRET') {
      return (
        clientId: OAuthClients.yandexClientId,
        clientSecret: OAuthClients.yandexClientSecret,
      );
    }

    throw StateError(
      'Нет Yandex OAuth: добавьте assets/secrets/yandex_oauth.json '
      'или secrets/yandex_oauth.desktop.json',
    );
  }

  ({String clientId, String clientSecret})? _parseCredsJson(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      Map map = json;
      final installed = json['installed'];
      if (installed is Map) map = installed;
      final id = '${map['client_id'] ?? ''}'.trim();
      final secret = '${map['client_secret'] ?? ''}'.trim();
      if (id.isEmpty || secret.isEmpty) return null;
      if (id == 'YOUR_YANDEX_CLIENT_ID') return null;
      return (clientId: id, clientSecret: secret);
    } catch (_) {
      return null;
    }
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
