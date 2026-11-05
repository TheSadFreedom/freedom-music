import 'browser_hit.dart';

/// Плагин онлайн-источника для страницы «Браузер».
abstract class BrowserSource {
  String get id;
  String get name;

  /// Referer / Origin при скачивании файла.
  String get referer;

  Future<List<BrowserHit>> search(String query, {int limit = 30});

  /// Свежая ссылка на файл (у MusOpen — подписанный URL).
  Future<Uri> resolveDownload(BrowserHit hit);
}

/// Источник умеет отдать чарт / новинки без поискового запроса.
abstract class BrowserFeaturedSource {
  Future<List<BrowserHit>> featured({int limit = 3});
}
