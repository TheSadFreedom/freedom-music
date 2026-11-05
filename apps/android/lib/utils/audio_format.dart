import 'dart:io';

import 'package:path/path.dart' as p;

/// Определяет расширение по сигнатуре, а не по URL.
String? sniffAudioExtension(List<int> header) {
  if (header.length < 12) return null;

  // ID3 → MP3
  if (header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
    return '.mp3';
  }

  // fLaC
  if (header[0] == 0x66 &&
      header[1] == 0x4C &&
      header[2] == 0x61 &&
      header[3] == 0x43) {
    return '.flac';
  }

  // OggS
  if (header[0] == 0x4F &&
      header[1] == 0x67 &&
      header[2] == 0x67 &&
      header[3] == 0x53) {
    return '.ogg';
  }

  // RIFF....WAVE
  if (header[0] == 0x52 &&
      header[1] == 0x49 &&
      header[2] == 0x46 &&
      header[3] == 0x46 &&
      header.length >= 12 &&
      header[8] == 0x57 &&
      header[9] == 0x41 &&
      header[10] == 0x56 &&
      header[11] == 0x45) {
    return '.wav';
  }

  // ISO BMFF (m4a/mp4/aac in MP4): ....ftyp
  if (header[4] == 0x66 &&
      header[5] == 0x74 &&
      header[6] == 0x79 &&
      header[7] == 0x70) {
    return '.m4a';
  }

  // MPEG sync
  if (header[0] == 0xFF && (header[1] & 0xE0) == 0xE0) {
    final layer = (header[1] >> 1) & 0x03;
    // layer == 0 → AAC ADTS; иначе MPEG audio (обычно MP3)
    if (layer == 0) return '.aac';
    return '.mp3';
  }

  return null;
}

/// Переименовывает файл, если сигнатура не совпадает с расширением.
Future<File> ensureAudioExtension(File file) async {
  final raf = await file.open();
  late final List<int> header;
  try {
    header = await raf.read(32);
  } finally {
    await raf.close();
  }
  final sniffed = sniffAudioExtension(header);
  if (sniffed == null) return file;

  final current = p.extension(file.path).toLowerCase();
  if (current == sniffed) return file;

  final renamed = File(
    p.join(
      p.dirname(file.path),
      '${p.basenameWithoutExtension(file.path)}$sniffed',
    ),
  );
  if (await renamed.exists() && !p.equals(renamed.path, file.path)) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final stamped = File(
      p.join(
        p.dirname(file.path),
        '${p.basenameWithoutExtension(file.path)}_$stamp$sniffed',
      ),
    );
    return file.rename(stamped.path);
  }
  return file.rename(renamed.path);
}
