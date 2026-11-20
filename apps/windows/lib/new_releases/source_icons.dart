import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';
import 'models.dart';

class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.source, this.size = 22});

  final ReleaseSource source;
  final double size;

  String get _asset => switch (source) {
        ReleaseSource.spotify => 'assets/source_spotify.svg',
        ReleaseSource.yandex => 'assets/source_yandex_music.svg',
      };

  String get _label => switch (source) {
        ReleaseSource.spotify => 'Spotify',
        ReleaseSource.yandex => 'Яндекс Музыка',
      };

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _label,
      waitDuration: const Duration(milliseconds: 350),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
            BoxShadow(
              color: AppTheme.ink.withValues(alpha: 0.25),
              blurRadius: 2,
              spreadRadius: 0.5,
            ),
          ],
        ),
        child: SvgPicture.asset(
          _asset,
          width: size,
          height: size,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
