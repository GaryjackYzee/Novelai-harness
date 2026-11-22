import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/presets/agent_preset.dart';
import 'package:novelai_harness/data/services/config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('V5 Full 绘图专家是默认内置预设，且不含 Novi/V4.5 人设', () {
    final preset = BuiltinPresets.v5FullExpert;
    expect(preset.id, 'novelai-v5-full-art-expert');
    expect(preset.name, 'NovelAI V5 Full 绘图专家');
    expect(preset.isBuiltin, isTrue);
    expect(BuiltinPresets.all.first.id, preset.id);
    expect(preset.enabledSkillIds, contains('v5-architect'));
    expect(preset.enabledSkillIds, contains('inpaint-specialist'));
    expect(preset.enabledSkillIds, isNot(contains('novi')));
    expect(preset.enabledToolNames, contains('novelai_generate'));
    expect(preset.enabledToolNames, contains('library_query'));
    expect(preset.enabledToolNames, contains('memory'));
    expect(preset.systemPrompt, contains('V5 Full'));
    expect(preset.systemPrompt, isNot(contains('Novi')));
    expect(preset.systemPrompt, isNot(contains('V4.5')));
  });

  test('无配置时默认切到 V5 Full 绘图专家', () async {
    SharedPreferences.setMockInitialValues({});
    final config = await ConfigService().loadConfig();
    expect(config.activePresetId, BuiltinPresets.v5FullExpert.id);
    expect(
      config.presets.any(
        (preset) => preset.id == BuiltinPresets.v5FullExpert.id,
      ),
      isTrue,
    );
  });

  test('旧默认 V5 架构师自动迁移到 V5 Full 绘图专家', () async {
    SharedPreferences.setMockInitialValues({
      'active_preset_id': BuiltinPresets.v5Architect.id,
    });
    final config = await ConfigService().loadConfig();
    expect(config.activePresetId, BuiltinPresets.v5FullExpert.id);
  });

  test('升级后首次启动把当前 Novi/自定义预设也切到新默认', () async {
    SharedPreferences.setMockInitialValues({'active_preset_id': 'preset_novi'});
    final config = await ConfigService().loadConfig();
    expect(config.activePresetId, BuiltinPresets.v5FullExpert.id);
  });
}
