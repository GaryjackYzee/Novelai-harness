import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novelai_harness/data/services/wd14_online_service.dart';

void main() {
  test('WD14 解析 HuggingFace 数组并按阈值过滤排序', () async {
    final service = Wd14OnlineService(
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer token');
        final body = jsonEncode([
          {'label': 'long_hair', 'score': 0.9},
          {'label': 'blue_eyes', 'score': 0.6},
          {'label': 'noise', 'score': 0.1},
        ]);
        return http.Response(body, 200);
      }),
    );
    final tags = await service.tag(
      imageBytes: const [1, 2, 3],
      token: 'token',
      threshold: 0.35,
    );
    expect(tags.map((tag) => tag.name), ['long hair', 'blue eyes']);
  });

  test('WD14 解析通用 tags map 端点', () async {
    final service = Wd14OnlineService(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'tags': {'silver_hair': 0.8, 'smile': 0.4},
          }),
          200,
        );
      }),
    );
    final tags = await service.tag(imageBytes: const [1], threshold: 0.3);
    expect(tags.first.name, 'silver hair');
    expect(tags.length, 2);
  });

  test('WD14 非 2xx 抛 Wd14Exception', () async {
    final service = Wd14OnlineService(
      client: MockClient((request) async => http.Response('bad', 500)),
    );
    await expectLater(
      service.tag(imageBytes: const [1]),
      throwsA(isA<Wd14Exception>()),
    );
  });

  test('WD14 解析 Gradio Space 的 confidences', () async {
    final service = Wd14OnlineService(
      client: MockClient((request) async {
        final body = jsonEncode({
          'data': [
            {'label': 'general', 'confidences': []},
            '1girl, long_hair',
            {
              'label': '1girl',
              'confidences': [
                {'label': '1girl', 'confidence': 0.99},
                {'label': 'long_hair', 'confidence': 0.8},
                {'label': 'noise', 'confidence': 0.1},
              ],
            },
          ],
        });
        return http.Response(body, 200);
      }),
    );
    final tags = await service.tag(imageBytes: const [1, 2, 3], threshold: 0.3);
    expect(tags.map((tag) => tag.name), ['1girl', 'long hair']);
  });
}
