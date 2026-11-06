/// Public OAuth client IDs (not secrets). Desktop secret lives in gitignored JSON.
abstract final class OAuthClients {
  static const androidClientId =
      '578058048224-ncij386i5t48e0dav6f5mdnqgteim3o7.apps.googleusercontent.com';

  static const desktopClientId =
      '578058048224-4uhhoevauud9230f88ol29pa5opcafd4.apps.googleusercontent.com';

  /// Web client ID — required by google_sign_in 7 as [serverClientId] on Android.
  static const webClientId =
      '578058048224-u5dsfiojnptpso3ooa8p8u4e2ccg47g0.apps.googleusercontent.com';

  static const driveAppDataScope =
      'https://www.googleapis.com/auth/drive.appdata';

  static const emailScope = 'email';
  static const openIdScope = 'openid';

  static const scopes = <String>[
    openIdScope,
    emailScope,
    driveAppDataScope,
  ];
}
