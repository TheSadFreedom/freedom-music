import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../data/track_key.dart';
import '../models/artist_release.dart';
import '../models/catalog_search.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../navigation/library_navigation.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../widgets/cover_image.dart';
import '../widgets/home_hero.dart';
import '../widgets/playing_track.dart';
import '../widgets/playlist_mosaic.dart';
import '../widgets/system_playlist_icon.dart';
import '../widgets/marquee_text.dart';
import '../widgets/track_title_line.dart';
import '../widgets/track_overflow_menu.dart';
import 'playlists_screen.dart';
import 'release_detail_screen.dart';
import 'release_metadata_editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

enum _SearchFilter { all, tracks, artists, producers, albums, playlists }

class HomeScreenState extends State<HomeScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';
  String _appliedQuery = '';
  _SearchFilter _filter = _SearchFilter.all;
  Timer? _searchTimer;

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Clears the home search field and results (e.g. re-tap Home tab).
  void clearSearch() {
    _searchTimer?.cancel();
    _searchController.clear();
    _searchFocus.unfocus();
    if (!mounted) return;
    setState(() {
      _query = '';
      _appliedQuery = '';
      _filter = _SearchFilter.all;
    });
  }

  void _scheduleSearch(String value) {
    _searchTimer?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      if (_appliedQuery.isEmpty) return;
      setState(() {
        _appliedQuery = '';
        _filter = _SearchFilter.all;
      });
      return;
    }
    _searchTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _appliedQuery = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final playing = context.select<PlayerService, bool>((p) => p.playing);
    final searching = _appliedQuery.trim().isNotEmpty;
    final results = searching
        ? library.searchCatalog(_appliedQuery)
        : CatalogSearch.empty;

    return HomeStage(
      playing: playing,
      child: Column(
        children: [
          Padding(
            padding: pagePadding(context).copyWith(bottom: 0),
            child: _SearchBar(
              controller: _searchController,
              focusNode: _searchFocus,
              query: _query,
              searching: searching,
              onChanged: (v) {
                setState(() => _query = v);
                _scheduleSearch(v);
              },
              onClear: () {
                _searchTimer?.cancel();
                _searchController.clear();
                setState(() {
                  _query = '';
                  _appliedQuery = '';
                  _filter = _SearchFilter.all;
                });
              },
              onBack: clearSearch,
            ),
          ),
          if (searching) ...[
            const SizedBox(height: 10),
            _SearchChips(
              results: results,
              selected: _filter,
              onSelected: (f) => setState(() => _filter = f),
            ),
          ] else
            const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: pagePadding(context).copyWith(top: 0),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: searching
                    ? KeyedSubtree(
                        key: const ValueKey('search'),
                        child: _SearchResults(
                          results: results,
                          filter: _filter,
                        ),
                      )
                    : const KeyedSubtree(
                        key: ValueKey('hero'),
                        child: _LiveHero(),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.searching,
    required this.onChanged,
    required this.onClear,
    required this.onBack,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final bool searching;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.inkLift,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            if (searching)
              IconButton(
                tooltip: 'Назад',
                onPressed: onBack,
                icon: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: AppTheme.paper,
                  size: 18,
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(left: 14),
                child: Icon(Icons.search_rounded, color: AppTheme.paperMuted),
              ),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                style: GoogleFonts.figtree(
                  color: AppTheme.paper,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                cursorColor: AppTheme.lime,
                decoration: InputDecoration(
                  hintText: 'Треки, артисты, альбомы…',
                  hintStyle: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontWeight: FontWeight.w500,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            if (query.isNotEmpty)
              IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded, color: AppTheme.paperMuted),
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _SearchChips extends StatelessWidget {
  const _SearchChips({
    required this.results,
    required this.selected,
    required this.onSelected,
  });

  final CatalogSearch results;
  final _SearchFilter selected;
  final ValueChanged<_SearchFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final chips = <({_SearchFilter id, String label, int count})>[
      (
        id: _SearchFilter.all,
        label: 'Все',
        count: results.tracks.length +
            results.artists.length +
            results.producers.length +
            results.albums.length +
            results.playlists.length,
      ),
      if (results.tracks.isNotEmpty)
        (id: _SearchFilter.tracks, label: 'Треки', count: results.tracks.length),
      if (results.artists.isNotEmpty)
        (
          id: _SearchFilter.artists,
          label: 'Артисты',
          count: results.artists.length
        ),
      if (results.producers.isNotEmpty)
        (
          id: _SearchFilter.producers,
          label: 'Продюсеры',
          count: results.producers.length
        ),
      if (results.albums.isNotEmpty)
        (
          id: _SearchFilter.albums,
          label: 'Релизы',
          count: results.albums.length
        ),
      if (results.playlists.isNotEmpty)
        (
          id: _SearchFilter.playlists,
          label: 'Плейлисты',
          count: results.playlists.length
        ),
    ];

    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final chip = chips[index];
          final active = chip.id == selected;
          return Material(
            color: active
                ? AppTheme.moss.withValues(alpha: 0.35)
                : AppTheme.inkLift,
            shape: StadiumBorder(
              side: BorderSide(
                color: active
                    ? AppTheme.lime.withValues(alpha: 0.7)
                    : Colors.white.withValues(alpha: 0.06),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onSelected(chip.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  child: Text(
                    chip.label,
                    style: GoogleFonts.figtree(
                      color: active ? AppTheme.lime : AppTheme.paper,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Watches playback on its own so search results are not rebuilt every tick.
class _LiveHero extends StatelessWidget {
  const _LiveHero();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final playing = context.select<PlayerService, bool>(
      (p) => p.playing && p.current != null,
    );
    final current = context.select<PlayerService, Track?>((p) => p.current);
    return _CenteredHero(
      trackCount: library.catalogTracks.length,
      empty: library.isEmpty,
      playing: playing,
      current: current,
      onPlay: library.catalogTracks.isEmpty && current == null
          ? null
          : () {
              final player = context.read<PlayerService>();
              if (player.current != null) {
                player.togglePlayPause();
              } else {
                player.playRandomAll();
              }
            },
    );
  }
}

class _CenteredHero extends StatelessWidget {
  const _CenteredHero({
    required this.trackCount,
    required this.empty,
    required this.playing,
    required this.current,
    required this.onPlay,
  });

  final int trackCount;
  final bool empty;
  final bool playing;
  final Track? current;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final phone = isPhone(context);
    final vinylSize = phone
        ? (h * 0.28).clamp(160.0, 220.0)
        : (h * 0.34).clamp(200.0, 300.0);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'FREEDOM MUSIC',
              textAlign: TextAlign.center,
              style: GoogleFonts.syne(
                fontSize: phone ? 34 : 52,
                fontWeight: FontWeight.w800,
                height: 0.95,
                letterSpacing: phone ? 1.6 : 3.2,
                color: AppTheme.paper,
              ),
            ),
            const SizedBox(height: 14),
            if (empty)
              Text(
                'Положите треки в music и отсканируйте библиотеку.',
                textAlign: TextAlign.center,
                style: GoogleFonts.figtree(
                  color: AppTheme.paperMuted,
                  fontSize: phone ? 14 : 16,
                  height: 1.45,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.15,
                ),
              )
            else
              Text.rich(
                TextSpan(
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontSize: phone ? 14 : 16,
                    height: 1.45,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.15,
                  ),
                  children: [
                    const TextSpan(text: 'Случайный поток из '),
                    TextSpan(
                      text: '$trackCount',
                      style: const TextStyle(
                        color: AppTheme.lime,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const TextSpan(text: ' треков вашей библиотеки.'),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            SizedBox(height: phone ? 20 : 28),
            VinylPlayControl(
              size: vinylSize,
              playing: playing,
              enabled: onPlay != null,
              onPressed: onPlay,
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 72,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 420),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.12),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: current == null
                    ? Text(
                        key: const ValueKey('idle'),
                        'Нажмите, чтобы начать',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.figtree(
                          color: AppTheme.paperMuted,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : _NowPlaying(
                        track: current!,
                        onStop: () =>
                            context.read<PlayerService>().stopAndClear(),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.track, required this.onStop});

  final Track track;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    Widget cover = Container(
      width: 52,
      height: 52,
      color: AppTheme.inkLift,
      child: const Icon(Icons.album, color: AppTheme.mossBright),
    );
    if (track.coverPath != null && File(track.coverPath!).existsSync()) {
      cover = fileCover(
        context,
        track.coverPath!,
        logicalSize: 52,
      );
    }

    final titleStyle = GoogleFonts.syne(
      color: AppTheme.paper,
      fontSize: 17,
      fontWeight: FontWeight.w700,
    );
    final artistStyle = GoogleFonts.figtree(
      color: AppTheme.paperMuted,
      fontSize: 13,
    );
    return TrackContextMenu(
      actions: standardTrackActions(context, track),
      child: Row(
        key: ValueKey(track.trackKey),
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(10), child: cover),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'СЕЙЧАС',
                  style: GoogleFonts.figtree(
                    color: AppTheme.lime,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                MarqueeText(
                  text: track.displayTitle,
                  style: titleStyle,
                ),
                const SizedBox(height: 2),
                Text(
                  track.displayArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: artistStyle,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: AppTheme.lime,
            shape: const CircleBorder(),
            elevation: 2,
            shadowColor: Colors.black,
            child: InkWell(
              customBorder: const CircleBorder(),
              mouseCursor: SystemMouseCursors.click,
              onTap: onStop,
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.stop_rounded, color: Colors.black, size: 22),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _countLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return '$count трек';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$count трека';
  }
  return '$count треков';
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.results,
    required this.filter,
  });

  final CatalogSearch results;
  final _SearchFilter filter;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final rows = <Widget>[];

    void addHeader(String title) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Text(
            title,
            style: GoogleFonts.syne(
              color: AppTheme.lime,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ),
      );
    }

    final showAll = filter == _SearchFilter.all;

    if ((showAll || filter == _SearchFilter.tracks) &&
        results.tracks.isNotEmpty) {
      if (showAll) addHeader('Треки');
      for (var i = 0; i < results.tracks.length; i++) {
        final track = results.tracks[i];
        final playing = PlayingTrack.watch(context, track.trackKey);
        rows.add(
          TrackContextMenu(
            actions: standardTrackActions(context, track),
            child: _SearchRow(
              title: track.displayTitle,
              note: track.displayNote,
              subtitle: track.displayArtist,
              leading: _CoverMark(path: track.coverPath, size: 52),
              titleColor: PlayingTrack.titleColor(playing),
              highlighted: playing,
              onTap: () => context.read<PlayerService>().playTracks(
                    results.tracks,
                    startIndex: i,
                  ),
            ),
          ),
        );
      }
    }

    if ((showAll || filter == _SearchFilter.artists) &&
        results.artists.isNotEmpty) {
      if (showAll) addHeader('Артисты');
      for (final person in results.artists) {
        rows.add(
          _SearchRow(
            title: person.name,
            subtitle: _countLabel(person.trackCount),
            leading: _PersonMark(
              photoPath: library.artistPhotoPath(person.name),
              icon: Icons.person_rounded,
              size: 52,
            ),
            onTap: () => openArtistPage(context, person.name),
          ),
        );
      }
    }

    if ((showAll || filter == _SearchFilter.producers) &&
        results.producers.isNotEmpty) {
      if (showAll) addHeader('Продюсеры');
      for (final person in results.producers) {
        rows.add(
          _SearchRow(
            title: person.name,
            subtitle: _countLabel(person.trackCount),
            leading: _PersonMark(
              photoPath: library.artistPhotoPath(person.name),
              icon: Icons.headphones_rounded,
              size: 52,
            ),
            onTap: () => openArtistPage(context, person.name, producer: true),
          ),
        );
      }
    }

    if ((showAll || filter == _SearchFilter.albums) &&
        results.albums.isNotEmpty) {
      if (showAll) addHeader('Релизы');
      for (final album in results.albums) {
        final year = album.release.year;
        final kind = releaseKindLabel(album.release.kind);
        rows.add(
          TrackContextMenu(
            actions: releaseMenuActions(context, album.release),
            child: _SearchRow(
              title: metaFieldText(album.release.title),
              subtitle: year == null
                  ? '${album.artist} · $kind'
                  : '${album.artist} · $year · $kind',
              leading: _CoverMark(
                path: library.releaseCover(album.release),
                size: 52,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReleaseDetailScreen(
                      release: album.release,
                      primaryArtist: album.artist,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }
    }

    if ((showAll || filter == _SearchFilter.playlists) &&
        results.playlists.isNotEmpty) {
      if (showAll) addHeader('Плейлисты');
      for (final playlist in results.playlists) {
        rows.add(
          _SearchRow(
            title: playlist.name,
            subtitle: _countLabel(playlist.trackCount),
            leading: _PlaylistMark(playlist: playlist, size: 52),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PlaylistDetailScreen(playlistId: playlist.id),
                ),
              );
            },
          ),
        );
      }
    }

    if (rows.isEmpty) {
      return Center(
        child: Text(
          'Ничего не найдено',
          style: GoogleFonts.figtree(color: AppTheme.paperMuted, fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index],
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.onTap,
    this.note,
    this.titleColor = AppTheme.paper,
    this.highlighted = false,
  });

  final String title;
  final String? note;
  final String subtitle;
  final Widget leading;
  final VoidCallback onTap;
  final Color titleColor;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PlayingTrack.surface(highlighted),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TrackTitleLine(
                      title: title,
                      note: note,
                      style: GoogleFonts.figtree(
                        color: titleColor,
                        fontWeight: PlayingTrack.titleWeight(highlighted),
                        fontSize: 16,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.figtree(
                        color: AppTheme.paperMuted,
                        fontSize: 13,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                color: AppTheme.paperMuted.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PersonMark extends StatelessWidget {
  const _PersonMark({
    required this.photoPath,
    required this.icon,
    this.size = 22,
  });

  final String? photoPath;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final path = photoPath;
    Widget child = Icon(icon, color: AppTheme.ink, size: size * 0.55);
    if (path != null && File(path).existsSync()) {
      child = fileCover(
        context,
        path,
        logicalSize: size,
      );
    }
    return ClipOval(
      child: ColoredBox(
        color: AppTheme.lime,
        child: SizedBox(width: size, height: size, child: child),
      ),
    );
  }
}

class _CoverMark extends StatelessWidget {
  const _CoverMark({required this.path, this.size = 22});

  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget child = Icon(
      Icons.album,
      color: AppTheme.mossBright,
      size: size * 0.7,
    );
    final cover = path;
    if (cover != null && File(cover).existsSync()) {
      child = fileCover(
        context,
        cover,
        logicalSize: size,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: ColoredBox(
        color: AppTheme.inkLift,
        child: SizedBox(width: size, height: size, child: child),
      ),
    );
  }
}

class _PlaylistMark extends StatelessWidget {
  const _PlaylistMark({required this.playlist, this.size = 22});

  final Playlist playlist;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (Color background, Color foreground) = switch (playlist.systemKind) {
      Playlist.kindNew => (const Color(0xFFFFDB4D), const Color(0xFF141414)),
      Playlist.kindIncomplete => (AppTheme.lime, const Color(0xFF141414)),
      Playlist.kindNoProducer => (AppTheme.mossBright, const Color(0xFF141414)),
      Playlist.kindMissingGenre => (
        const Color(0xFFFFDB4D),
        const Color(0xFF141414),
      ),
      Playlist.kindMissingLyrics => (
        AppTheme.mossBright,
        const Color(0xFF141414),
      ),
      Playlist.kindMetadataReady => (AppTheme.lime, const Color(0xFF141414)),
      Playlist.kindTrash => (const Color(0xFF3A3330), AppTheme.paper),
      _ => (AppTheme.inkLift, AppTheme.mossBright),
    };
    final cover = playlist.coverPath;
    Widget child = SystemPlaylistIcon(
      kind: playlist.systemKind,
      color: foreground,
      size: size * 0.62,
    );
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      child = fileCover(
        context,
        cover,
        logicalSize: size,
      );
    } else if (!playlist.isSystem) {
      child = PlaylistMosaicLoader(
        playlistId: playlist.id,
        fallback: child,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: ColoredBox(
        color: background,
        child: SizedBox(width: size, height: size, child: child),
      ),
    );
  }
}
