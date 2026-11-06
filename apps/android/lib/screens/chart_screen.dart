import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../data/track_key.dart';
import '../models/artist_release.dart';
import '../models/track.dart';
import '../screens/metadata_editor_screen.dart';
import '../screens/release_detail_screen.dart';
import '../screens/release_metadata_editor_screen.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../utils/duration_format.dart';
import '../utils/playlist_actions.dart';
import '../utils/trash_actions.dart';
import '../widgets/playing_track.dart';
import '../widgets/screen_title.dart';
import '../widgets/track_cover_play.dart';
import '../widgets/track_meta_links.dart';
import '../widgets/track_overflow_menu.dart';

const _kChartGold = Color(0xFFE8C96A);
const _kChartAmber = Color(0xFFFFDB4D);
const _kChartSilver = Color(0xFFC8CDD6);
const _kChartBronze = Color(0xFFD4A574);

enum _RankDelta { up, down, same, newEntry }

Color? _podiumColor(int rank) => switch (rank) {
      1 => _kChartGold,
      2 => _kChartSilver,
      3 => _kChartBronze,
      _ => null,
    };

class _ChartRow {
  const _ChartRow({
    required this.rank,
    required this.entry,
    required this.delta,
  });

  final int rank;
  final ChartEntry entry;
  final _RankDelta delta;
}

class _AlbumChartRow {
  const _AlbumChartRow({
    required this.rank,
    required this.release,
    required this.artist,
    required this.listens,
    required this.delta,
  });

  final int rank;
  final ArtistRelease release;
  final String artist;
  final int listens;
  final _RankDelta delta;
}

class _ChartData {
  const _ChartData({
    required this.tracks,
    required this.albums,
    required this.playCounts,
    required this.albumSnapshot,
  });

  final List<_ChartRow> tracks;
  final List<_AlbumChartRow> albums;
  final Map<String, int> playCounts;
  final Map<String, int> albumSnapshot;
}

