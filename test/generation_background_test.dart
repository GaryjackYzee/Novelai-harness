import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/models/novelai_models.dart';
import 'package:novelai_harness/data/repositories/novelai_repository.dart';
import 'package:novelai_harness/data/services/config_service.dart';
import 'package:novelai_harness/l10n/app_localizations.dart';
import 'package:novelai_harness/ui/core/widgets/app_thumbnail_card.dart';
import 'package:novelai_harness/ui/features/studio/view_models/studio_view_model.dart';
import 'package:novelai_harness/ui/features/studio/widgets/canvas_history_sidebar.dart';
import 'package:novelai_harness/ui/features/studio/widgets/generate_dock.dart';
import 'package:novelai_harness/ui/features/studio/widgets/image_stream_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 最小合法 PNG 头 (仅用于流式帧占位，不参与解码断言)
final Uint8List _pngBytes = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
]);

class _Config extends ConfigService {
  @override
  Future<AppConfig> loadConfig() async => const AppConfig(
    novelAiKey: 'mock-only',
    enableStreamPreview: true,
    enableImagePersistence: false,
    enableTagDictionaryAutoUpdate: false,
    autoSaveImages: false,
  );
}

/// 完全替换网络边界：流式生成由测试手动喂帧，不消耗 Anlas、不访问 NovelAI。
///
/// 控制器在 [generateStream] 被调用时才创建 (即测试体内)，确保它归属
/// 当前测试的 fake-async zone，避免取消订阅的 Future 挂在真实事件循环上。
class _StreamRepository extends NovelAiRepository {
  StreamController<NaiStreamProgress>? streamController;

  @override
  Future<NaiAccountInfo> fetchAccountInfo({required String apiKey}) async =>
      NaiAccountInfo.fromJson({
        'subscription': {'tier': 3, 'active': true},
      });

  @override
  Stream<NaiStreamProgress> generateStream({
    required String apiKey,
    required NaiGenerationParams params,
    required String saveDir,
    bool enablePersistence = true,
    int maxImages = 50,
    bool stripMetadata = false,
    bool stripStealth = false,
    bool enableWatermark = false,
    bool keepOriginalImage = false,
    WatermarkConfig? watermarkConfig,
    Uint8List? watermarkBytes,
    bool autoSave = true,
    String imageSaveTemplate = '',
  }) {
    final controller = StreamController<NaiStreamProgress>();
    streamController = controller;
    return controller.stream;
  }

