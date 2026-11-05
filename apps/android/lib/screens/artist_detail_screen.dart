import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/track_key.dart';
import '../models/artist_release.dart';
import '../models/track.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../utils/image_pick.dart';
import '../utils/playlist_actions.dart';
import '../widgets/ambient_backdrop.dart';
import '../widgets/app_bottom_sheet.dart';
import '../widgets/cover_image.dart';
import '../widgets/listen_actions.dart';
import '../widgets/playing_track.dart';
import '../widgets/track_cover_play.dart';
import '../widgets/track_overflow_menu.dart';
import '../widgets/track_meta_links.dart';
import 'release_detail_screen.dart';
import 'release_metadata_editor_screen.dart';

const _kYellow = Color(0xFFFFDB4D);

Map<String, List<Track>> _artistsIn(
  List<Track> source,
  LibraryService library,
) {
  final map = <String, List<Track>>{};
  final labels = <String, String>{};
  for (final track in source) {
    for (final name in track.artists) {
      final card = library.artistCardName(name);
      final label = labels.putIfAbsent(card.toLowerCase(), () => card);
      final list = map.putIfAbsent(label, () => []);
      if (!list.any((existing) => existing.trackKey == track.trackKey)) {
        list.add(track);
      }
    }
  }
  return map;
}

/// Yandex Music–inspired artist page.
class ArtistDetailScreen extends StatefulWidget {
  const ArtistDetailScreen({
    super.key,
    required this.artist,
    required this.tracks,
    required this.playCount,
    required this.chartRank,
    required this.trackPlayCounts,
    this.byProducer = false,
    this.battleOnly = false,
  });

  final String artist;
  final List<Track> tracks;
  final int playCount;
  final int chartRank;
  final Map<String, int> trackPlayCounts;
  final bool byProducer;

  /// Legacy battles page: only Battle-Rap tracks.
  final bool battleOnly;

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  List<Track> _genrePool(LibraryService library) {
    return widget.battleOnly ? library.battleTracks : library.catalogTracks;
  }

  List<Track> _liveTracks(LibraryService library) {
    final want = widget.artist.toLowerCase();
    final live = _genrePool(library)
        .where(
          (t) => widget.byProducer
              ? producerNames(t.producer).any(
                  (name) =>
                      library.producerCardName(name).toLowerCase() == want,
                )
              : t.artists.any(
                  (name) =>
                      library.artistCardName(name).toLowerCase() == want,
                ),
        )
        .toList(growable: false);
    if (live.isNotEmpty) return live;
    return [
      for (final track in widget.tracks)
        if (!widget.battleOnly || track.isBattle) track,
    ];
  }

  List<_ProducerCollab> _collaborations(
    LibraryService library,
    List<Track> tracks,
  ) {
    final grouped = <String, List<Track>>{};
    final labels = <String, String>{};
    for (final track in tracks) {
      final seen = <String>{};
      for (final name in track.artists) {
        final card = library.artistCardName(name).trim();
        final key = card.toLowerCase();
        if (key.isEmpty || key == 'unknown' || !seen.add(key)) {
          continue;
        }
        labels.putIfAbsent(key, () => card);
        final bucket = grouped.putIfAbsent(key, () => []);
        if (!bucket.any((existing) => existing.trackKey == track.trackKey)) {
          bucket.add(track);
        }
      }
    }

    final collabs = <_ProducerCollab>[];
    for (final entry in grouped.entries) {
      final artist = labels[entry.key]!;
      final list = _popularOf(entry.value);
      String? cover = library.artistPhotoPath(artist);
      if (cover == null) {
        for (final track in list) {
          final path = track.coverPath;
          if (path != null && path.isNotEmpty) {
            cover = path;
            break;
          }
        }
      }
      collabs.add(
        _ProducerCollab(artist: artist, tracks: list, coverPath: cover),
      );
    }
    collabs.sort((a, b) {
      final byCount = b.tracks.length.compareTo(a.tracks.length);
      if (byCount != 0) return byCount;
      return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
    });
    return collabs;
  }

