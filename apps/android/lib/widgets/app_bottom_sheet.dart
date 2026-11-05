import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';

const _kYellow = Color(0xFFFFDB4D);
const _kSheetGlass = Color(0xFF1A2220);
const _kSheetBarrier = Color(0x99000000);

/// Pop a sheet opened by [showAppBottomSheet] (navigator or overlay).
void popAppSheet<T>(BuildContext context, [T? result]) {
  final host = _OverlaySheetHost.maybeOf(context);
  if (host != null) {
    host.complete(result);
    return;
  }
  Navigator.of(context).pop(result);
}

/// Shared dark bottom sheet chrome: handle, title, padded list.
///
/// Uses the nearest [Overlay] when there is no [Navigator] (fullscreen player).
/// Pass [buildChildren] for a static list, or [body] for a custom scrollable.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required String title,
  List<Widget> Function(BuildContext sheetContext)? buildChildren,
  Widget Function(BuildContext sheetContext)? body,
  bool scrollControlled = false,
}) {
  assert(buildChildren != null || body != null);
  if (Navigator.maybeOf(context) == null) {
    return _showOverlayBottomSheet<T>(
      context: context,
      title: title,
      buildChildren: buildChildren,
      body: body,
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: scrollControlled,
    barrierColor: _kSheetBarrier,
    builder: (ctx) => _AppSheetChrome(
      title: title,
      body: body?.call(ctx),
      children: buildChildren?.call(ctx),
    ),
  );
}

Future<T?> _showOverlayBottomSheet<T>({
  required BuildContext context,
  required String title,
  List<Widget> Function(BuildContext sheetContext)? buildChildren,
  Widget Function(BuildContext sheetContext)? body,
}) {
  final completer = Completer<T?>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  void finish([Object? value]) {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete(value as T?);
  }

  entry = OverlayEntry(
    builder: (overlayCtx) {
      return _OverlaySheetHost(
        complete: finish,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => finish(),
                child: const ColoredBox(color: _kSheetBarrier),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Builder(
                  builder: (sheetCtx) => _AppSheetChrome(
                    title: title,
                    body: body?.call(sheetCtx),
                    children: buildChildren?.call(sheetCtx),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  overlay.insert(entry);
  return completer.future;
}

class _OverlaySheetHost extends InheritedWidget {
  const _OverlaySheetHost({
    required this.complete,
    required super.child,
  });

  final void Function([Object? result]) complete;

  static _OverlaySheetHost? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<_OverlaySheetHost>();
  }

  @override
  bool updateShouldNotify(_OverlaySheetHost oldWidget) => false;
}

class _AppSheetChrome extends StatelessWidget {
  const _AppSheetChrome({
    required this.title,
    this.body,
    this.children,
  });

  final String title;
  final Widget? body;
  final List<Widget>? children;

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final radius = BorderRadius.circular(20);
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 0, 10, 10 + bottomInset),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.42),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _kSheetGlass.withValues(alpha: 0.78),
                    const Color(0xFF121816).withValues(alpha: 0.82),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 10),
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppTheme.paper.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                        child: Text(
                          title,
                          style: GoogleFonts.syne(
                            color: AppTheme.paper,
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      Flexible(
                        child: body ??
                            ListView(
                              shrinkWrap: true,
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                              children: children ?? const [],
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SheetRow extends StatelessWidget {
  const SheetRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.leadingColor,
    this.leadingIcon,
    this.leadingAccent = false,
    this.trailing,
    this.selected = false,
    this.destructive = false,
    this.showChevron = true,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Color? leadingColor;
  final IconData? leadingIcon;
  final bool leadingAccent;
  final Widget? trailing;
  final bool selected;
  final bool destructive;
  final bool showChevron;
  final VoidCallback? onTap;

  static const _destructive = Color(0xFFFF8A80);

  @override
  Widget build(BuildContext context) {
    final accentColor = destructive ? _destructive : _kYellow;
    final iconColor = leadingColor ??
        (leadingAccent || selected || destructive
            ? accentColor
            : AppTheme.paperMuted);
    final titleColor = destructive ? _destructive : AppTheme.paper;
    final lead = leading ??
        (leadingIcon == null
            ? null
            : _SheetIconWell(
                icon: leadingIcon!,
                color: iconColor,
                accent: leadingAccent ||
                    selected ||
                    destructive ||
                    leadingColor == _kYellow,
              ));
    final Widget? trail = trailing ??
        (!showChevron
            ? null
            : selected
                ? Icon(Icons.check_rounded, color: accentColor, size: 22)
                : Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.paper.withValues(alpha: 0.22),
                    size: 22,
                  ));

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              if (lead != null) ...[
                lead,
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.figtree(
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        height: 1.2,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.figtree(
                          color: selected
                              ? accentColor.withValues(alpha: 0.75)
                              : AppTheme.paperMuted,
                          fontWeight: FontWeight.w500,
                          fontSize: 12,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?trail,
            ],
          ),
        ),
      ),
    );
  }
}

class SheetArtistAvatar extends StatelessWidget {
  const SheetArtistAvatar({super.key, this.photoPath, this.size = 44});

  final String? photoPath;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget child = Icon(
      Icons.person_rounded,
      color: AppTheme.paperMuted.withValues(alpha: 0.85),
      size: size * 0.5,
    );
    final path = photoPath;
    if (path != null) {
      child = Image.file(
        File(path),
        fit: BoxFit.cover,
        width: size,
        height: size,
        errorBuilder: (_, _, _) => Icon(
          Icons.person_rounded,
          color: AppTheme.paperMuted.withValues(alpha: 0.85),
          size: size * 0.5,
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.inkLift,
        shape: BoxShape.circle,
        border: Border.all(
          color: AppTheme.paper.withValues(alpha: 0.08),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _SheetIconWell extends StatelessWidget {
  const _SheetIconWell({
    required this.icon,
    required this.color,
    this.accent = false,
  });

  final IconData icon;
  final Color color;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: accent
            ? color.withValues(alpha: 0.14)
            : AppTheme.paper.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 24),
    );
  }
}
