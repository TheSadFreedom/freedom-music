import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Human-readable Russian message for release-fetch failures.
String formatReleaseError(Object error) {
  final text = '$error';
  if (_isDnsOrHost(error, text)) {
    return 'Не удалось связаться с сервером (DNS/сеть). '
        'Проверь интернет и повтори через несколько секунд.';
  }
  if (_isTimeout(error, text)) {
    return 'Сервер не ответил вовремя. Попробуй ещё раз.';
  }
  if (error is http.ClientException || text.contains('ClientException')) {
    return 'Ошибка сети при запросе. Попробуй ещё раз.';
  }
  return text
      .replaceFirst(RegExp(r'^Bad state:\s*'), '')
      .replaceFirst(RegExp(r'^Exception:\s*'), '')
      .replaceFirst(RegExp(r'^StateError:\s*'), '');
}

bool isTransientNetworkError(Object error) {
  final text = '$error';
  return _isDnsOrHost(error, text) ||
      _isTimeout(error, text) ||
      error is http.ClientException ||
      text.contains('Connection reset') ||
      text.contains('Connection refused') ||
      text.contains('Software caused connection abort');
}

bool _isDnsOrHost(Object error, String text) {
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    if (code == 11001 || code == 8 || code == -2) return true;
    final msg = error.message.toLowerCase();
    if (msg.contains('failed host lookup') ||
        msg.contains('name or service not known') ||
        msg.contains('host is unknown')) {
      return true;
    }
  }
  return text.contains('Failed host lookup') ||
      text.contains('Этот хост неизвестен') ||
      text.contains('errno = 11001') ||
      text.contains('SocketException');
}

bool _isTimeout(Object error, String text) {
  return error is TimeoutException ||
      text.contains('TimeoutException') ||
      text.contains('timed out');
}

/// Retries [action] on transient network errors.
Future<T> withNetworkRetry<T>(
  Future<T> Function() action, {
  int attempts = 3,
  Duration baseDelay = const Duration(milliseconds: 450),
}) async {
  Object? last;
  for (var i = 0; i < attempts; i++) {
    try {
      return await action();
    } catch (e) {
      last = e;
      if (!isTransientNetworkError(e) || i == attempts - 1) rethrow;
      await Future<void>.delayed(baseDelay * (i + 1));
    }
  }
  throw last ?? StateError('Сетевая ошибка');
}
