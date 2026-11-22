import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/types.dart';
import 'package:novelai_harness/data/models/nai_character_prompt.dart';
import 'package:novelai_harness/data/models/nai_generation_params.dart';
import 'package:novelai_harness/data/models/style_preset.dart';
import 'package:novelai_harness/data/services/chat_queue_store.dart';

void main() {
  group('StylePreset', () {
    test('编码/解码保留正负 tag 与脱敏标记', () {
      const preset = StylePreset(
        id: 'style_1',
        name: '厚涂',
        positive: 'painterly, thick strokes',
        negative: 'flat color',
        stripMetadata: true,
        stripStealth: true,
        styleInMetadata: false,
      );
      final decoded = StylePreset.decode(preset.encode());
      expect(decoded.name, '厚涂');
      expect(decoded.positive, 'painterly, thick strokes');
      expect(decoded.negative, 'flat color');
      expect(decoded.stripMetadata, isTrue);
      expect(decoded.stripStealth, isTrue);
      expect(decoded.styleInMetadata, isFalse);
    });

    test('旧数据默认写入元数据', () {
      final decoded = StylePreset.decode(
        '{"id":"a","name":"x","positive":"y","negative":"z"}',
      );
      expect(decoded.styleInMetadata, isTrue);
    });
  });

  group('画风串参与生成与元数据', () {
    test('stylePositive 进入实际提示词', () {
      const params = NaiGenerationParams(
        prompt: '1girl',
        stylePositive: 'painterly',
        styleNegative: 'flat color',
      );
      expect(params.effectivePrompt, contains('painterly'));
      expect(params.effectiveNegativePrompt, contains('flat color'));
      expect('${params.toApiPayload()}', contains('painterly'));
    });

    test('关闭 styleTagsInMetadata 时导出注释不含画风串', () {
      const params = NaiGenerationParams(
        prompt: '1girl',
        stylePositive: 'painterly',
        styleTagsInMetadata: false,
      );
      final comment = params.toMetadataComment(seed: 1);
      expect('${comment['prompt']}', isNot(contains('painterly')));
    });

    test('开启时导出注释包含画风串', () {
      const params = NaiGenerationParams(
        prompt: '1girl',
        stylePositive: 'painterly',
      );
      final comment = params.toMetadataComment(seed: 1);
      expect('${comment['prompt']}', contains('painterly'));
    });
  });

  test('画风串字段随参数持久化恢复', () {
    const params = NaiGenerationParams(
      prompt: '1girl',
      stylePositive: 'painterly',
      styleNegative: 'flat color',
      styleTagsInMetadata: false,
    );
    final restored = NaiGenerationParams.fromJson(params.toJson());
    expect(restored.stylePositive, 'painterly');
    expect(restored.styleNegative, 'flat color');
    expect(restored.styleTagsInMetadata, isFalse);
    expect(restored.effectivePrompt, contains('painterly'));
  });

  group('QueuedChatMessage', () {
    test('带图片的消息可序列化', () {
      final message = QueuedChatMessage(
        content: '继续',
        images: [AgentMessageImage.fromBytes(bytes: Uint8List.fromList(const [1, 2, 3]))],
      );
      final decoded = QueuedChatMessage.decode(message.encode());
      expect(decoded.content, '继续');
      expect(decoded.images, hasLength(1));
      expect(decoded.images.first.bytes, [1, 2, 3]);
    });
  });

  test('画风组去除时元数据不含画风串，但生成请求仍包含', () {
    final params = NaiGenerationParams(
      prompt: '1girl',
      stylePositive: 'styleonlytoken',
      styleNegative: 'styleonlyneg',
      styleTagsInMetadata: false,
    );
    expect(params.effectivePrompt, contains('styleonlytoken'));
    expect(params.metadataPrompt, isNot(contains('styleonlytoken')));
    expect(params.metadataPrompt, isNot(contains('styleonlyneg')));
    final comment = params.toMetadataComment(seed: 1);
    expect(comment['prompt'] as String, isNot(contains('styleonlytoken')));
    expect(comment['uc'] as String, isNot(contains('styleonlyneg')));

    final kept = params.copyWith(styleTagsInMetadata: true);
    expect(
      kept.toMetadataComment(seed: 1)['prompt'] as String,
      contains('styleonlytoken'),
    );
  });

  test('角色提示词里的私有 tag 不写入元数据', () {
    final params = NaiGenerationParams(
      prompt: '1girl',
      stripTags: 'privatechar',
      characterPrompts: [
        NaiCharacterPrompt(
          id: 'aabbccdd',
          name: 'c',
          prompt: 'privatechar, silver hair',
        ),
      ],
    );
    final comment = params.toMetadataComment(seed: 1);
    final v4 = comment['v4_prompt'] as Map<String, dynamic>;
    final caption = v4['caption'] as Map<String, dynamic>;
    final chars = caption['char_captions'] as List<dynamic>;
    expect(chars.toString(), isNot(contains('privatechar')));
    expect(chars.toString(), contains('silver hair'));
  });
}