  void _openCollab(BuildContext context, _ProducerCollab collab) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ArtistAllTracksScreen(
          artist: collab.artist,
          title: collab.artist,
          tracks: collab.tracks,
          trackPlayCounts: widget.trackPlayCounts,
        ),
      ),
    );
  }

  List<Track> _popularOf(List<Track> tracks) {
    return List<Track>.from(tracks)
      ..sort((a, b) {
        final ca = widget.trackPlayCounts[a.trackKey] ?? 0;
        final cb = widget.trackPlayCounts[b.trackKey] ?? 0;
        if (cb != ca) return cb.compareTo(ca);
        return a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase());
      });
  }

  String? _resolvePhoto(LibraryService library, List<Track> popular) {
    final custom = library.artistPhotoPath(widget.artist);
    if (custom != null) return custom;
    for (final t in popular) {
      final p = t.coverPath;
      if (p != null && File(p).existsSync()) return p;
    }
    return null;
  }

  Future<void> _mergePerson(BuildContext context) async {
    final library = context.read<LibraryService>();
    final producers = widget.byProducer;
    final grouped = producers
        ? library.tracksByProducer()
        : widget.battleOnly
            ? _artistsIn(library.battleTracks, library)
            : library.tracksByArtist();
    final others = grouped
        .keys
        .where((n) => n.toLowerCase() != widget.artist.toLowerCase())
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (others.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            producers
                ? 'Нет других продюсеров для объединения'
                : 'Нет других артистов для объединения',
            style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.inkLift,
        ),
      );
      return;
    }

    final selected = await showAppBottomSheet<String>(
      context: context,
      title: producers ? 'Объединить продюсеров' : 'Объединить артистов',
      scrollControlled: true,
      body: (sheetCtx) => SizedBox(
        height: MediaQuery.sizeOf(sheetCtx).height * 0.62,
        child: _MergeArtistSheet(
          currentArtist: widget.artist,
          candidates: others,
          producers: producers,
          sheetContext: sheetCtx,
        ),
      ),
    );
    if (selected == null || !context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2220),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          producers ? 'Объединить продюсеров?' : 'Объединить артистов?',
          style: GoogleFonts.syne(
            color: AppTheme.paper,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          '«$selected» попадёт на карточку «${widget.artist}». '
          'В треках останется исходное имя. '
          'Поиск найдёт и старое, и новое название.',
          style: GoogleFonts.figtree(
            color: AppTheme.paperMuted,
            height: 1.45,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Отмена',
              style: GoogleFonts.figtree(color: AppTheme.paperMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Объединить',
              style: GoogleFonts.figtree(
                color: _kYellow,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    if (producers) {
      await library.mergeProducers(into: widget.artist, from: selected);
    } else {
      await library.mergeArtists(into: widget.artist, from: selected);
    }
    if (!context.mounted) return;

    final byArtist = producers
        ? library.tracksByProducer()
        : widget.battleOnly
            ? _artistsIn(library.battleTracks, library)
            : library.tracksByArtist();
    var tracks = <Track>[];
    for (final e in byArtist.entries) {
      if (e.key.toLowerCase() == widget.artist.toLowerCase()) {
        tracks = e.value;
        break;
      }
    }
    final counts = await library.playCountsAllTime();
    if (!context.mounted) return;

    final plays = tracks.fold<int>(
      0,
      (sum, t) => sum + (counts[t.trackKey] ?? 0),
    );

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ArtistDetailScreen(
          artist: widget.artist,
          tracks: tracks,
          playCount: plays,
          chartRank: widget.chartRank,
          trackPlayCounts: counts,
          byProducer: widget.byProducer,
          battleOnly: widget.battleOnly,
        ),
      ),
    );
  }

  Future<void> _pickPhoto(BuildContext context) async {
    final library = context.read<LibraryService>();
    final bytes = await pickImageBytes();
    if (bytes == null || !context.mounted) return;
    await library.setArtistPhoto(widget.artist, bytes);
  }

  Future<void> _clearPhoto(BuildContext context) async {
    await context.read<LibraryService>().clearArtistPhoto(widget.artist);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final library = context.watch<LibraryService>();
    final tracks = _liveTracks(library);
    final popular = _popularOf(tracks);
    final collabs = widget.byProducer
        ? _collaborations(library, tracks)
        : const <_ProducerCollab>[];
    final groups = widget.byProducer
        ? null
        : groupArtistReleases(
            artistTracks: tracks,
            libraryTracks: _genrePool(library),
            isThisArtist: (name) =>
                library.artistCardName(name).toLowerCase() ==
                widget.artist.toLowerCase(),
            cardName: library.artistCardName,
          );
    final albums = groups?.albums ?? const <ArtistRelease>[];
    final eps = groups?.eps ?? const <ArtistRelease>[];
    final singles = groups?.singles ?? const <ArtistRelease>[];
    final appearances = groups?.appearances ?? const <ArtistRelease>[];
    final photoPath = _resolvePhoto(library, popular);

    return Scaffold(
      backgroundColor: AppTheme.ink,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: AppTheme.ink.withValues(alpha: 0.92),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              widget.artist,
              style: GoogleFonts.syne(fontWeight: FontWeight.w700),
            ),
          ),
          SliverToBoxAdapter(child: _Header(
            artist: widget.artist,
            photoPath: photoPath,
            canClearPhoto: library.artistPhotoPath(widget.artist) != null,
            chartRank: widget.chartRank,
            trackCount: tracks.length,
            onListen: () => player.playTracks(popular, shuffle: false),
            onShuffle: () => player.playTracks(tracks, shuffle: true),
            onPickPhoto: () => _pickPhoto(context),
            onClearPhoto: () => _clearPhoto(context),
            onMerge: () => _mergePerson(context),
            mergeTooltip: widget.byProducer
                ? 'Объединить продюсеров'
                : 'Объединить артистов',
            roleLabel: widget.byProducer ? 'Продюсер' : 'Артист',
          )),
          if (widget.byProducer) ...[
            if (popular.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _SectionTitle(
                  title: 'Популярные треки',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _ArtistAllTracksScreen(
                          artist: widget.artist,
                          tracks: popular,
                          trackPlayCounts: widget.trackPlayCounts,
                        ),
                      ),
                    );
                  },
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final track = popular[index];
                    final plays = library.playCountFor(
                      widget.trackPlayCounts,
                      track.trackKey,
                    );
                    return _PopularTrackRow(
                      index: index + 1,
                      track: track,
                      plays: plays,
                      onTap: () =>
                          player.playTracks(popular, startIndex: index),
                    );
                  },
                  childCount: popular.length.clamp(0, 10),
                ),
              ),
            ],
            if (collabs.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                  child: Text(
                    'Нет сотрудничества.',
                    style: GoogleFonts.figtree(color: AppTheme.paperMuted),
                  ),
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: _SectionTitle(
                  title: 'Сотрудничество',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _CollabGridScreen(
                          producer: widget.artist,
                          collabs: collabs,
                          onOpen: (collab) => _openCollab(context, collab),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SliverToBoxAdapter(
                child: _CollabCarousel(
                  collabs: collabs,
                  onOpen: (collab) => _openCollab(context, collab),
                ),
              ),
            ],
          ] else ...[
            if (popular.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _SectionTitle(
                  title: 'Популярные треки',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _ArtistAllTracksScreen(
                          artist: widget.artist,
                          tracks: popular,
                          trackPlayCounts: widget.trackPlayCounts,
                        ),
                      ),
                    );
                  },
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final track = popular[index];
                    final plays = library.playCountFor(
                      widget.trackPlayCounts,
                      track.trackKey,
                    );
                    return _PopularTrackRow(
                      index: index + 1,
                      track: track,
                      plays: plays,
                      onTap: () =>
                          player.playTracks(popular, startIndex: index),
                    );
                  },
                  childCount: popular.length.clamp(0, 10),
                ),
              ),
            ],
            if (albums.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverToBoxAdapter(
              child: _SectionTitle(
                title: 'Альбомы',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _ArtistAllReleasesScreen(
                        artist: widget.artist,
                        section: _ReleaseSection.albums,
                        playCountsByKey: widget.trackPlayCounts,
                        battleOnly: widget.battleOnly,
                      ),
                    ),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: _ReleaseCarousel(
                releases: albums,
                artist: widget.artist,
                playCountsByKey: widget.trackPlayCounts,
              ),
            ),
          ],
          if (eps.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverToBoxAdapter(
              child: _SectionTitle(
                title: 'EP',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _ArtistAllReleasesScreen(
                        artist: widget.artist,
                        section: _ReleaseSection.eps,
                        playCountsByKey: widget.trackPlayCounts,
                        battleOnly: widget.battleOnly,
                      ),
                    ),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: _ReleaseCarousel(
                releases: eps,
                artist: widget.artist,
                playCountsByKey: widget.trackPlayCounts,
              ),
            ),
          ],
          if (singles.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverToBoxAdapter(
              child: _SectionTitle(
                title: 'Синглы',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _ArtistAllReleasesScreen(
                        artist: widget.artist,
                        section: _ReleaseSection.singles,
                        playCountsByKey: widget.trackPlayCounts,
                        battleOnly: widget.battleOnly,
                      ),
                    ),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: _ReleaseCarousel(
                releases: singles,
                artist: widget.artist,
                playCountsByKey: widget.trackPlayCounts,
              ),
            ),
          ],
          if (appearances.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverToBoxAdapter(
              child: _SectionTitle(
                title: 'Участие в релизах',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _ArtistAllReleasesScreen(
                        artist: widget.artist,
                        section: _ReleaseSection.appearances,
                        playCountsByKey: widget.trackPlayCounts,
                        battleOnly: widget.battleOnly,
                      ),
                    ),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: _ReleaseCarousel(
                releases: appearances,
                artist: widget.artist,
                playCountsByKey: widget.trackPlayCounts,
              ),
            ),
          ],
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.artist,
    required this.photoPath,
    required this.canClearPhoto,
    required this.chartRank,
    required this.trackCount,
    required this.onListen,
    required this.onShuffle,
    required this.onPickPhoto,
    required this.onClearPhoto,
    this.onMerge,
    this.mergeTooltip = 'Объединить артистов',
    this.roleLabel = 'Артист',
  });

  final String artist;
  final String? photoPath;
  final bool canClearPhoto;
  final int chartRank;
  final int trackCount;
  final VoidCallback onListen;
  final VoidCallback onShuffle;
  final VoidCallback onPickPhoto;
  final VoidCallback onClearPhoto;
  final VoidCallback? onMerge;
  final String mergeTooltip;
  final String roleLabel;

  List<Widget> get _photoActions => [
        _PhotoActionButton(
          icon: const Icon(Icons.image_outlined, size: 18),
          tooltip: 'Изменить фото',
          onPressed: onPickPhoto,
        ),
        if (onMerge != null)
          _PhotoActionButton(
            icon: const Icon(Icons.merge_type_rounded, size: 18),
            tooltip: mergeTooltip,
            onPressed: onMerge!,
          ),
        if (canClearPhoto)
          _PhotoActionButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Сбросить фото',
            onPressed: onClearPhoto,
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = (size.width * 1.08).clamp(340.0, 560.0);
    final path = photoPath;
    final hasPhoto = path != null && File(path).existsSync();
    final actions = _photoActions;
    final chipColor = Colors.white.withValues(alpha: 0.78);

    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasPhoto)
            GestureDetector(
              onTap: () => _showArtistPhoto(context, File(path)),
              child: fileCover(
                context,
                path,
                logicalSize: size.width,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              ),
            )
          else
            const AmbientBackdrop(
              accent: Color(0xFF3D6B8B),
              secondary: Color(0xFF2A4A5C),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.4),
                  Colors.black.withValues(alpha: 0.08),
                  AppTheme.ink.withValues(alpha: 0.72),
                  AppTheme.ink,
                ],
                stops: const [0, 0.32, 0.7, 1],
              ),
            ),
          ),
          if (actions.isNotEmpty)
            Positioned(
              top: 10,
              right: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    actions[i],
                  ],
                ],
              ),
            ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  roleLabel,
                  style: GoogleFonts.figtree(
                    color: chipColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  artist,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.syne(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    _MetaChip(
                      icon: Icons.emoji_events_outlined,
                      text: chartRank > 0
                          ? '$chartRank место в топе'
                          : 'Нет в топе',
                      color: chipColor,
                    ),
                    _MetaChip(
                      icon: Icons.music_note_outlined,
                      text: '$trackCount треков',
                      color: chipColor,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ListenActions(
                  onListen: onListen,
                  onShuffle: onShuffle,
                  center: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoActionButton extends StatelessWidget {
  const _PhotoActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      mouseCursor: SystemMouseCursors.click,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.38),
        foregroundColor: Colors.white,
        minimumSize: const Size(40, 40),
        fixedSize: const Size(40, 40),
        shape: const CircleBorder(),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
      ),
      icon: icon,
    );
  }
}

