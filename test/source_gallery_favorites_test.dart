import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novelai_harness/data/models/danbooru_models.dart';
import 'package:novelai_harness/data/services/aitag_service.dart';
import 'package:novelai_harness/data/services/danbooru_favorite_store.dart';
import 'package:novelai_harness/data/services/source_favorite_store.dart';
import 'package:novelai_harness/l10n/app_localizations.dart';
import 'package:novelai_harness/ui/features/studio/view_models/studio_view_model.dart';
import 'package:novelai_harness/ui/features/studio/widgets/source_gallery_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 1×1 透明 PNG：图源卡片/详情用 Image.file / Image.memory 渲染，必须是真图。
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Map<String, dynamic> _danbooruPostJson({int id = 42}) => <String, dynamic>{
  'id': id,
  'score': 12,
  'rating': 'g',
  'file_ext': 'png',
  'image_width': 800,
  'image_height': 1200,
  'tag_string': '1girl solo smile',
  'tag_string_artist': 'some_artist',
  'tag_string_character': '',
  'tag_string_copyright': '',
  'preview_file_url': 'https://cdn.example.test/preview.png',
  'file_url': 'https://cdn.example.test/original.png',
  'large_file_url': 'https://cdn.example.test/large.png',
  'source': 'https://example.test/source',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testRoot;
  late SourceFavoriteStore sourceFavorites;
  late DanbooruFavoriteStore danbooruFavorites;
  late AitagService aitag;
  late StudioViewModel viewModel;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    testRoot = Directory.systemTemp.createTempSync('source-gallery-fav-');
    sourceFavorites = SourceFavoriteStore.forTesting(
      Directory('${testRoot.path}/source'),
    );
    danbooruFavorites = DanbooruFavoriteStore.forTesting(
      Directory('${testRoot.path}/danbooru'),
    );
    await sourceFavorites.load();
    await danbooruFavorites.load();
    await sourceFavorites.save(
      scope: 'aitag',
      id: 'w1',
      title: 'AITag 收藏作品',
      bytes: _tinyPng,
      metadata: <String, dynamic>{
        'title': 'AITag 收藏作品',
        'tags': <String>['1girl', 'solo'],
        'imageCount': 1,
        'thumbUrl': 'https://img.example.test/thumb.png',
        'aiType': 'NAI',
      },
    );
    await sourceFavorites.save(
      scope: 'codex',
      id: 'c1',
      title: '法典 收藏条目',
      bytes: _tinyPng,
      metadata: <String, dynamic>{
        'title': '法典 收藏条目',
        'tags': '1girl, masterpiece, blue eyes',
        'negative': 'lowres',
        'rating': 'general',
        'note': '',
        'width': 832,
        'height': 1216,
        'imageFiles': <String>['cover.png'],
        'packId': 'test_pack',
      },
    );
    await danbooruFavorites.save(
      DanbooruPost.fromJson(_danbooruPostJson()),
      _tinyPng,
    );

    aitag = AitagService.forTesting(
      baseUrl: 'https://aitag.test',
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/api/ai_works_search':
            return http.Response(
              jsonEncode(<String, dynamic>{'items': []}),
              200,
            );
          case '/api/work/w1':
            return http.Response(
              jsonEncode(<String, dynamic>{
                'images': [
                  <String, dynamic>{'prompt_text': '1girl, solo, smile'},
                ],
              }),
              200,
            );
        }
        return http.Response.bytes(_tinyPng, 200);
      }),
    );

    viewModel = StudioViewModel(sessionLogBaseDir: testRoot.path);
    await viewModel.init();
  });

  tearDown(() {
    viewModel.dispose();
    try {
      testRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录清理失败不影响测试结论。
    }
  });

  Widget buildGallery() {
    return MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SourceGalleryView(
          viewModel: viewModel,
          onClose: () {},
          aitagService: aitag,
          sourceFavoriteStore: sourceFavorites,
          danbooruFavoriteStore: danbooruFavorites,
        ),
      ),
    );
  }

  Future<void> pumpGallery(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildGallery());
    await tester.pumpAndSettle();
  }

  testWidgets('顶部收藏 tab 按 AITag / 法典 / Danbooru 分来源展示本地收藏', (tester) async {
    await pumpGallery(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
    await tester.pumpAndSettle();

    // 默认 AITag 子页：只有 AITag 收藏可见。
    expect(find.text('AITag 收藏作品'), findsOneWidget);
    expect(find.text('法典 收藏条目'), findsNothing);
    expect(find.text('some artist'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '法典 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('法典 收藏条目'), findsOneWidget);
    expect(find.text('AITag 收藏作品'), findsNothing);
    expect(find.text('some artist'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Danbooru (1)'));
    await tester.pumpAndSettle();
    expect(find.text('some artist'), findsOneWidget);
    expect(find.text('AITag 收藏作品'), findsNothing);
    expect(find.text('法典 收藏条目'), findsNothing);

    // 收藏页卡片提供取消收藏与发送聊天入口（实际删除由同一回调处理）。
    await tester.tap(find.widgetWithText(ChoiceChip, 'AITag (1)'));
    await tester.pumpAndSettle();
    expect(find.text('AITag 收藏作品'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    expect(find.byTooltip('发送到聊天框'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AITag 详情「发送到聊天框」只填充草稿不自动发送', (tester) async {
    await pumpGallery(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AITag 收藏作品'));
    await tester.pumpAndSettle();

    expect(find.text('发送到聊天框'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '发送到聊天框'));
    await tester.pumpAndSettle();

    final restore = viewModel.composerRestore;
    expect(restore, isNotNull);
    expect(restore!.text, '1girl, solo, smile');
    expect(viewModel.chatDraft, '1girl, solo, smile');
    // 只是填入输入框，禁止自动发送消息。
    expect(viewModel.messages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('attachTextToAgentComposer 只发布草稿恢复事件，不发送消息', () {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final root = Directory.systemTemp.createTempSync('attach-text-');
    final vm = StudioViewModel(sessionLogBaseDir: root.path);
    addTearDown(() {
      vm.dispose();
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    var notifications = 0;
    vm.addListener(() => notifications++);
    vm.attachTextToAgentComposer('1girl, solo, detailed background');

    expect(vm.chatDraft, '1girl, solo, detailed background');
    expect(vm.composerRestore?.text, '1girl, solo, detailed background');
    expect(vm.composerRestore?.images, isEmpty);
    expect(vm.messages, isEmpty);
    expect(notifications, greaterThan(0));
  });
}
