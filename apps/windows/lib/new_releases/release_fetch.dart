import 'models.dart';
import 'spotify_client.dart';
import 'ym_client.dart';

enum DetectedSource { yandex, spotify, unknown }

DetectedSource detectSource(String rawUrl) {
  if (YmClient.parseArtistId(rawUrl) != null) return DetectedSource.yandex;
  if (SpotifyClient.parseArtistId(rawUrl) != null) {
    return DetectedSource.spotify;
  }
  return DetectedSource.unknown;
}

class ReleaseFetch {
  ReleaseFetch({YmClient? ym, SpotifyClient? spotify})
      : _ym = ym ?? YmClient(),
        _spotify = spotify ?? SpotifyClient();

  final YmClient _ym;
  final SpotifyClient _spotify;

  Future<LatestRelease> fetch(String rawUrl) async {
    switch (detectSource(rawUrl)) {
      case DetectedSource.yandex:
        return _ym.fetchLatestRelease(rawUrl);
      case DetectedSource.spotify:
        return _spotify.fetchLatestRelease(rawUrl);
      case DetectedSource.unknown:
        throw StateError(
          'Нужна ссылка music.yandex.ru/artist/… или open.spotify.com/artist/…',
        );
    }
  }

  /// Fetches from both links (when present) and returns the newest release.
  Future<LatestRelease> fetchNewest({
    String? yandexUrl,
    String? spotifyUrl,
  }) async {
    final ym = yandexUrl?.trim() ?? '';
    final sp = spotifyUrl?.trim() ?? '';
    if (ym.isEmpty && sp.isEmpty) {
      throw StateError('Укажи хотя бы одну ссылку');
    }
    if (ym.isNotEmpty && detectSource(ym) != DetectedSource.yandex) {
      throw StateError('Неверная ссылка Яндекс Музыки');
    }
    if (sp.isNotEmpty && detectSource(sp) != DetectedSource.spotify) {
      throw StateError('Неверная ссылка Spotify');
    }

    LatestRelease? best;
    Object? lastError;

    Future<void> tryFetch(String url) async {
      try {
        final release = await fetch(url);
        if (best == null || release.releaseDateMs >= best!.releaseDateMs) {
          best = release;
        }
      } catch (e) {
        lastError = e;
      }
    }

    if (ym.isNotEmpty) await tryFetch(ym);
    if (sp.isNotEmpty) await tryFetch(sp);

    if (best != null) return best!;
    throw lastError ?? StateError('Не удалось загрузить релиз');
  }

  void close() {
    _ym.close();
    _spotify.close();
  }
}
