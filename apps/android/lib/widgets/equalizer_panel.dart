import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/equalizer_state.dart';
import '../services/player_service.dart';

const _kYellow = Color(0xFFFFDB4D);
const _kCard = Color(0xFF141414);
const _kTrack = Color(0xFF3A3A3A);
const _kMuted = Color(0xFF8E8A82);
const _kIcon = Color(0xFFE8E4DC);

/// Fullscreen EQ pane over the player (same role as lyrics / queue).
class EqualizerPanel extends StatefulWidget {
  const EqualizerPanel({super.key});

  @override
  State<EqualizerPanel> createState() => _EqualizerPanelState();
}

class _EqualizerPanelState extends State<EqualizerPanel> {
  bool _presetsOpen = true;

  void _togglePresets() => setState(() => _presetsOpen = !_presetsOpen);

  Future<void> _pickPreset(String id) async {
    setState(() => _presetsOpen = false);
    if (id == EqualizerPresets.customId) return;
    await context.read<PlayerService>().applyEqualizerPreset(id);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final eq = player.equalizer;
    final presetLabel = EqualizerPresets.displayName(eq.presetId);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Эквалайзер',
                    style: GoogleFonts.syne(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                _EqSwitch(
                  value: eq.enabled,
                  onChanged: player.setEqualizerEnabled,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 228,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: _EqGraph(
                enabled: eq.enabled,
                level: eq.level,
                bands: eq.bands,
                onLevel: player.setEqualizerLevel,
                onBand: player.setEqualizerBand,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _togglePresets,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 12, 6, 12),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: eq.enabled ? _kYellow : _kMuted,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        presetLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.figtree(
                          color: _kIcon,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    Icon(
                      _presetsOpen
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: _kMuted,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_presetsOpen)
            Expanded(
              child: _PresetsList(
                selectedId: eq.presetId,
                onPick: _pickPreset,
              ),
            )
          else
            const Spacer(),
        ],
      ),
    );
  }
}

class _EqSwitch extends StatelessWidget {
  const _EqSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.black,
      activeTrackColor: _kYellow,
      inactiveThumbColor: const Color(0xFFB0B0B0),
      inactiveTrackColor: const Color(0xFF3A3A3A),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    );
  }
}

class _PresetsList extends StatelessWidget {
  const _PresetsList({
    required this.selectedId,
    required this.onPick,
  });

