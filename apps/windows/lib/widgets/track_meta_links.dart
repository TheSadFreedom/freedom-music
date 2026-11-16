import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../navigation/library_navigation.dart';
import '../services/library_service.dart';
import 'track_title_line.dart';

/// Title → album page, artist → artist page.
class TrackMetaLinks extends StatelessWidget {
  const TrackMetaLinks({
    super.key,
    required this.track,
    this.titleStyle,
    this.artistStyle,
    this.showArtist = true,
    this.maxTitleLines = 1,
    this.maxArtistLines = 1,
  });

  final Track track;
  final TextStyle? titleStyle;
  final TextStyle? artistStyle;
  final bool showArtist;
  final int maxTitleLines;
  final int maxArtistLines;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final live = library.resolveTrack(track);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TrackTitleLine(
          title: live.displayTitle,
          note: live.displayNote,
          verified: live.verified,
          style: titleStyle,
          maxLines: maxTitleLines,
          onTap: () => openAlbumForTrack(context, live),
        ),
        if (showArtist) ...[
          const SizedBox(height: 2),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openArtistFromTrack(context, live),
              child: Text(
                live.displayArtist,
                maxLines: maxArtistLines,
                overflow: TextOverflow.ellipsis,
                style: artistStyle,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
