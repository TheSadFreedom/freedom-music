import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../models/track.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';
import '../widgets/collective_editor_dialog.dart';
import '../widgets/cover_image.dart';
import '../widgets/kept_icons.dart';
import '../widgets/screen_title.dart';
import 'artist_detail_screen.dart';

enum _CollectiveSort { plays, tracks, name }

class _SortOption {
  const _SortOption({
    required this.value,
    required this.label,
    required this.icon,
  });

  final _CollectiveSort value;
  final String label;
  final IconData icon;
}

const _sortOptions = <_SortOption>[
  _SortOption(
    value: _CollectiveSort.plays,
    label: 'Прослушивания',
    icon: Icons.headphones_rounded,
  ),
  _SortOption(
    value: _CollectiveSort.tracks,
    label: 'Треки',
    icon: Icons.music_note_rounded,
  ),
  _SortOption(
    value: _CollectiveSort.name,
    label: 'А–Я',
    icon: Icons.sort_by_alpha_rounded,
  ),
];

class _CollectiveRow {
  const _CollectiveRow({
    required this.collective,
    required this.tracks,
    required this.playCount,
    required this.rank,
  });

  final CreativeCollective collective;
  final List<Track> tracks;
  final int playCount;
  final int rank;

  String get name => collective.name;
  int get trackCount => tracks.length;

  String? coverFromTracks() {
    for (final t in tracks) {
      final p = t.coverPath;
      if (p != null && File(p).existsSync()) return p;
    }
    return null;
  }
}

class CollectivesScreen extends StatefulWidget {
  const CollectivesScreen({super.key});

  @override
  State<CollectivesScreen> createState() => _CollectivesScreenState();
}

