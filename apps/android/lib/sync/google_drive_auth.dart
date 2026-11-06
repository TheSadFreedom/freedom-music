import 'dart:convert';
import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
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

/// Google auth for Drive appData: Sign-In on Android, installed-app flow on Windows.
class GoogleDriveAuth {
  AutoRefreshingAuthClient? _desktopClient;
  GoogleSignInAccount? _androidAccount;
  String? _email;

  String? get email => _email;
  bool get isSignedIn => _email != null;
  bool get authorizationRequiresUserInteraction =>
      Platform.isAndroid &&
      GoogleSignIn.instance.authorizationRequiresUserInteraction();

  Future<DriveAuthSession> signIn() async {
    if (Platform.isAndroid) {
      await signInAccount();
      final session = await authorizeDrive(interactive: true);
      if (session == null) {
        throw StateError('Нет доступа к Google Drive (scope drive.appdata)');
      }
      return session;
    }
    if (Platform.isWindows) return _signInDesktop();
    throw UnsupportedError('Синк Google Drive пока только Android/Windows');
  }

  /// Android: account picker only (no Drive consent UI yet).
  Future<String> signInAccount() async {
    if (!Platform.isAndroid) {
      final session = await this.signIn();
      return session.email;
    }
    final gsi = GoogleSignIn.instance;
    await gsi.initialize(serverClientId: OAuthClients.webClientId);
    final account = await gsi.authenticate(
      scopeHint: OAuthClients.scopes,
    );
    _androidAccount = account;
    _email = account.email;
    return account.email;
  }

  /// Obtain Drive appData access token.
  /// On Android [interactive] must be true from a fresh button/dialog press.
  Future<DriveAuthSession?> authorizeDrive({required bool interactive}) async {
    if (Platform.isWindows) {
      if (_desktopClient != null && _email != null) {
        return DriveAuthSession(client: _desktopClient!, email: _email!);
      }
      return _signInDesktop();
    }
    if (!Platform.isAndroid) return null;

    var account = _androidAccount;
    if (account == null) {
      final gsi = GoogleSignIn.instance;
      await gsi.initialize(serverClientId: OAuthClients.webClientId);
      account = await gsi.attemptLightweightAuthentication();
      if (account == null) return null;
      _androidAccount = account;
      _email = account.email;
    }

    final authClient = account.authorizationClient;
    var authed = await authClient.authorizationForScopes(OAuthClients.scopes);
    if (authed == null && interactive) {
      authed = await authClient.authorizeScopes(OAuthClients.scopes);
    }
    if (authed == null) return null;
    return DriveAuthSession(
      client: authed.authClient(scopes: OAuthClients.scopes),
      email: account.email,
    );
  }

  Future<DriveAuthSession?> trySilent() async {
    try {
      if (!Platform.isAndroid) return null;
      final gsi = GoogleSignIn.instance;
      await gsi.initialize(serverClientId: OAuthClients.webClientId);
      final account = await gsi.attemptLightweightAuthentication();
      if (account == null) return null;
      _androidAccount = account;
      _email = account.email;
      return authorizeDrive(interactive: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> signOut() async {
    if (Platform.isAndroid) {
      await GoogleSignIn.instance.signOut();
    }
    _desktopClient?.close();
    _desktopClient = null;
    _androidAccount = null;
    _email = null;
  }

  Future<DriveAuthSession> _signInDesktop() async {
    final secret = await _loadDesktopSecret();
    final id = ClientId(OAuthClients.desktopClientId, secret);
    final client = await clientViaUserConsent(
      id,
      OAuthClients.scopes,
      (url) async {
        final uri = Uri.parse(url);
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok) {
          throw StateError('Не удалось открыть браузер для входа Google');
        }
      },
    );
    _desktopClient = client;
    _email = _email ?? 'google-user';
    return DriveAuthSession(client: client, email: _email!);
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
