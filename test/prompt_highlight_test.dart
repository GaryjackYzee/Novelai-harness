import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/ui/features/studio/widgets/rich_prompt_text_controller.dart';

/// 展开富文本 Span 树，返回所有非空叶子 Span (保持前后顺序)
List<TextSpan> _flatten(TextSpan span) {
  final result = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null && s.text!.isNotEmpty) result.add(s);
      s.children?.forEach(walk);
    }
  }

  span.children?.forEach(walk);
  return result;
}

/// 用当前上下文构建指定文本的富文本 Span
Future<List<TextSpan>> _buildFlat(
  WidgetTester tester,
  RichPromptTextController controller,
) async {
  TextSpan? span;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              withComposing: false,
            );
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return _flatten(span!);
}

void main() {
  testWidgets('{{pov,1boy}} 跨逗号区域连续底纹', (tester) async {
    final flat = await _buildFlat(
      tester,
      RichPromptTextController(text: '{{pov,1boy}}'),
    );

    // 富文本必须与原文逐字一致 (光标/IME 依赖)
    expect(flat.map((s) => s.text).join(), '{{pov,1boy}}');

    final regionBg = flat.first.style?.backgroundColor;
    expect(regionBg, isNotNull, reason: '括号权重区域应染色');
    for (final span in flat) {
      expect(
        span.style?.backgroundColor,
        regionBg,
        reason: '"${span.text}" 应共享同一括号权重底纹',
      );
    }
  });

  testWidgets('[[pov,1boy]] 跨逗号区域与单 tag 下调权重同色', (tester) async {
    final multi = await _buildFlat(
      tester,
      RichPromptTextController(text: '[[pov,1boy]]'),
    );
    final single = await _buildFlat(
      tester,
      RichPromptTextController(text: '[[pov]]'),
    );

    final singleBg = single
        .firstWhere((s) => s.text == 'pov')
        .style
        ?.backgroundColor;
    expect(singleBg, isNotNull);

    expect(multi.map((s) => s.text).join(), '[[pov,1boy]]');
    for (final span in multi) {
      expect(
        span.style?.backgroundColor,
        singleBg,
        reason: '"${span.text}" 应与 [[单 tag]] 下调权重同色',
      );
    }
  });

  testWidgets('嵌套括号整段连续底纹且不泄漏到相邻标签', (tester) async {
    final flat = await _buildFlat(
      tester,
      RichPromptTextController(text: '{{{pov,1boy}}}, 1girl'),
    );

    expect(flat.map((s) => s.text).join(), '{{{pov,1boy}}}, 1girl');

    final regionBg = flat.first.style?.backgroundColor;
    expect(regionBg, isNotNull);
    expect(
      flat.firstWhere((s) => s.text == '{{{pov').style?.backgroundColor,
      regionBg,
    );
    expect(
      flat.firstWhere((s) => s.text == '1boy}}}').style?.backgroundColor,
      regionBg,
    );
    // 区域内的逗号与区域后的分隔符/标签不受影响
    expect(
      flat.firstWhere((s) => s.text == ',').style?.backgroundColor,
      regionBg,
    );
    expect(
      flat.firstWhere((s) => s.text == ', ').style?.backgroundColor,
      isNull,
    );
    expect(
      flat.firstWhere((s) => s.text == '1girl').style?.backgroundColor,
      isNull,
    );
  });

  testWidgets('单 tag 与普通提示词行为保持', (tester) async {
    final single = await _buildFlat(
      tester,
      RichPromptTextController(text: '{{pov}}'),
    );
    final singleBg = single
        .firstWhere((s) => s.text == 'pov')
        .style
        ?.backgroundColor;
    expect(singleBg, isNotNull);
    expect(
      single.every((s) => s.style?.backgroundColor == singleBg),
      isTrue,
      reason: '单 tag 括号内应整体染色',
    );

    final plain = await _buildFlat(
      tester,
      RichPromptTextController(text: '1girl, solo'),
    );
    expect(plain.every((s) => s.style?.backgroundColor == null), isTrue);
  });

  testWidgets('未闭合括号与禁用标签不产生括号底纹', (tester) async {
    final unclosed = await _buildFlat(
      tester,
      RichPromptTextController(text: '{{pov,1boy'),
    );
    expect(unclosed.every((s) => s.style?.backgroundColor == null), isTrue);

    final disabled = await _buildFlat(
      tester,
      RichPromptTextController(text: '~bad anatomy~, 1girl'),
    );
    expect(disabled.every((s) => s.style?.backgroundColor == null), isTrue);

    final disabledGroup = await _buildFlat(
      tester,
      RichPromptTextController(text: '~{{pov,1boy}}~'),
    );
    expect(
      disabledGroup.every((s) => s.style?.backgroundColor == null),
      isTrue,
    );
  });

  testWidgets('数值权重跨逗号行为保持', (tester) async {
    final flat = await _buildFlat(
      tester,
      RichPromptTextController(text: '1.5::tag1, tag2::'),
    );

    expect(flat.map((s) => s.text).join(), '1.5::tag1, tag2::');
    final regionBg = flat.first.style?.backgroundColor;
    expect(regionBg, isNotNull);
    for (final span in flat) {
      expect(
        span.style?.backgroundColor,
        regionBg,
        reason: '"${span.text}" 应共享数值权重底纹',
      );
    }
  });
}