class ChartScreen extends StatefulWidget {
  const ChartScreen({super.key});

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  Future<_ChartData>? _future;
  bool _refreshing = false;
  int? _playStatsEpoch;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final epoch = context.watch<LibraryService>().playStatsEpoch;
    if (_future == null || _playStatsEpoch != epoch) {
      _playStatsEpoch = epoch;
      _future = _load();
    }
  }

  Future<_ChartData> _load() async {
    final library = context.read<LibraryService>();
    final settings = context.read<SettingsService>();
    final entries = await library.chart(ChartPeriod.allTime);
    final playCounts = await library.playCountsAllTime();
    final trackSnapshot = settings.chartSnapshot(ChartPeriod.allTime.name);
    final albumSnapshot = settings.chartSnapshot('albums');
    final trackRows = _rankTracks(entries, trackSnapshot);
    final albumRows = _rankAlbums(
      library.catalogTracks,
      playCounts,
      albumSnapshot,
    );
    await settings.saveChartSnapshot(ChartPeriod.allTime.name, {
      for (final row in trackRows) row.entry.track.trackKey: row.rank,
    });
    await settings.saveChartSnapshot('albums', {
      for (final row in albumRows) _albumKey(row.release, row.artist): row.rank,
    });
    return _ChartData(
      tracks: trackRows,
      albums: albumRows,
      playCounts: playCounts,
      albumSnapshot: albumSnapshot,
    );
  }

  List<_ChartRow> _rankTracks(List<ChartEntry> entries, Map<String, int> prev) {
    final rows = <_ChartRow>[];
    for (var i = 0; i < entries.length; i++) {
      final rank = i + 1;
      rows.add(_ChartRow(
        rank: rank,
        entry: entries[i],
        delta: _delta(prev, entries[i].track.trackKey, rank),
      ));
    }
    return rows;
  }

  List<_AlbumChartRow> _rankAlbums(
    List<Track> tracks,
    Map<String, int> playCounts,
    Map<String, int> prev,
  ) {
    final groups = <String, List<Track>>{};
    final artistLabel = <String, String>{};
    final albumLabel = <String, String>{};
    for (final track in tracks) {
      final album = track.displayAlbum.trim();
      if (album.isEmpty || album.toLowerCase() == 'unknown') continue;
      final artist = (track.albumArtist != null &&
              track.albumArtist!.trim().isNotEmpty)
          ? track.albumArtist!.trim()
          : track.displayArtist;
      final key = '${artist.toLowerCase()}\u0001${album.toLowerCase()}';
      groups.putIfAbsent(key, () => []).add(track);
      artistLabel.putIfAbsent(key, () => artist);
      albumLabel.putIfAbsent(key, () => album);
    }

    final ranked = <_AlbumChartRow>[];
    for (final entry in groups.entries) {
      final list = entry.value;
      if (list.length <= 1) continue;
      list.sort((a, b) {
        final ta = a.trackNumber ?? 9999;
        final tb = b.trackNumber ?? 9999;
        if (ta != tb) return ta.compareTo(tb);
        return a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase());
      });
      final years = list.map((t) => t.year).whereType<int>().toList();
      String? cover;
      for (final track in list) {
        final path = track.coverPath;
        if (path != null && path.isNotEmpty) {
          cover = path;
          break;
        }
      }
      final release = ArtistRelease(
        title: albumLabel[entry.key]!,
        tracks: list,
        kind: ReleaseKind.album,
        year: years.isEmpty ? null : years.reduce((a, b) => a > b ? a : b),
        coverPath: cover,
      );
      ranked.add(_AlbumChartRow(
        rank: 0,
        release: release,
        artist: artistLabel[entry.key]!,
        listens: releaseListenCount(release, playCounts),
        delta: _RankDelta.same,
      ));
    }
    ranked.sort((a, b) {
      final byListens = b.listens.compareTo(a.listens);
      if (byListens != 0) return byListens;
      final byTitle = a.release.title.toLowerCase().compareTo(
            b.release.title.toLowerCase(),
          );
      if (byTitle != 0) return byTitle;
      return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
    });
    return [
      for (var i = 0; i < ranked.length; i++)
        _AlbumChartRow(
          rank: i + 1,
          release: ranked[i].release,
          artist: ranked[i].artist,
          listens: ranked[i].listens,
          delta: _delta(
            prev,
            _albumKey(ranked[i].release, ranked[i].artist),
            i + 1,
          ),
        ),
    ];
  }

  _RankDelta _delta(Map<String, int> prev, String key, int rank) {
    final old = prev[key];
    if (old == null) {
      return prev.isEmpty ? _RankDelta.same : _RankDelta.newEntry;
    }
    if (old == rank) return _RankDelta.same;
    return old > rank ? _RankDelta.up : _RankDelta.down;
  }

  String _albumKey(ArtistRelease release, String artist) =>
      '${artist.toLowerCase()}\u0001${release.title.toLowerCase()}';

  void _reload() {
    setState(() {
      _refreshing = true;
      _future = _load().whenComplete(() {
        if (mounted) setState(() => _refreshing = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final player = context.read<PlayerService>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChartHeroHeader(
          refreshing: _refreshing,
          onRefresh: _refreshing ? null : _reload,
        ),
        Expanded(
          child: library.isEmpty
              ? const _ChartEmptyState()
              : FutureBuilder<_ChartData>(
                  key: ValueKey(
                    'chart-${library.catalogTracks.length}-${library.playStatsEpoch}',
                  ),
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(
                        child: CircularProgressIndicator(
                          color: _kChartGold,
                          strokeWidth: 2.4,
                        ),
                      );
                    }
                    final data = snapshot.data;
                    if (data == null) return const SizedBox.shrink();
                    final rows = [
                      for (final row in data.tracks)
                        _ChartRow(
                          rank: row.rank,
                          delta: row.delta,
                          entry: ChartEntry(
                            track: library.resolveTrack(row.entry.track),
                            playCount: row.entry.playCount,
                          ),
                        ),
                    ];
                    final albums = _rankAlbums(
                      library.catalogTracks,
                      data.playCounts,
                      data.albumSnapshot,
                    );
                    final tracks = rows.map((r) => r.entry.track).toList();
                    const preview = 3;
                    final trackPreview = rows.take(preview).toList();
                    final albumPreview = albums.take(preview).toList();
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(0, 4, 0, 32),
                      children: [
                        _ChartSectionHeader(
                          title: 'Треки',
                          subtitle: rows.isEmpty
                              ? null
                              : '${rows.length}',
                          onTap: rows.isEmpty
                              ? null
                              : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => _FullChartTracksScreen(
                                        rows: rows,
                                        onReload: _reload,
                                      ),
                                    ),
                                  ),
                        ),
                        if (rows.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 28),
                            child: _ChartEmpty(text: 'Пока нет прослушиваний'),
                          )
                        else ...[
                          if (trackPreview.isNotEmpty)
                            _ChartPodium(
                              rows: trackPreview,
                              onPlayIndex: (i) => player.playTracks(
                                tracks,
                                startIndex: i,
                              ),
                              onEdit: (row) async {
                                final ok = await openMetadataEditor(
                                  context,
                                  row.entry.track,
                                );
                                if (ok && mounted) _reload();
                              },
                            ),
                          if (rows.length > preview)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                              child: _ChartSeeAllButton(
                                label: 'Весь чарт треков',
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => _FullChartTracksScreen(
                                      rows: rows,
                                      onReload: _reload,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                        const SizedBox(height: 18),
                        _ChartSectionHeader(
                          title: 'Альбомы',
                          subtitle: albums.isEmpty
                              ? null
                              : '${albums.length}',
                          onTap: albums.isEmpty
                              ? null
                              : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => _FullChartAlbumsScreen(
                                        rows: albums,
                                        onEdited: _reload,
                                      ),
                                    ),
                                  ),
                        ),
                        if (albums.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 28),
                            child: _ChartEmpty(text: 'Нет альбомов'),
                          )
                        else ...[
                          for (final row in albumPreview)
                            _AlbumChartTile(
                              row: row,
                              onPlay: () =>
                                  player.playTracks(row.release.tracks),
                              onEdited: _reload,
                            ),
                          if (albums.length > preview)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                              child: _ChartSeeAllButton(
                                label: 'Весь чарт альбомов',
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => _FullChartAlbumsScreen(
                                      rows: albums,
                                      onEdited: _reload,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ChartHeroHeader extends StatelessWidget {
  const _ChartHeroHeader({
    required this.refreshing,
    required this.onRefresh,
  });

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
                  'ЧАРТ',
                  style: GoogleFonts.syne(
                    color: _kChartGold.withValues(alpha: 0.85),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Топ',
                  style: GoogleFonts.syne(
                    color: AppTheme.paper,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                  ),
                ),
                Text(
                  'по прослушиваниям',
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRefresh,
            tooltip: 'Обновить',
            style: IconButton.styleFrom(
              foregroundColor: AppTheme.paperMuted,
              backgroundColor: Colors.white.withValues(alpha: 0.04),
            ),
            icon: refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _kChartGold,
                    ),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }
}

class _ChartEmptyState extends StatelessWidget {
  const _ChartEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.ssid_chart_rounded,
              size: 48,
              color: _kChartGold.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 16),
            Text(
              'Чарт пуст',
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Сканируйте папку music в Настройках — рейтинг появится после прослушиваний.',
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

class _ChartSeeAllButton extends StatelessWidget {
  const _ChartSeeAllButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
            gradient: LinearGradient(
              colors: [
                _kChartGold.withValues(alpha: 0.08),
                Colors.white.withValues(alpha: 0.02),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: GoogleFonts.figtree(
                      color: AppTheme.paper,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: _kChartGold.withValues(alpha: 0.9),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartPodium extends StatelessWidget {
  const _ChartPodium({
    required this.rows,
    required this.onPlayIndex,
    required this.onEdit,
  });

  final List<_ChartRow> rows;
  final void Function(int index) onPlayIndex;
  final void Function(_ChartRow row) onEdit;

  @override
  Widget build(BuildContext context) {
    final top = rows.first;
    final rest = rows.skip(1).toList();
    return Column(
      children: [
        _ChartCrownCard(
          row: top,
          onPlay: () => onPlayIndex(0),
          onEdit: () => onEdit(top),
        ),
        for (var i = 0; i < rest.length; i++)
          SizedBox(
            height: 68,
            child: _ChartTrackRow(
              row: rest[i],
              onPlay: () => onPlayIndex(i + 1),
              onEdit: () => onEdit(rest[i]),
            ),
          ),
      ],
    );
  }
}

class _ChartCrownCard extends StatelessWidget {
  const _ChartCrownCard({
    required this.row,
    required this.onPlay,
    required this.onEdit,
  });

  final _ChartRow row;
  final VoidCallback onPlay;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final track = row.entry.track;
    final playing = PlayingTrack.watch(context, track.trackKey);
    final cover = track.coverPath;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: TrackContextMenu(
        actions: [
          TrackMenuAction(
            icon: Icons.edit_outlined,
            label: 'Метаданные',
            onSelected: onEdit,
          ),
          TrackMenuAction(
            icon: Icons.queue_music_rounded,
            label: 'В плейлист',
            onSelected: () => addTrackToPlaylist(context, track),
          ),
          TrackMenuAction(
            icon: Icons.delete_outline_rounded,
            label: 'В корзину',
            destructive: true,
            onSelected: () => moveTrackToTrash(context, track),
          ),
        ],
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPlay,
            onLongPress: onEdit,
            borderRadius: BorderRadius.circular(20),
            child: Ink(
              height: 148,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _kChartGold.withValues(alpha: 0.28),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF2A2418),
                    AppTheme.inkLift,
                    playing
                        ? PlayingTrack.accent.withValues(alpha: 0.18)
                        : const Color(0xFF1A1712),
                  ],
                ),
              ),
              child: Stack(
                children: [
                  Positioned(
                    right: -20,
                    top: -28,
                    child: IgnorePointer(
                      child: Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _kChartGold.withValues(alpha: 0.07),
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
                            TrackCoverPlay(
                              path: cover,
                              size: 112,
                              onPlay: onPlay,
                            ),
                            Positioned(
                              left: -6,
                              top: -6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _kChartGold,
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _kChartGold.withValues(alpha: 0.35),
                                      blurRadius: 10,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
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
                              Row(
                                children: [
                                  _DeltaIcon(delta: row.delta),
                                  const SizedBox(width: 8),
                                  Text(
                                    'ЛИДЕР',
                                    style: GoogleFonts.syne(
                                      color: _kChartGold,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.6,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              TrackMetaLinks(
                                track: track,
                                titleStyle: GoogleFonts.syne(
                                  color: playing
                                      ? PlayingTrack.accent
                                      : AppTheme.paper,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  height: 1.15,
                                ),
                                artistStyle: GoogleFonts.figtree(
                                  color: AppTheme.paperMuted,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  if (row.entry.playCount > 0)
                                    _ChartStatChip(
                                      icon: Icons.graphic_eq_rounded,
                                      label: '${row.entry.playCount}',
                                    ),
                                  const SizedBox(width: 8),
                                  _ChartStatChip(
                                    icon: Icons.schedule_rounded,
                                    label: formatTrackDuration(track.durationMs),
                                  ),
                                ],
                              ),
                            ],
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
      ),
    );
  }
}

class _ChartStatChip extends StatelessWidget {
  const _ChartStatChip({required this.icon, required this.label});

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

class _ChartSectionHeader extends StatelessWidget {
  const _ChartSectionHeader({
    required this.title,
    this.subtitle,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 22,
                decoration: BoxDecoration(
                  color: _kChartGold,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: GoogleFonts.syne(
                  color: AppTheme.paper,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    subtitle!,
                    style: GoogleFonts.figtree(
                      color: AppTheme.paperMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  color: _kChartGold.withValues(alpha: 0.75),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartEmpty extends StatelessWidget {
  const _ChartEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: GoogleFonts.figtree(
          color: AppTheme.paperMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _FullChartTracksScreen extends StatelessWidget {
  const _FullChartTracksScreen({
    required this.rows,
    required this.onReload,
  });

  final List<_ChartRow> rows;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final tracks = rows.map((r) => r.entry.track).toList();
    return Scaffold(
      backgroundColor: AppTheme.ink,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenTitle(
            title: 'Чарт · Треки',
            trailing: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '${rows.length}',
                style: GoogleFonts.figtree(
                  color: _kChartGold,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemExtent: 68,
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return _ChartTrackRow(
                  row: row,
                  onPlay: () => player.playTracks(
                    tracks,
                    startIndex: index,
                  ),
                  onEdit: () async {
                    final ok = await openMetadataEditor(
                      context,
                      row.entry.track,
                    );
                    if (ok) onReload();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FullChartAlbumsScreen extends StatelessWidget {
  const _FullChartAlbumsScreen({
    required this.rows,
    required this.onEdited,
  });

  final List<_AlbumChartRow> rows;
  final VoidCallback onEdited;

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    return Scaffold(
      backgroundColor: AppTheme.ink,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenTitle(
            title: 'Чарт · Альбомы',
            trailing: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '${rows.length}',
                style: GoogleFonts.figtree(
                  color: _kChartGold,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemExtent: 82,
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return _AlbumChartTile(
                  row: row,
                  onPlay: () => player.playTracks(row.release.tracks),
                  onEdited: onEdited,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumChartTile extends StatelessWidget {
  const _AlbumChartTile({
    required this.row,
    required this.onPlay,
    required this.onEdited,
  });

  final _AlbumChartRow row;
  final VoidCallback onPlay;
  final VoidCallback onEdited;

  static final _titleStyle = GoogleFonts.figtree(
    color: AppTheme.paper,
    fontWeight: FontWeight.w600,
    fontSize: 15,
  );
  static final _artistStyle = GoogleFonts.figtree(
    color: AppTheme.paperMuted,
    fontSize: 13,
  );
  static final _metaStyle = GoogleFonts.figtree(
    color: AppTheme.paperMuted.withValues(alpha: 0.7),
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );

  @override
  Widget build(BuildContext context) {
    final artistName = splitArtists(row.artist).first;
    final podium = _podiumColor(row.rank);
    return TrackContextMenu(
      actions: releaseMenuActions(
        context,
        row.release,
        onSaved: onEdited,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          hoverColor: Colors.white.withValues(alpha: 0.04),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ReleaseDetailScreen(
                  release: row.release,
                  primaryArtist: artistName,
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _RankBadge(rank: row.rank, delta: row.delta, accent: podium),
                const SizedBox(width: 4),
                TrackCoverPlay(
                  path:
                      context.read<LibraryService>().releaseCover(row.release),
                  onPlay: onPlay,
                  size: 56,
                  borderRadius: 8,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        metaFieldText(row.release.title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _titleStyle,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        row.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _artistStyle,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        releaseCaption(row.release, row.listens),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _metaStyle,
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

class _ChartTrackRow extends StatelessWidget {
  const _ChartTrackRow({
    required this.row,
    required this.onPlay,
    required this.onEdit,
  });

  final _ChartRow row;
  final VoidCallback onPlay;
  final VoidCallback onEdit;

  static final _titleStyle = GoogleFonts.figtree(
    color: AppTheme.paper,
    fontWeight: FontWeight.w600,
    fontSize: 15,
  );
  static final _artistStyle = GoogleFonts.figtree(
    color: AppTheme.paperMuted,
    fontSize: 13,
  );
  static final _playsStyle = GoogleFonts.figtree(
    color: AppTheme.paperMuted.withValues(alpha: 0.55),
    fontSize: 11,
    fontWeight: FontWeight.w500,
  );
  static final _durationStyle = GoogleFonts.figtree(
    color: AppTheme.paperMuted,
    fontSize: 13,
    fontWeight: FontWeight.w500,
  );

  @override
  Widget build(BuildContext context) {
    final track = row.entry.track;
    final plays = row.entry.playCount;
    final playing = PlayingTrack.watch(context, track.trackKey);
    final podium = _podiumColor(row.rank);

    return TrackContextMenu(
      actions: [
        TrackMenuAction(
          icon: Icons.edit_outlined,
          label: 'Метаданные',
          onSelected: onEdit,
        ),
        TrackMenuAction(
          icon: Icons.queue_music_rounded,
          label: 'В плейлист',
          onSelected: () => addTrackToPlaylist(context, track),
        ),
        TrackMenuAction(
          icon: Icons.delete_outline_rounded,
          label: 'В корзину',
          destructive: true,
          onSelected: () => moveTrackToTrash(context, track),
        ),
      ],
      child: Material(
        color: PlayingTrack.surface(playing),
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          hoverColor: Colors.white.withValues(alpha: 0.04),
          onTap: onPlay,
          onLongPress: onEdit,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _RankBadge(
                  rank: row.rank,
                  delta: row.delta,
                  accent: playing ? PlayingTrack.accent : podium,
                ),
                const SizedBox(width: 4),
                TrackCoverPlay(
                  path: track.coverPath,
                  onPlay: onPlay,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TrackMetaLinks(
                    track: track,
                    titleStyle: playing
                        ? _titleStyle.copyWith(
                            color: PlayingTrack.accent,
                            fontWeight: FontWeight.w700,
                          )
                        : _titleStyle,
                    artistStyle: _artistStyle,
                  ),
                ),
                if (plays > 0) ...[
                  const SizedBox(width: 8),
                  Text('$plays', style: _playsStyle),
                ],
                const SizedBox(width: 8),
                SizedBox(
                  width: 44,
                  child: Text(
                    formatTrackDuration(track.durationMs),
                    textAlign: TextAlign.right,
                    style: _durationStyle,
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

class _RankBadge extends StatelessWidget {
  const _RankBadge({
    required this.rank,
    required this.delta,
    this.accent,
  });

  final int rank;
  final _RankDelta delta;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? AppTheme.paperMuted;
    return SizedBox(
      width: 42,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$rank',
            style: GoogleFonts.syne(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: accent != null ? 16 : 14,
            ),
          ),
          const SizedBox(height: 2),
          _DeltaIcon(delta: delta),
        ],
      ),
    );
  }
}

class _DeltaIcon extends StatelessWidget {
  const _DeltaIcon({required this.delta});

  final _RankDelta delta;

  @override
  Widget build(BuildContext context) {
    return switch (delta) {
      _RankDelta.up => const _TrendTriangle(up: true),
      _RankDelta.down => const _TrendTriangle(up: false),
      _RankDelta.newEntry => Text(
          'new',
          style: GoogleFonts.figtree(
            color: _kChartAmber,
            fontSize: 9,
            fontWeight: FontWeight.w800,
          ),
        ),
      _RankDelta.same => Container(
          width: 8,
          height: 1.5,
          margin: const EdgeInsets.symmetric(vertical: 5),
          color: AppTheme.paperMuted.withValues(alpha: 0.65),
        ),
    };
  }
}

class _TrendTriangle extends StatelessWidget {
  const _TrendTriangle({required this.up});

  final bool up;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(10, 7),
      painter: _TrianglePainter(
        color: up ? const Color(0xFF3DDC84) : const Color(0xFFFF5C5C),
        pointUp: up,
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter({required this.color, required this.pointUp});

  final Color color;
  final bool pointUp;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (pointUp) {
      path
        ..moveTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height)
        ..close();
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter old) =>
      old.color != color || old.pointUp != pointUp;
}

