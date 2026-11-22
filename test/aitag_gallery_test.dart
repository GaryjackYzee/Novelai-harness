import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novelai_harness/data/services/aitag_service.dart';

void main() {
  test('AITag parses all original images and resolves NAI badge', () async {
    final service = AitagService.forTesting(
      baseUrl: 'https://aitag.test',
      client: MockClient((request) async {
        if (request.url.path == '/api/ai_works_search') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 7,
                  'title': 'work',
                  'tags': ['1girl'],
                  'original_urls': [
                    'https://img.test/1.png',
                    'https://img.test/2.png',
                  ],
                  'AI_type': 'NAI',
                  'create_date': '2026-01-01',
                  'image_count': 2,
                },
              ],
            }),
            200,
          );
        }
        final comment = jsonEncode({
          'model_name': 'NovelAI Diffusion V5',
          'uc': 'lowres',
          'width': 832,
          'height': 1216,
          'steps': 28,
          'scale': 5.0,
          'sampler': 'k_euler',
          'noise_schedule': 'karras',
          'seed': 42,
        });
        return http.Response(
          jsonEncode({
            'images': [
              {
                'prompt_text': '1girl, solo',
                'ai_json': jsonEncode({'Comment': comment}),
              },
            ],
          }),
          200,
        );
      }),
    );

    final works = await service.search('1girl');
    expect(works.single.imageUrls, hasLength(2));
    expect(works.single.aiType, 'NAI');

    final badges = await service.resolveModelBadges(<String>['7']);
    expect(badges['7'], 'NAI5');

    final detail = await service.work('7');
    expect(detail.prompt, '1girl, solo');
    expect(detail.seed, 42);
  });
}
