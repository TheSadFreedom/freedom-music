import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../navigation/app_navigator.dart';
import '../services/library_service.dart';
import '../services/metadata_writer.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../widgets/lyrics_view.dart';

/// Pick a new audio file and replace the track's file on disk.
Future<void> replaceTrackAudio(BuildContext context, Track track) async {
  dismissLyrics(context);
  context = navigatorContext(context);
  if (track.primaryPath == null) return;

  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg'],
    allowMultiple: false,
  );
  if (!context.mounted) return;
  if (result == null || result.files.isEmpty) return;
  final path = result.files.first.path;
  if (path == null || path.isEmpty) return;

  final library = context.read<LibraryService>();
  final player = context.read<PlayerService>();
  final messenger = ScaffoldMessenger.of(context);

  try {
    final oldKey = track.trackKey;
    final oldPaths = List<String>.from(track.filePaths);
    final updated = await library.replaceTrackAudioFile(track, path);
    await player.syncTrackAfterFileReplace(updated, oldTrackKey: oldKey);
    await MetadataWriter.deleteReplacedAudioFiles(
      oldPaths: oldPaths,
      keepPaths: updated.filePaths,
    );
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Файл заменён',
          style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.inkLift,
        duration: const Duration(seconds: 2),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Не удалось заменить файл: $e',
          style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF3A1A1C),
        duration: const Duration(seconds: 4),
      ),
    );
  }
}
