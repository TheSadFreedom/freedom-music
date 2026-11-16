import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'verified_badge.dart';

/// Track title with the optional note and verified mark immediately to its right.
class TrackTitleLine extends StatelessWidget {
  const TrackTitleLine({
    super.key,
    required this.title,
    this.note,
    this.style,
    this.maxLines = 1,
    this.onTap,
    this.centered = false,
    this.verified = false,
  });

  final String title;
  final String? note;
  final TextStyle? style;
  final int maxLines;
  final VoidCallback? onTap;
  final bool centered;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    final label = note?.trim() ?? '';
    final base = style ?? const TextStyle(color: AppTheme.paper);
    final titleStyle = DefaultTextStyle.of(context).style.merge(base);
    final titleText = Text(
      title,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.start,
      style: titleStyle,
    );
    final titleWidget = onTap == null
        ? titleText
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: titleText,
            ),
          );

    final hasNote = label.isNotEmpty;
    final noteStyle = titleStyle.copyWith(
      color: (titleStyle.color ?? AppTheme.paper).withValues(alpha: 0.45),
    );

    final row = LayoutBuilder(
      builder: (context, constraints) {
        return _TitleBadgeNoteRow(
          title: titleWidget,
          note: hasNote ? label : null,
          noteStyle: noteStyle,
          verified: verified,
          maxWidth: constraints.maxWidth,
          centered: centered,
        );
      },
    );
    if (!centered) return row;
    return Center(child: row);
  }
}

class _TitleBadgeNoteRow extends StatelessWidget {
  const _TitleBadgeNoteRow({
    required this.title,
    required this.note,
    required this.noteStyle,
    required this.verified,
    required this.maxWidth,
    required this.centered,
  });

  final Widget title;
  final String? note;
  final TextStyle noteStyle;
  final bool verified;
  final double maxWidth;
  final bool centered;

  static const _gap = 6.0;
  static const _badgeSize = 16.0;

  @override
  Widget build(BuildContext context) {
    final hasNote = note != null && note!.isNotEmpty;
    final badgeWidth = verified ? _gap + _badgeSize : 0.0;

    Widget noteWidget = const SizedBox.shrink();
    var noteWidth = 0.0;
    if (hasNote) {
      final natural = _singleLineWidth(context, note!, noteStyle);
      final roomForNote = maxWidth.isFinite
          ? math.max(0.0, maxWidth - badgeWidth - _gap)
          : natural;
      noteWidth = math.min(natural, roomForNote);
      noteWidget = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.max(noteWidth, 0)),
        child: Text(
          note!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: noteStyle,
        ),
      );
    }

    final trailingWidth =
        badgeWidth + (hasNote ? _gap + noteWidth : 0.0);
    final titleMax = maxWidth.isFinite
        ? math.max(0.0, maxWidth - trailingWidth)
        : double.infinity;

    return Row(
      mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (titleMax > 0)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: titleMax),
            child: title,
          ),
        if (verified) ...[
          const SizedBox(width: _gap),
          const VerifiedBadge(verified: true, size: _badgeSize),
        ],
        if (hasNote) ...[
          const SizedBox(width: _gap),
          noteWidget,
        ],
      ],
    );
  }
}

double _singleLineWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  return painter.width.ceilToDouble();
}
