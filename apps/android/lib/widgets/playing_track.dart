import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/player_service.dart';
import '../theme/app_theme.dart';

/// Выделение текущего трека в списках — как в очереди плеера.
abstract final class PlayingTrack {
  static const accent = Color(0xFFFFDB4D);

  static bool watch(BuildContext context, String trackKey) {
    return context.select<PlayerService, bool>(
      (p) => p.current?.trackKey == trackKey,
    );
  }

  static Color surface(bool playing) =>
      playing ? AppTheme.inkLift : Colors.transparent;

  static Color titleColor(bool playing) =>
      playing ? accent : AppTheme.paper;

  static FontWeight titleWeight(bool playing) =>
      playing ? FontWeight.w700 : FontWeight.w600;
}
