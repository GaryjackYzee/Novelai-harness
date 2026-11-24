import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/types.dart';
import 'package:novelai_harness/l10n/app_localizations.dart';
import 'package:novelai_harness/ui/features/studio/view_models/chat_checkpoints.dart';
import 'package:novelai_harness/ui/features/studio/widgets/agent_rewind_tree.dart';

void main() {
  testWidgets('rewind tree renders root, checkpoint and branch, tap restores', (
    tester,
  ) async {
    final user = AgentMessage(
      id: 'u1',
      role: AgentRole.user,
      content: '第一轮问题',
      createdAt: DateTime(2026, 1, 1, 12),
    );
    final branch = ChatBranch(
      id: 'b1',
      sessionId: 's1',
      forkMessageId: 'u1',
      label: '旧分支标签',
      createdAt: DateTime(2026, 1, 1, 12, 30),
      messages: const [],
    );
    ChatBranch? restored;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: AgentRewindTree(
              checkpoints: [
                ChatCheckpoint(index: 1, userMessage: user),
              ],
              branches: [branch],
              sessionId: 's1',
              selectedIndex: null,
              itemKeys: <int, GlobalKey>{},
              onSelectCheckpoint: (_) {},
              onConfirmCheckpoint: (_) {},
              onRestoreBranch: (value) => restored = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('第一轮问题'), findsOneWidget);
    expect(find.text('旧分支标签'), findsOneWidget);
    await tester.tap(find.text('旧分支标签'));
    expect(restored?.id, 'b1');
  });
}
