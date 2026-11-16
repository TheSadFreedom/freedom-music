import 'dart:io';

import 'package:flutter/material.dart';

/// Decodes a cover at the size it is shown, not the full file.
Image fileCover(
  BuildContext context,
  String path, {
  required double logicalSize,
  BoxFit fit = BoxFit.cover,
  FilterQuality filterQuality = FilterQuality.low,
  ImageErrorWidgetBuilder? errorBuilder,
}) {
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final px = (logicalSize * dpr).round().clamp(48, 640);
  // Only one cache dimension — both would force a square decode and squash
  // non-square artist portraits before BoxFit.cover can crop.
  return Image.file(
    File(path),
    fit: fit,
    cacheWidth: px,
    filterQuality: filterQuality,
    gaplessPlayback: true,
    errorBuilder: errorBuilder,
  );
}
