import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';
import '../widgets/cover_image.dart';
import 'artist_detail_screen.dart';

const _kArtistsAccent = Color(0xFF8BB8D4);
const _kProducersAccent = Color(0xFFA8D080);
const _kPodiumGold = Color(0xFFE8C96A);
const _kPodiumSilver = Color(0xFFC8CDD6);
const _kPodiumBronze = Color(0xFFD4A574);

Color? _podiumColor(int rank) => switch (rank) {
      1 => _kPodiumGold,
      2 => _kPodiumSilver,
      3 => _kPodiumBronze,
      _ => null,
    };

class _ArtistRow {
  const _ArtistRow({
    required this.name,
    required this.tracks,
    required this.playCount,
    required this.rank,
  });

  final String name;
  final List<Track> tracks;
  final int playCount;
  final int rank;

  int get trackCount => tracks.length;

  String? coverFromTracks() {
    for (final t in tracks) {
      final p = t.coverPath;
      if (p != null && File(p).existsSync()) return p;
    }
    return null;
  }
}

class ArtistsScreen extends StatefulWidget {
  const ArtistsScreen({super.key, this.producers = false});

  final bool producers;

  @override
  State<ArtistsScreen> createState() => _ArtistsScreenState();
}

class _ArtistsScreenState extends State<ArtistsScreen> {
  Map<String, int> _playCounts = {};
  bool _loadingCounts = true;
  bool _refreshing = false;
  final _number = NumberFormat('#,###', 'ru');
  final _searchController = TextEditingController();
  String _query = '';

  Color get _accent =>
      widget.producers ? _kProducersAccent : _kArtistsAccent;

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

  List<_ArtistRow> _sortedRows(
    Map<String, List<Track>> artists,
    LibraryService library,
  ) {
    final rows = artists.entries.map((e) {
      final plays = e.value.fold<int>(
        0,
        (sum, t) => sum + (_playCounts[t.trackKey] ?? 0),
      );
      return _ArtistRow(
        name: e.key,
        tracks: e.value,
        playCount: plays,
        rank: 0,
      );
    }).toList();

    // Chart rank is always by plays (all-time top).
    final byPlays = List<_ArtistRow>.from(rows)
      ..sort((a, b) {
        final byPlay = b.playCount.compareTo(a.playCount);
        if (byPlay != 0) return byPlay;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final rankByName = <String, int>{
      for (var i = 0; i < byPlays.length; i++) byPlays[i].name: i + 1,
    };

    var ranked = rows
        .map(
          (r) => _ArtistRow(
            name: r.name,
            tracks: r.tracks,
            playCount: r.playCount,
            rank: rankByName[r.name] ?? 0,
          ),
        )
        .toList();

    final q = _query.trim();
    if (q.isNotEmpty) {
      ranked = ranked
          .where(
            (r) => widget.producers
                ? library.producerCardMatchesQuery(r.name, q)
                : library.artistCardMatchesQuery(r.name, q),
          )
          .toList();
    }

    ranked.sort((a, b) => a.rank.compareTo(b.rank));
    return ranked;
  }

  int _crossAxisCount(double width) {
    if (width >= 1400) return 6;
    if (width >= 1100) return 5;
    if (width >= 900) return 5;
    if (width >= 700) return 4;
    if (width >= 520) return 3;
    return 2;
  }

  Future<void> _openDetail(_ArtistRow row) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailScreen(
          artist: row.name,
          tracks: row.tracks,
          playCount: row.playCount,
          chartRank: row.rank,
          trackPlayCounts: _playCounts,
          byProducer: widget.producers,
        ),
      ),
    );
    await _loadPlayCounts();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final artists = widget.producers
        ? library.tracksByProducer()
        : library.tracksByArtist();
    final eyebrow = widget.producers ? 'ПРОДЮСЕРЫ' : 'АРТИСТЫ';
    final headline = widget.producers ? 'Битмейкеры' : 'Исполнители';
    final subtitle = widget.producers
        ? 'по прослушиваниям'
        : 'по прослушиваниям';
    final emptyLabel = widget.producers ? 'Нет продюсеров' : 'Нет артистов';
    final searchHint =
        widget.producers ? 'Поиск продюсера' : 'Поиск артиста';
    final emptyIcon =
        widget.producers ? Icons.headphones_rounded : Icons.person_rounded;

