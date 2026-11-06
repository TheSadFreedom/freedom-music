import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../browser/browser_hit.dart';
import '../browser/browser_playlist.dart';
import '../browser/browser_source.dart';
import '../services/browser_import_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../utils/duration_format.dart';
import '../widgets/ambient_backdrop.dart';
import '../widgets/library_track_picker.dart';
import '../widgets/listen_actions.dart';

const _kYellow = Color(0xFFFFDB4D);

class BrowserPlaylistDetailScreen extends StatefulWidget {
  const BrowserPlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.source,
  });

  final BrowserPlaylist playlist;
  final BrowserSource source;

  @override
  State<BrowserPlaylistDetailScreen> createState() =>
      _BrowserPlaylistDetailScreenState();
}

class _BrowserPlaylistDetailScreenState
    extends State<BrowserPlaylistDetailScreen> {
  List<BrowserHit> _hits = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  String? _busyKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _hitKey(BrowserHit hit) => '${hit.sourceId}:${hit.id}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hits = await widget.playlist.load(limit: 100).timeout(
        const Duration(seconds: 45),
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hits = const [];
        _loading = false;
        _error = '$e';
      });
    }
  }

  List<BrowserHit> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _hits;
    return [
      for (final hit in _hits)
        if (hit.title.toLowerCase().contains(q) ||
            hit.artist.toLowerCase().contains(q) ||
            (hit.subtitle?.toLowerCase().contains(q) ?? false))
          hit,
    ];
  }

  Future<void> _preview(BrowserHit hit) async {
    if (_busyKey != null) return;
    final key = _hitKey(hit);
    setState(() => _busyKey = key);
    try {
      final uri = await widget.source.resolveDownload(hit);
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
          HttpHeaders.refererHeader: widget.source.referer,
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Превью: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF5C2B2B),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _download(BrowserHit hit) async {
    if (_busyKey != null) return;
    final key = _hitKey(hit);
    setState(() => _busyKey = key);
    try {
      final library = context.read<LibraryService>();
      final player = context.read<PlayerService>();
      final importer = BrowserImportService(
        paths: library.paths,
        library: library,
      );
      final track = await importer.download(widget.source, hit);
      if (!mounted) return;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Скачивание: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF5C2B2B),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _replace(BrowserHit hit) async {
    if (_busyKey != null) return;
    final target = await showLibraryTrackPicker(
      context,
      title: 'Какой трек заменить?',
    );
    if (target == null || !mounted) return;
    final key = _hitKey(hit);
    setState(() => _busyKey = key);
    try {
      final library = context.read<LibraryService>();
      final player = context.read<PlayerService>();
      final importer = BrowserImportService(
        paths: library.paths,
        library: library,
      );
      final updated = await importer.replaceLibraryTrack(
        source: widget.source,
        hit: hit,
        target: target,
        player: player,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Заменено: ${updated.displayTitle}',
            style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.inkLift,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Замена: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF5C2B2B),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pl = widget.playlist;
    final filtered = _filtered;
    final wide = MediaQuery.sizeOf(context).width >= 720;

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
              pl.title,
              style: GoogleFonts.syne(fontWeight: FontWeight.w700),
            ),
          ),
          SliverToBoxAdapter(
            child: _Header(
              playlist: pl,
              trackCount: _hits.length,
              loading: _loading,
              wide: wide,
              onListen: _hits.isEmpty || _busyKey != null
                  ? null
                  : () => _preview(_hits.first),
              onShuffle: _hits.isEmpty || _busyKey != null
                  ? null
                  : () => _preview(_hits[Random().nextInt(_hits.length)]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: GoogleFonts.figtree(color: AppTheme.paper),
                decoration: InputDecoration(
                  hintText: 'Поиск трека',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: AppTheme.inkLift,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.figtree(color: const Color(0xFFFF8A80)),
                  ),
                ),
              ),
            )
          else if (_hits.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  'Плейлист пуст.',
                  style: GoogleFonts.figtree(color: AppTheme.paperMuted),
                ),
              ),
            )
          else if (filtered.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  'Ничего не найдено.',
                  style: GoogleFonts.figtree(color: AppTheme.paperMuted),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final hit = filtered[index];
                    final key = _hitKey(hit);
                    final locked = _busyKey != null;
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == filtered.length - 1 ? 0 : 8,
                      ),
                      child: _TrackRow(
                        hit: hit,
                        sourceName: pl.subtitle,
                        busy: _busyKey == key,
                        onPreview: locked ? null : () => _preview(hit),
                        onDownload: locked ? null : () => _download(hit),
                        onReplace: locked ? null : () => _replace(hit),
                      ),
                    );
                  },
                  childCount: filtered.length,
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.playlist,
    required this.trackCount,
    required this.loading,
    required this.wide,
    required this.onListen,
    required this.onShuffle,
  });

  final BrowserPlaylist playlist;
  final int trackCount;
  final bool loading;
  final bool wide;
  final VoidCallback? onListen;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    final cover = Container(
      width: wide ? 200 : 160,
      height: wide ? 200 : 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ColoredBox(
        color: playlist.coverColor,
        child: Center(
          child: playlist.coverLabel != null
              ? Text(
                  playlist.coverLabel!,
                  style: GoogleFonts.syne(
                    color: playlist.coverForeground,
                    fontWeight: FontWeight.w800,
                    fontSize: wide ? 56 : 48,
                    letterSpacing: 1.2,
                  ),
                )
              : Icon(
                  playlist.icon,
                  color: playlist.coverForeground,
                  size: wide ? 72 : 64,
                ),
        ),
      ),
    );

    final info = Column(
      crossAxisAlignment:
          wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          'Онлайн-плейлист',
          style: GoogleFonts.figtree(
            color: AppTheme.paperMuted,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          playlist.title,
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: GoogleFonts.syne(
            color: AppTheme.paper,
            fontSize: wide ? 42 : 30,
            fontWeight: FontWeight.w800,
            height: 1.05,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          playlist.subtitle,
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: GoogleFonts.figtree(
            color: AppTheme.paperMuted,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          loading
              ? 'Загрузка…'
              : '$trackCount треков · ${playlist.subtitle}',
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: GoogleFonts.figtree(
            color: AppTheme.paperMuted.withValues(alpha: 0.8),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 22),
        ListenActions(
          onListen: onListen,
          onShuffle: onShuffle,
          center: !wide,
        ),
      ],
    );

    return SizedBox(
      width: double.infinity,
      child: Stack(
        children: [
          const Positioned.fill(
            child: AmbientBackdrop(
              accent: Color(0xFF5A3A6E),
              secondary: Color(0xFF3D2A5C),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      cover,
                      const SizedBox(width: 28),
                      Expanded(child: info),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      cover,
                      const SizedBox(height: 20),
                      SizedBox(width: double.infinity, child: info),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.hit,
    required this.sourceName,
    required this.busy,
    required this.onPreview,
    required this.onDownload,
    required this.onReplace,
  });

  final BrowserHit hit;
  final String sourceName;
  final bool busy;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onReplace;

  @override
  Widget build(BuildContext context) {
    final duration = hit.duration;
    final meta = [
      if (hit.subtitle != null && hit.subtitle!.isNotEmpty) hit.subtitle!,
      if (duration != null) formatTrackDuration(duration.inMilliseconds),
    ].join(' · ');

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
                onTap: onPreview,
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: _kYellow.withValues(alpha: 0.18),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.music_note_rounded,
                        color: _kYellow,
                        size: 22,
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
                          if (meta.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
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
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
              IconButton(
                tooltip: 'Слушать',
                onPressed: onPreview,
                icon: const Icon(Icons.play_arrow_rounded, color: _kYellow),
              ),
              IconButton(
                tooltip: 'Скачать',
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded, color: _kYellow),
              ),
              IconButton(
                tooltip: 'Заменить',
                onPressed: onReplace,
                icon: Icon(
                  Icons.swap_horiz_rounded,
                  color: AppTheme.paperMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
