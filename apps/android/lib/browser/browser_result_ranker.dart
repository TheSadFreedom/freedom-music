import 'browser_hit.dart';

/// Локальное уточнение выдачи Браузера: без повторных запросов к сайтам.
class BrowserResultRanker {
  BrowserResultRanker._();

  static final _wsRe = RegExp(r'\s+');
  static final _punctRe = RegExp(r'[^\p{L}\p{N}\s]+', unicode: true);

  /// Сортирует [hits] по релевантности к [query].
  /// При наличии совпадений отбрасывает нулевой score.
  static List<BrowserHit> refine(String query, List<BrowserHit> hits) {
    if (hits.isEmpty) return const [];
    final tokens = _tokens(query);
    if (tokens.isEmpty) return List<BrowserHit>.of(hits);

    final consensus = <String, int>{};
    for (final hit in hits) {
      final key = _trackKey(hit);
      consensus[key] = (consensus[key] ?? 0) + 1;
    }

    final scored = <({int score, BrowserHit hit})>[];
    for (final hit in hits) {
      final base = _score(hit, tokens);
      final bonus =
          base > 0 ? _consensusBonus(consensus[_trackKey(hit)] ?? 1) : 0;
      scored.add((score: base + bonus, hit: hit));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.hit.title.toLowerCase().compareTo(b.hit.title.toLowerCase());
    });

    final matched = [
      for (final e in scored)
        if (e.score > 0) e.hit,
    ];
    if (matched.isNotEmpty) return matched;
    return [for (final e in scored) e.hit];
  }

  static int _consensusBonus(int count) {
    if (count <= 1) return 0;
    return (count - 1).clamp(1, 3);
  }

  static int _score(BrowserHit hit, List<String> tokens) {
    final artist = _normalize(hit.artist);
    final title = _normalize(hit.title);
    final hay = '$artist $title';
    var score = 0;
    var matched = 0;
    for (final t in tokens) {
      var ok = false;
      if (artist.contains(t)) {
        score += 3;
        ok = true;
      }
      if (title.contains(t)) {
        score += 2;
        ok = true;
      }
      if (!ok && hay.contains(t)) {
        score += 1;
        ok = true;
      }
      if (ok) matched++;
    }
    if (matched == tokens.length) score += 4;
    return score;
  }

  static String _trackKey(BrowserHit hit) =>
      '${_normalize(hit.artist)}|${_normalize(hit.title)}';

  static List<String> _tokens(String query) {
    final normalized = _normalize(query);
    if (normalized.isEmpty) return const [];
    return [
      for (final t in normalized.split(_wsRe))
        if (t.length >= 2) t,
    ];
  }

  static String _normalize(String raw) {
    var text = raw.toLowerCase().replaceAll('ё', 'е');
    text = text.replaceAll(_punctRe, ' ');
    return text.replaceAll(_wsRe, ' ').trim();
  }
}
