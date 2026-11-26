import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/tools/precise_reference_tool.dart';
import 'package:novelai_harness/data/models/nai_generation_params.dart';
import 'package:novelai_harness/ui/features/studio/view_models/studio_view_model.dart';

void main() {
  test('precise reference tool lists, views, updates and removes', () async {
    final entries = <NaiPreciseReference>[
      NaiPreciseReference(
        bytes: Uint8List.fromList([1, 2, 3]),
        type: NaiPreciseRefType.character,
        strength: 2.5,
        preferSameOutfit: true,
      ),
    ];
    int? updatedIndex;
    double? updatedStrength;
    int? removedIndex;
    var cleared = false;
    final tool = PreciseReferenceTool(
      list: () => entries,
      supported: () => true,
      addFromCanvas: ({
        required type,
        required strength,
        required fidelity,
        required preferSameOutfit,
        required fromChat,
        required imageIndex,
        required libraryEntryId,
      }) async => true,
      update: (index, {type, strength, fidelity, preferSameOutfit, enabled}) {
        updatedIndex = index;
        updatedStrength = strength;
      },
      remove: (index) => removedIndex = index,
      clear: () => cleared = true,
    );

    final listResult = await tool.execute('1', {'action': 'list'});
    expect(listResult.content, contains('character'));
    expect(listResult.content, contains('strength=2.50'));

    final viewResult = await tool.execute('2', {
      'action': 'view',
      'index': 0,
    });
    expect(viewResult.imageBase64, isNotEmpty);

    await tool.execute('3', {
      'action': 'update',
      'index': 0,
      'strength': 1.5,
    });
    expect(updatedIndex, 0);
    expect(updatedStrength, 1.5);

    await tool.execute('4', {'action': 'remove', 'index': 0});
    expect(removedIndex, 0);
    await tool.execute('5', {'action': 'clear'});
    expect(cleared, isTrue);
  });

  test('auto approve uses <= threshold and ignores zero/negative cost', () {
    expect(shouldAutoApproveGeneration(10, 10), isTrue);
    expect(shouldAutoApproveGeneration(11, 10), isFalse);
    expect(shouldAutoApproveGeneration(0, 10), isFalse);
    expect(shouldAutoApproveGeneration(-3, 10), isFalse);
    expect(shouldAutoApproveGeneration(1, 0), isFalse);
  });
}
