import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../navigation/app_navigator.dart';
import '../navigation/library_navigation.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../utils/duration_format.dart';
import '../utils/lyrics_format.dart';
import '../screens/metadata_editor_screen.dart';
import '../utils/playlist_actions.dart';
import 'app_bottom_sheet.dart';
import 'cover_image.dart';
import 'equalizer_panel.dart';
import 'kept_icons.dart';
import 'lyrics_view.dart';
import 'player_expansion.dart';
import 'track_overflow_menu.dart';
import 'track_title_line.dart';

const _kYellow = Color(0xFFFFDB4D);
const _kSurface = Color(0xFF0A0A0A);
const _kChip = Color(0xFF2A2A2A);
const _kIcon = Color(0xFFE8E4DC);
const _kMuted = Color(0xFF8E8A82);

class FullPlayer extends StatefulWidget {
  const FullPlayer({super.key});

  @override
  State<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<FullPlayer> {
  bool _showLyrics = false;
  bool _showEqualizer = false;
  bool _showQueue = false;
  bool _showMetadata = false;
  double _dragOffset = 0;
  PlayerExpansion? _expansion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final expansion = context.read<PlayerExpansion>();
    if (!identical(_expansion, expansion)) {
      _expansion?.setBackHandler(null);
      _expansion = expansion;
      _expansion!.setBackHandler(_back);
    }
  }

  @override
  void dispose() {
    _expansion?.setBackHandler(null);
    super.dispose();
  }

  void _close() => (_expansion ?? context.read<PlayerExpansion>()).close();

  bool get _showingPanel =>
      _showQueue || _showLyrics || _showEqualizer || _showMetadata;

  bool get _hideTransport => _showEqualizer || _showMetadata;

  void _dismissPanel() {
    if (!_showingPanel) return;
    setState(() {
      _showQueue = false;
      _showLyrics = false;
      _showEqualizer = false;
      _showMetadata = false;
    });
  }

  void _openMetadata() {
    setState(() {
      _showQueue = false;
      _showLyrics = false;
      _showEqualizer = false;
      _showMetadata = true;
    });
  }

  void _back() {
    if (_showingPanel) {
      _dismissPanel();
      return;
    }
    _close();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (d.delta.dy <= 0 && _dragOffset <= 0) return;
    setState(() => _dragOffset = (_dragOffset + d.delta.dy).clamp(0.0, 320.0));
  }

  void _onDragEnd(DragEndDetails d) {
    final shouldClose =
        _dragOffset > 120 || (d.primaryVelocity ?? 0) > 900;
    if (shouldClose) {
      if (_showingPanel) {
        setState(() {
          _dragOffset = 0;
          _showQueue = false;
          _showLyrics = false;
          _showEqualizer = false;
          _showMetadata = false;
        });
      } else {
        _close();
      }
    } else {
      setState(() => _dragOffset = 0);
    }
  }

  void _onHorizontalSkip(DragEndDetails d) {
    if (_showingPanel) return;
    final v = d.primaryVelocity ?? 0;
    if (v <= -350) {
      context.read<PlayerService>().next();
    } else if (v >= 350) {
      context.read<PlayerService>().previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = context.select<PlayerService, Track?>((p) => p.current);
    final playing = context.select<PlayerService, bool>((p) => p.playing);
    final shuffle = context.select<PlayerService, bool>((p) => p.shuffle);
    final repeat =
        context.select<PlayerService, PlayRepeatMode>((p) => p.repeat);
    final player = context.read<PlayerService>();
    final library = context.watch<LibraryService>();
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final size = MediaQuery.sizeOf(context);

    if (track == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _close();
      });
      return const SizedBox.shrink();
    }

