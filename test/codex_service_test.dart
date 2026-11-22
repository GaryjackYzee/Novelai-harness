import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novelai_harness/data/services/codex_service.dart';

const _packJson = {
  'title': '测试法典',
  'version': '2026.10',
  'tree': [
    {
      'name': '服装',
      'count': 3,
      'children': [
        {'name': '校服', 'count': 2},
      ],
    },
  ],
  'entries': [
    {
      'id': 'e1',
      'title': '校园制服',
      'tags': '1girl, school uniform, serafuku',
      'negative': 'lowres',
      'rating': 'safe',
      'note': '测试备注',
      'image': 'e1.jpg',
      'imageWidth': 832,
      'imageHeight': 1216,
    },
    {'id': 'e2', 'title': '泳装', 'tags': '1girl, swimsuit', 'image': 'e2.jpg'},
    {
      'id': 'e3',
      'title': '制服泳装混合',
      'tags': 'swimsuit, serafuku',
      'images': [
        {'path': 'e3-a.jpg'},
        {'path': 'e3-b.jpg'},
      ],
    },
  ],
};

CodexService _service(MockClient client) {
  return CodexService.forTesting(
    client: client,
    dataBase: 'https://codex.test/data/',
  );
}

MockClient _cdn() {
  return MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/data/current.json')) {
      return http.Response(
        jsonEncode({
          'release': '20261024',
          'manifest': '20261024/manifest.json',
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (path.endsWith('/data/20261024/codexes.json')) {
      return http.Response(
        jsonEncode([
          {
            'id': 'pack_a',
            'title': '法典 A',
            'version': '1',
            'entryCount': 3,
            'cover': 'cover.jpg',
          },
        ]),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (path.endsWith('/data/20261024/pack_a.json')) {
      return http.Response(
        jsonEncode(_packJson),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('listPacks resolves the release manifest', () async {
    final packs = await _service(_cdn()).listPacks();
    expect(packs, hasLength(1));
    expect(packs.first.id, 'pack_a');
    expect(packs.first.title, '法典 A');
    expect(packs.first.entryCount, 3);
  });

  test('search pages and maps entries', () async {
    final result = await _service(_cdn()).search(packId: 'pack_a', limit: 6);
    expect(result.total, 3);
    expect(result.page, 1);
    expect(result.pages, 1);
    expect(result.entries, hasLength(3));
    final first = result.entries.first;
    expect(first.title, '校园制服');
    expect(first.tags, contains('school uniform'));
    expect(first.negative, 'lowres');
    expect(first.width, 832);
    expect(first.imageFiles, ['e1.jpg']);
    expect(result.entries[2].imageFiles, ['e3-a.jpg', 'e3-b.jpg']);
    expect(result.categories, isNotEmpty);
    expect(result.categories.first.name, '服装');
    expect(result.categories.any((item) => item.path.contains('校服')), isTrue);
  });

  test('search filters by term and category', () async {
    final service = _service(_cdn());
    final byTerm = await service.search(
      packId: 'pack_a',
      query: '泳装',
      limit: 6,
    );
    expect(byTerm.total, 2);
    final byCategory = await service.search(
      packId: 'pack_a',
      category: '校服',
      limit: 6,
    );
    // The test pack does not put a path on entries, so category filtering keeps none.
    expect(byCategory.total, 0);
  });

  test('clamps the page size and slices past the end', () async {
    final service = _service(_cdn());
    final clamped = await service.search(packId: 'pack_a', limit: 2);
    // The service clamps tiny limits up to 6, so all three entries fit.
    expect(clamped.entries, hasLength(3));
    expect(clamped.pages, 1);
    final pastEnd = await service.search(packId: 'pack_a', page: 3, limit: 6);
    expect(pastEnd.entries, isEmpty);
    expect(pastEnd.pages, 1);
  });

  test('imageUrl escapes pack and file names', () {
    final url = _service(_cdn()).imageUrl('pack_a', 'a b.jpg');
    expect(url, 'https://assets.quicktagcloud.com/images/pack_a/a%20b.jpg');
  });

  test('non-200 responses raise CodexException', () async {
    final client = MockClient((request) async => http.Response('boom', 500));
    await expectLater(
      _service(client).search(packId: 'pack_a'),
      throwsA(isA<CodexException>()),
    );
  });
}
