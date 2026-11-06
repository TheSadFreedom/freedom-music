import 'dart:async';

import 'package:flutter/material.dart';

/// Single-line text that scrolls horizontally when it overflows.
///
/// Short labels stay still. On [text] change the animation resets.
class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.velocity = 36,
    this.blankSpace = 48,
    this.pauseDuration = const Duration(milliseconds: 1400),
  });

  final String text;
  final TextStyle? style;

  /// Scroll speed in logical pixels per second.
  final double velocity;

  /// Gap between the end of the text and the next loop copy.
  final double blankSpace;

  /// Pause at the start of each loop (and briefly after a full scroll).
  final Duration pauseDuration;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int _loopGen = 0;
  double _textWidth = 0;
  double _containerWidth = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.velocity != widget.velocity ||
        oldWidget.blankSpace != widget.blankSpace ||
        oldWidget.pauseDuration != widget.pauseDuration) {
      _scheduleRestart();
    }
  }

  @override
  void dispose() {
    _loopGen++;
    _controller.dispose();
    super.dispose();
  }

  bool get _overflows => _textWidth > _containerWidth + 0.5;

  double get _scrollDistance => _textWidth + widget.blankSpace;

  void _scheduleRestart() {
    final gen = ++_loopGen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || gen != _loopGen) return;
      _controller.stop();
      _controller.value = 0;
      unawaited(_runLoop(gen));
    });
  }

  void _syncMetrics(double containerWidth, double textWidth) {
    if (_containerWidth == containerWidth && _textWidth == textWidth) return;
    _containerWidth = containerWidth;
    _textWidth = textWidth;
    _scheduleRestart();
  }

  Future<void> _runLoop(int gen) async {
    while (mounted && gen == _loopGen) {
      if (!_overflows || _containerWidth <= 0 || widget.velocity <= 0) {
        _controller.value = 0;
        return;
      }

      _controller.value = 0;
      await Future<void>.delayed(widget.pauseDuration);
      if (!mounted || gen != _loopGen || !_overflows) return;

      final ms =
          (_scrollDistance / widget.velocity * 1000).round().clamp(1, 60000);
      _controller.duration = Duration(milliseconds: ms);
      await _controller.forward(from: 0);
      if (!mounted || gen != _loopGen || !_overflows) return;

      await Future<void>.delayed(widget.pauseDuration);
    }
  }

  TextStyle _resolveStyle(BuildContext context) {
    return DefaultTextStyle.of(context).style.merge(widget.style);
  }

  @override
  Widget build(BuildContext context) {
    final style = _resolveStyle(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (!maxWidth.isFinite || maxWidth <= 0) {
          return const SizedBox.shrink();
        }

        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();

        final textWidth = painter.width;
        final height = painter.height;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncMetrics(maxWidth, textWidth);
        });

        if (textWidth <= maxWidth) {
          return SizedBox(
            width: maxWidth,
            height: height,
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: style,
            ),
          );
        }

        final label = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          style: style,
        );

        return ClipRect(
          child: SizedBox(
            width: maxWidth,
            height: height,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final dx = -_controller.value * (textWidth + widget.blankSpace);
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Transform.translate(offset: Offset(dx, 0), child: child),
                    Transform.translate(
                      offset: Offset(dx + textWidth + widget.blankSpace, 0),
                      child: child,
                    ),
                  ],
                );
              },
              child: label,
            ),
          ),
        );
      },
    );
  }
}
