import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/agent_harness.dart';
import 'package:novelai_harness/core/harness/presets/agent_preset.dart';
import 'package:novelai_harness/core/harness/providers/llm_provider.dart';
import 'package:novelai_harness/core/harness/tools/agent_tool.dart';
import 'package:novelai_harness/core/harness/tools/memory_tool.dart';
import 'package:novelai_harness/core/harness/tools/reflection_tools.dart';
import 'package:novelai_harness/core/harness/types.dart';
import 'package:novelai_harness/data/models/reflection_entry.dart';

/// 最小 LLM mock：按轮次返回预设事件，并记录收到的工具列表。
class _MockLlmProvider implements LlmProvider {
  _MockLlmProvider(this.onStream);

  final List<HarnessEvent> Function(
    List<AgentMessage> messages,
    List<AgentTool> tools,
  )
  onStream;

  final List<List<AgentTool>> receivedToolSets = [];

  @override
  String get modelId => 'mock-model';

  @override
  void close() {}

  @override
  Stream<HarnessEvent> streamChat({
    required List<AgentMessage> messages,
    required List<AgentTool> tools,
    double temperature = 0.7,
    String? promptCacheKey,
  }) async* {
    receivedToolSets.add(tools);
    for (final event in onStream(messages, tools)) {
      yield event;
    }
  }
}

ReflectionEntry _entry({
  required String id,
  required String title,
  String summary = '',
  List<String> lessons = const <String>[],
  String source = 'reflect',
  DateTime? createdAt,
}) {
  return ReflectionEntry(
    id: id,
    title: title,
    source: source,
    summary: summary,
    lessons: lessons,
    createdAt: createdAt ?? DateTime(2026, 1, 1),
  );
}