    if (library.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PeopleHeroHeader(
            eyebrow: eyebrow,
            headline: headline,
            subtitle: 'Сканируйте папку music',
            accent: _accent,
            refreshing: _refreshing,
            onRefresh: null,
          ),
          Expanded(
            child: _PeopleEmptyState(
              icon: emptyIcon,
              title: 'Коллекция пуста',
              body:
                  'Сканируйте папку music в Настройках — список появится после импорта.',
              accent: _accent,
            ),
          ),
        ],
      );
    }

    final rows = _sortedRows(artists, library);
    final searching = _query.trim().isNotEmpty;
    final top = !searching && rows.isNotEmpty ? rows.first : null;
    final gridRows = top == null ? rows : rows.skip(1).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PeopleHeroHeader(
          eyebrow: eyebrow,
          headline: headline,
          subtitle: rows.isEmpty
              ? subtitle
              : '${rows.length} · $subtitle',
          accent: _accent,
          refreshing: _refreshing,
          onRefresh: _refreshing ? null : _loadPlayCounts,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: _PeopleSearchField(
            controller: _searchController,
            hint: searchHint,
            accent: _accent,
            query: _query,
            onChanged: (v) => setState(() => _query = v),
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
        ),
        Expanded(
          child: _loadingCounts
              ? Center(
                  child: CircularProgressIndicator(
                    color: _accent,
                    strokeWidth: 2.4,
                  ),
                )
              : rows.isEmpty
                  ? _PeopleEmptyState(
                      icon: emptyIcon,
                      title: searching ? 'Ничего не найдено' : emptyLabel,
                      body: searching
                          ? 'Попробуйте другое имя или очистите поиск.'
                          : 'Добавьте треки с метаданными — карточки появятся здесь.',
                      accent: _accent,
                    )
                  : CustomScrollView(
                      slivers: [
                        if (top != null)
                          SliverToBoxAdapter(
                            child: _PeopleCrownCard(
                              row: top,
                              photoPath: library.artistPhotoPath(top.name) ??
                                  top.coverFromTracks(),
                              tracksLabel: _number.format(top.trackCount),
                              playsLabel: _number.format(top.playCount),
                              accent: _accent,
                              producers: widget.producers,
                              onTap: () => _openDetail(top),
                            ),
                          ),
                        if (gridRows.isNotEmpty)
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              top == null ? 4 : 8,
                              16,
                              28,
                            ),
                            sliver: SliverLayoutBuilder(
                              builder: (context, constraints) {
                                final count =
                                    _crossAxisCount(constraints.crossAxisExtent);
                                return SliverGrid(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: count,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 16,
                                    childAspectRatio: 0.68,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      final row = gridRows[index];
                                      final photo =
                                          library.artistPhotoPath(row.name) ??
                                              row.coverFromTracks();
                                      return _ArtistGridTile(
                                        row: row,
                                        photoPath: photo,
                                        tracksLabel:
                                            _number.format(row.trackCount),
                                        playsLabel:
                                            _number.format(row.playCount),
                                        accent: _accent,
                                        icon: emptyIcon,
                                        onTap: () => _openDetail(row),
                                      );
                                    },
                                    childCount: gridRows.length,
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }
}

class _PeopleHeroHeader extends StatelessWidget {
  const _PeopleHeroHeader({
    required this.eyebrow,
    required this.headline,
    required this.subtitle,
    required this.accent,
    required this.refreshing,
    required this.onRefresh,
  });

  final String eyebrow;
  final String headline;
  final String subtitle;
  final Color accent;
  final bool refreshing;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Padding(
      padding: EdgeInsets.fromLTRB(canPop ? 4 : 20, 10, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (canPop)
            Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: IconButton(
                tooltip: 'Назад',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(
                  Icons.arrow_back_rounded,
                  color: AppTheme.paper,
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow,
                  style: GoogleFonts.syne(
                    color: accent.withValues(alpha: 0.9),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  headline,
                  style: GoogleFonts.syne(
                    color: AppTheme.paper,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (onRefresh != null || refreshing)
            IconButton(
              onPressed: onRefresh,
              tooltip: 'Обновить',
              style: IconButton.styleFrom(
                foregroundColor: AppTheme.paperMuted,
                backgroundColor: Colors.white.withValues(alpha: 0.04),
              ),
              icon: refreshing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
    );
  }
}

class _PeopleSearchField extends StatelessWidget {
  const _PeopleSearchField({
    required this.controller,
    required this.hint,
    required this.accent,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String hint;
  final Color accent;
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
      cursorColor: accent,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.figtree(color: AppTheme.paperMuted),
        prefixIcon: Icon(Icons.search_rounded, color: accent.withValues(alpha: 0.75)),
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
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: Colors.white.withValues(alpha: 0.06),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: accent.withValues(alpha: 0.45)),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 12,
        ),
      ),
    );
  }
}

class _PeopleEmptyState extends StatelessWidget {
  const _PeopleEmptyState({
    required this.icon,
    required this.title,
    required this.body,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: accent.withValues(alpha: 0.45)),
            const SizedBox(height: 16),
            Text(
              title,
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
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

class _PeopleCrownCard extends StatelessWidget {
  const _PeopleCrownCard({
    required this.row,
    required this.photoPath,
    required this.tracksLabel,
    required this.playsLabel,
    required this.accent,
    required this.producers,
    required this.onTap,
  });

  final _ArtistRow row;
  final String? photoPath;
  final String tracksLabel;
  final String playsLabel;
  final Color accent;
  final bool producers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    Widget avatar = Icon(
      producers ? Icons.headphones_rounded : Icons.person_rounded,
      color: AppTheme.paperMuted.withValues(alpha: 0.7),
      size: 48,
    );
    final path = photoPath;
    if (path != null) {
      avatar = fileCover(
        context,
        path,
        logicalSize: 360,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => Icon(
          producers ? Icons.headphones_rounded : Icons.person_rounded,
          color: AppTheme.paperMuted.withValues(alpha: 0.7),
          size: 48,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Ink(
            height: 148,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: accent.withValues(alpha: 0.28)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  producers
                      ? const Color(0xFF1A2A18)
                      : const Color(0xFF182430),
                  AppTheme.inkLift,
                  const Color(0xFF121816),
                ],
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  right: -24,
                  top: -36,
                  child: IgnorePointer(
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.1),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                  child: Row(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 112,
                            height: 112,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _kPodiumGold.withValues(alpha: 0.55),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _kPodiumGold.withValues(alpha: 0.2),
                                  blurRadius: 16,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ClipOval(child: avatar),
                          ),
                          Positioned(
                            left: -4,
                            top: -4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: _kPodiumGold,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '#1',
                                style: GoogleFonts.syne(
                                  color: const Color(0xFF1A1408),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'ЛИДЕР',
                              style: GoogleFonts.syne(
                                color: accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.6,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              row.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.syne(
                                color: AppTheme.paper,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                _StatChip(
                                  icon: Icons.music_note_rounded,
                                  label: tracksLabel,
                                ),
                                const SizedBox(width: 8),
                                _StatChip(
                                  icon: Icons.headphones_rounded,
                                  label: playsLabel,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: accent.withValues(alpha: 0.7),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppTheme.paperMuted),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.figtree(
              color: AppTheme.paperMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistGridTile extends StatelessWidget {
  const _ArtistGridTile({
    required this.row,
    required this.photoPath,
    required this.tracksLabel,
    required this.playsLabel,
    required this.onTap,
    required this.accent,
    this.icon = Icons.person_rounded,
  });

  final _ArtistRow row;
  final String? photoPath;
  final String tracksLabel;
  final String playsLabel;
  final VoidCallback onTap;
  final Color accent;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    Widget avatar = Icon(
      icon,
      color: AppTheme.paperMuted.withValues(alpha: 0.7),
      size: 36,
    );
    final path = photoPath;
    if (path != null) {
      avatar = fileCover(
        context,
        path,
        // Decode a bit above the largest tile size so wide windows / high-DPI
        // displays never upscale the portrait; the cache caps this at 640px.
        logicalSize: 360,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => Icon(
          icon,
          color: AppTheme.paperMuted.withValues(alpha: 0.7),
          size: 36,
        ),
      );
    }

    final podium = _podiumColor(row.rank);
    final ring = podium ?? accent.withValues(alpha: 0.22);

    final metaStyle = GoogleFonts.figtree(
      color: AppTheme.paperMuted,
      fontWeight: FontWeight.w600,
      fontSize: 11,
      height: 1,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppTheme.inkLift,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: ring,
                              width: podium != null ? 2.2 : 1.2,
                            ),
                          ),
                          child: ClipOval(child: avatar),
                        ),
                        if (row.rank > 0)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 26),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: podium ?? AppTheme.inkLift,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: AppTheme.ink,
                                  width: 1.5,
                                ),
                              ),
                              child: Text(
                                '${row.rank}',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.syne(
                                  color: podium != null
                                      ? const Color(0xFF1A1408)
                                      : AppTheme.paper,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                row.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.figtree(
                  color: AppTheme.paper,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tracksLabel, style: metaStyle),
                    const SizedBox(width: 3),
                    Icon(
                      Icons.music_note_rounded,
                      size: 12,
                      color: AppTheme.paperMuted.withValues(alpha: 0.9),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Text('–', style: metaStyle),
                    ),
                    Text(playsLabel, style: metaStyle),
                    const SizedBox(width: 3),
                    Icon(
                      Icons.headphones_rounded,
                      size: 12,
                      color: accent.withValues(alpha: 0.75),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
