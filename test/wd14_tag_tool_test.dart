import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/tools/wd14_tag_tool.dart';
import 'package:novelai_harness/data/services/wd14_online_service.dart';

void main() {
  test('wd14_tag 按 source 选择来源并写入提示词', () async {
    String? calledSource;
    List<Wd14Tag>? applied;
    final tool = Wd14TagTool(
      tagImage: ({required String source, double? threshold}) async {
        calledSource = source;
        return const [
          Wd14Tag(name: '1girl', score: 0.9),
          Wd14Tag(name: 'smile', score: 0.5),
        ];
      },
      applyTags: (tags) async => applied = tags,
    );

    final result = await tool.execute(
      'call-1',
      {'source': 'chat', 'apply': true, 'threshold': 0.4},
    );
    expect(calledSource, 'chat');
    expect(applied, hasLength(2));
    expect(result.isError, isFalse);
    expect(result.content, contains('1girl'));
  });

  test('wd14_tag 默认反推画布', () async {
    String? calledSource;
    final tool = Wd14TagTool(
      tagImage: ({required String source, double? threshold}) async {
        calledSource = source;
        return const [Wd14Tag(name: 'solo', score: 0.8)];
      },
      applyTags: (_) async {},
    );
    await tool.execute('call-2', {});
    expect(calledSource, 'canvas');
  });

  test('wd14_tag 把 Wd14Exception 转为工具错误', () async {
    final tool = Wd14TagTool(
      tagImage: ({required String source, double? threshold}) async {
        throw Wd14Exception('端点不可达');
      },
      applyTags: (_) async {},
    );
    final result = await tool.execute('call-3', {});
    expect(result.isError, isTrue);
    expect(result.content, contains('端点不可达'));
  });
}
