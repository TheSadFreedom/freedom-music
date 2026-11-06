import 'package:flutter/material.dart';

import 'bib_source.dart';
import 'browser_hit.dart';
import 'browser_source.dart';
import 'lmusic_source.dart';
import 'mp3bob_source.dart';
import 'muzpace_source.dart';
import 'muzskil_source.dart';
import 'muzso_source.dart';
import 'muzyet_source.dart';
import 'tunemir_source.dart';
import 'zaycev_source.dart';

/// Курируемый онлайн-плейлист в Браузере (не поиск).
class BrowserPlaylist {
  const BrowserPlaylist({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.sourceId,
    required this.load,
    required this.coverColor,
    required this.coverForeground,
    this.icon = Icons.queue_music_rounded,
    this.coverLabel,
  });

  final String id;
  final String title;
  final String subtitle;
  final String sourceId;
  final Future<List<BrowserHit>> Function({int limit}) load;
  final Color coverColor;
  final Color coverForeground;
  final IconData icon;
  /// Крупная подпись на обложке (как NEW у системных).
  final String? coverLabel;
}

BrowserPlaylist _pl({
  required String id,
  required String title,
  required BrowserSource source,
  required Future<List<BrowserHit>> Function({int limit}) load,
  required Color coverColor,
  required Color coverForeground,
  required String coverLabel,
}) {
  return BrowserPlaylist(
    id: id,
    title: title,
    subtitle: source.name,
    sourceId: source.id,
    load: load,
    coverColor: coverColor,
    coverForeground: coverForeground,
    coverLabel: coverLabel,
  );
}

