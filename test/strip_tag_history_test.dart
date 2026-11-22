import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/repositories/novelai_repository.dart';
import 'package:novelai_harness/data/services/config_service.dart';
import 'package:novelai_harness/data/services/novelai_service.dart';
import 'package:novelai_harness/l10n/app_localizations.dart';
import 'package:novelai_harness/ui/core/theme/app_theme.dart';
import 'package:novelai_harness/ui/features/studio/view_models/studio_view_model.dart';
import 'package:novelai_harness/ui/features/studio/widgets/prompts_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('擦除 tag 输入历史缓存', () {
    test('默认无历史；记录后最新在前，新实例可从持久化加载', () async {
      final service = ConfigService();
      expect(await service.loadStripTagHistory(), isEmpty);

      await service.recordStripTagHistory('silver hair');
      await service.recordStripTagHistory('blue eyes');

      final reloaded = await ConfigService().loadStripTagHistory();
      expect(reloaded, ['blue eyes', 'silver hair']);
    });

    test('重复输入去重并移到最前，空输入不污染历史', () async {
      final service = ConfigService();
      await service.recordStripTagHistory('a');
      await service.recordStripTagHistory('b');
      await service.recordStripTagHistory('c');

      expect(await service.recordStripTagHistory('a'), ['a', 'c', 'b']);
      expect(await service.recordStripTagHistory('  c  '), ['c', 'a', 'b']);
      expect(await service.recordStripTagHistory('   '), ['c', 'a', 'b']);
    });

    test('最多保留 10 条，超出的最旧记录被丢弃', () async {
      final service = ConfigService();
      for (var i = 0; i < 12; i++) {
        await service.recordStripTagHistory('tag $i');
      }

      final history = await service.loadStripTagHistory();
      expect(history.length, ConfigService.stripTagHistoryLimit);
      expect(history.first, 'tag 11');
      expect(history.last, 'tag 2');
      expect(history, isNot(contains('tag 0')));
      expect(history, isNot(contains('tag 1')));
    });

    test('正面与负面历史互相独立', () async {
      final service = ConfigService();
      await service.recordStripTagHistory('private tag');
      await service.recordStripTagHistory('private uc', negative: true);

      expect(await service.loadStripTagHistory(), ['private tag']);
      expect(await service.loadStripTagHistory(negative: true), ['private uc']);
    });

    test('清空只移除对应历史', () async {
      final service = ConfigService();
      await service.recordStripTagHistory('private tag');
      await service.recordStripTagHistory('private uc', negative: true);

      await service.clearStripTagHistory();
      expect(await service.loadStripTagHistory(), isEmpty);
      expect(await service.loadStripTagHistory(negative: true), ['private uc']);

      await service.clearStripTagHistory(negative: true);
      expect(await service.loadStripTagHistory(negative: true), isEmpty);
    });

    test('重启后仍可查 (重置偏好单例再从存储加载)', () async {
      await ConfigService().recordStripTagHistory('persisted tag');
      await ConfigService().recordStripTagHistory(
        'persisted uc',
        negative: true,
      );

      SharedPreferences.resetStatic();

      expect(await ConfigService().loadStripTagHistory(), ['persisted tag']);
      expect(await ConfigService().loadStripTagHistory(negative: true), [
        'persisted uc',
      ]);
    });

    test('加载时归一化空白/空项/重复项等脏数据', () async {
      SharedPreferences.setMockInitialValues({
        'novelai_strip_tag_history': ['  a  ', '', 'a', 'b', '  '],
      });

      expect(await ConfigService().loadStripTagHistory(), ['a', 'b']);
    });
  });

  group('擦除 tag 历史 UI', () {
    late StudioViewModel viewModel;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final configService = ConfigService();
      await configService.loadConfig();
      viewModel = StudioViewModel(
        configService: configService,
        repository: NovelAiRepository(service: NovelAiService()),
      );
    });

    Widget buildTestWidget(Widget child) {
      return MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.darkTheme,
        home: Scaffold(body: child),
      );
    }

    testWidgets('失焦提交后可从历史下拉回填，擦除语义保持不变', (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        buildTestWidget(PromptsPage(viewModel: viewModel)),
      );
      await tester.pumpAndSettle();

      final stripField = find.byKey(const Key('strip_tags_field'));
      expect(stripField, findsOneWidget);

      await tester.enterText(stripField, 'silver hair, blue eyes');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(await viewModel.loadStripTagHistory(), ['silver hair, blue eyes']);
      expect(viewModel.params.stripTags, 'silver hair, blue eyes');

      // 清空输入后从历史下拉回填，避免与输入框现有文本混淆。
      await tester.enterText(stripField, '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('strip_tags_history_button')));
      await tester.pumpAndSettle();

      final historyItem = find.text('silver hair, blue eyes');
      expect(historyItem, findsOneWidget);
      await tester.tap(historyItem);
      await tester.pumpAndSettle();

      final controller = tester.widget<TextField>(stripField).controller!;
      expect(controller.text, 'silver hair, blue eyes');
      expect(viewModel.params.stripTags, 'silver hair, blue eyes');
      // stripTags 仍只用于擦除元数据：请求提示词携带，元数据注释剔除。
      expect(
        viewModel.params.generationPrompt,
        contains('silver hair, blue eyes'),
      );
      expect(
        viewModel.params.toMetadataComment(seed: 1)['prompt'],
        isNot(contains('silver hair')),
      );
      expect(await viewModel.loadStripTagHistory(), ['silver hair, blue eyes']);
    });
  });
}
