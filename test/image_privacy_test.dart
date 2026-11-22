import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:novelai_harness/data/services/image_privacy_settings.dart';
import 'package:novelai_harness/data/services/watermark_service.dart';

void main() {
  tearDown(() {
    ImagePrivacySettings.stripStealth = false;
    ImagePrivacySettings.stripMetadata = false;
  });

  test('隐私开关开启时导出会清除 Alpha LSB 隐写', () async {
    final source = img.Image(width: 4, height: 4, numChannels: 4);
    for (final pixel in source) {
      pixel
        ..r = 10
        ..g = 20
        ..b = 30
        ..a = 253; // 奇数 LSB
    }
    final bytes = Uint8List.fromList(img.encodePng(source));
    ImagePrivacySettings.stripStealth = true;

    final output = await WatermarkService.processExportImage(
      rawBytes: bytes,
      stripMetadata: false,
      enableWatermark: false,
    );
    final decoded = img.decodePng(output)!;
    for (final pixel in decoded) {
      expect(pixel.a.toInt().isEven, isTrue);
    }
  });

  test('隐私开关关闭时保留 Alpha LSB', () async {
    final source = img.Image(width: 4, height: 4, numChannels: 4);
    for (final pixel in source) {
      pixel
        ..r = 10
        ..g = 20
        ..b = 30
        ..a = 253;
    }
    final bytes = Uint8List.fromList(img.encodePng(source));
    ImagePrivacySettings.stripStealth = false;

    final output = await WatermarkService.processExportImage(
      rawBytes: bytes,
      stripMetadata: false,
      enableWatermark: false,
    );
    final decoded = img.decodePng(output)!;
    expect(decoded.getPixel(0, 0).a, 253);
  });
}
