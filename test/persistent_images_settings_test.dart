import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/services/config_service.dart';
import 'package:novelai_harness/l10n/app_localizations.dart';
import 'package:novelai_harness/ui/features/settings/widgets/defaults_settings_tab.dart';
import 'package:novelai_harness/ui/features/studio/view_models/studio_view_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpTab(
    WidgetTester tester, {
    Locale locale = const Locale('zh'),
    AppConfig config = const AppConfig(),
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final draft = DefaultsSettingsDraft(config);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(child: DefaultsSettingsTab(draft: draft)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('图片持久发送开关在上下文管理分组渲染', (tester) async {
    await pumpTab(tester);
    expect(find.text('图片持久发送'), findsOneWidget);
    // 上游合并后压缩开关走 AppSettingTile，原生 Switch 只剩图片持久发送一项
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, isNotEmpty);
    expect(switches.first.value, isFalse); // 默认关闭 = 保持 imageEpoch 折叠现状
  });

  testWidgets('切换开关后控件状态翻转', (tester) async {
    await pumpTab(tester);
    final target = find.byType(Switch).first;
    await tester.tap(target);
    await tester.pumpAndSettle();
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.first.value, isTrue);
  });

  test('AppConfig.agentPersistentImages 默认关闭且可持久化往返', () async {
    expect(const AppConfig().agentPersistentImages, isFalse);
    expect(
      const AppConfig()
          .copyWith(agentPersistentImages: true)
          .agentPersistentImages,
      isTrue,
    );
    // 不传时保持原值
    expect(
      const AppConfig(agentPersistentImages: true)
          .copyWith()
          .agentPersistentImages,
      isTrue,
    );
  });

  test('AppConfig.agentAutoApproveAnlas defaults to disabled and persists', () {
    expect(const AppConfig().agentAutoApproveAnlas, 0);
    expect(
      const AppConfig().copyWith(agentAutoApproveAnlas: 10).agentAutoApproveAnlas,
      10,
    );
    expect(
      const AppConfig(agentAutoApproveAnlas: 10)
          .copyWith()
          .agentAutoApproveAnlas,
      10,
    );
  });

  test('agent auto approve threshold setter clamps to 0..500', () async {
    SharedPreferences.setMockInitialValues({});
    final vm = StudioViewModel();
    await vm.setAgentAutoApproveAnlas(600);
    expect(vm.config.agentAutoApproveAnlas, 500);
    await vm.setAgentAutoApproveAnlas(-1);
    expect(vm.config.agentAutoApproveAnlas, 0);
    await vm.setAgentAutoApproveAnlas(10);
    expect(vm.config.agentAutoApproveAnlas, 10);
    vm.dispose();
  });
}
