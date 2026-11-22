import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/models/nai_generation_params.dart';

void main() {
  final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

  test('img2img source lands in the payload parameters', () {
    final params = NaiGenerationParams(
      prompt: '1girl, solo',
      seed: 123,
      img2imgBytes: bytes,
      img2imgStrength: 0.42,
      img2imgNoise: 0.07,
    );
    final payload = params.toApiPayload();
    expect(payload['action'], 'img2img');
    final parameters = payload['parameters'] as Map<String, dynamic>;
    expect(parameters['image'], base64Encode(bytes));
    expect(parameters['strength'], 0.42);
    expect(parameters['noise'], 0.07);
    expect(parameters['color_correct'], isFalse);
    expect(parameters['extra_noise_seed'], 122);
  });

  test('plain text-to-image payload has no image fields', () {
    const params = NaiGenerationParams(prompt: '1girl');
    final payload = params.toApiPayload();
    expect(payload['action'], 'generate');
    final parameters = payload['parameters'] as Map<String, dynamic>;
    expect(parameters.containsKey('image'), isFalse);
    expect(parameters.containsKey('reference_image_multiple'), isFalse);
  });

  test('reference images land in the V5 payload', () {
    final params = NaiGenerationParams(
      prompt: '1girl',
      referenceImages: <NaiReferenceImage>[
        NaiReferenceImage(
          bytes: bytes,
          strength: 0.55,
          informationExtracted: 0.9,
        ),
      ],
    );
    final parameters =
        params.toApiPayload()['parameters'] as Map<String, dynamic>;
    expect(parameters['reference_image_multiple'], <String>[
      base64Encode(bytes),
    ]);
    expect(parameters['reference_strength_multiple'], <double>[0.55]);
    expect(parameters['reference_information_extracted_multiple'], <double>[
      0.9,
    ]);
    expect(parameters['normalize_reference_strength_multiple'], isFalse);
  });

  test('copyWith can set and clear the img2img source', () {
    final params = NaiGenerationParams(prompt: '1girl', img2imgBytes: bytes);
    final updated = params.copyWith(img2imgStrength: 0.7);
    expect(updated.img2imgBytes, bytes);
    expect(updated.img2imgStrength, 0.7);
    final cleared = updated.copyWith(clearImg2img: true);
    expect(cleared.img2imgBytes, isNull);
  });

  test('copyWith can clear reference images', () {
    final params = NaiGenerationParams(
      prompt: '1girl',
      referenceImages: <NaiReferenceImage>[NaiReferenceImage(bytes: bytes)],
    );
    expect(
      params.copyWith(clearReferenceImages: true).referenceImages,
      isEmpty,
    );
  });

  test('infill payload never uses img2img source or reference fields', () {
    final source = Uint8List.fromList(<int>[10, 11, 12]);
    final mask = Uint8List.fromList(<int>[255]);
    final img2img = Uint8List.fromList(<int>[20, 21, 22]);
    final params = NaiGenerationParams(
      prompt: '1girl',
      img2imgBytes: img2img,
      img2imgStrength: 0.42,
      img2imgNoise: 0.07,
      referenceImages: <NaiReferenceImage>[
        NaiReferenceImage(bytes: img2img, strength: 0.9),
      ],
    );

    final parameters =
        params.toInfillApiPayload(
              sourceBytes: source,
              maskBytes: mask,
              requestWidth: 64,
              requestHeight: 64,
              strength: 0.7,
              noise: 0.05,
            )['parameters']
            as Map<String, dynamic>;

    expect(parameters['image'], base64Encode(source));
    expect(parameters['mask'], base64Encode(mask));
    expect(parameters['strength'], 0.7);
    expect(parameters['noise'], 0.05);
    expect(parameters.containsKey('reference_image_multiple'), isFalse);
  });

  test(
    'private tags and img2img strengths persist through toJson/fromJson',
    () {
      final params = NaiGenerationParams(
        prompt: '1girl',
        stripTags: 'secret-tag',
        stripNegativeTags: 'secret-uc',
        img2imgStrength: 0.42,
        img2imgNoise: 0.07,
      );
      final restored = NaiGenerationParams.fromJson(params.toJson());
      expect(restored.stripTags, 'secret-tag');
      expect(restored.stripNegativeTags, 'secret-uc');
      expect(restored.img2imgStrength, 0.42);
      expect(restored.img2imgNoise, 0.07);
    },
  );
}
