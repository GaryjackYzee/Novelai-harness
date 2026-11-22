import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/tools/tool_path_guard.dart';
import 'package:path/path.dart' as p;

Uint8List _pngHeader() => Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  1,
  2,
  3,
  4,
]);

void main() {
  late Directory root;
  late File inside;
  late File outside;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nai-path-guard-');
    inside = File(p.join(root.path, 'inside.png'));
    await inside.writeAsBytes(_pngHeader());
    final other = await Directory.systemTemp.createTemp('nai-path-guard-out-');
    outside = File(p.join(other.path, 'outside.png'));
    await outside.writeAsBytes(_pngHeader());
    addTearDown(() => other.delete(recursive: true));
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('accepts files inside allowed roots only', () async {
    expect(isPathInsideRoots(inside.path, [root.path]), isTrue);
    expect(isPathInsideRoots(outside.path, [root.path]), isFalse);

    final ok = await readAgentImagePath(inside.path, [root.path]);
    expect(ok.error, isNull);
    expect(ok.bytes, isNotEmpty);

    final rejected = await readAgentImagePath(outside.path, [root.path]);
    expect(rejected.bytes, isNull);
    expect(rejected.error, contains('不在允许读取的目录内'));
  });

  test('rejects non-image and empty roots', () async {
    final text = File(p.join(root.path, 'note.txt'));
    await text.writeAsString('not an image');
    final result = await readAgentImagePath(text.path, [root.path]);
    expect(result.bytes, isNull);
    expect(result.error, contains('不是受支持的图片格式'));

    final noRoots = await readAgentImagePath(inside.path, const []);
    expect(noRoots.bytes, isNull);
    expect(noRoots.error, contains('未配置可读目录'));
  });
}
