import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:win32/win32.dart';

/// Reads an image from the system clipboard.
///
/// On Windows the native CF_DIB/CF_DIBV5 format is converted to a BMP in Dart,
/// avoiding the all-black DIB result produced by the pasteboard plugin for some
/// screenshot tools.
class ClipboardImageService {
  const ClipboardImageService._();

  static Future<Uint8List?> read() async {
    // Keep the original plugin path; only fall back when it yields a black DIB.
    final raw = await Pasteboard.image;
    if (raw != null && raw.isNotEmpty && !_mostlyBlack(raw)) return raw;
    if (Platform.isWindows) {
      final native = _readWindowsDib();
      if (native != null && native.isNotEmpty) return native;
      final system = await _readWithWindowsClipboard();
      if (system != null && system.isNotEmpty) return system;
    }
    return raw;
  }

  static bool _mostlyBlack(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return false;
    var dark = 0;
    var sampled = 0;
    final stepX = (decoded.width ~/ 16).clamp(1, 64);
    final stepY = (decoded.height ~/ 16).clamp(1, 64);
    for (var y = 0; y < decoded.height; y += stepY) {
      for (var x = 0; x < decoded.width; x += stepX) {
        final pixel = decoded.getPixel(x, y);
        final value = (pixel.r + pixel.g + pixel.b) / 3;
        if (value < 8) dark += 1;
        sampled += 1;
      }
    }
    return sampled > 0 && dark / sampled > 0.98;
  }

  static Uint8List? _readWindowsDib() {
    if (OpenClipboard(NULL) == 0) return null;
    try {
      for (final format in <int>[CF_DIBV5, CF_DIB]) {
        final handle = GetClipboardData(format);
        if (handle == 0) continue;
        final size = GlobalSize(Pointer.fromAddress(handle));
        if (size <= 0) continue;
        final pointer = GlobalLock(Pointer.fromAddress(handle));
        if (pointer.address == 0) continue;
        try {
          final dib = pointer.cast<Uint8>().asTypedList(size);
          final bmp = bmpFromDib(Uint8List.fromList(dib));
          if (bmp != null) return bmp;
        } finally {
          GlobalUnlock(Pointer.fromAddress(handle));
        }
      }
    } on Object {
      // Fall through to the plugin.
    } finally {
      CloseClipboard();
    }
    return null;
  }

  /// Wrap raw CF_DIB bytes in a BITMAPFILEHEADER so the image package can read
  /// them. Exposed for tests.
  static Uint8List? bmpFromDib(Uint8List dib) {
    if (dib.length < 40) return null;
    final data = ByteData.sublistView(dib);
    final headerSize = data.getUint32(0, Endian.little);
    final bitCount = data.getUint16(14, Endian.little);
    final compression = data.getUint32(16, Endian.little);
    final clrUsed = data.getUint32(32, Endian.little);
    var paletteBytes = 0;
    if (bitCount <= 8) {
      paletteBytes = (clrUsed == 0 ? 1 << bitCount : clrUsed) * 4;
    } else if (bitCount == 16 || bitCount == 32) {
      if (compression == 3) paletteBytes = 12;
    }
    final offset = 14 + headerSize + paletteBytes;
    final bmp = Uint8List(14 + dib.length);
    final header = ByteData.sublistView(bmp);
    header.setUint16(0, 0x4D42, Endian.little);
    header.setUint32(2, bmp.length, Endian.little);
    header.setUint32(10, offset, Endian.little);
    bmp.setRange(14, bmp.length, dib);
    return bmp;
  }

  static Future<Uint8List?> _readWithWindowsClipboard() async {
    final temp = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}novelai_clipboard_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    final script = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
\$image = [System.Windows.Forms.Clipboard]::GetImage()
if (\$image -ne \$null) {
  \$image.Save('${temp.path.replaceAll("'", "''")}', [System.Drawing.Imaging.ImageFormat]::Png)
  \$image.Dispose()
}
''';
    try {
      final result = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      if (result.exitCode == 0 && await temp.exists()) {
        return await temp.readAsBytes();
      }
    } on Object {
      // Best-effort fallback.
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } on Object {
        // ignore cleanup failure
      }
    }
    return null;
  }
}
