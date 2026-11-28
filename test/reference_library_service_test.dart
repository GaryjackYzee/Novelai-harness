import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/services/reference_library_service.dart';

const List<int> _png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reference library roundtrip, thumbnail and remove', () async {
    final dir = await Directory.systemTemp.createTemp('ref_library_test');
    addTearDown(() async {
      ReferenceLibraryService.setStorageDirectoryForTesting(null);
      await dir.delete(recursive: true);
    });
    ReferenceLibraryService.setStorageDirectoryForTesting(dir);
    final service = ReferenceLibraryService.instance;
    final entry = await service.add(
      kind: ReferenceLibraryKind.precise,
      name: 'demo',
      bytes: Uint8List.fromList(_png),
      strength: 9,
    );
    expect(entry, isNotNull);
    expect(entry!.strength, 5);
    final loaded = await service.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.bytes, isNull);
    expect(loaded.single.thumbnailBytes, isNotEmpty);
    expect(await service.loadFull(loaded.single), Uint8List.fromList(_png));
    await service.remove(loaded.single);
    expect(await service.load(), isEmpty);
  });
}
