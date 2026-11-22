import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// NovelAI Precise Reference (Director Reference) 图片规范化。
///
/// 官方网页端要求参考图落到三种固定画布之一，并铺黑底、去掉透明通道：
/// 1024x1536 / 1536x1024 / 1472x1472。直接上传任意尺寸/带透明通道的图片
/// 可能让服务端返回 500。
class PreciseReferenceImageService {
  const PreciseReferenceImageService._();

  static const List<(int, int)> _targets = [
    (1024, 1536),
    (1536, 1024),
    (1472, 1472),
  ];

  static Uint8List? normalize(Uint8List raw) {
    if (raw.isEmpty) return null;
    final decoded = img.decodeImage(raw);
    if (decoded == null) return null;
    final upright = img.bakeOrientation(decoded);
    final width = upright.width;
    final height = upright.height;
    if (width <= 0 || height <= 0) return null;

    final aspect = width / height;
    var target = _targets.first;
    var bestDelta = (target.$1 / target.$2 - aspect).abs();
    for (final candidate in _targets.skip(1)) {
      final delta = (candidate.$1 / candidate.$2 - aspect).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        target = candidate;
      }
    }
    final targetWidth = target.$1;
    final targetHeight = target.$2;
    final targetAspect = targetWidth / targetHeight;
    final (newWidth, newHeight) = aspect > targetAspect
        ? (targetWidth, (targetWidth / aspect).round())
        : ((targetHeight * aspect).round(), targetHeight);

    final resized = img.copyResize(
      upright,
      width: newWidth,
      height: newHeight,
      interpolation: img.Interpolation.cubic,
    );
    final canvas = img.Image(
      width: targetWidth,
      height: targetHeight,
      numChannels: 3,
      backgroundColor: img.ColorRgb8(0, 0, 0),
    );
    img.compositeImage(
      canvas,
      resized,
      dstX: (targetWidth - newWidth) ~/ 2,
      dstY: (targetHeight - newHeight) ~/ 2,
    );
    return Uint8List.fromList(img.encodePng(canvas));
  }
}