class _CollectivesScreenState extends State<CollectivesScreen> {
  Map<String, int> _playCounts = {};
  bool _loadingCounts = true;
  bool _refreshing = false;
  final _number = NumberFormat('#,###', 'ru');
  final _searchController = TextEditingController();
  String _query = '';
  _CollectiveSort _sort = _CollectiveSort.plays;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPlayCounts());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPlayCounts() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final library = context.read<LibraryService>();
    final counts = await library.playCountsAllTime();
    if (!mounted) return;
    setState(() {
      _playCounts = counts;
      _loadingCounts = false;
      _refreshing = false;
    });
  }

  List<_CollectiveRow> _sortedRows(LibraryService library) {
    final rows = library.collectives.map((c) {
      final tracks = library.collectiveTracks(c);
      final plays = tracks.fold<int>(
        0,
        (sum, t) => sum + (_playCounts[t.trackKey] ?? 0),
      );
      return _CollectiveRow(
        collective: c,
        tracks: tracks,
        playCount: plays,
        rank: 0,
      );
    }).toList();

    final byPlays = List<_CollectiveRow>.from(rows)
      ..sort((a, b) {
        final byPlay = b.playCount.compareTo(a.playCount);
        if (byPlay != 0) return byPlay;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final rankById = <String, int>{
      for (var i = 0; i < byPlays.length; i++) byPlays[i].collective.id: i + 1,
    };

    var ranked = rows
        .map(
          (r) => _CollectiveRow(
            collective: r.collective,
            tracks: r.tracks,
            playCount: r.playCount,
            rank: rankById[r.collective.id] ?? 0,
          ),
        )
        .toList();

    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      ranked = ranked.where((r) {
        if (r.name.toLowerCase().contains(q)) return true;
        return r.collective.members.any((m) => m.toLowerCase().contains(q));
      }).toList();
    }

    int byName(_CollectiveRow a, _CollectiveRow b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());

    ranked.sort((a, b) {
      switch (_sort) {
        case _CollectiveSort.plays:
          final byPlay = b.playCount.compareTo(a.playCount);
          if (byPlay != 0) return byPlay;
          return byName(a, b);
        case _CollectiveSort.tracks:
          final byTracks = b.trackCount.compareTo(a.trackCount);
          if (byTracks != 0) return byTracks;
          return byName(a, b);
        case _CollectiveSort.name:
          return byName(a, b);
      }
    });
    return ranked;
  }

  Future<void> _openCollective(_CollectiveRow row) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailScreen(
          artist: row.name,
          tracks: row.tracks,
          playCount: row.playCount,
          chartRank: row.rank,
          trackPlayCounts: _playCounts,
          byCollective: true,
          collectiveId: row.collective.id,
        ),
      ),
    );
    await _loadPlayCounts();
  }

  Future<void> _addCollective() async {
    final created = await showCollectiveEditorDialog(context);
    if (created == null || !mounted) return;
    await _loadPlayCounts();
  }

  static const _cardWidth = 336.0;
  static const _cardHeight = 432.0;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final rows = _sortedRows(library);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenTitle(
          title: 'Творческие объединения',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Добавить',
                onPressed: _addCollective,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_rounded, color: AppTheme.paper),
              ),
              IconButton(
                onPressed: _refreshing ? null : _loadPlayCounts,
                visualDensity: VisualDensity.compact,
                icon: _refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, color: AppTheme.paper),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              final search = _SearchField(
                controller: _searchController,
                query: _query,
                onChanged: (v) => setState(() => _query = v),
                onClear: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              );
              final sort = _CollectiveSortSwitcher(
                selected: _sort,
                onChanged: (value) => setState(() => _sort = value),
              );

              if (wide) {
                return Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: 18),
                    sort,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  search,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerLeft, child: sort),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: _loadingCounts
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty
                  ? Center(
                      child: Text(
                        _query.trim().isEmpty
                            ? 'Нет объединений. Нажмите «+», чтобы добавить.'
                            : 'Ничего не найдено',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.figtree(
                          color: AppTheme.paperMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 14,
                        runSpacing: 16,
                        children: [
                          for (final entry in rows.asMap().entries)
                            SizedBox(
                              width: _cardWidth,
                              height: _cardHeight,
                              child: _CollectiveTile(
                                index: entry.key + 1,
                                row: entry.value,
                                photoPath: library.artistPhotoPath(
                                      entry.value.name,
                                    ) ??
                                    entry.value.coverFromTracks(),
                                highlight: _sort == _CollectiveSort.plays &&
                                    entry.value.rank > 0 &&
                                    entry.value.rank <= 3,
                                tracksLabel:
                                    '${_number.format(entry.value.trackCount)} ${_trackWord(entry.value.trackCount)}',
                                playsLabel:
                                    '${_number.format(entry.value.playCount)} ${_listenWord(entry.value.playCount)}',
                                onTap: () => _openCollective(entry.value),
                              ),
                            ),
                        ],
                      ),
                    ),
        ),
      ],
    );
  }

  String _trackWord(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'трек';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'трека';
    }
    return 'треков';
  }

  String _listenWord(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'прослушивание';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'прослушивания';
    }
    return 'прослушиваний';
  }
}

class _CollectiveSortSwitcher extends StatelessWidget {
  const _CollectiveSortSwitcher({
    required this.selected,
    required this.onChanged,
  });

  final _CollectiveSort selected;
  final ValueChanged<_CollectiveSort> onChanged;

