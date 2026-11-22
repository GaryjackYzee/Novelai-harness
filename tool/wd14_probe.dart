import 'dart:io';

import 'package:novelai_harness/data/services/wd14_online_service.dart';

/// 手动探测在线 WD14：dart run tool/wd14_probe.dart <图片路径>
Future<void> main(List<String> args) async {
  final path = args.isEmpty ? '' : args.first;
  if (path.isEmpty) {
    stdout.writeln('用法: dart run tool/wd14_probe.dart <图片路径>');
    exitCode = 2;
    return;
  }
  final file = File(path);
  if (!await file.exists()) {
    stdout.writeln('图片不存在: $path');
    exitCode = 2;
    return;
  }
  final bytes = await file.readAsBytes();
  stdout.writeln('图片: $path (${bytes.length} bytes)');
  try {
    final tags = await Wd14OnlineService().tag(imageBytes: bytes);
    stdout.writeln('标签数: ${tags.length}');
    for (final tag in tags.take(30)) {
      stdout.writeln(
        '${tag.name} ${(tag.score * 100).toStringAsFixed(1)}%',
      );
    }
  } on Wd14Exception catch (error) {
    stdout.writeln('WD14 失败: ${error.message}');
    exitCode = 1;
  }
}
