import 'bib_source.dart';
import 'browser_source.dart';
import 'drivemusic_source.dart';
import 'lmusic_source.dart';
import 'mp3bob_source.dart';
import 'muzpace_source.dart';
import 'muzskil_source.dart';
import 'muzso_source.dart';
import 'muzyet_source.dart';
import 'tunemir_source.dart';
import 'zaycev_source.dart';

/// Все онлайн-источники Браузера (новый набор экземпляров).
List<BrowserSource> createBrowserSources() {
  return [
    ZaycevSource(),
    TunemirSource(),
    MuzpaceSource(),
    MuzsoSource(),
    DrivemusicSource(),
    Mp3bobSource(),
    MuzskilSource(),
    MuzyetSource(),
    LmusicSource(),
    BibSource(),
  ];
}

void closeBrowserSource(BrowserSource source) {
  if (source is ZaycevSource) {
    source.close();
  } else if (source is TunemirSource) {
    source.close();
  } else if (source is MuzpaceSource) {
    source.close();
  } else if (source is MuzsoSource) {
    source.close();
  } else if (source is DrivemusicSource) {
    source.close();
  } else if (source is Mp3bobSource) {
    source.close();
  } else if (source is MuzskilSource) {
    source.close();
  } else if (source is MuzyetSource) {
    source.close();
  } else if (source is LmusicSource) {
    source.close();
  } else if (source is BibSource) {
    source.close();
  }
}

void closeBrowserSources(Iterable<BrowserSource> sources) {
  for (final source in sources) {
    closeBrowserSource(source);
  }
}
