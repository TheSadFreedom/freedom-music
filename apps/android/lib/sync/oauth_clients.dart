/// Public OAuth client IDs (not secrets). Prefer assets/secrets/yandex_oauth.json.
abstract final class OAuthClients {
  /// Yandex OAuth client id (public).
  static const yandexClientId = '35b128160f6c4bf1b8e53e9736e66204';

  /// Fallback for local/release when asset is missing.
  static const yandexClientSecret = '6d13c24f6f6443b083cd574de8595813';
}