  NaiGeneratedImage makeImage(NaiGenerationParams params) => NaiGeneratedImage(
    id: 'mock-image',
    bytes: _pngBytes,
    params: params,
    seed: params.seed,
    isOpusFree: true,
    createdAt: DateTime(2026),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _StreamRepository repository;
  late StudioViewModel viewModel;
  late Future<void> generationFuture;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('generation-bg-test-');
    repository = _StreamRepository();
    viewModel = StudioViewModel(
      configService: _Config(),
      repository: repository,
      sessionLogBaseDir: tempDir.path,
    );
    await viewModel.init();
    viewModel.updateParams(
      viewModel.params.copyWith(
        prompt: 'background generation test',
        seed: 1,
        seedMode: NaiSeedMode.fixed,
        seedTiming: NaiSeedTiming.before,
      ),
    );
    generationFuture = Future<void>.value();
  });

  tearDown(() async {
    try {
      if (viewModel.isGenerating) {
        await viewModel.abortGeneration().timeout(const Duration(seconds: 2));
      }
      await generationFuture
          .catchError((_) {})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 收尾超时不阻塞其他测试；生产路径的回调由测试各自断言。
    }
    await viewModel.flushPendingSaves();
    viewModel.dispose();
    repository.streamController?.close();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // 目录清理失败不影响断言
    }
  });

  /// 生成中的流式请求由测试手动推进，先等到 isGenerating 点亮。
  Future<void> startGeneration({bool awaitSteps = false}) async {
    generationFuture = viewModel.generateImage();
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!viewModel.isGenerating || repository.streamController == null) {
      if (DateTime.now().isAfter(deadline)) {
        fail('generateImage 未在超时前进入 isGenerating 状态');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (awaitSteps) {
      for (var i = 0; i < 100; i++) {
        if (viewModel.liveTotalSteps > 0) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() predicate) async {
    for (var i = 0; i < 80; i++) {
      if (predicate()) return;
      await tester.pump(const Duration(milliseconds: 10));
    }
    fail('Widget 测试等待条件超时');
  }

  Widget wrapApp(Widget Function() childBuilder) => MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) => childBuilder(),
      ),
    ),
  );

  test('生成中可转后台/回前台，后台仍接收进度，终止后复位且不落图', () async {
    await startGeneration(awaitSteps: true);
    expect(viewModel.generationBackgrounded, isFalse);
    expect(viewModel.liveTotalSteps, viewModel.params.effectiveSteps);

    viewModel.backgroundGeneration();
    expect(viewModel.isGenerating, isTrue, reason: '转后台不能终止请求');
    expect(viewModel.generationBackgrounded, isTrue);

    repository.streamController!.add(
      NaiStreamProgress.intermediate(
        previewImage: _pngBytes,
        currentStep: 7,
        totalSteps: viewModel.liveTotalSteps,
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (viewModel.liveCurrentStep != 7) {
      if (DateTime.now().isAfter(deadline)) fail('后台生成没有再接收流式进度');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(viewModel.livePreviewBytes, isNotNull);

    viewModel.foregroundGeneration();
    expect(viewModel.generationBackgrounded, isFalse);
    expect(viewModel.isGenerating, isTrue);

    viewModel.backgroundGeneration();
    await viewModel.abortGeneration();
    expect(viewModel.isGenerating, isFalse);
    expect(viewModel.generationBackgrounded, isFalse);
    expect(viewModel.livePreviewBytes, isNull);
    expect(viewModel.gallery, isEmpty, reason: '丢弃后不应落任何历史图');
  });

  test('后台生成完成时自动复位并落图', () async {
    await startGeneration(awaitSteps: true);
    viewModel.backgroundGeneration();
    expect(viewModel.generationBackgrounded, isTrue);

    final image = repository.makeImage(viewModel.params);
    repository.addImageForTesting(image);
    repository.streamController!.add(
      NaiStreamProgress.finalResult(
        finalImage: _pngBytes,
        generatedImage: image,
        totalSteps: viewModel.liveTotalSteps,
      ),
    );
    await repository.streamController!.close();
    await generationFuture;

    expect(viewModel.isGenerating, isFalse);
    expect(viewModel.generationBackgrounded, isFalse);
    expect(viewModel.gallery, hasLength(1));
    expect(viewModel.selectedImage?.id, image.id);
  });

  testWidgets('占位卡提供丢弃/转后台；转后台后画布隐藏占位卡并可恢复', (tester) async {
    final controller = CanvasStreamController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrapApp(
        () => SizedBox(
          width: 800,
          height: 600,
          child: ImageStreamView(viewModel: viewModel, controller: controller),
        ),
      ),
    );
    await tester.pump();

    generationFuture = viewModel.generateImage();
    await pumpUntil(tester, () => viewModel.isGenerating);
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byType(CanvasGeneratingCard), findsOneWidget);
    expect(find.text('转后台'), findsOneWidget);
    expect(find.text('丢弃'), findsOneWidget);

    await tester.tap(find.text('转后台'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(viewModel.generationBackgrounded, isTrue);
    expect(viewModel.isGenerating, isTrue);
    expect(find.byType(CanvasGeneratingCard), findsNothing);
    expect(find.byType(BackgroundGenerationBanner), findsOneWidget);
    expect(find.text('图片正在后台生成'), findsOneWidget);
    expect(find.text('查看生成'), findsOneWidget);

    // 后台期间流式步数仍在小进度条上刷新
    repository.streamController!.add(
      NaiStreamProgress.intermediate(
        previewImage: _pngBytes,
        currentStep: 5,
        totalSteps: viewModel.liveTotalSteps,
      ),
    );
    await tester.pump();
    expect(find.text('5/${viewModel.liveTotalSteps}'), findsOneWidget);

    await tester.tap(find.text('查看生成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(viewModel.generationBackgrounded, isFalse);
    expect(find.byType(BackgroundGenerationBanner), findsNothing);
    expect(find.byType(CanvasGeneratingCard), findsOneWidget);

    await tester.tap(find.text('丢弃'));
    for (var i = 0; i < 80 && viewModel.isGenerating; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
    expect(viewModel.isGenerating, isFalse);
    expect(viewModel.generationBackgrounded, isFalse);
    expect(find.byType(CanvasGeneratingCard), findsNothing);
    expect(viewModel.gallery, isEmpty);
  });

  testWidgets('生成坞与历史侧栏在后台时提供查看生成恢复入口', (tester) async {
    final controller = CanvasStreamController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrapApp(
        () => Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 360,
            child: GenerateDock(viewModel: viewModel),
          ),
        ),
      ),
    );
    await tester.pump();

    generationFuture = viewModel.generateImage();
    await pumpUntil(tester, () => viewModel.isGenerating);
    viewModel.backgroundGeneration();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byType(BackgroundGenerationBanner), findsOneWidget);
    expect(find.text('查看生成'), findsOneWidget);

    await tester.tap(find.text('查看生成'));
    await tester.pump();
    expect(viewModel.generationBackgrounded, isFalse);
    expect(find.byType(BackgroundGenerationBanner), findsNothing);

    // 历史侧栏：后台生成不再插入实时预览缩略图，只保留一条恢复入口。
    viewModel.backgroundGeneration();
    repository.addImageForTesting(repository.makeImage(viewModel.params));
    await tester.pumpWidget(
      wrapApp(
        () => SizedBox(
          width: 120,
          height: 600,
          child: CanvasHistorySidebar(
            viewModel: viewModel,
            selectedImage: viewModel.gallery.first,
            stream: controller,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byType(BackgroundGenerationBanner), findsOneWidget);
    expect(find.text('查看生成'), findsOneWidget);
    // 只有一张历史缩略图，没有额外的生成中预览缩略图。
    expect(find.byType(AppThumbnailCard), findsOneWidget);
  });
}
