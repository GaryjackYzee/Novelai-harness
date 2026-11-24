import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/ui/features/studio/view_models/chat_checkpoints.dart';

void main() {
  group('ChatBranch metadata', () {
    test('branch json keeps session, fork point, label and relative file', () {
      final branch = ChatBranch(
        id: 'b-1',
        sessionId: 's-1',
        forkMessageId: 'm-9',
        label: '旧分支',
        createdAt: DateTime(2026, 1, 2, 3, 4),
        messages: const [],
        filePath: 'b-1.jsonl',
      );
      final json = chatBranchToJson(branch);
      final restored = chatBranchFromJson(json);
      expect(restored.id, 'b-1');
      expect(restored.sessionId, 's-1');
      expect(restored.forkMessageId, 'm-9');
      expect(restored.label, '旧分支');
      expect(restored.filePath, 'b-1.jsonl');
      expect(restored.createdAt, branch.createdAt);
    });

    test('invalid json falls back to safe defaults', () {
      final restored = chatBranchFromJson(const <String, dynamic>{});
      expect(restored.id, isEmpty);
      expect(restored.messages, isEmpty);
      expect(restored.filePath, isNull);
    });
  });
}
