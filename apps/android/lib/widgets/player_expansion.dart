import 'package:flutter/foundation.dart';

/// Controls the fullscreen now-playing sheet above the mini player.
class PlayerExpansion extends ChangeNotifier {
  bool _open = false;

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
}