void _showArtistPhoto(BuildContext context, File? file) {
  final side = MediaQuery.sizeOf(context).shortestSide * 0.72;
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.82),
    builder: (context) {
      return GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: SizedBox(
              width: side,
              height: side,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: ColoredBox(
                  color: AppTheme.inkLift,
                  child: file == null
                      ? const Icon(
                          Icons.person,
                          size: 120,
                          color: AppTheme.mossBright,
                        )
                      : InteractiveViewer(
                          child: SizedBox(
                            width: side,
                            height: side,
                            child: Image.file(file, fit: BoxFit.contain),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.text,
    this.color,
  });

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.paperMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 6),
        Text(
          text,
          style: GoogleFonts.figtree(
            color: c,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
      child: InkWell(
        mouseCursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onTap: onTap,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: Row(
          children: [
            Text(
              title,
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: AppTheme.paperMuted),
            ],
          ],
        ),
      ),
    );
  }
}

class _PopularTrackRow extends StatelessWidget {
  const _PopularTrackRow({
    required this.index,
    required this.track,
    required this.plays,
    required this.onTap,
  });

  final int index;
  final Track track;
  final int plays;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final playing = PlayingTrack.watch(context, track.trackKey);
    return TrackContextMenu(
      actions: standardTrackActions(context, track),
      child: Material(
        color: PlayingTrack.surface(playing),
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '$index',
                    style: GoogleFonts.figtree(
                      color: playing
                          ? PlayingTrack.accent
                          : AppTheme.paperMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TrackCoverPlay(
                  path: track.coverPath,
                  onPlay: onTap,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TrackMetaLinks(
                    track: track,
                    titleStyle: GoogleFonts.figtree(
                      color: PlayingTrack.titleColor(playing),
                      fontSize: 15,
                      fontWeight: PlayingTrack.titleWeight(playing),
                    ),
                    artistStyle: GoogleFonts.figtree(
                      color: AppTheme.paperMuted,
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  plays > 0
                      ? NumberFormat.compact(locale: 'ru').format(plays)
                      : '—',
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => addTrackToPlaylist(context, track),
                  icon: const Icon(
                    Icons.queue_music_rounded,
                    color: AppTheme.paperMuted,
                    size: 22,
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

class _ProducerCollab {
  const _ProducerCollab({
    required this.artist,
    required this.tracks,
    this.coverPath,
  });

  final String artist;
  final List<Track> tracks;
  final String? coverPath;
}

class _CollabCarousel extends StatelessWidget {
  const _CollabCarousel({required this.collabs, required this.onOpen});

  final List<_ProducerCollab> collabs;
  final ValueChanged<_ProducerCollab> onOpen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 236,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        scrollDirection: Axis.horizontal,
        itemCount: collabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final collab = collabs[index];
          return _CollabCard(
            collab: collab,
            onTap: () => onOpen(collab),
          );
        },
      ),
    );
  }
}

class _CollabCard extends StatelessWidget {
  const _CollabCard({
    required this.collab,
    required this.onTap,
    this.width = 148,
  });

  final _ProducerCollab collab;
  final VoidCallback onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final path = collab.coverPath;
    Widget cover = const ColoredBox(
      color: AppTheme.inkLift,
      child: Icon(Icons.person_rounded, color: AppTheme.mossBright, size: 40),
    );
    if (path != null && File(path).existsSync()) {
      cover = fileCover(context, path, logicalSize: width ?? 148);
    }

    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(aspectRatio: 1, child: cover),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              collab.artist,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.figtree(
                color: AppTheme.paper,
                fontWeight: FontWeight.w700,
                fontSize: 13,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Плейлист',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 12,
              ),
            ),
            Text(
              _trackCountLabel(collab.tracks.length),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollabGridScreen extends StatelessWidget {
  const _CollabGridScreen({
    required this.producer,
    required this.collabs,
    required this.onOpen,
  });

  final String producer;
  final List<_ProducerCollab> collabs;
  final ValueChanged<_ProducerCollab> onOpen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.ink,
      appBar: AppBar(
        backgroundColor: AppTheme.ink,
        title: Text(
          'Сотрудничество $producer',
          style: GoogleFonts.syne(fontWeight: FontWeight.w700),
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 18,
          crossAxisSpacing: 14,
          childAspectRatio: 0.62,
        ),
        itemCount: collabs.length,
        itemBuilder: (context, index) {
          final collab = collabs[index];
          return _CollabCard(
            collab: collab,
            width: null,
            onTap: () => onOpen(collab),
          );
        },
      ),
    );
  }
}

String _trackCountLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return '$count трек';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$count трека';
  }
  return '$count треков';
}

class _ReleaseCarousel extends StatelessWidget {
  const _ReleaseCarousel({
    required this.releases,
    required this.artist,
    required this.playCountsByKey,
  });

