import 'package:flutter/material.dart';

/// Each icon is returned by its own [build]. A switch or a field drops the
/// glyph from the release font.

class FolderOpenGlyph extends StatelessWidget {
  const FolderOpenGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.folder_open_rounded);
  }
}

class FiberNewGlyph extends StatelessWidget {
  const FiberNewGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.fiber_new_rounded);
  }
}

class ManageSearchGlyph extends StatelessWidget {
  const ManageSearchGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.manage_search_rounded);
  }
}

class TravelExploreGlyph extends StatelessWidget {
  const TravelExploreGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.travel_explore_rounded);
  }
}

class HeadphonesGlyph extends StatelessWidget {
  const HeadphonesGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.headphones_rounded);
  }
}

class LyricsGlyph extends StatelessWidget {
  const LyricsGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.lyrics_outlined);
  }
}

class EditGlyph extends StatelessWidget {
  const EditGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.edit_outlined);
  }
}

class FacePhotoGlyph extends StatelessWidget {
  const FacePhotoGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.face_retouching_natural_rounded);
  }
}

class UploadGlyph extends StatelessWidget {
  const UploadGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.upload_rounded);
  }
}

class DownloadGlyph extends StatelessWidget {
  const DownloadGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.download_rounded);
  }
}

class RestartGlyph extends StatelessWidget {
  const RestartGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.restart_alt_rounded);
  }
}

class ArticleGlyph extends StatelessWidget {
  const ArticleGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.article_outlined);
  }
}

class SellGlyph extends StatelessWidget {
  const SellGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.sell_outlined);
  }
}

class TaskAltGlyph extends StatelessWidget {
  const TaskAltGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.task_alt_rounded);
  }
}

class DeleteOutlineRoundedGlyph extends StatelessWidget {
  const DeleteOutlineRoundedGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.delete_outline_rounded);
  }
}

class CalendarMonthGlyph extends StatelessWidget {
  const CalendarMonthGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.calendar_month_outlined);
  }
}

/// Drawn people mark. Material `groups` / `people` codepoints come out blank
/// in the Windows release icon font (same class of bug as repeat).
class GroupsGlyph extends StatelessWidget {
  const GroupsGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 24;
    final color = theme.color ?? const Color(0xFF9AA89A);
    return CustomPaint(
      size: Size.square(size),
      painter: _GroupsGlyphPainter(color: color),
    );
  }
}

class _GroupsGlyphPainter extends CustomPainter {
  const _GroupsGlyphPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);

    // Back person (left).
    canvas.drawCircle(const Offset(8.2, 7.2), 3.1, paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3.4, 11.2, 9.6, 8.4),
        const Radius.circular(4.2),
      ),
      paint,
    );

    // Front person (right).
    canvas.drawCircle(const Offset(15.8, 7.2), 3.1, paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(11.0, 11.2, 9.6, 8.4),
        const Radius.circular(4.2),
      ),
      paint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GroupsGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

class QueueMusicGlyph extends StatelessWidget {
  const QueueMusicGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.queue_music);
  }
}

class EqualizerGlyph extends StatelessWidget {
  const EqualizerGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.equalizer_rounded);
  }
}

class DriveFileMoveGlyph extends StatelessWidget {
  const DriveFileMoveGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.drive_file_move_outlined);
  }
}

class CloudOutlinedGlyph extends StatelessWidget {
  const CloudOutlinedGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.cloud_outlined);
  }
}

class VerifiedCheckGlyph extends StatelessWidget {
  const VerifiedCheckGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.check_rounded);
  }
}

class UnverifiedGlyph extends StatelessWidget {
  const UnverifiedGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.radio_button_unchecked_rounded);
  }
}
