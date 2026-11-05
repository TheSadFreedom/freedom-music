import 'package:flutter/services.dart';

/// Requests all-files / media access via MainActivity MethodChannel.
class StorageAccess {
  StorageAccess._();

  static const _channel = MethodChannel('com.freedom.music/storage');

  static Future<bool> ensureMusicAccess() async {
    try {
      final ok = await _channel.invokeMethod<bool>('ensureMusicAccess');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Android 13+: текущий статус POST_NOTIFICATIONS (без диалога).
  static Future<bool> hasNotifications() async {
    try {
      final ok = await _channel.invokeMethod<bool>('hasNotifications');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return true;
    }
  }

  /// Android 13+: запрос POST_NOTIFICATIONS для media notification.
  static Future<bool> ensureNotifications() async {
    try {
      final ok = await _channel.invokeMethod<bool>('ensureNotifications');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
