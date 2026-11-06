import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import 'player_expansion.dart';

/// Compact pill mini-player above the bottom navigation.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, this.barKey});

  final GlobalKey? barKey;

  void _openFull(BuildContext context) {
    context.read<PlayerExpansion>().open();
  }

  @override
  Widget build(BuildContext context) {
    final track = context.select<PlayerService, Track?>((p) => p.current);
    final playing = context.select<PlayerService, bool>((p) => p.playing);
    if (track == null) return const SizedBox.shrink();

    final player = context.read<PlayerService>();

    return Material(
      color: Colors.transparent,
      child: Padding(
        key: barKey,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Material(
          color: const Color(0xF71A1A1A),
          elevation: 14,
          shadowColor: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _openFull(context),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                      child: Row(
                        children: [
                          _Cover(path: track.coverPath),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  track.displayTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.figtree(
                                    color: AppTheme.paper,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                    height: 1.15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  track.displayArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.figtree(
                                    color: AppTheme.paperMuted,
                                    fontWeight: FontWeight.w500,
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
                _Ctrl(
                  icon: Icons.skip_previous_rounded,
                  onPressed: player.previous,
                ),
                _Play(
                  playing: playing,
                  onPressed: player.togglePlayPause,
                ),
                _Ctrl(
                  icon: Icons.skip_next_rounded,
                  onPressed: player.next,
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final filePath = path;
    final has = filePath != null && File(filePath).existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 46,
        height: 46,
        child: has
            ? Image.file(
                File(filePath),
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            : ColoredBox(
                color: AppTheme.ink,
                child: Icon(
                  Icons.album,
                  color: AppTheme.paperMuted,
                  size: 22,
                ),
              ),
      ),
    );
  }
}

class _Ctrl extends StatelessWidget {
  const _Ctrl({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
      icon: Icon(icon, color: AppTheme.paper, size: 26),
    );
  }
}

class _Play extends StatelessWidget {
  const _Play({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.lime,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: AppTheme.ink,
            size: 24,
          ),
        ),
      ),
    );
  }
}
