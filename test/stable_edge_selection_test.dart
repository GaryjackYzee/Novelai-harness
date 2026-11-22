import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/ui/core/widgets/stable_edge_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('输入框拖出下边缘后匀速续选到全文，视口不来回跳', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final text = List.generate(
      30,
      (i) => 'line ${i.toString().padLeft(2, '0')} chat draft',
    ).join('\n');
    final tail = 'TAIL_TOKEN_END';
    final full = '$text\n$tail';
    final controller = TextEditingController(text: full);
    final scroll = ScrollController();
    final deltas = <double>[];
    scroll.addListener(() {
      final offset = scroll.offset;
      deltas.add(offset);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              height: 96,
              child: StableEdgeSelection(
                controller: scroll,
                child: TextField(
                  controller: controller,
                  scrollController: scroll,
                  scrollPhysics: const StableSelectionScrollPhysics(),
                  scrollPadding: EdgeInsets.zero,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(border: InputBorder.none),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final box = tester.getRect(find.byType(TextField));
    final gesture = await tester.startGesture(
      box.topLeft + const Offset(12, 8),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(box.left + 12, box.bottom + 24));
    for (var i = 0; i < 360 && controller.selection.end < full.length; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(controller.selection.end, full.length);
    expect(full.substring(controller.selection.start), contains(tail));
    expect(deltas, isNotEmpty);
    for (var i = 1; i < deltas.length; i++) {
      final step = deltas[i] - deltas[i - 1];
      expect(step, greaterThanOrEqualTo(-0.5));
      expect(step, lessThanOrEqualTo(8.5));
    }
  });

  testWidgets('触控按住输入框下边缘同样能选到末尾', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final text =
        '${List.filled(24, 'touch line of the draft').join('\n')}\nEND';
    final controller = TextEditingController(text: text);
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              height: 80,
              child: StableEdgeSelection(
                controller: scroll,
                child: TextField(
                  controller: controller,
                  scrollController: scroll,
                  scrollPhysics: const StableSelectionScrollPhysics(),
                  scrollPadding: EdgeInsets.zero,
                  maxLines: null,
                  expands: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final box = tester.getRect(find.byType(TextField));
    final gesture = await tester.startGesture(
      box.topLeft + const Offset(10, 8),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(Offset(box.left + 10, box.bottom + 20));
    for (var i = 0; i < 360 && controller.selection.end < text.length; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    expect(controller.selection.end, text.length);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('限高文本框拖出边缘时只滚自己，外层列表不动', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final text = List.generate(
      40,
      (i) => 'tool line $i ${'x' * 12}',
    ).join('\n');
    final tail = 'TOOL_TAIL';
    final full = '$text\n$tail';
    final parent = ScrollController();
    final deltas = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 360,
            child: ListView(
              controller: parent,
              children: [
                const SizedBox(height: 48, child: Text('above')),
                BoundedSelectableText(
                  text: full,
                  maxHeight: 100,
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 480, child: Text('below')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final box = tester.getRect(find.byType(BoundedSelectableText));
    final inner = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(BoundedSelectableText),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    inner.addListener(() => deltas.add(inner.pixels));
    int selectionEnd() {
      final selection = tester
          .state<EditableTextState>(find.byType(EditableText))
          .textEditingValue
          .selection;
      return selection.isValid ? selection.end : -1;
    }

    final gesture = await tester.startGesture(
      box.topLeft + const Offset(8, 8),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(box.left + 8, box.bottom + 16));
    for (var i = 0; i < 400 && selectionEnd() < full.length; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();

    final selection = tester
        .state<EditableTextState>(find.byType(EditableText))
        .textEditingValue
        .selection;
    expect(selection.end, full.length);
    expect(parent.offset, 0);
    expect(deltas, isNotEmpty);
    for (var i = 1; i < deltas.length; i++) {
      final step = deltas[i] - deltas[i - 1];
      expect(step, greaterThanOrEqualTo(-0.5));
      expect(step, lessThanOrEqualTo(8.5));
    }
    debugDefaultTargetPlatformOverride = null;
    parent.dispose();
  });
}