  final String selectedId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final entries = <({String id, String name})>[
      if (selectedId == EqualizerPresets.customId)
        (id: EqualizerPresets.customId, name: EqualizerPresets.customName),
      for (final preset in EqualizerPresets.all)
        (id: preset.id, name: preset.name),
    ];

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = entry.id == selectedId;
        return Material(
          color: selected
              ? _kYellow.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onPick(entry.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 14,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.name,
                      style: GoogleFonts.figtree(
                        color: selected ? _kYellow : Colors.white,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  if (selected)
                    const Icon(
                      Icons.check_rounded,
                      color: _kYellow,
                      size: 18,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EqGraph extends StatefulWidget {
  const _EqGraph({
    required this.enabled,
    required this.level,
    required this.bands,
    required this.onLevel,
    required this.onBand,
  });

  final bool enabled;
  final double level;
  final List<double> bands;
  final ValueChanged<double> onLevel;
  final void Function(int index, double value) onBand;

  @override
  State<_EqGraph> createState() => _EqGraphState();
}

class _EqGraphState extends State<_EqGraph> {
  static const _labelH = 24.0;
  static const _scaleW = 34.0;
  static const _thumbR = 7.5;

  int? _active;
  double? _dragValue;

  int get _count => EqualizerState.bandCount + 1;

  double _valueAt(int i) {
    if (_active == i && _dragValue != null) return _dragValue!;
    return i == 0 ? widget.level : widget.bands[i - 1];
  }

  List<double> get _values => [
        for (var i = 0; i < _count; i++) _valueAt(i),
      ];

  double _dbFromDy(double localY, double graphH) {
    final usable = graphH - 2 * _thumbR;
    final t = ((localY - _thumbR) / usable).clamp(0.0, 1.0);
    return ui.lerpDouble(EqualizerState.maxDb, EqualizerState.minDb, t)!;
  }

  void _commit(int index, double db) {
    final v = db.clamp(EqualizerState.minDb, EqualizerState.maxDb);
    if (index == 0) {
      widget.onLevel(v);
    } else {
      widget.onBand(index - 1, v);
    }
  }

  int? _hitIndex(Offset local, Size size) {
    final graphW = size.width - _scaleW;
    final graphH = size.height - _labelH;
    if (local.dx < _scaleW || local.dy < 0 || local.dy > graphH) return null;
    final col = (local.dx - _scaleW) / graphW;
    return (col * _count).floor().clamp(0, _count - 1);
  }

  @override
  Widget build(BuildContext context) {
    final labels = <String>['ур.', ...EqualizerState.bandLabels];

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: widget.enabled
              ? (d) {
                  final i = _hitIndex(d.localPosition, size);
                  if (i == null) return;
                  HapticFeedback.selectionClick();
                  final graphH = size.height - _labelH;
                  final v = _dbFromDy(d.localPosition.dy, graphH);
                  setState(() {
                    _active = i;
                    _dragValue = v;
                  });
                  _commit(i, v);
                }
              : null,
          onPanUpdate: widget.enabled
              ? (d) {
                  final i = _active;
                  if (i == null) return;
                  final graphH = size.height - _labelH;
                  final v = _dbFromDy(d.localPosition.dy, graphH);
                  setState(() => _dragValue = v);
                  _commit(i, v);
                }
              : null,
          onPanEnd: widget.enabled
              ? (_) {
                  setState(() {
                    _active = null;
                    _dragValue = null;
                  });
                }
              : null,
          onPanCancel: () {
            setState(() {
              _active = null;
              _dragValue = null;
            });
          },
          child: CustomPaint(
            size: size,
            painter: _EqPainter(
              values: _values,
              labels: labels,
              enabled: widget.enabled,
              active: _active,
              scaleW: _scaleW,
              labelH: _labelH,
              thumbR: _thumbR,
            ),
          ),
        );
      },
    );
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter({
    required this.values,
    required this.labels,
    required this.enabled,
    required this.active,
    required this.scaleW,
    required this.labelH,
    required this.thumbR,
  });

  final List<double> values;
  final List<String> labels;
  final bool enabled;
  final int? active;
  final double scaleW;
  final double labelH;
  final double thumbR;

  @override
  void paint(Canvas canvas, Size size) {
    final graphW = size.width - scaleW;
    final graphH = size.height - labelH;
    final n = values.length;
    final colW = graphW / n;
    final accent = enabled ? _kYellow : _kMuted;

    final scaleStyle = GoogleFonts.figtree(
      color: _kMuted,
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
    );
    _paintText(canvas, '12dB', Offset(0, 2), scaleStyle);
    _paintText(canvas, '0dB', Offset(0, graphH / 2 - 6), scaleStyle);
    _paintText(canvas, '-12dB', Offset(0, graphH - 14), scaleStyle);

    final zeroY = _yForDb(0, graphH);
    canvas.drawLine(
      Offset(scaleW, zeroY),
      Offset(size.width, zeroY),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.07)
        ..strokeWidth = 1,
    );

    final centers = <Offset>[
      for (var i = 0; i < n; i++)
        Offset(
          scaleW + colW * (i + 0.5),
          _yForDb(values[i], graphH),
        ),
    ];

    for (var i = 0; i < n; i++) {
      final cx = centers[i].dx;
      final activeCol = active == i;
      canvas.drawLine(
        Offset(cx, thumbR),
        Offset(cx, graphH - thumbR),
        Paint()
          ..color = activeCol
              ? accent.withValues(alpha: 0.35)
              : _kTrack.withValues(alpha: 0.9)
          ..strokeWidth = activeCol ? 2.4 : 1.6
          ..strokeCap = StrokeCap.round,
      );
    }

    if (centers.length >= 2) {
      final curve = _smoothPath(centers, graphH);
      final fill = Path.from(curve)
        ..lineTo(centers.last.dx, graphH - thumbR)
        ..lineTo(centers.first.dx, graphH - thumbR)
        ..close();

      canvas.drawPath(
        fill,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, thumbR),
            Offset(0, graphH),
            [
              accent.withValues(alpha: enabled ? 0.22 : 0.08),
              accent.withValues(alpha: 0.0),
            ],
          )
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );

      canvas.drawPath(
        curve,
        Paint()
          ..color = accent.withValues(alpha: enabled ? 0.28 : 0.1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
          ..isAntiAlias = true,
      );

      canvas.drawPath(
        curve,
        Paint()
          ..color = accent.withValues(alpha: enabled ? 0.95 : 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
    }

    for (var i = 0; i < centers.length; i++) {
      final c = centers[i];
      final isActive = active == i;
      final r = isActive ? thumbR + 1.8 : thumbR;

      if (enabled) {
        canvas.drawCircle(
          c,
          r + 3,
          Paint()
            ..color = accent.withValues(alpha: isActive ? 0.28 : 0.14)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
      }

      canvas.drawCircle(c, r, Paint()..color = _kCard);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = isActive ? 2.6 : 2.1
          ..isAntiAlias = true,
      );
      if (isActive) {
        canvas.drawCircle(
          c,
          2.2,
          Paint()..color = accent,
        );
      }
    }

    final labelStyle = GoogleFonts.figtree(
      color: _kMuted,
      fontSize: 10,
      fontWeight: FontWeight.w600,
    );
    for (var i = 0; i < labels.length; i++) {
      final cx = centers[i].dx;
      _paintCenteredText(
        canvas,
        labels[i],
        Offset(cx, graphH + 5),
        labelStyle,
        maxWidth: colW,
      );
    }
  }

  double _yForDb(double db, double graphH) {
    final t = ((EqualizerState.maxDb - db) /
            (EqualizerState.maxDb - EqualizerState.minDb))
        .clamp(0.0, 1.0);
    return thumbR + t * (graphH - 2 * thumbR);
  }

  Path _smoothPath(List<Offset> pts, double graphH) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    if (pts.length == 2) {
      path.lineTo(pts[1].dx, pts[1].dy);
      return path;
    }

    final minY = thumbR;
    final maxY = graphH - thumbR;
    Offset clampY(Offset o) =>
        Offset(o.dx, o.dy.clamp(minY, maxY).toDouble());

    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = pts[i == 0 ? i : i - 1];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = pts[i + 2 < pts.length ? i + 2 : i + 1];

      const t = 1 / 8;
      final c1 = clampY(Offset(
        p1.dx + (p2.dx - p0.dx) * t,
        p1.dy + (p2.dy - p0.dy) * t,
      ));
      final c2 = clampY(Offset(
        p2.dx - (p3.dx - p1.dx) * t,
        p2.dy - (p3.dy - p1.dy) * t,
      ));
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    return path;
  }

  void _paintText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    tp.paint(canvas, offset);
  }

  void _paintCenteredText(
    Canvas canvas,
    String text,
    Offset topCenter,
    TextStyle style, {
    required double maxWidth,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(8, maxWidth));
    tp.paint(canvas, Offset(topCenter.dx - tp.width / 2, topCenter.dy));
  }

  @override
  bool shouldRepaint(covariant _EqPainter old) {
    if (old.enabled != enabled ||
        old.active != active ||
        old.values.length != values.length) {
      return true;
    }
    for (var i = 0; i < values.length; i++) {
      if (old.values[i] != values[i]) return true;
    }
    return false;
  }
}
