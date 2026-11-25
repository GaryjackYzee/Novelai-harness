import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/models/nai_catalog.dart';
import 'package:novelai_harness/data/models/nai_generation_params.dart';

void main() {
  test('V4.5 Precise Reference 发送 director_reference 字段并跳过 Vibe', () {
    final params = NaiGenerationParams(
      prompt: '1girl',
      model: NaiModel.v45Full,
      preciseReferences: [
        NaiPreciseReference(
          bytes: Uint8List.fromList([1, 2, 3]),
          type: NaiPreciseRefType.style,
          strength: 0.7,
          fidelity: 0.4,
        ),
      ],
      referenceImages: [
        NaiReferenceImage(bytes: Uint8List.fromList([9, 9, 9])),
      ],
    );

    final payload = params.toApiPayload();
    final parameters = payload['parameters'] as Map<String, dynamic>;

    expect(parameters['normalize_reference_strength_multiple'], isTrue);
    expect(parameters['director_reference_images'], hasLength(1));
    final descriptions =
        parameters['director_reference_descriptions'] as List<dynamic>;
    final description = descriptions.single as Map<String, dynamic>;
    expect(
      (description['caption'] as Map<String, dynamic>)['base_caption'],
      'style',
    );
    expect(parameters['director_reference_strength_values'], <double>[0.7]);
    expect(
      (parameters['director_reference_secondary_strength_values'] as List)
          .single,
      closeTo(0.6, 0.0001),
    );
    expect(parameters.containsKey('reference_image_multiple'), isFalse);
  });

  test('V5 Precise Reference 发送 director 字段并跳过 Vibe', () {
    final params = NaiGenerationParams(
      prompt: '1girl',
      model: NaiModel.v5Full,
      preciseReferences: [
        NaiPreciseReference(
          bytes: Uint8List.fromList([1, 2, 3]),
          type: NaiPreciseRefType.character,
          strength: 0.8,
          fidelity: 0.6,
        ),
      ],
      referenceImages: [
        NaiReferenceImage(bytes: Uint8List.fromList([9, 9, 9])),
      ],
    );

    final parameters =
        params.toApiPayload()['parameters'] as Map<String, dynamic>;
    expect(NaiModel.v5Full.supportsPreciseReference, isTrue);
    expect(NaiModel.v45Full.supportsPreciseReference, isTrue);
    expect(parameters['director_reference_images'], hasLength(1));
    expect(parameters['director_reference_strength_values'], <double>[0.8]);
    expect(
      parameters['director_reference_secondary_strength_values'],
      <double>[0.0],
    );
    expect(parameters.containsKey('reference_image_multiple'), isFalse);
  });

  test('V5 outfit / prefer same outfit maps to official captions', () {
    final params = NaiGenerationParams(
      prompt: '1girl',
      model: NaiModel.v5Full,
      preciseReferences: [
        NaiPreciseReference(
          bytes: Uint8List.fromList([1, 2, 3]),
          type: NaiPreciseRefType.outfit,
          strength: 4.2,
        ),
        NaiPreciseReference(
          bytes: Uint8List.fromList([4, 5, 6]),
          type: NaiPreciseRefType.character,
          strength: 2.0,
          preferSameOutfit: true,
        ),
      ],
    );
    final parameters =
        params.toApiPayload()['parameters'] as Map<String, dynamic>;
    final descriptions =
        parameters['director_reference_descriptions'] as List<dynamic>;
    expect(
      ((descriptions[0] as Map)['caption'] as Map)['base_caption'],
      'costume',
    );
    expect(
      ((descriptions[1] as Map)['caption'] as Map)['base_caption'],
      'character_mainoutfit',
    );
    expect(
      parameters['director_reference_strength_values'],
      <double>[4.2, 2.0],
    );
    expect(
      parameters['director_reference_secondary_strength_values'],
      <double>[0.0, 0.0],
    );
  });
}
