import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novelai_harness/data/models/danbooru_models.dart';
import 'package:novelai_harness/data/services/config_service.dart';
import 'package:novelai_harness/data/services/danbooru_favorite_store.dart';
import 'package:novelai_harness/data/services/danbooru_gallery_service.dart';
import 'package:novelai_harness/data/services/network_proxy_service.dart';
import 'package:novelai_harness/data/services/source_favorite_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _postJson({
  int id = 1,
  String fileExt = 'jpg',
  String preview = 'https://cdn.example.test/preview.jpg',
  String file = 'https://cdn.example.test/original.jpg',
  String large = 'https://cdn.example.test/large.jpg',
}) => <String, dynamic>{
  'id': id,
  'score': 12,
  'rating': 'g',
  'file_ext': fileExt,
  'image_width': 800,
  'image_height': 1200,
  'tag_string': '1girl solo',
  'tag_string_artist': 'some_artist',
  'tag_string_character': '',
  'tag_string_copyright': '',
  'preview_file_url': preview,
  'file_url': file,
  'large_file_url': large,
  'source': 'https://example.test/source',
};

void main() {
  group('DanbooruGalleryService', () {
    test('默认补 rating:general，并过滤视频/无缩略图帖子', () async {
      Uri? requested;
      final service = DanbooruGalleryService.forTesting(
        baseUrl: 'https://danbooru.test',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode([
              _postJson(id: 1),
              _postJson(id: 2, fileExt: 'mp4'),
              _postJson(id: 3, preview: '', file: '', large: ''),
            ]),
            200,
          );
        }),
      );

      final posts = await service.search('1girl');

      expect(
        requested!.queryParameters['tags'],
        '1girl order:rank rating:general',
      );
      expect(posts.map((post) => post.id), <int>[1]);
      expect(posts.single.displayTags, 'some artist');
    });

    test('按 rating 参数拼接标签，all 不加分级', () async {
      final queries = <String>[];
      final service = DanbooruGalleryService.forTesting(
        baseUrl: 'https://danbooru.test',
        client: MockClient((request) async {
          queries.add(request.url.queryParameters['tags'] ?? '');
          return http.Response(jsonEncode([_postJson()]), 200);
        }),
      );

      await service.search('1girl', rating: 'questionable');
      await service.search('1girl', rating: 'all');
      expect(queries[0], '1girl order:rank rating:questionable');
      expect(queries[1], '1girl order:rank');
    });

    test('显式 rating:explicit 不重复追加', () async {
      Uri? requested;
      final service = DanbooruGalleryService.forTesting(
        baseUrl: 'https://danbooru.test',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(jsonEncode([_postJson()]), 200);
        }),
      );

      await service.search('1girl rating:explicit');

      expect(
        requested!.queryParameters['tags'],
        '1girl rating:explicit order:rank',
      );
    });
  });

  group('DanbooruFavoriteStore', () {
    test('保存/重载/删除本地收藏', () async {
      final root = Directory.systemTemp.createTempSync('danbooru-favorites-');
      addTearDown(() => root.deleteSync(recursive: true));
      final post = DanbooruPost.fromJson(_postJson(id: 42));
      final store = DanbooruFavoriteStore.forTesting(root);
      await store.load();

      final favorite = await store.save(
        post,
        Uint8List.fromList(<int>[1, 2, 3]),
      );
      expect(File(favorite.localPath).existsSync(), isTrue);
      expect(store.contains(42), isTrue);

      final reloaded = DanbooruFavoriteStore.forTesting(root);
      await reloaded.load();
      expect(reloaded.contains(42), isTrue);
      expect(await reloaded.readBytes(42), <int>[1, 2, 3]);

      await reloaded.remove(42);
      expect(reloaded.contains(42), isFalse);
      expect(File(favorite.localPath).existsSync(), isFalse);
      expect(File(p.join(root.path, 'favorites.json')).existsSync(), isTrue);
    });
  });

  group('SourceFavoriteStore', () {
    test('AITag/法典收藏保存、重载、按 scope 过滤与删除', () async {
      final root = Directory.systemTemp.createTempSync('source-favorites-');
      addTearDown(() => root.deleteSync(recursive: true));
      final store = SourceFavoriteStore.forTesting(root);
      await store.load();

      final aitag = await store.save(
        scope: 'aitag',
        id: 'w1',
        title: 'work',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        metadata: <String, dynamic>{
          'tags': <String>['1girl'],
        },
      );
      await store.save(
        scope: 'codex',
        id: 'c1',
        title: 'codex',
        bytes: Uint8List.fromList(<int>[4, 5, 6]),
      );

      final reloaded = SourceFavoriteStore.forTesting(root);
      await reloaded.load();
      expect(reloaded.contains('aitag', 'w1'), isTrue);
      expect(reloaded.contains('codex', 'c1'), isTrue);
      expect(reloaded.forScope('aitag'), hasLength(1));
      expect(await reloaded.readBytes('aitag', 'w1'), <int>[1, 2, 3]);

      await reloaded.remove('aitag', 'w1');
      expect(reloaded.contains('aitag', 'w1'), isFalse);
      expect(File(aitag.localPath).existsSync(), isFalse);
      expect(reloaded.contains('codex', 'c1'), isTrue);
    });
  });

  group('NetworkProxyService', () {
    tearDown(() {
      NetworkProxyService.instance.configure(
        enabled: false,
        host: '',
        port: 7890,
      );
    });

    test('代理按功能开关与配置持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ConfigService();
      final config = (await service.loadConfig()).copyWith(
        proxyEnabled: true,
        proxyHost: '127.0.0.1',
        proxyPort: 7890,
        proxyUseNovelAi: false,
        proxyUseAgent: true,
        proxyUseGallery: false,
      );
      await service.saveConfig(config);

      final reloaded = await ConfigService().loadConfig();
      expect(reloaded.proxyEnabled, isTrue);
      expect(reloaded.proxyHost, '127.0.0.1');
      expect(reloaded.proxyPort, 7890);
      expect(reloaded.proxyUseNovelAi, isFalse);
      expect(reloaded.proxyUseAgent, isTrue);
      expect(reloaded.proxyUseGallery, isFalse);
    });

    test('校验主机/端口并生成代理指令', () {
      expect(NetworkProxyService.isValidHost('127.0.0.1'), isTrue);
      expect(NetworkProxyService.isValidHost('http://127.0.0.1'), isFalse);
      expect(NetworkProxyService.isValidPort(7890), isTrue);
      expect(NetworkProxyService.isValidPort(0), isFalse);

      NetworkProxyService.instance.configure(
        enabled: true,
        host: '127.0.0.1',
        port: 7890,
      );
      expect(
        NetworkProxyService.instance.proxyDirectiveFor(
          Uri.parse('https://danbooru.donmai.us/posts.json'),
        ),
        'PROXY 127.0.0.1:7890',
      );
      expect(
        NetworkProxyService.instance.proxyDirectiveFor(
          Uri.parse('http://127.0.0.1:8188/'),
        ),
        'DIRECT',
      );

      NetworkProxyService.instance.configure(
        enabled: true,
        host: '127.0.0.1',
        port: 7890,
        useNovelAi: false,
        useAgent: true,
        useGallery: true,
      );
      expect(
        NetworkProxyService.instance.usesProxy(NetworkFeature.novelAi),
        isFalse,
      );
      expect(
        NetworkProxyService.instance.usesProxy(NetworkFeature.agent),
        isTrue,
      );
      expect(
        NetworkProxyService.instance.usesProxy(NetworkFeature.gallery),
        isTrue,
      );
    });
  });
}