/// Все плейлисты Браузера (расширяется по мере добавления).
List<BrowserPlaylist> createBrowserPlaylists(
  Map<String, BrowserSource> byId,
) {
  final out = <BrowserPlaylist>[];

  final zaycev = byId['zaycev'];
  if (zaycev is ZaycevSource) {
    out.add(
      _pl(
        id: 'zaycev-new',
        title: 'Новинки',
        source: zaycev,
        load: ({int limit = 100}) => zaycev.featured(limit: limit),
        coverColor: const Color(0xFFFFDB4D),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'NEW',
      ),
    );
    out.add(
      _pl(
        id: 'zaycev-popular',
        title: 'Топ',
        source: zaycev,
        load: ({int limit = 100}) => zaycev.popular(limit: limit),
        coverColor: const Color(0xFFE8C96A),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'TOP',
      ),
    );
  }

  final tunemir = byId['tunemir'];
  if (tunemir is TunemirSource) {
    out.add(
      _pl(
        id: 'tunemir-new',
        title: 'Новинки',
        source: tunemir,
        load: ({int limit = 100}) => tunemir.newest(limit: limit),
        coverColor: const Color(0xFF7EC8A3),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'NEW',
      ),
    );
    out.add(
      _pl(
        id: 'tunemir-top',
        title: 'Топ',
        source: tunemir,
        load: ({int limit = 100}) => tunemir.popular(limit: limit),
        coverColor: const Color(0xFF8BB8D4),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'TOP',
      ),
    );
  }

  final muzpace = byId['muzpace'];
  if (muzpace is MuzpaceSource) {
    out.add(
      _pl(
        id: 'muzpace-new',
        title: 'Новинки',
        source: muzpace,
        load: ({int limit = 100}) => muzpace.newest(limit: limit),
        coverColor: const Color(0xFFD4A0C0),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'NEW',
      ),
    );
    out.add(
      _pl(
        id: 'muzpace-popular',
        title: 'Топ',
        source: muzpace,
        load: ({int limit = 100}) => muzpace.popular(limit: limit),
        coverColor: const Color(0xFFB8A0E8),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'TOP',
      ),
    );
  }

  final muzso = byId['muzso'];
  if (muzso is MuzsoSource) {
    out.add(
      _pl(
        id: 'muzso-new',
        title: 'Новинки',
        source: muzso,
        load: ({int limit = 100}) => muzso.newest(limit: limit),
        coverColor: const Color(0xFF5A9E8F),
        coverForeground: const Color(0xFFFFFFFF),
        coverLabel: 'NEW',
      ),
    );
    out.add(
      _pl(
        id: 'muzso-hits',
        title: 'Хиты',
        source: muzso,
        load: ({int limit = 100}) => muzso.popular(limit: limit),
        coverColor: const Color(0xFF3D7A6E),
        coverForeground: const Color(0xFFFFFFFF),
        coverLabel: 'HIT',
      ),
    );
  }

  final mp3bob = byId['mp3bob'];
  if (mp3bob is Mp3bobSource) {
    out.add(
      _pl(
        id: 'mp3bob-popular',
        title: 'Топ',
        source: mp3bob,
        load: ({int limit = 100}) => mp3bob.popular(limit: limit),
        coverColor: const Color(0xFFFF8A65),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'TOP',
      ),
    );
  }

  final muzskil = byId['muzskil'];
  if (muzskil is MuzskilSource) {
    out.add(
      _pl(
        id: 'muzskil-new',
        title: 'Новинки',
        source: muzskil,
        load: ({int limit = 100}) => muzskil.newest(limit: limit),
        coverColor: const Color(0xFF81C784),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'NEW',
      ),
    );
  }

  final lmusic = byId['lmusic'];
  if (lmusic is LmusicSource) {
    const charts = <(String, String, String)>[
      ('lmusic-kz-monthly', 'Топ KZ', 'top_kz/monthly'),
      ('lmusic-shazam', 'Shazam', 'hit-parade/shazam-music'),
      ('lmusic-europa', 'Европа Плюс', 'hit-parade/europaplus-music'),
      ('lmusic-love', 'Love Radio', 'hit-parade/loveradio'),
      ('lmusic-energy', 'ENERGY', 'hit-parade/energy-music'),
      ('lmusic-dfm', 'DFM', 'hit-parade/dfm'),
      ('lmusic-avto', 'Авторадио', 'hit-parade/avtoradio'),
    ];
    const colors = <Color>[
      Color(0xFF64B5F6),
      Color(0xFF4FC3F7),
      Color(0xFF4DD0E1),
      Color(0xFFF48FB1),
      Color(0xFFFFB74D),
      Color(0xFF9575CD),
      Color(0xFFA1887F),
    ];
    for (var i = 0; i < charts.length; i++) {
      final (pid, title, path) = charts[i];
      out.add(
        _pl(
          id: pid,
          title: title,
          source: lmusic,
          load: ({int limit = 100}) => lmusic.catalog(path, limit: limit),
          coverColor: colors[i],
          coverForeground: const Color(0xFF141414),
          coverLabel: title.length <= 4 ? title.toUpperCase() : 'TOP',
        ),
      );
    }
  }

  final bib = byId['bib'];
  if (bib is BibSource) {
    out.add(
      _pl(
        id: 'bib-popular',
        title: 'Популярное',
        source: bib,
        load: ({int limit = 100}) => bib.popular(limit: limit),
        coverColor: const Color(0xFF90A4AE),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'TOP',
      ),
    );
  }

  final muzyet = byId['muzyet'];
  if (muzyet is MuzyetSource) {
    out.add(
      _pl(
        id: 'muzyet-new',
        title: 'Новинки',
        source: muzyet,
        load: ({int limit = 100}) => muzyet.newest(limit: limit),
        coverColor: const Color(0xFFAED581),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'NEW',
      ),
    );
    out.add(
      _pl(
        id: 'muzyet-hits',
        title: 'Хиты',
        source: muzyet,
        load: ({int limit = 100}) => muzyet.popular(limit: limit),
        coverColor: const Color(0xFF9CCC65),
        coverForeground: const Color(0xFF141414),
        coverLabel: 'HIT',
      ),
    );
  }

  return out;
}