void main() {
  test('memory search 返回完整条目而不是截断预览', () async {
    final longText =
        'tsaritsa 角色设定：${'冰蓝色长发、圆环耳饰、蓝色眼睛、白睫毛、蓝色王冠、苍白皮肤、毛边蓝袍。' * 6}';
    final tool = MemoryTool(
      getEntries: () => [longText],
      addEntry: (_) async {},
      removeEntry: (_) async {},
    );
    final result = await tool.execute('t', {'action': 'search', 'query': 'tsaritsa'});
    expect(result.isError, isFalse);
    expect(result.content, contains('毛边蓝袍'));
    expect(result.content, isNot(contains('…')));
  });


  group('MemoryTool 检索与去重', () {
    late List<String> store;
    late MemoryTool tool;

    setUp(() {
      store = <String>[];
      tool = MemoryTool(
        getEntries: () => List<String>.unmodifiable(store),
        addEntry: (text) async => store.insert(0, text),
        removeEntry: (index) async => store.removeAt(index),
      );
    });

    test('add 拒绝空内容，并对相同内容去重（忽略大小写与多余空白）', () async {
      final first = await tool.execute('add-1', {
        'action': 'add',
        'text': '用户偏好银发长直',
      });
      expect(first.isError, isFalse);
      expect(store, hasLength(1));

      final duplicate = await tool.execute('add-2', {
        'action': 'add',
        'text': '  用户偏好银发长直  ',
      });
      expect(duplicate.isError, isFalse);
      expect(duplicate.content, contains('已存在'));
      expect(store, hasLength(1));

      final empty = await tool.execute('add-3', {
        'action': 'add',
        'text': '   ',
      });
      expect(empty.isError, isTrue);
      expect(store, hasLength(1));

      final english = await tool.execute('add-4', {
        'action': 'add',
        'text': 'User prefers Silver  Hair',
      });
      expect(english.isError, isFalse);
      final englishDuplicate = await tool.execute('add-5', {
        'action': 'add',
        'text': 'user prefers silver hair',
      });
      expect(englishDuplicate.content, contains('已存在'));
      expect(store, hasLength(2));
    });

    test('search 多关键词 AND、大小写不敏感，返回可用 remove 的序号', () async {
      await tool.execute('seed-1', {
        'action': 'add',
        'text': '用户喜欢 silver hair',
      });
      await tool.execute('seed-2', {
        'action': 'add',
        'text': '常用画风 cinematic lighting',
      });
      // store 顺序（新到旧）：[cinematic lighting, silver hair]
      final result = await tool.execute('search-1', {
        'action': 'search',
        'query': 'SILVER  hair',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('2. 用户喜欢 silver hair'));
      expect(result.content, isNot(contains('cinematic')));

      final multi = await tool.execute('search-2', {
        'action': 'search',
        'keywords': <String>['cinematic', 'LIGHTING'],
      });
      expect(multi.content, contains('1. 常用画风 cinematic lighting'));

      // 检索输出里的序号与 list 一致，可直接用于 remove
      final removed = await tool.execute('remove-1', {
        'action': 'remove',
        'index': 2,
      });
      expect(removed.isError, isFalse);
      expect(store, hasLength(1));
      expect(store.single, contains('cinematic'));
    });

    test('search 全不命中时给出部分命中提示，digest 最多 20 条', () async {
      for (var index = 0; index < 25; index += 1) {
        store.add('entry-$index keyword');
      }

      final digest = await tool.execute('digest-1', {'action': 'digest'});
      expect(digest.isError, isFalse);
      expect(digest.content, contains('共 25 条'));
      final numbered = RegExp(
        r'^\d+\. ',
        multiLine: true,
      ).allMatches(digest.content).length;
      expect(numbered, 20);

      final partial = await tool.execute('search-partial', {
        'action': 'search',
        'query': 'entry-3 missing-token',
      });
      expect(partial.isError, isFalse);
      expect(partial.content, contains('部分关键词'));
      expect(partial.content, contains('entry-3 keyword'));
    });

    test('list 支持 limit 并提示剩余条数', () async {
      for (var index = 0; index < 5; index += 1) {
        store.add('memo-$index');
      }
      final result = await tool.execute('list-limit', {
        'action': 'list',
        'limit': 2,
      });
      expect(result.content, contains('1. memo-0'));
      expect(result.content, contains('2. memo-1'));
      expect(result.content, isNot(contains('memo-2')));
      expect(result.content, contains('还有 3 条未显示'));
    });
  });

  group('ReflectionTool 历史复盘检索', () {
    late List<ReflectionEntry> store;
    late ReflectionTool tool;

    setUp(() {
      store = <ReflectionEntry>[
        _entry(
          id: 'r-1',
          title: 'Cinematic Lighting 复盘',
          summary: '主光源从左上打，边缘光偏暖',
          lessons: <String>['高光不要过曝'],
          source: 'reflect',
        ),
        _entry(
          id: 'r-2',
          title: '手部修复',
          summary: '手指结构不稳时先降 steps 再局部修复',
          lessons: <String>['不要写 without extra fingers，改用正向占位'],
          source: 'auto',
          createdAt: DateTime(2026, 2, 2),
        ),
        _entry(
          id: 'r-3',
          title: '分镜排版',
          summary: '竖构图更容易切出三格',
          source: 'dream',
          createdAt: DateTime(2026, 3, 3),
        ),
      ];
      tool = ReflectionTool(
        listEntries: () => List<ReflectionEntry>.unmodifiable(store),
        addEntry:
            ({
              required String title,
              required String summary,
              required List<String> lessons,
              required String source,
            }) async {
              store.insert(
                0,
                _entry(
                  id: 'r-${store.length + 1}',
                  title: title,
                  summary: summary,
                  lessons: lessons,
                  source: source,
                  createdAt: DateTime(2026, 4, 4),
                ),
              );
            },
        removeEntry: (id) async => store.removeWhere((item) => item.id == id),
      );
    });

    test('search 命中标题、摘要与 lessons，且大小写不敏感', () async {
      final byTitle = await tool.execute('s-1', {
        'action': 'search',
        'query': 'CINEMATIC',
      });
      expect(byTitle.isError, isFalse);
      expect(byTitle.content, contains('r-1'));

      final byLesson = await tool.execute('s-2', {
        'action': 'search',
        'query': 'extra fingers',
      });
      expect(byLesson.content, contains('r-2'));
      expect(byLesson.content, contains('命中'));

      final byChinese = await tool.execute('s-3', {
        'action': 'search',
        'keywords': <String>['手部'],
      });
      expect(byChinese.content, contains('r-2'));
    });

    test('search 无结果与多关键词部分命中都不报错', () async {
      final none = await tool.execute('s-4', {
        'action': 'search',
        'query': '不存在的关键词',
      });
      expect(none.isError, isFalse);
      expect(none.content, contains('没有找到'));

      final partial = await tool.execute('s-5', {
        'action': 'search',
        'query': '手部 不存在的关键词',
      });
      expect(partial.isError, isFalse);
      expect(partial.content, contains('部分关键词'));
      expect(partial.content, contains('r-2'));
    });

    test('list 默认最近在前并支持 limit，read 仍按 id 读取详情', () async {
      final limited = await tool.execute('l-1', {'action': 'list', 'limit': 2});
      expect(limited.content, contains('r-1'));
      expect(limited.content, contains('r-2'));
      expect(limited.content, isNot(contains('r-3')));
      expect(limited.content, contains('还有 1 条未显示'));

      final read = await tool.execute('read-1', {
        'action': 'read',
        'id': 'r-2',
      });
      expect(read.isError, isFalse);
      expect(read.content, contains('不要写 without extra fingers'));

      final missing = await tool.execute('read-missing', {
        'action': 'read',
        'id': 'r-missing',
      });
      expect(missing.isError, isTrue);
    });
  });

  group('AgentHarness 基础工具放行与记忆摘要注入', () {
    late List<String> memoryStore;
    late List<ReflectionEntry> reflectionStore;
    late ToolRegistry registry;

    setUp(() {
      memoryStore = <String>[];
      reflectionStore = <ReflectionEntry>[];
      registry = ToolRegistry()
        ..register(
          MemoryTool(
            getEntries: () => List<String>.unmodifiable(memoryStore),
            addEntry: (text) async => memoryStore.insert(0, text),
            removeEntry: (index) async => memoryStore.removeAt(index),
          ),
        )
        ..register(
          ReflectionTool(
            listEntries: () =>
                List<ReflectionEntry>.unmodifiable(reflectionStore),
            addEntry:
                ({
                  required String title,
                  required String summary,
                  required List<String> lessons,
                  required String source,
                }) async {
                  reflectionStore.insert(
                    0,
                    _entry(
                      id: 'r-${reflectionStore.length + 1}',
                      title: title,
                      summary: summary,
                      lessons: lessons,
                      source: source,
                    ),
                  );
                },
            removeEntry: (id) async =>
                reflectionStore.removeWhere((item) => item.id == id),
          ),
        );
    });

    test('受限自定义预设仍可调用 memory 与 reflection 基础工具', () async {
      memoryStore.add('用户偏好银发');
      reflectionStore.add(_entry(id: 'r-1', title: '光影复盘', summary: '主光从左上打'));

      var turn = 0;
      final provider = _MockLlmProvider((messages, tools) {
        turn += 1;
        if (turn == 1) {
          // 预设白名单为空，但基础工具应全局放行出现在工具表中
          expect(tools.map((tool) => tool.name), contains('memory'));
          expect(tools.map((tool) => tool.name), contains('reflection'));
          return <HarnessEvent>[
            ToolCallEvent(
              const ToolCall(
                id: 'call-memory',
                name: 'memory',
                arguments: <String, dynamic>{'action': 'search', 'query': '银发'},
              ),
            ),
            ToolCallEvent(
              const ToolCall(
                id: 'call-reflection',
                name: 'reflection',
                arguments: <String, dynamic>{'action': 'search', 'query': '光影'},
              ),
            ),
          ];
        }
        return <HarnessEvent>[ContentDeltaEvent('已检索完记忆与复盘')];
      });

      final harness = AgentHarness(
        tools: registry,
        provider: provider,
        initialPreset: const AgentPreset(
          id: 'restricted',
          name: '受限预设',
          description: '',
          systemPrompt: '',
          enabledToolNames: <String>[],
          allowedModifiableParams: <String>[],
        ),
      );

      final events = await harness.send('开始任务').toList();
      final results = events.whereType<ToolResultEvent>().toList();
      expect(results, hasLength(2));
      expect(results.every((event) => !event.result.isError), isTrue);
      expect(results.first.result.content, contains('用户偏好银发'));
      expect(results.last.result.content, contains('r-1'));
      expect(harness.messages.last.content, '已检索完记忆与复盘');
    });

    test('buildSystemPrompt 注入最多 20 条记忆摘要与检索/写回指令', () {
      final harness = AgentHarness(tools: registry);
      harness.memoryEntriesProvider = () =>
          List<String>.generate(25, (index) => 'memory-$index');

      final prompt = harness.buildSystemPrompt(
        const AgentPreset(
          id: 'restricted',
          name: '受限预设',
          description: '',
          systemPrompt: '系统人设',
          enabledToolNames: <String>[],
          allowedModifiableParams: <String>[],
        ),
      );

      expect(prompt, startsWith('系统人设'));
      expect(prompt, contains('<user_memory>'));
      expect(prompt, contains('共 25 条'));
      // 只注入最近 20 条，避免 prompt 爆炸
      final injected = RegExp(r'memory-\d+').allMatches(prompt).length;
      expect(injected, 20);
      expect(prompt, contains('memory-0'));
      expect(prompt, isNot(contains('memory-24')));
      // 明确指令：先查记忆/资料库，结束写回 memory / reflection
      expect(prompt, contains('memory search'));
      expect(prompt, contains('library_query'));
      expect(prompt, contains('reflection search'));
      expect(prompt, contains('memory add'));
      expect(prompt, contains('reflection add'));
    });

    test('未注入或回调异常时系统提示退化为无摘要且不抛错', () {
      final harness = AgentHarness(tools: registry);
      final preset = const AgentPreset(
        id: 'restricted',
        name: '受限预设',
        description: '',
        systemPrompt: '人设',
      );

      final withoutProvider = harness.buildSystemPrompt(preset);
      expect(withoutProvider, contains('长期记忆与检索'));
      expect(withoutProvider, isNot(contains('<user_memory>')));

      harness.memoryEntriesProvider = () => throw StateError('boom');
      final throwingProvider = harness.buildSystemPrompt(preset);
      expect(throwingProvider, isNot(contains('<user_memory>')));
    });
  });
}
