import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';
import '../utils/duration_format.dart';

/// Диалог выбора трека из библиотеки (поиск по каталогу).
Future<Track?> showLibraryTrackPicker(
  BuildContext context, {
  String title = 'Выбрать трек',
}) {
  final library = context.read<LibraryService>();
  final all = library.catalogTracks;
  if (all.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Библиотека пуста — сначала отсканируй музыку',
          style: GoogleFonts.figtree(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.inkLift,
      ),
    );
    return Future.value(null);
  }

  return showDialog<Track>(
    context: context,
    builder: (dialogContext) {
      var query = '';
      return StatefulBuilder(
        builder: (context, setLocal) {
          final filtered = [
            for (final t in all)
              if (library.trackMatchesQuery(t, query)) t,
          ];
          return AlertDialog(
            backgroundColor: AppTheme.inkLift,
            title: Text(
              title,
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: SizedBox(
              width: 520,
              height: 460,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    style: GoogleFonts.figtree(color: AppTheme.paper),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: AppTheme.paperMuted,
                      ),
                      hintText: 'Поиск в библиотеке',
                      hintStyle: GoogleFonts.figtree(
                        color: AppTheme.paperMuted,
                      ),
                      filled: true,
                      fillColor: AppTheme.ink,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (v) => setLocal(() => query = v),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              'Ничего не найдено',
                              style: GoogleFonts.figtree(
                                color: AppTheme.paperMuted,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final t = filtered[index];
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () =>
                                      Navigator.pop(dialogContext, t),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                t.displayTitle,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: GoogleFonts.figtree(
                                                  color: AppTheme.paper,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 15,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                t.displayArtist,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: GoogleFonts.figtree(
                                                  color: AppTheme.paperMuted,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          formatTrackDuration(t.durationMs),
                                          style: GoogleFonts.figtree(
                                            color: AppTheme.paperMuted,
                                            fontSize: 13,
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
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(
                  'Отмена',
                  style: GoogleFonts.figtree(
                    color: AppTheme.paperMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
