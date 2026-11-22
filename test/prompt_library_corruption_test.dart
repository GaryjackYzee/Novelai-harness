import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/models/prompt_library_models.dart';
import 'package:novelai_harness/data/services/prompt_library_service.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'corrupt prompt library is backed up instead of silently wiped',
    () async {
      final dir = await Directory.systemTemp.createTemp('nai-prompt-library-');
      final service = PromptLibraryService();
      service.setCustomStorageDirectory(dir.path);
      addTearDown(() => service.setCustomStorageDirectory(null));
      addTearDown(() => dir.delete(recursive: true));

      final file = File(p.join(dir.path, 'prompt_library.json'));
      await file.writeAsString(
        '[{"id":"keep","title":"keep","category":"角色","prompt":"p",'
        '"createdAt":"2026-01-01T00:00:00.000",'
        '"updatedAt":"2026-01-01T00:00:00.000"',
      );

      expect(await service.loadEntries(), isEmpty);
      await service.addEntry(
        PromptComboEntry(
          id: 'new',
          title: 'new',
          prompt: 'p',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final backups = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupt-'))
          .toList();
      expect(backups, isNotEmpty);
      expect(await backups.first.readAsString(), contains('"keep"'));

      final saved = await file.readAsString();
      expect(saved, contains('"new"'));
    },
  );
}
