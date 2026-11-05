import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'full_player.dart';
import 'lyrics_view.dart';
import 'player_expansion.dart';

/// Kept for screens that still watch dock height (now always 0 — mini is in shell).
class PlayerDock extends ChangeNotifier {
  double get height => 0;

  void setHeight(double value) {}
}

/// Fullscreen player overlay above the app.
class AppPlayerLayer extends StatefulWidget {
  const AppPlayerLayer({super.key, required this.child});

  final Widget child;

  @override
  State<AppPlayerLayer> createState() => _AppPlayerLayerState();
}

class _AppPlayerLayerState extends State<AppPlayerLayer> {
  final _dock = PlayerDock();
  final _lyrics = LyricsPresentation();
  final _expansion = PlayerExpansion();
  late final OverlayEntry _entry = OverlayEntry(builder: _buildStack);

  @override
  void initState() {
    super.initState();
    _lyrics.addListener(_entry.markNeedsBuild);
    _expansion.addListener(_entry.markNeedsBuild);
  }

  @override
  void dispose() {
    _lyrics.removeListener(_entry.markNeedsBuild);
    _expansion.removeListener(_entry.markNeedsBuild);
    _entry.remove();
    _entry.dispose();
    _dock.dispose();
    _lyrics.dispose();
    _expansion.dispose();
    super.dispose();
  }

  Widget _buildStack(BuildContext context) {
    final expanded = _expansion.isOpen;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _dock),
        ChangeNotifierProvider.value(value: _lyrics),
        ChangeNotifierProvider.value(value: _expansion),
      ],
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (expanded)
            const Positioned.fill(
              key: ValueKey('full-player'),
              child: FullPlayer(),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _entry.markNeedsBuild();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _dock),
        ChangeNotifierProvider.value(value: _lyrics),
        ChangeNotifierProvider.value(value: _expansion),
      ],
      child: Overlay(initialEntries: [_entry]),
    );
  }
}
