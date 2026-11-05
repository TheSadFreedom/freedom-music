import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../browser/browser_hit.dart';
import '../browser/browser_result_ranker.dart';
import '../browser/browser_source.dart';
import '../browser/browser_sources.dart';
import '../services/browser_import_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../utils/duration_format.dart';
import '../widgets/library_track_picker.dart';

const _kYellow = Color(0xFFFFDB4D);

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final TextEditingController _query;
  late final List<BrowserSource> _sources;
  late final Map<String, BrowserSource> _byId;
  late final Set<String> _enabledIds;
  List<BrowserHit> _hits = const [];
  bool _searching = false;
  bool _sourcesExpanded = false;
  String? _downloadingKey;
  String? _previewingKey;
  String? _replacingKey;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController();
    _query.addListener(() {
      if (mounted) setState(() {});
    });
    _sources = createBrowserSources();
    _byId = {for (final s in _sources) s.id: s};
    _enabledIds = {for (final s in _sources) s.id};
  }

  @override
  void dispose() {
    _query.dispose();
    closeBrowserSources(_sources);
    super.dispose();
  }

  List<BrowserSource> get _activeSources => [
        for (final s in _sources)
          if (_enabledIds.contains(s.id)) s,
      ];

  String _hitKey(BrowserHit hit) => '${hit.sourceId}:${hit.id}';

  String? _sourceName(String sourceId) => _byId[sourceId]?.name;

  void _toggleSource(BrowserSource source, bool enabled) {
    if (_searching ||
        _downloadingKey != null ||
        _previewingKey != null ||
        _replacingKey != null) {
      return;
    }
    setState(() {
      if (enabled) {
        _enabledIds.add(source.id);
      } else {
        if (_enabledIds.length <= 1 && _enabledIds.contains(source.id)) {
          return;
        }
        _enabledIds.remove(source.id);
      }
      _error = null;
    });
  }

  void _toggleAllSources() {
    if (_searching ||
        _downloadingKey != null ||
        _previewingKey != null ||
        _replacingKey != null) {
      return;
    }
    if (_sources.isEmpty) return;
    setState(() {
      final allOn = _enabledIds.length >= _sources.length;
      if (allOn) {
        // Хотя бы один источник должен остаться.
        _enabledIds
          ..clear()
          ..add(_sources.first.id);
      } else {
        _enabledIds
          ..clear()
          ..addAll(_sources.map((s) => s.id));
      }
      _error = null;
    });
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (_searching) return;
    final active = _activeSources;
    if (active.isEmpty) {
      setState(() {
        _error = 'Включи хотя бы один источник';
        _status = null;
        _hits = const [];
      });
      return;
    }
    if (q.isEmpty) {
      setState(() {
        _hits = const [];
        _error = null;
        _status = null;
      });
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
      _status = 'Ищем на ${active.map((s) => s.name).join(', ')}…';
      _hits = const [];
    });

    final errors = <String>[];
    final merged = <BrowserHit>[];

    await Future.wait([
      for (final source in active)
        () async {
          try {
            final hits = await source.search(q).timeout(
              const Duration(seconds: 35),
            );
            merged.addAll(hits);
          } catch (e) {
            errors.add('${source.name}: $e');
          }
        }(),
    ]);

    if (!mounted) return;
    final refined = BrowserResultRanker.refine(q, merged);

    setState(() {
      _hits = refined;
      _searching = false;
      if (refined.isEmpty) {
        _status = 'Ничего не найдено';
        _error = errors.isEmpty ? null : errors.join('\n');
      } else {
        final bySource = <String, int>{};
        for (final hit in refined) {
          bySource[hit.sourceId] = (bySource[hit.sourceId] ?? 0) + 1;
        }
        final parts = [
          for (final s in _sources)
            if (bySource.containsKey(s.id)) '${s.name}: ${bySource[s.id]}',
        ];
        final trimmed =
            refined.length < merged.length ? ' из ${merged.length}' : '';
        _status = '${refined.length}$trimmed · ${parts.join(' · ')}';
        _error = errors.isEmpty ? null : 'Частично: ${errors.join('; ')}';
      }
    });
  }

  Future<void> _replace(BrowserHit hit) async {
    if (_downloadingKey != null ||
        _previewingKey != null ||
        _replacingKey != null) {
      return;
    }
    final source = _byId[hit.sourceId];
    if (source == null) {
      setState(() => _error = 'Неизвестный источник: ${hit.sourceId}');
      return;
    }
    final target = await showLibraryTrackPicker(
      context,
      title: 'Какой трек заменить?',
    );
    if (target == null || !mounted) return;

    final key = _hitKey(hit);
    setState(() {
      _replacingKey = key;
      _error = null;
      _status = 'Замена: ${target.displayTitle}…';
    });
    try {
      final library = context.read<LibraryService>();
      final player = context.read<PlayerService>();
      final importer = BrowserImportService(
        paths: library.paths,
        library: library,
      );
      final updated = await importer.replaceLibraryTrack(
        source: source,
        hit: hit,
        target: target,
        player: player,
      );
      if (!mounted) return;
      setState(() {
        _replacingKey = null;
        _status = 'Заменено: ${updated.displayTitle}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Файл заменён, метаданные сохранены',
            style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.inkLift,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _replacingKey = null;
        _error = e.toString();
        _status = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Замена не удалась: $e',
            style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF5C2B2B),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _preview(BrowserHit hit) async {
    if (_downloadingKey != null ||
        _previewingKey != null ||
        _replacingKey != null) {
      return;
    }
    final source = _byId[hit.sourceId];
    if (source == null) {
      setState(() => _error = 'Неизвестный источник: ${hit.sourceId}');
      return;
    }
    final key = _hitKey(hit);
    setState(() {
      _previewingKey = key;
      _error = null;
      _status = 'Слушаю: ${hit.title}…';
    });
    try {
      final uri = await source.resolveDownload(hit);
      if (!mounted) return;
      final player = context.read<PlayerService>();
      await player.playRemote(
        uri,
        title: hit.title,
        artist: hit.artist,
        httpHeaders: {
          HttpHeaders.userAgentHeader:
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
          HttpHeaders.refererHeader: source.referer,
        },
      );
      if (!mounted) return;
      setState(() {
        _previewingKey = null;
        _status = 'Превью: ${hit.artist} — ${hit.title}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _previewingKey = null;
        _error = e.toString();
        _status = null;
      });
    }
  }

  Future<void> _download(BrowserHit hit) async {
    if (_downloadingKey != null ||
        _previewingKey != null ||
        _replacingKey != null) {
      return;
    }
    final source = _byId[hit.sourceId];
    if (source == null) {
      setState(() => _error = 'Неизвестный источник: ${hit.sourceId}');
      return;
    }
    final key = _hitKey(hit);
    setState(() {
      _downloadingKey = key;
      _error = null;
      _status = 'Скачивание с ${source.name}…';
    });
    try {
      final library = context.read<LibraryService>();
      final player = context.read<PlayerService>();
      final importer = BrowserImportService(
        paths: library.paths,
        library: library,
      );
      final track = await importer.download(source, hit);
      if (!mounted) return;
      setState(() {
        _downloadingKey = null;
        _status = track != null
            ? 'В библиотеке: ${track.displayTitle}'
            : 'Скачано, но трек не найден после скана';
      });
      if (track != null) {
        await player.playTracks([track]);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            track != null
                ? 'Добавлено и воспроизводится'
                : 'Файл скачан — запустите скан библиотеки',
            style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.inkLift,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadingKey = null;
        _error = e.toString();
        _status = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    final busy = _searching ||
        _downloadingKey != null ||
        _previewingKey != null ||
        _replacingKey != null;
    final hPad = phone ? 16.0 : 22.0;
    final emptyQuery = _query.text.trim().isEmpty && !_searching;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _BrowserHero(
              phone: phone,
              query: _query,
              searching: _searching,
              enabledCount: _enabledIds.length,
              totalCount: _sources.length,
              onSearch:
                  busy && !_searching ? null : (_searching ? null : _search),
              onClear: () {
                _query.clear();
                setState(() {
                  _hits = const [];
                  _error = null;
                  _status = null;
                });
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 0),
              child: _SourcesBar(
                sources: _sources,
                enabledIds: _enabledIds,
                expanded: _sourcesExpanded,
                busy: busy,
                onToggle: _toggleSource,
                onToggleAll: _toggleAllSources,
                onExpandToggle: () =>
                    setState(() => _sourcesExpanded = !_sourcesExpanded),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 6),
              child: _ResultsHeader(
                status: _status,
                error: _error,
                count: _hits.length,
                searching: _searching,
              ),
            ),
          ),
          if (_hits.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 100),
                child: _EmptyState(
                  searching: _searching,
                  activeCount: _activeSources.length,
                  nothingFound: _status == 'Ничего не найдено',
                ),
              ),
            )
          else
            ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 0),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final hit = _hits[index];
                      final key = _hitKey(hit);
                      final busyHit = _downloadingKey == key ||
                          _previewingKey == key ||
                          _replacingKey == key;
                      final locked = _downloadingKey != null ||
                          _previewingKey != null ||
                          _replacingKey != null;
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == _hits.length - 1 ? 0 : 8,
                        ),
                        child: _HitCard(
                          hit: hit,
                          sourceName:
                              _sourceName(hit.sourceId) ?? hit.sourceId,
                          index: index,
                          busy: busyHit,
                          onPreview: locked ? null : () => _preview(hit),
                          onDownload: locked ? null : () => _download(hit),
                          onReplace: locked ? null : () => _replace(hit),
                        ),
                      );
                    },
                    childCount: _hits.length,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          if (emptyQuery || _hits.isEmpty)
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}

