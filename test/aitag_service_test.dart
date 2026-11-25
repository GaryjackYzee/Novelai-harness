import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novelai_harness/data/models/aitag_models.dart';
import 'package:novelai_harness/data/services/aitag_service.dart';

AitagService _service(MockClient client) {
  return AitagService.forTesting(client: client, baseUrl: 'https://aitag.test');
}

void main() {
  group('AitagService.search', () {
    test('parses work rows and thumbnail', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/ai_works_search');
        expect(request.url.queryParameters['q'], '1girl');
        expect(request.url.queryParameters['page'], '2');
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': 151150897,
                'title': 'Untitled',
                'tags': ['R-18', 'オリジナル'],
                'create_date': '2026-10-22T22:46:59',
                'image_count': 1,
                'original_urls': [
                  'https://i.pximg.net/img-original/151150897_p0.png',
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final works = await _service(client).search('1girl', page: 2);
      expect(works, hasLength(1));
      expect(works.first.id, '151150897');
      expect(works.first.title, 'Untitled');
      expect(works.first.tags, contains('R-18'));
      expect(works.first.thumbUrl, contains('151150897_p0.png'));
      expect(works.first.imageCount, 1);
    });

    test('empty query falls back to 1girl', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['q'], '1girl');
        return http.Response(jsonEncode({'items': []}), 200);
      });
      final works = await _service(client).search('  ');
      expect(works, isEmpty);
    });

    test('404 becomes a readable exception', () async {
      final client = MockClient(
        (request) async => http.Response('missing', 404),
      );
      await expectLater(
        _service(client).search('no-such-thing'),
        throwsA(isA<AitagException>()),
      );
    });
  });

  group('AitagService.work', () {
    test(
      'parses prompt, parameters and dedupes inline character captions',
      () async {
        final aiJson = jsonEncode({
          'Comment': jsonEncode({
            'prompt': '1girl, solo, 2b, black hair, short hair',
            'uc': 'lowres, bad anatomy',
            'width': 832,
            'height': 1216,
            'steps': 28,
            'scale': 5.5,
            'seed': 1422686933,
            'sampler': 'k_euler_ancestral',
            'noise_schedule': 'karras',
            'model_name': 'NovelAI Diffusion V5',
            'v4_prompt': {
              'caption': {
                'base_caption': '1girl, solo',
                'char_captions': [
                  {
                    'char_caption': '2b, black hair, short hair',
                    'centers': [
                      {'x': 0.3, 'y': 0.4},
                    ],
                  },
                ],
              },
            },
          }),
        });
        final client = MockClient((request) async {
          expect(request.url.path, '/api/work/42');
          return http.Response(
            jsonEncode({
              'work': {'id': 42},
              'images': [
                {
                  'prompt_text': '1girl, solo, 2b, black hair, short hair',
                  'ai_json': aiJson,
                },
              ],
            }),
            200,
          );
        });
        final detail = await _service(client).work('42');
        expect(detail.prompt, '1girl, solo');
        expect(detail.negative, 'lowres, bad anatomy');
        expect(detail.modelName, 'NovelAI Diffusion V5');
        expect(detail.width, 832);
        expect(detail.height, 1216);
        expect(detail.steps, 28);
        expect(detail.scale, 5.5);
        expect(detail.seed, 1422686933);
        expect(detail.sampler, 'k_euler_ancestral');
        expect(detail.noiseSchedule, 'karras');
        expect(detail.characters, hasLength(1));
        expect(detail.characters.first.prompt, '2b, black hair, short hair');
        expect(detail.characters.first.x, 0.3);
        expect(detail.characters.first.y, 0.4);
      },
    );

    test('keeps the raw prompt when there are no character captions', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'images': [
              {'prompt_text': '1girl, solo, red dress'},
            ],
          }),
          200,
        );
      });
      final detail = await _service(client).work('7');
      expect(detail.prompt, '1girl, solo, red dress');
      expect(detail.characters, isEmpty);
      expect(detail.negative, isEmpty);
    });
  });

  group('AitagService.dedupePrompt', () {
    test('uses base caption when a character caption was inlined', () {
      expect(
        AitagService.dedupePrompt(
          prompt: '1girl, solo, 2b, black hair',
          basePrompt: '1girl, solo',
          characters: const [AitagCharacter(prompt: '2b, black hair')],
        ),
        '1girl, solo',
      );
    });

    test('strips captions when no base caption is available', () {
      expect(
        AitagService.dedupePrompt(
          prompt: '1girl, solo, 2b, black hair',
          basePrompt: '',
          characters: const [AitagCharacter(prompt: '2b, black hair')],
        ),
        '1girl, solo',
      );
    });

    test('keeps the text unchanged without characters', () {
      expect(
        AitagService.dedupePrompt(
          prompt: '1girl, solo',
          basePrompt: '1girl',
          characters: const [],
        ),
        '1girl, solo',
      );
    });
  });

  test('parses original_urls when the API returns a JSON string', () {
    final work = AitagWork.fromJson({
      'id': 1,
      'title': 't',
      'original_urls': '["https://i.pximg.net/a.png", "https://i.pximg.net/b.png"]',
      'tags': '["a", "b"]',
    });
    expect(work.thumbUrl, 'https://i.pximg.net/a.png');
    expect(work.imageUrls, hasLength(2));
    expect(work.tags, ['a', 'b']);
  });
}
