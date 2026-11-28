import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/tools/history_metadata_tool.dart';
import 'package:novelai_harness/data/models/nai_generation_params.dart';
import 'package:novelai_harness/data/models/nai_image_result.dart';

void main() {
  test('history metadata lists, gets and reuses fields', () async {
    final image = NaiGeneratedImage(
      id: 'img_1',
      bytes: Uint8List.fromList([1]),
      params: const NaiGenerationParams(
        prompt: '1girl, solo',
        negativePrompt: 'bad hands',
        width: 832,
        height: 1216,
        steps: 28,
        scale: 5,
        seed: 42,
      ),
      createdAt: DateTime(2026, 1, 1),
      seed: 42,
      isOpusFree: false,
    );
    Set<String>? reused;
    final tool = HistoryMetadataTool(
      getHistory: () => [image],
      reuse: (_, fields) => reused = fields,
    );
    final list = await tool.execute('1', {'action': 'list'});
    expect(list.content, contains('img_1'));
    final get = await tool.execute('2', {'action': 'get', 'index': 0});
    expect(get.content, contains('1girl, solo'));
    await tool.execute('3', {
      'action': 'reuse',
      'index': 0,
      'fields': ['prompt', 'steps'],
    });
    expect(reused, {'prompt', 'steps'});
  });
}
