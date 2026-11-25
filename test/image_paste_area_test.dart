import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/ui/features/studio/widgets/image_paste_area.dart';

void main() {
  testWidgets('hover + Ctrl+V triggers paste without focus', (tester) async {
    var pasted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: ImagePasteArea(
                onPaste: () => pasted += 1,
                child: const ColoredBox(color: Colors.grey),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(1, 1));
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(ImagePasteArea)));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(pasted, 1);
  });
}
