import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';

/// Large page title matching the Chart header style.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle({
    super.key,
    required this.title,
    this.trailing,
    this.showBack,
  });

  final String title;
  final Widget? trailing;

  /// `null` — показать, если экран можно закрыть (`Navigator.canPop`).
  final bool? showBack;

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    final back = showBack ?? Navigator.of(context).canPop();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        back ? (phone ? 4 : 8) : (phone ? 16 : 20),
        phone ? 8 : 12,
        phone ? 16 : 20,
        8,
      ),
      child: Row(
        children: [
          if (back)
            IconButton(
              tooltip: 'Назад',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.paper),
            ),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.syne(
                color: AppTheme.paper,
                fontSize: phone ? 26 : 28,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