    final lyricsSource = library.resolveTrack(track);
    final lyricsText = formatLyrics(lyricsSource.lyrics);
    final lyricsFetching = library.isFetchingLyrics(track.trackKey);
    final artistName = track.artists.isNotEmpty
        ? track.artists.first
        : track.displayArtist;
    final artistPhoto = library.artistPhotoPath(artistName);
    final coverSide = (size.width - 48).clamp(260.0, 420.0);
    final showingPanel = _showingPanel;
    final headerTitle = showingPanel
        ? (_showMetadata
            ? 'Метаданные'
            : _showEqualizer
                ? 'Эквалайзер'
                : _showLyrics
                    ? 'Текст'
                    : 'Очередь')
        : (track.displayAlbum.isNotEmpty &&
                track.displayAlbum.toLowerCase() != 'unknown'
            ? track.displayAlbum
            : 'Сейчас играет');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Material(
        color: _kSurface,
        child: GestureDetector(
          onHorizontalDragEnd: _onHorizontalSkip,
          child: Transform.translate(
            offset: Offset(0, _dragOffset),
            child: Opacity(
              opacity: (1 - _dragOffset / 320).clamp(0.35, 1.0),
              child: Stack(
                fit: StackFit.expand,
              children: [
                if (track.coverPath != null &&
                    File(track.coverPath!).existsSync())
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.18,
                      child: ImageFiltered(
                        imageFilter:
                            ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                        child: fileCover(
                          context,
                          track.coverPath!,
                          logicalSize: 240,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      if (showingPanel)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragUpdate: _onDragUpdate,
                          onVerticalDragEnd: _onDragEnd,
                          child: _PlayerHeader(
                            title: headerTitle,
                            showingPanel: true,
                            onBack: _back,
                          ),
                        )
                      else
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragUpdate: _onDragUpdate,
                            onVerticalDragEnd: _onDragEnd,
                            child: Column(
                              children: [
                                _PlayerHeader(
                                  title: headerTitle,
                                  showingPanel: false,
                                  onBack: _back,
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      24,
                                      12,
                                      24,
                                      0,
                                    ),
                                    child: Column(
                                      children: [
                                        Expanded(
                                          child: Center(
                                            child: _CoverHero(
                                              path: track.coverPath,
                                              side: coverSide,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 20),
                                        _MetaRow(
                                          track: track,
                                          artistName: artistName,
                                          artistPhoto: artistPhoto,
                                          onArtist: () {
                                            _close();
                                            openArtistFromTrack(
                                              context,
                                              track,
                                            );
                                          },
                                          onTitle: () {
                                            _close();
                                            openAlbumForTrack(
                                              context,
                                              track,
                                            );
                                          },
                                          onEqualizer: () {
                                            setState(() {
                                              _showQueue = false;
                                              _showLyrics = false;
                                              _showMetadata = false;
                                              _showEqualizer = true;
                                            });
                                          },
                                          onMetadata: _openMetadata,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (showingPanel)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              8,
                              8,
                              8,
                              _hideTransport ? bottomInset : 0,
                            ),
                            child: _showMetadata
                                ? MetadataEditorScreen(
                                    key: ValueKey(
                                      'meta:${track.trackKey}',
                                    ),
                                    track: track,
                                    embedded: true,
                                    onClosed: (_) => _dismissPanel(),
                                  )
                                : _showQueue
                                    ? _QueuePane(
                                        queue: player.queue,
                                        currentKey: track.trackKey,
                                        onSelect: (i) {
                                          player.playQueueIndex(i);
                                          setState(() => _showQueue = false);
                                        },
                                      )
                                    : _showLyrics
                                        ? _LyricsPane(
                                            title: track.displayTitle,
                                            note: track.displayNote,
                                            raw: lyricsSource.lyrics,
                                            fetching: lyricsFetching,
                                            empty: lyricsText.isEmpty,
                                          )
                                        : const EqualizerPanel(),
                          ),
                        ),
                      if (!_hideTransport)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            20,
                            10,
                            20,
                            28 + bottomInset,
                          ),
                          child: Column(
                            children: [
                              const _FullProgress(),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  _TransportIcon(
                                    icon: Icons.queue_music_rounded,
                                    active: _showQueue,
                                    onPressed: () {
                                      setState(() {
                                        _showLyrics = false;
                                        _showEqualizer = false;
                                        _showMetadata = false;
                                        _showQueue = !_showQueue;
                                      });
                                    },
                                  ),
                                  const Spacer(),
                                  _TransportIcon(
                                    icon: Icons.skip_previous_rounded,
                                    size: 36,
                                    onPressed: player.previous,
                                  ),
                                  const SizedBox(width: 18),
                                  _PlayBig(
                                    playing: playing,
                                    onPressed: player.togglePlayPause,
                                  ),
                                  const SizedBox(width: 18),
                                  _TransportIcon(
                                    icon: Icons.skip_next_rounded,
                                    size: 36,
                                    onPressed: player.next,
                                  ),
                                  const Spacer(),
                                  _TransportIcon(
                                    icon: Icons.playlist_add_rounded,
                                    onPressed: () =>
                                        addTrackToPlaylist(context, track),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _PillButton(
                                    icon: Icons.repeat_rounded,
                                    mark: repeat == PlayRepeatMode.one
                                        ? const Icon(
                                            Icons.repeat_one_rounded,
                                          )
                                        : null,
                                    active: repeat != PlayRepeatMode.off,
                                    onPressed: player.cycleRepeat,
                                  ),
                                  const SizedBox(width: 14),
                                  _PillButton(
                                    icon: Icons.lyrics_outlined,
                                    mark: const LyricsGlyph(),
                                    active: _showLyrics,
                                    onPressed: () {
                                      final opening = !_showLyrics;
                                      setState(() {
                                        _showQueue = false;
                                        _showEqualizer = false;
                                        _showMetadata = false;
                                        _showLyrics = opening;
                                      });
                                      if (opening && lyricsText.isEmpty) {
                                        library
                                            .ensureRemoteLyrics(lyricsSource)
                                            .then((updated) {
                                          if (updated != null) {
                                            player.syncTrack(updated);
                                          }
                                        });
                                      }
                                    },
                                  ),
                                  const SizedBox(width: 14),
                                  _PillButton(
                                    icon: Icons.shuffle_rounded,
                                    active: shuffle,
                                    onPressed: player.toggleShuffle,
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

class _PlayerHeader extends StatelessWidget {
  const _PlayerHeader({
    required this.title,
    required this.showingPanel,
    required this.onBack,
  });

  final String title;
  final bool showingPanel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: showingPanel ? 'Назад' : 'Свернуть',
            onPressed: onBack,
            icon: Icon(
              showingPanel
                  ? Icons.arrow_back_rounded
                  : Icons.keyboard_arrow_down_rounded,
              color: _kIcon,
              size: showingPanel ? 24 : 30,
            ),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.figtree(
                color: _kIcon,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.track,
    required this.artistName,
    required this.artistPhoto,
    required this.onArtist,
    required this.onTitle,
    required this.onEqualizer,
    required this.onMetadata,
  });

  final Track track;
  final String artistName;
  final String? artistPhoto;
  final VoidCallback onArtist;
  final VoidCallback onTitle;
  final VoidCallback onEqualizer;
  final VoidCallback onMetadata;

  @override
  Widget build(BuildContext context) {
    final photo = artistPhoto;
    final hasPhoto = photo != null && File(photo).existsSync();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: onArtist,
          child: CircleAvatar(
            radius: 22,
            backgroundColor: _kChip,
            backgroundImage: hasPhoto ? FileImage(File(photo)) : null,
            child: hasPhoto
                ? null
                : Text(
                    artistName.isNotEmpty ? artistName[0].toUpperCase() : '?',
                    style: GoogleFonts.syne(
                      color: _kIcon,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TrackTitleLine(
                title: track.displayTitle,
                note: track.displayNote,
                maxLines: 1,
                onTap: onTitle,
                style: GoogleFonts.figtree(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 3),
              GestureDetector(
                onTap: onArtist,
                child: Text(
                  track.displayArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.figtree(
                    color: _kMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        _PlayerMoreMenu(
          track: track,
          onEqualizer: onEqualizer,
          onMetadata: onMetadata,
        ),
      ],
    );
  }
}

class _PlayerMoreMenu extends StatelessWidget {
  const _PlayerMoreMenu({
    required this.track,
    required this.onEqualizer,
    required this.onMetadata,
  });

  final Track track;
  final VoidCallback onEqualizer;
  final VoidCallback onMetadata;

  Future<void> _open(BuildContext context) async {
    final navCtx = navigatorContext(context);
    final expansion = context.read<PlayerExpansion>();
    final actions = standardTrackActions(
      navCtx,
      track,
      copyTitle: true,
      playlist: false,
    );

    await showAppBottomSheet<void>(
      context: context,
      title: 'Ещё',
      buildChildren: (sheetCtx) => [
        SheetRow(
          title: 'Эквалайзер',
          subtitle: 'Настройка звука',
          leadingIcon: Icons.equalizer_rounded,
          leadingAccent: true,
          showChevron: false,
          onTap: () {
            popAppSheet(sheetCtx);
            onEqualizer();
          },
        ),
        for (final action in actions)
          SheetRow(
            title: action.label,
            subtitle: switch (action.label) {
              'Метаданные' => 'Редактировать теги',
              'Копировать название' => 'В буфер обмена',
              'В корзину' => 'Убрать из библиотеки',
              _ => null,
            },
            leadingIcon: action.icon,
            destructive: action.destructive,
            showChevron: false,
            onTap: () {
              popAppSheet(sheetCtx);
              if (action.label == 'Метаданные') {
                onMetadata();
                return;
              }
              if (action.label == 'Копировать название') {
                action.onSelected();
                return;
              }
              expansion.close();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                action.onSelected();
              });
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Ещё',
      onPressed: () => _open(context),
      icon: const Icon(Icons.more_vert_rounded, color: _kIcon),
    );
  }
}

class _CoverHero extends StatelessWidget {
  const _CoverHero({required this.path, required this.side});

  final String? path;
  final double side;

  @override
  Widget build(BuildContext context) {
    final filePath = path;
    final has = filePath != null && File(filePath).existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: side,
        height: side,
        child: has
            ? fileCover(context, filePath, logicalSize: side)
            : const ColoredBox(
                color: Color(0xFF1A1A1A),
                child: Icon(Icons.album, color: _kMuted, size: 72),
              ),
      ),
    );
  }
}

class _FullProgress extends StatelessWidget {
  const _FullProgress();

  @override
  Widget build(BuildContext context) {
    final position = context.select<PlayerService, Duration>((p) => p.position);
    final duration =
        context.select<PlayerService, Duration?>((p) => p.duration);
    final player = context.read<PlayerService>();
    final total = duration?.inMilliseconds ?? 0;
    final value = total <= 0
        ? 0.0
        : (position.inMilliseconds / total).clamp(0.0, 1.0);

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
            thumbColor: Colors.white,
            overlayColor: Colors.white.withValues(alpha: 0.12),
          ),
          child: Slider(
            value: value,
            onChanged: total <= 0
                ? null
                : (v) {
                    player.seek(
                      Duration(milliseconds: (total * v).round()),
                    );
                  },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Text(
                formatTrackDuration(position.inMilliseconds),
                style: GoogleFonts.figtree(
                  color: _kMuted,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              Text(
                formatTrackDuration(total > 0 ? total : null),
                style: GoogleFonts.figtree(
                  color: _kMuted,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlayBig extends StatelessWidget {
  const _PlayBig({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _kYellow,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 68,
          height: 68,
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Colors.black,
            size: 38,
          ),
        ),
      ),
    );
  }
}

class _TransportIcon extends StatelessWidget {
  const _TransportIcon({
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.size = 26,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(
        icon,
        color: active ? _kYellow : _kIcon,
        size: size,
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.onPressed,
    this.mark,
    this.active = false,
  });

  final IconData icon;
  final Widget? mark;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? _kYellow : _kIcon;
    return Material(
      color: _kChip,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: mark == null
                ? Icon(icon, color: color, size: 22)
                : IconTheme(
                    data: IconThemeData(color: color, size: 22),
                    child: mark!,
                  ),
          ),
        ),
      ),
    );
  }
}

class _QueuePane extends StatelessWidget {
  const _QueuePane({
    required this.queue,
    required this.currentKey,
    required this.onSelect,
  });

  final List<Track> queue;
  final String currentKey;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'Очередь',
            style: GoogleFonts.syne(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            itemCount: queue.length,
            itemBuilder: (context, index) {
              final t = queue[index];
              final active = t.trackKey == currentKey;
              return Material(
                color: active
                    ? AppTheme.moss.withValues(alpha: 0.22)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelect(index),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.figtree(
                              color: active ? _kYellow : _kMuted,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _QueueCover(path: t.coverPath, active: active),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.figtree(
                                  color: active ? _kYellow : Colors.white,
                                  fontWeight: active
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                t.displayArtist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.figtree(
                                  color: _kMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _QueueCover extends StatelessWidget {
  const _QueueCover({required this.path, required this.active});

  final String? path;
  final bool active;

  static const _size = 48.0;

  @override
  Widget build(BuildContext context) {
    final filePath = path;
    final has = filePath != null && File(filePath).existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: _size,
        height: _size,
        child: has
            ? fileCover(context, filePath, logicalSize: _size)
            : ColoredBox(
                color: _kChip,
                child: Icon(
                  Icons.album_rounded,
                  color: active ? _kYellow : _kMuted,
                  size: 22,
                ),
              ),
      ),
    );
  }
}

class _LyricsPane extends StatelessWidget {
  const _LyricsPane({
    required this.title,
    required this.note,
    required this.raw,
    required this.fetching,
    required this.empty,
  });

  final String title;
  final String? note;
  final String? raw;
  final bool fetching;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final hasText = hasLyrics(raw);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.syne(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (note != null && note!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                note!,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.figtree(color: _kMuted),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: fetching && !hasText
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: _kYellow,
                    ),
                  )
                : empty && !hasText
                    ? Center(
                        child: Text(
                          'Текст не найден',
                          style: GoogleFonts.figtree(
                            color: _kMuted,
                            fontSize: 16,
                          ),
                        ),
                      )
                    : SyncedLyricsView(
                        key: ValueKey('lyrics:${raw?.hashCode ?? 0}'),
                        raw: raw,
                      ),
          ),
        ],
      ),
    );
  }
}
