import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:novelai_harness/data/services/precise_reference_image_service.dart';

void main() {
  test('Precise Reference 图片规范化为官方固定画布并铺黑底', () {
    final source = img.Image(width: 100, height: 200);
    img.fill(source, color: img.ColorRgb8(200, 30, 40));
    final normalized = PreciseReferenceImageService.normalize(
      Uint8List.fromList(img.encodePng(source)),
    );

    expect(normalized, isNotNull);
    final decoded = img.decodePng(normalized!)!;
    expect(decoded.width, 1024);
    expect(decoded.height, 1536);
    expect(decoded.numChannels, 3);
    // 原图窄于目标画布：左右留黑边。
    final left = decoded.getPixel(10, 768);
    expect(left.r, lessThan(10));
    expect(left.g, lessThan(10));
    expect(left.b, lessThan(10));
  });
}
