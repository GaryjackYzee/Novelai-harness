import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:novelai_harness/data/services/clipboard_image_service.dart';

void main() {
  test('wraps a 24-bit CF_DIB into a decodable BMP', () {
    const width = 2;
    const height = 2;
    const rowBytes = 8; // 2 * 3 bytes padded to 4
    final dib = Uint8List(40 + rowBytes * height);
    final data = ByteData.sublistView(dib);
    data.setUint32(0, 40, Endian.little);
    data.setInt32(4, width, Endian.little);
    data.setInt32(8, height, Endian.little);
    data.setUint16(12, 1, Endian.little);
    data.setUint16(14, 24, Endian.little);
    data.setUint32(20, rowBytes * height, Endian.little);
    // two red pixels at the bottom-left, rest zero
    dib.setRange(40, 43, <int>[0, 0, 255]);
    final bmp = ClipboardImageService.bmpFromDib(dib);
    expect(bmp, isNotNull);
    final decoded = img.decodeImage(bmp!);
    expect(decoded, isNotNull);
    expect(decoded!.width, width);
    expect(decoded.height, height);
  });
}
