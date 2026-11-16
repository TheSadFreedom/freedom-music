import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../navigation/library_navigation.dart';
import '../screens/metadata_editor_screen.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';
import '../utils/duration_format.dart';
import 'playing_track.dart';
import 'track_cover_play.dart';
import 'track_overflow_menu.dart';
import 'track_title_line.dart';

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.trailing,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.enableMetadataEdit = true,
    this.enableTrash = true,
    this.enableLibraryNavigation = true,
    this.showDuration = true,
  });

  final Track track;
  final Widget? trailing;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enableMetadataEdit;
  final bool enableTrash;

  /// Если false — тап по названию/артисту не открывает альбом/артиста
  /// (нужно для диалогов выбора трека).
  final bool enableLibraryNavigation;
  final bool showDuration;

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LibraryService>().resolveTrack(track);
    final playing = PlayingTrack.watch(context, live.trackKey);
    return TrackContextMenu(
      actions: enableMetadataEdit || enableTrash
          ? standardTrackActions(
              context,
              live,
              metadata: enableMetadataEdit,
              replace: enableMetadataEdit,
              deleteForever: enableTrash,
            )
          : const [],
      child: Material(
        color: PlayingTrack.surface(playing),
        child: InkWell(
          mouseCursor: onTap != null || enableMetadataEdit || enableTrash
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onTap: onTap,
          onLongPress:
              onLongPress ??
              (enableMetadataEdit
                  ? () => openMetadataEditor(context, live)
                  : null),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                TrackCoverPlay(path: live.coverPath, onPlay: onTap ?? () {}),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TrackTitleLine(
                        title: live.displayTitle,
                        note: live.displayNote,
                        verified: live.verified,
                        onTap: enableLibraryNavigation
                            ? () => openAlbumForTrack(context, live)
                            : null,
                        style: GoogleFonts.figtree(
                          color: PlayingTrack.titleColor(playing),
                          fontWeight: PlayingTrack.titleWeight(playing),
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.figtree(
                            color: AppTheme.paperMuted,
                            fontSize: 13,
                          ),
                        )
                      else if (!enableLibraryNavigation)
                        Text(
                          live.displayArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.figtree(
                            color: AppTheme.paperMuted,
                            fontSize: 13,
                          ),
                        )
                      else
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => openArtistFromTrack(context, live),
                            child: Text(
                              live.displayArtist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.figtree(
                                color: AppTheme.paperMuted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                if (showDuration) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    child: Text(
                      formatTrackDuration(live.durationMs),
                      textAlign: TextAlign.right,
                      style: GoogleFonts.figtree(
                        color: AppTheme.paperMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
