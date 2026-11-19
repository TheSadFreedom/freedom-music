import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';

class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.source, this.size = 22});

  final ReleaseSource source;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: CustomPaint(
          size: Size.square(size - 8),
          painter: switch (source) {
            ReleaseSource.spotify => const _SpotifyMarkPainter(),
            ReleaseSource.yandex => const _YandexMusicMarkPainter(),
          },
        ),
      ),
    );
  }
}

/// Simplified three-arc Spotify mark (green on transparent).
class _SpotifyMarkPainter extends CustomPainter {
  const _SpotifyMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1DB954)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.shortestSide / 2;

    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..color = const Color(0xFF1DB954)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );

    paint
      ..color = const Color(0xFF121212)
      ..strokeWidth = r * 0.18;

    void arc(double yFactor, double radiusFactor, double sweep) {
      final radius = r * radiusFactor;
      final rect = Rect.fromCircle(
        center: Offset(cx, cy + r * yFactor),
        radius: radius,
      );
      canvas.drawArc(rect, math.pi * 1.15, sweep, false, paint);
    }

    arc(-0.18, 0.55, math.pi * 0.7);
    arc(0.02, 0.42, math.pi * 0.7);
    arc(0.22, 0.30, math.pi * 0.7);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Simplified Yandex Music note mark (yellow/black).
class _YandexMusicMarkPainter extends CustomPainter {
  const _YandexMusicMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = Offset(size.width / 2, size.height / 2);

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = const Color(0xFFFFDB4D)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );

    final ink = Paint()
      ..color = const Color(0xFF121212)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Note head
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(c.dx - r * 0.18, c.dy + r * 0.22),
        width: r * 0.55,
        height: r * 0.42,
      ),
      ink,
    );
    // Stem
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(c.dx + r * 0.02, c.dy - r * 0.45, r * 0.14, r * 0.78),
        const Radius.circular(2),
      ),
      ink,
    );
    // Flag
    final flag = Path()
      ..moveTo(c.dx + r * 0.16, c.dy - r * 0.45)
      ..quadraticBezierTo(
        c.dx + r * 0.55,
        c.dy - r * 0.25,
        c.dx + r * 0.16,
        c.dy - r * 0.05,
      )
      ..close();
    canvas.drawPath(flag, ink);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