  static const _accent = AppTheme.lime;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.inkLift.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppTheme.paper.withValues(alpha: 0.08),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in _sortOptions)
              _SortSegmentButton(
                option: option,
                selected: option.value == selected,
                onTap: () {
                  if (option.value != selected) onChanged(option.value);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _SortSegmentButton extends StatelessWidget {
  const _SortSegmentButton({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _SortOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(999),
        splashColor: Colors.black.withValues(alpha: 0.08),
        highlightColor: Colors.black.withValues(alpha: 0.04),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? _CollectiveSortSwitcher._accent
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                option.icon,
                size: 15,
                color: selected ? AppTheme.ink : AppTheme.paperMuted,
              ),
              const SizedBox(width: 7),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                style: GoogleFonts.figtree(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  letterSpacing: -0.1,
                  height: 1.15,
                  color: selected ? AppTheme.ink : AppTheme.paperMuted,
                ),
                child: Text(option.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: GoogleFonts.figtree(
        color: AppTheme.paper,
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
      cursorColor: AppTheme.lime,
      decoration: InputDecoration(
        hintText: 'Поиск объединения',
        hintStyle: GoogleFonts.figtree(color: AppTheme.paperMuted),
        prefixIcon: const Icon(
          Icons.search_rounded,
          color: AppTheme.paperMuted,
        ),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                onPressed: onClear,
                icon: const Icon(
                  Icons.close_rounded,
                  color: AppTheme.paperMuted,
                ),
              ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: AppTheme.paper.withValues(alpha: 0.06),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: AppTheme.paper.withValues(alpha: 0.06),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: AppTheme.lime.withValues(alpha: 0.45),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 14,
        ),
      ),
    );
  }
}

class _CollectiveTile extends StatefulWidget {
  const _CollectiveTile({
    required this.index,
    required this.row,
    required this.photoPath,
    required this.highlight,
    required this.tracksLabel,
    required this.playsLabel,
    required this.onTap,
  });

  final int index;
  final _CollectiveRow row;
  final String? photoPath;
  final bool highlight;
  final String tracksLabel;
  final String playsLabel;
  final VoidCallback onTap;

  @override
  State<_CollectiveTile> createState() => _CollectiveTileState();
}

class _CollectiveTileState extends State<_CollectiveTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final accent = widget.highlight ? AppTheme.lime : AppTheme.mossBright;
    final indexLabel = widget.index.toString().padLeft(2, '0');

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
                transformAlignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: _hovered
                        ? accent.withValues(alpha: 0.4)
                        : Colors.transparent,
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: _hovered ? 0.35 : 0.18,
                      ),
                      blurRadius: _hovered ? 28 : 16,
                      offset: Offset(0, _hovered ? 14 : 8),
                    ),
                    if (_hovered)
                      BoxShadow(
                        color: accent.withValues(alpha: 0.14),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: AppTheme.inkLift),
                      _CollectivePhoto(path: widget.photoPath),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x330C1210),
                              Color(0x000C1210),
                              Color(0xB30C1210),
                              Color(0xF20C1210),
                            ],
                            stops: [0, 0.35, 0.72, 1],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 12,
                        left: 12,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.38),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: widget.highlight
                                  ? accent.withValues(alpha: 0.55)
                                  : AppTheme.paper.withValues(alpha: 0.12),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            child: Text(
                              indexLabel,
                              style: GoogleFonts.figtree(
                                color: widget.highlight
                                    ? accent
                                    : AppTheme.paper.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w800,
                                fontSize: 11.5,
                                letterSpacing: 0.6,
                                height: 1,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 14,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              row.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.syne(
                                color: AppTheme.paper,
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                                height: 1.1,
                                letterSpacing: -0.45,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${widget.tracksLabel}  ·  ${widget.playsLabel}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.figtree(
                                color: widget.highlight
                                    ? accent.withValues(alpha: 0.92)
                                    : AppTheme.paper.withValues(alpha: 0.72),
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                height: 1.15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectivePhoto extends StatelessWidget {
  const _CollectivePhoto({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final photo = path;
    if (photo == null) {
      return Center(
        child: IconTheme(
          data: IconThemeData(
            size: 52,
            color: AppTheme.paperMuted.withValues(alpha: 0.45),
          ),
          child: const GroupsGlyph(),
        ),
      );
    }

    return fileCover(
      context,
      photo,
      logicalSize: 360,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, _, _) => Center(
        child: IconTheme(
          data: IconThemeData(
            size: 52,
            color: AppTheme.paperMuted.withValues(alpha: 0.45),
          ),
          child: const GroupsGlyph(),
        ),
      ),
    );
  }
}
