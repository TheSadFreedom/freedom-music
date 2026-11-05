import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:pasteboard/pasteboard.dart';

class PickedImage {
  const PickedImage({required this.bytes, required this.mime});

  final Uint8List bytes;
  final String mime;
}

Future<Uint8List?> pickImageBytes() async {
  final picked = await pickImage();
  return picked?.bytes;
}

Future<PickedImage?> pickImage() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    withData: true,
    allowMultiple: false,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.first;
  var bytes = file.bytes;
  if (bytes == null && file.path != null) {
    bytes = await File(file.path!).readAsBytes();
  }
  if (bytes == null || bytes.isEmpty) return null;
  final ext = (file.extension ?? '').toLowerCase();
  return PickedImage(bytes: bytes, mime: _mimeFromExtension(ext, bytes));
}

/// Картинка из буфера: PNG/DIB через pasteboard или скопированный файл.
Future<PickedImage?> pasteImageFromClipboard() async {
  final image = await Pasteboard.image;
  if (image != null && image.isNotEmpty) {
    return PickedImage(bytes: image, mime: imageMimeOf(image));
  }

  final paths = await Pasteboard.files();
  for (final path in paths) {
    final lower = path.toLowerCase();
    final isImage =
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
    if (!isImage) continue;
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) continue;
    final ext = lower.split('.').last;
    return PickedImage(bytes: bytes, mime: _mimeFromExtension(ext, bytes));
  }
  return null;
}

String imageMimeOf(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  // Windows/pasteboard чаще отдаёт PNG.
  return 'image/png';
}

String _mimeFromExtension(String ext, Uint8List bytes) {
  return switch (ext) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'jpg' || 'jpeg' => 'image/jpeg',
    'bmp' => 'image/bmp',
    _ => imageMimeOf(bytes),
  };
}
