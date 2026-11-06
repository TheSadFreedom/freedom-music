import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'oauth_clients.dart';

class DriveAuthSession {
  const DriveAuthSession({
    required this.client,
    required this.email,
  });

  final http.Client client;
  final String email;
}

/// Desktop Google OAuth for Drive appData (Windows).
///
/// Uses a local loopback listener and the system default browser.
/// Refresh tokens are stored under [storageDir] so the session survives relaunch.
class GoogleDriveAuth {
  GoogleDriveAuth({String? storageDir}) : _storageDir = storageDir;

  final String? _storageDir;
  http.Client? _desktopClient;
  String? _email;
  StreamSubscription<AccessCredentials>? _credSub;

  String? get email => _email;
  bool get isSignedIn => _email != null;
  bool get authorizationRequiresUserInteraction => false;

  static const _credentialsFileName = 'google_drive_credentials.json';

  Future<DriveAuthSession> signIn() => _signInDesktop();

  Future<String> signInAccount() async {
    final session = await _signInDesktop();
    return session.email;
  }

  Future<DriveAuthSession?> authorizeDrive({required bool interactive}) async {
    final client = _desktopClient;
    final email = _email;
    if (client != null && email != null) {
      return DriveAuthSession(client: client, email: email);
    }
    if (!interactive) {
      return trySilent();
    }
    return _signInDesktop();
  }

  Future<DriveAuthSession?> trySilent() async {
    if (_desktopClient != null && _email != null) {
      return DriveAuthSession(client: _desktopClient!, email: _email!);
    }
    final stored = await _loadStoredSession();
    if (stored == null) return null;
    try {
      final secret = await _loadDesktopSecret();
      final clientId = ClientId(OAuthClients.desktopClientId, secret);
      final httpClient = http.Client();
      final refresh = stored.credentials.refreshToken;
      if (refresh == null || refresh.isEmpty) {
        httpClient.close();
        await _clearStoredSession();
        return null;
      }
      final authed = autoRefreshingClient(
        clientId,
        stored.credentials,
        httpClient,
      );
      _listenCredentialUpdates(authed, stored.email);
      _desktopClient = authed;
      _email = stored.email;
      // Persist refreshed access token immediately if the library refreshes.
      await _saveStoredSession(authed.credentials, stored.email);
      return DriveAuthSession(client: authed, email: stored.email);
    } catch (_) {
      await _clearStoredSession();
      return null;
    }
  }

  Future<void> signOut() async {
    await _credSub?.cancel();
    _credSub = null;
    try {
      _desktopClient?.close();
    } catch (_) {}
    _desktopClient = null;
    _email = null;
    await _clearStoredSession();
  }

  Future<DriveAuthSession> _signInDesktop() async {
    final secret = await _loadDesktopSecret();
    final clientId = ClientId(OAuthClients.desktopClientId, secret);
    final httpClient = http.Client();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://localhost:${server.port}';
    final state = _randomState();
    final codeVerifier = _createCodeVerifier();
    final authUrl = _authenticationUri(
      redirectUri: redirectUri,
      clientId: clientId.identifier,
      scopes: OAuthClients.scopes,
      codeVerifier: codeVerifier,
      state: state,
    );

    final completer = Completer<Uri>();
    var completed = false;

    void completeOnce(Uri uri) {
      if (completed) return;
      completed = true;
      if (!completer.isCompleted) completer.complete(uri);
    }

    server.listen((request) async {
      try {
        completeOnce(request.uri);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..headers.set('Cache-Control', 'no-store')
          ..write(_oauthSuccessHtml);
        await request.response.close();
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });

    final launched = await launchUrl(
      authUrl,
      mode: LaunchMode.platformDefault,
    );
    if (!launched) {
      await server.close(force: true);
      httpClient.close();
      throw StateError('Не удалось открыть браузер для входа Google');
    }

    late final Uri callback;
    try {
      callback = await completer.future.timeout(const Duration(minutes: 5));
    } on TimeoutException {
      await server.close(force: true);
      httpClient.close();
      throw StateError(
        'Время входа истекло. Проверьте браузер и что localhost '
        'не блокируется VPN/firewall.',
      );
    } finally {
      await server.close(force: true);
    }

    final returnedState = callback.queryParameters['state'];
    if (returnedState != null && returnedState != state) {
      httpClient.close();
      throw StateError('Неверный state в ответе Google');
    }
    final error = callback.queryParameters['error'];
    if (error != null) {
      httpClient.close();
      throw StateError('Google OAuth: $error');
    }
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) {
      httpClient.close();
      throw StateError('Google не вернул код авторизации');
    }

    final credentials = await obtainAccessCredentialsViaCodeExchange(
      httpClient,
      clientId,
      code,
      redirectUrl: redirectUri,
      codeVerifier: codeVerifier,
    );

    final AuthClient authed;
    if (credentials.refreshToken != null) {
      authed = autoRefreshingClient(clientId, credentials, httpClient);
    } else {
      authed = authenticatedClient(httpClient, credentials);
    }

    final email = await _resolveEmail(authed, credentials);
    if (authed is AutoRefreshingAuthClient) {
      _listenCredentialUpdates(authed, email);
    }
    _desktopClient = authed;
    _email = email;
    await _saveStoredSession(credentials, email);
    return DriveAuthSession(client: authed, email: email);
  }

  void _listenCredentialUpdates(AutoRefreshingAuthClient client, String email) {
    _credSub?.cancel();
    _credSub = client.credentialUpdates.listen((creds) {
      unawaited(_saveStoredSession(creds, email));
    });
  }

