import 'bib_source.dart';
import 'browser_source.dart';
import 'drivemusic_source.dart';
import 'fma_source.dart';
import 'gettune_source.dart';
import 'hitplayer_source.dart';
import 'imusic_source.dart';
import 'jamendo_source.dart';
import 'lalamus_source.dart';
import 'lmusic_source.dart';
import 'mp3bob_source.dart';
import 'mp3store_source.dart';
import 'mp3xa_source.dart';
import 'musopen_source.dart';
import 'muzofond_source.dart';
import 'muzofan_source.dart';
import 'muzfine_source.dart';
import 'muzok_source.dart';
import 'muzpace_source.dart';
import 'muzskil_source.dart';
import 'muzso_source.dart';
import 'muzyet_source.dart';
import 'muzzona_source.dart';
import 'pesni_source.dart';
import 'tribe_source.dart';
import 'tunemir_source.dart';
import 'zaycev_source.dart';
import 'zvuch_source.dart';

/// Все онлайн-источники Браузера (новый набор экземпляров).
List<BrowserSource> createBrowserSources() {
  return [
    ZaycevSource(),
    TunemirSource(),
    MuzpaceSource(),
    MuzsoSource(),
    ImusicSource(),
    MuzofondSource(),
    DrivemusicSource(),
    Mp3bobSource(),
    PesniSource(),
    LalamusSource(),
    MuzskilSource(),
    MuzyetSource(),
    MuzofanSource(),
    Mp3xaSource(),
    LmusicSource(),
    HitplayerSource(),
    MuzfineSource(),
    BibSource(),
    ZvuchSource(),
    GettuneSource(),
    MuzzonaSource(),
    MuzokSource(),
    Mp3storeSource(),
    FmaSource(),
    TribeSource(),
    JamendoSource(),
    MusOpenSource(),
  ];
}

void closeBrowserSource(BrowserSource source) {
  if (source is MusOpenSource) {
    source.close();
  } else if (source is ZaycevSource) {
    source.close();
  } else if (source is TunemirSource) {
    source.close();
  } else if (source is MuzpaceSource) {
    source.close();
  } else if (source is MuzsoSource) {
    source.close();
  } else if (source is ImusicSource) {
    source.close();
  } else if (source is MuzofondSource) {
    source.close();
  } else if (source is DrivemusicSource) {
    source.close();
  } else if (source is Mp3bobSource) {
    source.close();
  } else if (source is PesniSource) {
    source.close();
  } else if (source is LalamusSource) {
    source.close();
  } else if (source is MuzskilSource) {
    source.close();
  } else if (source is MuzyetSource) {
    source.close();
  } else if (source is MuzofanSource) {
    source.close();
  } else if (source is Mp3xaSource) {
    source.close();
  } else if (source is LmusicSource) {
    source.close();
  } else if (source is HitplayerSource) {
    source.close();
  } else if (source is MuzfineSource) {
    source.close();
  } else if (source is BibSource) {
    source.close();
  } else if (source is ZvuchSource) {
    source.close();
  } else if (source is GettuneSource) {
    source.close();
  } else if (source is MuzzonaSource) {
    source.close();
  } else if (source is MuzokSource) {
    source.close();
  } else if (source is Mp3storeSource) {
    source.close();
  } else if (source is FmaSource) {
    source.close();
  } else if (source is TribeSource) {
    source.close();
  } else if (source is JamendoSource) {
    source.close();
  }
}

void closeBrowserSources(Iterable<BrowserSource> sources) {
  for (final source in sources) {
    closeBrowserSource(source);
  }
}
