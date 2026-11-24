import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/models/prompt_library_models.dart';
import 'package:novelai_harness/data/services/prompt_library_mention.dart';
import 'package:novelai_harness/ui/features/studio/widgets/chat_mention_text_controller.dart';

PromptComboEntry _entry(String id, String title, {String category = '其他'}) {
  final now = DateTime(2026, 1, 1);
  return PromptComboEntry(
    id: id,
    title: title,
    category: category,
    prompt: title,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('# tag mention', () {
    test('extractActiveHashMention reads query after hash', () {
      const text = '画一个 #黑丝';
      final mention = extractActiveHashMention(text, text.length);
      expect(mention, isNotNull);
      expect(mention!.query, '黑丝');
      expect(text[mention.atIndex], '#');
    });

    test('extractActiveHashMention stops at whitespace', () {
      const text = '#黑丝 之后';
      expect(extractActiveHashMention(text, 3), isNotNull);
      expect(extractActiveHashMention(text, text.length), isNull);
    });

    test('matchTagMentionSuggestions filters by title containment', () {
      final entries = [
        _entry('a', '黑丝打底'),
        _entry('b', '白丝打底'),
        _entry('c', '黑丝手套'),
      ];
      final matched = matchTagMentionSuggestions('黑丝', entries);
      expect(matched.map((e) => e.title), ['黑丝打底', '黑丝手套']);
    });
  });

  group('tag chip serialization', () {
    test('tag chip serializes to raw tag and survives draft round-trip', () {
      final controller = ChatMentionTextController(
        entriesProvider: () => const <PromptComboEntry>[],
      );
      controller.insertTagChip('black tights', replaceStart: 0, replaceEnd: 0);
      expect(controller.text.contains('\uE000'), isTrue);
      expect(controller.toSerializedText().trim(), 'black tights');

      final draft = controller.toDraftText();
      final restored = ChatMentionTextController(
        entriesProvider: () => const <PromptComboEntry>[],
      );
      restored.setSerializedText(draft);
      expect(restored.text.contains('\uE000'), isTrue);
      expect(restored.toSerializedText().trim(), 'black tights');
    });

    test('titled tag chip sends marker and resolves library entry', () {
      final entry = PromptComboEntry(
        id: 'a',
        title: '黑丝打底',
        category: '服装',
        prompt: 'black bodystocking, black pantyhose',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        tags: const ['黑丝', '全身袜'],
      );
      final controller = ChatMentionTextController(
        entriesProvider: () => [entry],
      );
      controller.insertTagChip(
        'black bodystocking, black pantyhose',
        title: '黑丝打底',
        entryId: entry.id,
        replaceStart: 0,
        replaceEnd: 0,
      );
      expect(controller.toSerializedText().trim(), startsWith('#lib:'));
      final context = resolveLibraryEntriesForMessage(
        controller.toSerializedText(),
        [entry],
      );
      expect(context, contains('<library_entries>'));
      expect(context, contains('black bodystocking, black pantyhose'));

      final restored = ChatMentionTextController(
        entriesProvider: () => [entry],
      );
      restored.setSerializedText(controller.toDraftText());
      expect(restored.text.contains('\uE000'), isTrue);
      expect(restored.toSerializedText().trim(), startsWith('#lib:'));
    });

    test('literal hash-bracket text is not treated as library reference', () {
      final entry = _entry('a', '黑丝打底', category: '服装');
      expect(
        resolveLibraryEntriesForMessage('#[黑丝打底]', [entry]),
        isNull,
      );
    });

    test('removing tag chip cleans payload', () {
      final controller = ChatMentionTextController(
        entriesProvider: () => const <PromptComboEntry>[],
      );
      controller.insertTagChip('tag one', replaceStart: 0, replaceEnd: 0);
      controller.removeTokenAt(0);
      expect(controller.text.trim(), isEmpty);
      expect(controller.toSerializedText().trim(), isEmpty);
    });
  });
}
