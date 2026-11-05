import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../services/library_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../widgets/kept_icons.dart';
import 'artists_screen.dart';
import 'calendar_screen.dart';
import 'chart_screen.dart';
import 'playlists_screen.dart';

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
    final tracks = context.select<LibraryService, int>((l) => l.tracks.length);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad, phone ? 10 : 14, hPad, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Библиотека',
                  style: GoogleFonts.syne(
                    color: AppTheme.paper,
                    fontSize: phone ? 34 : 40,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                    letterSpacing: -1.0,
                  ),
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
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad, 22, hPad, 0),
            child: _FeaturePane(
              title: 'Плейлисты',
              subtitle: 'Свои и системные подборки',
              icon: const QueueMusicGlyph(),
              colors: const [
                Color(0xFF2A1A38),
                Color(0xFF1A2822),
                Color(0xFF15201C),
              ],
              glow: const Color(0xFFB8A0E8),
              onTap: () => _open(context, const PlaylistsScreen()),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 28),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.92,
            ),
            delegate: SliverChildListDelegate([
              _RoomTile(
                title: 'Артисты',
                subtitle: 'Исполнители',
                icon: const Icon(Icons.person_rounded),
                colors: const [Color(0xFF1A2A38), Color(0xFF15201C)],
                glow: const Color(0xFF8BB8D4),
                onTap: () => _open(context, const ArtistsScreen()),
              ),
              _RoomTile(
                title: 'Продюсеры',
                subtitle: 'Битмейкеры',
                icon: const HeadphonesGlyph(),
                colors: const [Color(0xFF1A3020), Color(0xFF15201C)],
                glow: const Color(0xFFA8D080),
                onTap: () =>
                    _open(context, const ArtistsScreen(producers: true)),
              ),
              _RoomTile(
                title: 'Чарт',
                subtitle: 'Топ прослушиваний',
                icon: const Icon(Icons.graphic_eq_rounded),
                colors: const [Color(0xFF302418), Color(0xFF15201C)],
                glow: const Color(0xFFE8C96A),
                onTap: () => _open(context, const ChartScreen()),
              ),
              _RoomTile(
                title: 'Календарь',
                subtitle: 'История дней',
                icon: const CalendarMonthGlyph(),
                colors: const [Color(0xFF182830), Color(0xFF15201C)],
                glow: const Color(0xFF7EC8A3),
                onTap: () => _open(context, const CalendarScreen()),
              ),
            ]),
          ),
        ),
      ],
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
}

class _FeaturePane extends StatelessWidget {
  const _FeaturePane({
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
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          height: 148,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            border: Border.all(color: AppTheme.paper.withValues(alpha: 0.06)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Stack(
              children: [
                Positioned(
                  right: -36,
                  top: -48,
                  child: Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: glow.withValues(alpha: 0.14),
                    ),
                  ),
                ),
                Positioned(
                  left: -20,
                  bottom: -40,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.mossBright.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                Positioned(
                  right: 18,
                  bottom: 16,
                  child: IconTheme(
                    data: IconThemeData(
                      color: glow.withValues(alpha: 0.55),
                      size: 72,
                    ),
                    child: icon,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: glow.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'СЛУШАТЬ',
                          style: GoogleFonts.figtree(
                            color: glow,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        title,
                        style: GoogleFonts.syne(
                          color: AppTheme.paper,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                          letterSpacing: -0.6,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
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
            border: Border.all(color: AppTheme.paper.withValues(alpha: 0.05)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              children: [
                Positioned(
                  right: -24,
                  top: -28,
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: glow.withValues(alpha: 0.14),
                    ),
                  ),
                ),
                Positioned(
                  left: -16,
                  bottom: -24,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: glow.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: glow.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        alignment: Alignment.center,
                        child: IconTheme(
                          data: IconThemeData(color: glow, size: 22),
                          child: icon,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        title,
                        style: GoogleFonts.syne(
                          color: AppTheme.paper,
                          fontSize: 20,
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
                          fontSize: 12.5,
                          height: 1.2,
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