Color _accentFor(String seed) {
  const palette = <Color>[
    AppTheme.mossBright,
    AppTheme.lime,
    Color(0xFF7EC8A3),
    Color(0xFFE8C96A),
    Color(0xFF8BB8D4),
    Color(0xFFD4A0C0),
    Color(0xFFB8A0E8),
    Color(0xFFA8D080),
  ];
  var hash = 0;
  for (final c in seed.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}

class _BrowserHero extends StatelessWidget {
  const _BrowserHero({
    required this.phone,
    required this.query,
    required this.searching,
    required this.enabledCount,
    required this.totalCount,
    required this.onSearch,
    required this.onClear,
  });

  final bool phone;
  final TextEditingController query;
  final bool searching;
  final int enabledCount;
  final int totalCount;
  final VoidCallback? onSearch;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(phone ? 12 : 16, phone ? 8 : 10, phone ? 12 : 16, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.moss.withValues(alpha: 0.42),
            AppTheme.inkLift,
            const Color(0xFF1A2822),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            right: -30,
            top: -40,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.lime.withValues(alpha: 0.08),
              ),
            ),
          ),
          Positioned(
            left: -20,
            bottom: -50,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.mossBright.withValues(alpha: 0.1),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              phone ? 16 : 22,
              phone ? 16 : 20,
              phone ? 16 : 22,
              phone ? 16 : 18,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.lime.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'ONLINE',
                        style: GoogleFonts.figtree(
                          color: AppTheme.lime,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$enabledCount / $totalCount',
                      style: GoogleFonts.figtree(
                        color: AppTheme.paperMuted,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Браузер',
                  style: GoogleFonts.syne(
                    color: AppTheme.paper,
                    fontSize: phone ? 30 : 34,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Поиск треков по онлайн-каталогам',
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: query,
                        style: GoogleFonts.figtree(
                          color: AppTheme.paper,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => onSearch?.call(),
                        decoration: InputDecoration(
                          hintText: 'Артист или трек…',
                          hintStyle: GoogleFonts.figtree(
                            color: AppTheme.paperMuted.withValues(alpha: 0.7),
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            color: AppTheme.paperMuted,
                          ),
                          suffixIcon: query.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Очистить',
                                  onPressed: onClear,
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    color: AppTheme.paperMuted,
                                  ),
                                ),
                          filled: true,
                          fillColor: AppTheme.ink.withValues(alpha: 0.55),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: onSearch,
                      style: FilledButton.styleFrom(
                        backgroundColor: _kYellow,
                        foregroundColor: AppTheme.ink,
                        disabledBackgroundColor:
                            AppTheme.inkLift.withValues(alpha: 0.8),
                        minimumSize: const Size(52, 52),
                        padding: EdgeInsets.symmetric(
                          horizontal: phone ? 14 : 20,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: searching
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: AppTheme.ink,
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.arrow_forward_rounded, size: 20),
                                if (!phone) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    'Найти',
                                    style: GoogleFonts.figtree(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourcesBar extends StatelessWidget {
  const _SourcesBar({
    required this.sources,
    required this.enabledIds,
    required this.expanded,
    required this.busy,
    required this.onToggle,
    required this.onToggleAll,
    required this.onExpandToggle,
  });

  final List<BrowserSource> sources;
  final Set<String> enabledIds;
  final bool expanded;
  final bool busy;
  final void Function(BrowserSource source, bool enabled) onToggle;
  final VoidCallback onToggleAll;
  final VoidCallback onExpandToggle;

  @override
  Widget build(BuildContext context) {
    final allOn = sources.isNotEmpty && enabledIds.length >= sources.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'Источники',
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${enabledIds.length} вкл.',
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: busy ? null : onToggleAll,
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.paperMuted,
                disabledForegroundColor:
                    AppTheme.paperMuted.withValues(alpha: 0.35),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                allOn ? 'Выкл все' : 'Вкл все',
                style: GoogleFonts.figtree(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: onExpandToggle,
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.mossBright,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                expanded ? 'Лента' : 'Сеткой',
                style: GoogleFonts.figtree(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (expanded)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final source in sources)
                _SourceChip(
                  name: source.name,
                  selected: enabledIds.contains(source.id),
                  accent: _accentFor(source.id),
                  enabled: !busy,
                  onSelected: (v) => onToggle(source, v),
                ),
            ],
          )
        else
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: sources.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final source = sources[index];
                return _SourceChip(
                  name: source.name,
                  selected: enabledIds.contains(source.id),
                  accent: _accentFor(source.id),
                  enabled: !busy,
                  onSelected: (v) => onToggle(source, v),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.name,
    required this.selected,
    required this.accent,
    required this.enabled,
    required this.onSelected,
  });

  final String name;
  final bool selected;
  final Color accent;
  final bool enabled;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(name),
      selected: selected,
      onSelected: enabled ? onSelected : null,
      showCheckmark: false,
      avatar: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? accent : AppTheme.paperMuted.withValues(alpha: 0.4),
        ),
      ),
      labelStyle: GoogleFonts.figtree(
        color: selected ? AppTheme.paper : AppTheme.paperMuted,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      selectedColor: accent.withValues(alpha: 0.28),
      backgroundColor: AppTheme.inkLift,
      side: BorderSide(
        color: selected
            ? accent.withValues(alpha: 0.45)
            : AppTheme.paper.withValues(alpha: 0.06),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({
    required this.status,
    required this.error,
    required this.count,
    required this.searching,
  });

  final String? status;
  final String? error;
  final int count;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    const label = 'Результаты';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.moss.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: GoogleFonts.figtree(
                    color: AppTheme.mossBright,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            if (searching) ...[
              const SizedBox(width: 10),
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.mossBright,
                ),
              ),
            ],
          ],
        ),
        if (status != null || error != null) ...[
          const SizedBox(height: 4),
          Text(
            [if (status != null) status!, if (error != null) error!].join('\n'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.figtree(
              color: error != null && count == 0
                  ? const Color(0xFFFF8A80)
                  : AppTheme.paperMuted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.searching,
    required this.activeCount,
    required this.nothingFound,
  });

  final bool searching;
  final int activeCount;
  final bool nothingFound;

  @override
  Widget build(BuildContext context) {
    final title = searching
        ? 'Ищем…'
        : (nothingFound ? 'Пусто' : 'Готов к поиску');
    final body = searching
        ? 'Опрашиваем $activeCount источников'
        : (nothingFound
            ? 'Попробуй другой запрос или другие источники'
            : 'Введи артиста или название трека');

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.inkLift,
                border: Border.all(
                  color: AppTheme.moss.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(
                searching
                    ? Icons.travel_explore_rounded
                    : (nothingFound
                        ? Icons.music_off_rounded
                        : Icons.graphic_eq_rounded),
                color: AppTheme.mossBright,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HitCard extends StatelessWidget {
  const _HitCard({
    required this.hit,
    required this.sourceName,
    required this.index,
    required this.busy,
    required this.onPreview,
    required this.onDownload,
    required this.onReplace,
  });

  final BrowserHit hit;
  final String sourceName;
  final int index;
  final bool busy;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onReplace;

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(hit.sourceId);
    final duration = hit.duration;
    final meta = [
      if (hit.subtitle != null && hit.subtitle!.isNotEmpty) hit.subtitle!,
      if (duration != null) formatTrackDuration(duration.inMilliseconds),
    ].join(' · ');
    final initial = hit.title.trim().isNotEmpty
        ? hit.title.trim().characters.first.toUpperCase()
        : '?';

    return Material(
      color: AppTheme.inkLift.withValues(alpha: 0.72),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppTheme.paper.withValues(alpha: 0.05)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                mouseCursor: SystemMouseCursors.click,
                onTap: onPreview,
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            accent.withValues(alpha: 0.55),
                            accent.withValues(alpha: 0.18),
                          ],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initial,
                        style: GoogleFonts.syne(
                          color: AppTheme.paper,
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hit.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.figtree(
                              color: AppTheme.paper,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hit.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.figtree(
                              color: AppTheme.paperMuted,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  sourceName,
                                  style: GoogleFonts.figtree(
                                    color: accent,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              if (meta.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    meta,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.figtree(
                                      color: AppTheme.paperMuted.withValues(
                                        alpha: 0.75,
                                      ),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              _RoundAction(
                tooltip: 'Слушать',
                onPressed: onPreview,
                background: accent.withValues(alpha: 0.2),
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: accent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 4),
              _RoundAction(
                tooltip: 'Скачать в библиотеку',
                onPressed: onDownload,
                background: _kYellow.withValues(alpha: 0.16),
                child: const Icon(
                  Icons.download_rounded,
                  color: _kYellow,
                  size: 20,
                ),
              ),
              const SizedBox(width: 4),
              _RoundAction(
                tooltip: 'Заменить трек в библиотеке',
                onPressed: onReplace,
                background: AppTheme.paper.withValues(alpha: 0.08),
                child: const BrowserReplaceIcon(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Иконка замены — отдельный build(), чтобы codepoint пережил tree-shaking.
class BrowserReplaceIcon extends StatelessWidget {
  const BrowserReplaceIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.swap_horiz_rounded,
      color: AppTheme.paperMuted,
      size: 20,
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.tooltip,
    required this.onPressed,
    required this.background,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          onTap: onPressed,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
