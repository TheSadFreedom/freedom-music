import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// Brand verified check when [verified] and Settings → «Галочки Verified» is on.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({
    super.key,
    required this.verified,
    this.size = 16,
  });

  final bool verified;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!verified) return const SizedBox.shrink();
    final show = context.select<SettingsService, bool>(
      (s) => s.showVerifiedBadges,
    );
    if (!show) return const SizedBox.shrink();

    return Tooltip(
      message: 'Проверенный',
      waitDuration: const Duration(milliseconds: 400),
      child: SvgPicture.asset(
        'assets/verified_check.svg',
        width: size,
        height: size,
        colorFilter: const ColorFilter.mode(
          AppTheme.lime,
          BlendMode.srcIn,
        ),
      ),
    );
  }
}
