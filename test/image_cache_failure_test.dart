import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:novelai_harness/data/models/novelai_models.dart';
import 'package:novelai_harness/data/repositories/novelai_repository.dart';
import 'package:novelai_harness/data/services/image_file_store.dart';
import 'package:novelai_harness/data/services/image_metadata_service.dart';
import 'package:novelai_harness/data/services/novelai_service.dart';
import 'package:path/path.dart' as p;

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));

class _FakeGenerateService extends NovelAiService {
  @override
  Future<List<Uint8List>> generateImage({
    required String apiKey,
    required NaiGenerationParams params,
  }) async => <Uint8List>[_png()];
}

void main() {
  test('ImageFileStore never truncates an existing image', () {
    final dir = Directory.systemTemp.createTempSync('nai-file-store-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final original = File(p.join(dir.path, 'a.png'))
      ..writeAsBytesSync(<int>[1, 2, 3]);

    final written = ImageFileStore.write(
      root: dir.path,
      relativePath: 'a.png',
      bytes: <int>[9, 9, 9],
    );

    expect(original.readAsBytesSync(), <int>[1, 2, 3]);
    expect(p.basename(written), 'a_2.png');
    expect(File(written).readAsBytesSync(), <int>[9, 9, 9]);
  });

  test('cache write failure keeps the generated image in memory', () async {
    final dir = Directory.systemTemp.createTempSync('nai-cache-fail-');
    addTearDown(() => dir.deleteSync(recursive: true));
    // 用“文件”充当保存目录：cache 子目录无法创建，触发回退链。
    final blocked = File(p.join(dir.path, 'blocked'))
      ..writeAsStringSync('not a directory');

    final repo = NovelAiRepository(service: _FakeGenerateService());
    final images = await repo.generate(
      apiKey: 'test-key',
      params: const NaiGenerationParams(prompt: '1girl', width: 8, height: 8),
      saveDir: blocked.path,
      autoSave: true,
      enablePersistence: false,
    );

    expect(images, hasLength(1));
    expect(images.single.bytes, isNotEmpty);
    // 回退到系统临时目录成功：图片仍可显示；失败也不应抛异常。
    expect(images.single.localFilePath, isNotNull);
    expect(File(images.single.localFilePath!).existsSync(), isTrue);
  });

  test('watermarked export keeps NovelAI metadata', () async {
    final dir = Directory.systemTemp.createTempSync('nai-export-meta-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final watermark = img.Image(width: 4, height: 4);
    img.fill(watermark, color: img.ColorRgba8(255, 0, 0, 180));
    const config = WatermarkConfig(
      enabled: true,
      posX: 1,
      posY: 1,
      scalePercent: 25,
      opacity: 1,
      marginPercent: 0,
    );

    final repo = NovelAiRepository(service: _FakeGenerateService());
    final images = await repo.generate(
      apiKey: 'test-key',
      params: const NaiGenerationParams(
        prompt: '1girl, solo',
        width: 8,
        height: 8,
      ),
      saveDir: dir.path,
      autoSave: true,
      enablePersistence: false,
      enableWatermark: true,
      watermarkConfig: config,
      watermarkBytes: Uint8List.fromList(img.encodePng(watermark)),
    );

    final saved = File(images.single.localFilePath!);
    expect(saved.existsSync(), isTrue);
    final metadata = ImageMetadataService.parseMetadata(
      Uint8List.fromList(saved.readAsBytesSync()),
    );
    expect(metadata, isNotNull);
    expect(metadata!.prompt, contains('1girl, solo'));
  });

  test(
    'manual save re-embeds metadata when cache text chunks are gone',
    () async {
      final dir = Directory.systemTemp.createTempSync('nai-save-meta-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cacheDir = Directory(p.join(dir.path, 'cache'))
        ..createSync(recursive: true);
      // 模拟被隐写清理/旧版本重编码过的缓存：只剩像素，没有文本块。
      final cacheFile = File(p.join(cacheDir.path, 'cached.png'))
        ..writeAsBytesSync(_png());
      final repo = NovelAiRepository(service: _FakeGenerateService())
        ..addImageForTesting(
          NaiGeneratedImage(
            id: 'cached',
            bytes: _png(),
            localFilePath: cacheFile.path,
            originalFilePath: cacheFile.path,
            params: const NaiGenerationParams(
              prompt: 'recovered prompt',
              width: 8,
              height: 8,
            ),
            createdAt: DateTime.now(),
            seed: 42,
            isOpusFree: false,
            isUnsaved: true,
          ),
        );

      final saved = await repo.saveUnsavedImageToDisk(
        imageId: 'cached',
        saveDir: dir.path,
        enablePersistence: false,
      );

      expect(saved, isNotNull);
      expect(saved!.isUnsaved, isFalse);
      final metadata = ImageMetadataService.parseMetadata(
        Uint8List.fromList(File(saved.localFilePath!).readAsBytesSync()),
      );
      expect(metadata, isNotNull);
      expect(metadata!.prompt, contains('recovered prompt'));
    },
  );
}
