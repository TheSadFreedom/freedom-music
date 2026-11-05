/// Результат поиска в онлайн-источнике «Браузера».
class BrowserHit {
  const BrowserHit({
    required this.sourceId,
    required this.id,
    required this.title,
    required this.artist,
    this.subtitle,
    this.duration,
    this.license,
    this.downloadUrl,
  });

  final String sourceId;
  final String id;
  final String title;

  /// Композитор / основной артист.
  final String artist;

  /// Исполнитель или доп. подпись.
  final String? subtitle;
  final Duration? duration;
  final String? license;

  /// Прямая ссылка, если источник уже отдал её в поиске.
  final String? downloadUrl;
}