  final List<ArtistRelease> releases;
  final String artist;
  final Map<String, int> playCountsByKey;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 252,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        scrollDirection: Axis.horizontal,
        itemCount: releases.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final release = releases[index];
          final credit = _releaseArtistLine(release, artist);
          return _ReleaseCard(
            release: release,
            artist: credit,
            listenCount: releaseListenCount(release, playCountsByKey),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ReleaseDetailScreen(
                    release: release,
                    primaryArtist: credit,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

String _releaseArtistLine(ArtistRelease release, String pageArtist) {
  final names = releaseAlbumArtists(release);
  if (names.isNotEmpty) return names.join(', ');
  final credit = release.credit?.trim();
  if (credit != null && credit.isNotEmpty) return credit;
  return pageArtist;
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({
    required this.release,
    required this.artist,
    required this.onTap,
    this.listenCount = 0,
    this.width = 148,
  });

  final ArtistRelease release;
  final String artist;
  final VoidCallback onTap;
  final int listenCount;
  /// Null expands to the parent (grid cell).
  final double? width;

  @override
  Widget build(BuildContext context) {
    Widget cover = ColoredBox(
      color: AppTheme.inkLift,
      child: const Icon(Icons.album, color: AppTheme.mossBright, size: 40),
    );
    final path = context.read<LibraryService>().releaseCover(release);
    if (path != null && File(path).existsSync()) {
      cover = fileCover(context, path, logicalSize: width ?? 148);
    }

    return TrackContextMenu(
      actions: releaseMenuActions(context, release),
      child: InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(aspectRatio: 1, child: cover),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              metaFieldText(release.title),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.figtree(
                color: AppTheme.paper,
                fontWeight: FontWeight.w700,
                fontSize: 13,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              artist,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 12,
              ),
            ),
            Text(
              releaseCaption(release, listenCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.figtree(
                color: AppTheme.paperMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

enum _ReleaseSection { albums, eps, singles, appearances }

/// Full album / single grid for an artist.
///
/// Releases are read from the library on each build, so a metadata edit
/// made from a release opened here shows up when this page is visible again.
class _ArtistAllReleasesScreen extends StatelessWidget {
  const _ArtistAllReleasesScreen({
    required this.artist,
    required this.section,
    required this.playCountsByKey,
    this.battleOnly = false,
  });

  final String artist;
  final _ReleaseSection section;
  final Map<String, int> playCountsByKey;
  final bool battleOnly;

  String get _sectionTitle {
    switch (section) {
      case _ReleaseSection.albums:
        return 'Альбомы';
      case _ReleaseSection.eps:
        return 'EP';
      case _ReleaseSection.singles:
        return 'Синглы';
      case _ReleaseSection.appearances:
        return 'Участие в релизах';
    }
  }

  List<ArtistRelease> _releases(LibraryService library) {
    final want = artist.toLowerCase();
    final pool =
        battleOnly ? library.battleTracks : library.catalogTracks;
    final tracks = pool
        .where(
          (track) => track.artists.any(
            (name) => library.artistCardName(name).toLowerCase() == want,
          ),
        )
        .toList(growable: false);
    final groups = groupArtistReleases(
      artistTracks: tracks,
      libraryTracks: pool,
      isThisArtist: (name) =>
          library.artistCardName(name).toLowerCase() == want,
      cardName: library.artistCardName,
    );
    switch (section) {
      case _ReleaseSection.albums:
        return groups.albums;
      case _ReleaseSection.eps:
        return groups.eps;
      case _ReleaseSection.singles:
        return groups.singles;
      case _ReleaseSection.appearances:
        return groups.appearances;
    }
  }

  int _listenCount(LibraryService library, ArtistRelease release) {
    var total = 0;
    for (final track in release.tracks) {
      total += library.playCountFor(playCountsByKey, track.trackKey);
    }
    return total;
  }

  void _open(BuildContext context, ArtistRelease release, String credit) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReleaseDetailScreen(
          release: release,
          primaryArtist: credit,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final releases = _releases(library);
    return Scaffold(
      backgroundColor: AppTheme.ink,
      appBar: AppBar(
        backgroundColor: AppTheme.ink,
        title: Text(
          '$_sectionTitle $artist',
          style: GoogleFonts.syne(fontWeight: FontWeight.w700),
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 18,
          crossAxisSpacing: 14,
          childAspectRatio: 0.62,
        ),
        itemCount: releases.length,
        itemBuilder: (context, index) {
          final release = releases[index];
          final credit = _releaseArtistLine(release, artist);
          return _ReleaseCard(
            release: release,
            artist: credit,
            width: null,
            listenCount: _listenCount(library, release),
            onTap: () => _open(context, release, credit),
          );
        },
      ),
    );
  }
}

class _MergeArtistSheet extends StatefulWidget {
  const _MergeArtistSheet({
    required this.currentArtist,
    required this.candidates,
    required this.producers,
    required this.sheetContext,
  });

  final String currentArtist;
  final List<String> candidates;
  final bool producers;
  final BuildContext sheetContext;

  @override
  State<_MergeArtistSheet> createState() => _MergeArtistSheetState();
}

class _MergeArtistSheetState extends State<_MergeArtistSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.candidates
        : widget.candidates
            .where((n) => n.toLowerCase().contains(q))
            .toList();
    final role = widget.producers ? 'продюсера' : 'артиста';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            'Добавить к «${widget.currentArtist}». Имена в треках не меняются.',
            style: GoogleFonts.figtree(
              color: AppTheme.paperMuted,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: TextField(
            autofocus: true,
            cursorColor: _kYellow,
            onChanged: (v) => setState(() => _query = v),
            style: GoogleFonts.figtree(color: AppTheme.paper),
            decoration: InputDecoration(
              hintText: 'Поиск $role',
              hintStyle: GoogleFonts.figtree(color: AppTheme.paperMuted),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: AppTheme.paperMuted.withValues(alpha: 0.9),
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    'Ничего не найдено',
                    style: GoogleFonts.figtree(color: AppTheme.paperMuted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final name = filtered[index];
                    final photo = library.artistPhotoPath(name);
                    return SheetRow(
                      title: name,
                      subtitle: widget.producers ? 'Продюсер' : 'Артист',
                      leading: _MergeAvatar(name: name, photoPath: photo),
                      onTap: () => popAppSheet(widget.sheetContext, name),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _MergeAvatar extends StatelessWidget {
  const _MergeAvatar({required this.name, this.photoPath});

  final String name;
  final String? photoPath;

  @override
  Widget build(BuildContext context) {
    final path = photoPath;
    final has = path != null && File(path).existsSync();
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppTheme.inkLift,
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.paper.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: has
          ? fileCover(context, path, logicalSize: 44)
          : Center(
              child: Text(
                letter,
                style: GoogleFonts.syne(
                  color: _kYellow,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ),
    );
  }
}

/// Full track list for an artist (from «Популярные треки»).
class _ArtistAllTracksScreen extends StatelessWidget {
  const _ArtistAllTracksScreen({
    required this.artist,
    required this.tracks,
    required this.trackPlayCounts,
    this.title = 'Все треки',
  });

  final String artist;
  final List<Track> tracks;
  final Map<String, int> trackPlayCounts;
  final String title;

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final library = context.watch<LibraryService>();
    final live = [
      for (final track in tracks) library.resolveTrack(track),
    ];

    return Scaffold(
      backgroundColor: AppTheme.ink,
      appBar: AppBar(
        backgroundColor: AppTheme.ink,
        title: Text(
          title,
          style: GoogleFonts.syne(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Слушать',
            onPressed: live.isEmpty
                ? null
                : () => player.playTracks(live, shuffle: false),
            icon: const Icon(Icons.play_arrow_rounded),
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 48),
        itemCount: live.length,
        itemBuilder: (context, index) {
          final source = tracks[index];
          final track = live[index];
          final plays = trackPlayCounts[track.trackKey] ??
              trackPlayCounts[source.trackKey] ??
              0;
          return _PopularTrackRow(
            index: index + 1,
            track: track,
            plays: plays,
            onTap: () => player.playTracks(live, startIndex: index),
          );
        },
      ),
    );
  }
}
