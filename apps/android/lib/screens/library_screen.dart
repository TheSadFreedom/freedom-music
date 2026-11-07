import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../services/library_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../widgets/kept_icons.dart';
import 'artists_screen.dart';
import 'calendar_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    final hPad = phone ? 16.0 : 24.0;
    final library = context.watch<LibraryService>();
    final tracks = library.tracks.length;
    final artists = library.tracksByArtist().length;
    final producers = library.tracksByProducer().length;

    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, phone ? 10 : 14, hPad, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Библиотека',
                  style: GoogleFonts.syne(
                    color: AppTheme.paper,
                    fontSize: phone ? 34 : 40,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                    letterSpacing: -1.0,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Настройки',
                onPressed: () => _open(context, const SettingsScreen()),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                style: IconButton.styleFrom(
                  foregroundColor: AppTheme.paperMuted.withValues(alpha: 0.7),
                ),
                icon: const Icon(Icons.settings_outlined, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tracks == 0
                ? 'Твоя коллекция локальных треков'
                : _tracksLabel(tracks),
            style: GoogleFonts.figtree(
              color: AppTheme.paperMuted,
              fontSize: 14,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 22),
          Expanded(
            flex: 7,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _RoomTile(
                    title: 'Артисты',
                    subtitle: artists == 0
                        ? 'Исполнители'
                        : _countLabel(
                            artists,
                            one: 'артист',
                            few: 'артиста',
                            many: 'артистов',
                          ),
                    icon: const Icon(Icons.person_rounded),
                    colors: const [
                      Color(0xFF1A2A38),
                      Color(0xFF15201C),
                    ],
                    glow: const Color(0xFF8BB8D4),
                    onTap: () => _open(context, const ArtistsScreen()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _RoomTile(
                    title: 'Продюсеры',
                    subtitle: producers == 0
                        ? 'Битмейкеры'
                        : _countLabel(
                            producers,
                            one: 'продюсер',
                            few: 'продюсера',
                            many: 'продюсеров',
                          ),
                    icon: const HeadphonesGlyph(),
                    colors: const [
                      Color(0xFF1A3020),
                      Color(0xFF15201C),
                    ],
                    glow: const Color(0xFFA8D080),
                    onTap: () => _open(
                      context,
                      const ArtistsScreen(producers: true),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 4,
            child: _LaneTile(
              title: 'Календарь',
              subtitle: 'История релизов по датам',
              icon: const CalendarMonthGlyph(),
              colors: const [
                Color(0xFF182830),
                Color(0xFF15201C),
              ],
              glow: const Color(0xFF7EC8A3),
              onTap: () => _open(context, const CalendarScreen()),
            ),
          ),
        ],
      ),
    );
  }

  String _tracksLabel(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    final word = (mod10 == 1 && mod100 != 11)
        ? 'трек'
        : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
            ? 'трека'
            : 'треков';
    return '$n $word в коллекции';
  }

  String _countLabel(
    int n, {
    required String one,
    required String few,
    required String many,
  }) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    final word = (mod10 == 1 && mod100 != 11)
        ? one
        : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
            ? few
            : many;
    return '$n $word';
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.colors,
    required this.glow,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget icon;
  final List<Color> colors;
  final Color glow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  right: -28,
                  top: -36,
                  child: Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: glow.withValues(alpha: 0.14),
                    ),
                  ),
                ),
                Positioned(
                  left: -16,
                  bottom: -28,
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.mossBright.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: glow.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: IconTheme(
                          data: IconThemeData(color: glow, size: 24),
                          child: icon,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        title,
                        style: GoogleFonts.syne(
                          color: AppTheme.paper,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          height: 1.05,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.figtree(
                          color: AppTheme.paperMuted,
                          fontSize: 13,
                          height: 1.25,
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
    );
  }
}

class _LaneTile extends StatelessWidget {
  const _LaneTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.colors,
    required this.glow,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget icon;
  final List<Color> colors;
  final Color glow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: colors,
            ),
            border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  right: -20,
                  top: -30,
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: glow.withValues(alpha: 0.12),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: glow.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: IconTheme(
                          data: IconThemeData(color: glow, size: 26),
                          child: icon,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              title,
                              style: GoogleFonts.syne(
                                color: AppTheme.paper,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                height: 1.05,
                                letterSpacing: -0.4,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.figtree(
                                color: AppTheme.paperMuted,
                                fontSize: 13,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: AppTheme.paperMuted.withValues(alpha: 0.55),
                      ),
                    ],
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
