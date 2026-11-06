import 'package:flutter/foundation.dart';

/// Controls the fullscreen now-playing sheet above the mini player.
class PlayerExpansion extends ChangeNotifier {
  bool _open = false;
  VoidCallback? _backHandler;

  bool get isOpen => _open;

  void open() {
    if (_open) return;
    _open = true;
    notifyListeners();
  }

  void close() {
    if (!_open) return;
    _open = false;
    notifyListeners();
  }

  void toggle() {
    _open = !_open;
    notifyListeners();
  }

  /// [FullPlayer] registers panel-then-close behaviour for system back.
  void setBackHandler(VoidCallback? handler) {
    _backHandler = handler;
  }

  /// Returns true if the open player (or its panel) consumed the back.
  bool handleBack() {
    if (!_open) return false;
    final handler = _backHandler;
    if (handler != null) {
      handler();
      return true;
    }
    close();
    return true;
  }
}