  Future<String> _resolveEmail(
    AuthClient client,
    AccessCredentials credentials,
  ) async {
    final fromToken = _emailFromIdToken(credentials.idToken);
    if (fromToken != null) return fromToken;
    try {
      final res = await client.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
      );
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body);
        if (json is Map && json['email'] is String) {
          final email = (json['email'] as String).trim();
          if (email.isNotEmpty) return email;
        }
      }
    } catch (_) {}
    return 'google-user';
  }

  String? _emailFromIdToken(String? idToken) {
    if (idToken == null || idToken.isEmpty) return null;
    try {
      final parts = idToken.split('.');
      if (parts.length < 2) return null;
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final json = jsonDecode(payload);
      if (json is Map && json['email'] is String) {
        final email = (json['email'] as String).trim();
        if (email.isNotEmpty) return email;
      }
    } catch (_) {}
    return null;
  }

  Future<File> _credentialsFile() async {
    final dir = await _resolveStorageDir();
    await Directory(dir).create(recursive: true);
    return File(p.join(dir, _credentialsFileName));
  }

  Future<String> _resolveStorageDir() async {
    if (_storageDir != null && _storageDir!.trim().isNotEmpty) {
      return _storageDir!;
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

  Future<void> _saveStoredSession(
    AccessCredentials credentials,
    String email,
  ) async {
    if (credentials.refreshToken == null ||
        credentials.refreshToken!.isEmpty) {
      return;
    }
    final file = await _credentialsFile();
    final payload = {
      'email': email,
      'credentials': {
        'accessToken': credentials.accessToken.toJson(),
        'refreshToken': credentials.refreshToken,
        'idToken': credentials.idToken,
        'scopes': credentials.scopes,
      },
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
  }

  Future<({AccessCredentials credentials, String email})?>
      _loadStoredSession() async {
    try {
      final file = await _credentialsFile();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final email = decoded['email'] as String?;
      final raw = decoded['credentials'];
      if (email == null || email.isEmpty || raw is! Map) return null;
      final credMap = Map<String, dynamic>.from(raw);
      final accessRaw = credMap['accessToken'];
      if (accessRaw is! Map) return null;
      final credentials = AccessCredentials(
        AccessToken.fromJson(Map<String, dynamic>.from(accessRaw)),
        credMap['refreshToken'] as String?,
        [
          for (final s in (credMap['scopes'] as List? ?? const []))
            if (s is String) s,
        ],
        idToken: credMap['idToken'] as String?,
      );
      if (credentials.refreshToken == null ||
          credentials.refreshToken!.isEmpty) {
        return null;
      }
      return (credentials: credentials, email: email);
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

  Future<String> _loadDesktopSecret() async {
    const fileName = 'google_oauth.desktop.json';
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
      final installed = json is Map ? json['installed'] : null;
      if (installed is Map && installed['client_secret'] is String) {
        return installed['client_secret'] as String;
      }
    }
    throw StateError(
      'Нет client_secret: положите secrets/google_oauth.desktop.json '
      'в корень репозитория или рядом с exe',
    );
  }
}

/// Tries to close the auth tab; browsers often allow this after OAuth redirect.
const _oauthSuccessHtml = '''
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>Вход выполнен</title>
<style>
  html,body{height:100%;margin:0;background:#12141a;color:#e8e6e0;
  font-family:Segoe UI,sans-serif}
  .box{display:flex;flex-direction:column;align-items:center;justify-content:center;
  height:100%;gap:8px;text-align:center;padding:24px}
  h1{font-size:20px;font-weight:700;margin:0}
  p{font-size:14px;opacity:.7;margin:0}
</style>
</head>
<body>
<div class="box" id="box">
  <h1>Вход выполнен</h1>
  <p id="hint">Закрываем вкладку…</p>
</div>
<script>
(function () {
  function showFallback() {
    var hint = document.getElementById('hint');
    if (hint) hint.textContent = 'Можно закрыть эту вкладку и вернуться в Freedom Music.';
  }
  function tryClose() {
    try { window.open('', '_self'); } catch (e) {}
    try { window.close(); } catch (e) {}
    try {
      if (window.history.length <= 1) window.close();
    } catch (e) {}
  }
  tryClose();
  setTimeout(tryClose, 150);
  setTimeout(tryClose, 400);
  setTimeout(showFallback, 700);
})();
</script>
</body>
</html>
''';

Uri _authenticationUri({
  required String redirectUri,
  required String clientId,
  required List<String> scopes,
  required String codeVerifier,
  required String state,
}) {
  final challenge = base64UrlEncode(
    sha256.convert(ascii.encode(codeVerifier)).bytes,
  ).replaceAll('=', '');
  return Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
    'client_id': clientId,
    'response_type': 'code',
    'redirect_uri': redirectUri,
    'scope': scopes.join(' '),
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
    'access_type': 'offline',
    'prompt': 'consent',
    'state': state,
  });
}

String _createCodeVerifier() {
  const safe =
      '0123456789-._~abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final rnd = Random.secure();
  return List.generate(128, (_) => safe[rnd.nextInt(safe.length)]).join();
}

String _randomState() {
  final rnd = Random.secure();
  final list = Uint32List(6);
  for (var i = 0; i < list.length; i++) {
    list[i] = rnd.nextInt(1 << 32);
  }
  return base64UrlEncode(Uint8List.view(list.buffer)).replaceAll('=', '');
}
