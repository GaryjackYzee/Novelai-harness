import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/tools/reference_library_tool.dart';
import 'package:novelai_harness/data/services/reference_library_service.dart';

void main() {
  test('reference library tool lists and applies entries', () async {
    final entry = ReferenceLibraryEntry(
      id: 'ref_1',
      kind: ReferenceLibraryKind.precise,
      name: 'demo',
      bytes: Uint8List.fromList([1, 2]),
      createdAt: DateTime(2026, 1, 1),
    );
    String? applied;
    final tool = ReferenceLibraryTool(
      list: () async => [entry],
      addHistory: (_, _) async => true,
      addCanvas: (_) async => true,
      apply: (id) async {
        applied = id;
        return true;
      },
      remove: (_) async => true,
    );
    final list = await tool.execute('1', {'action': 'list'});
    expect(list.content, contains('ref_1'));
    await tool.execute('2', {'action': 'apply', 'entry_id': 'ref_1'});
    expect(applied, 'ref_1');
  });
}
