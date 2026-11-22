import '../types.dart';
import 'agent_tool.dart';

/// 跨会话长期记忆工具：list / search / digest / add / remove。
///
/// - search：多关键词（空格/逗号分隔）大小写不敏感检索，命中项带原始序号，
///   可直接把序号交给 remove；
/// - digest：精简摘要（单条截断），供快速浏览与系统提示注入；
/// - add：空值校验 + 去重（忽略大小写与多余空白），最多 500 字；
/// - list/remove：保持原有行为，list 支持 limit 防止输出膨胀。
class MemoryTool extends AgentTool {
  MemoryTool({
    required this.getEntries,
    required this.addEntry,
    required this.removeEntry,
  }) : super(
         name: 'memory',
         label: '长期记忆',
         description:
             '跨会话长期记忆：search 按关键词检索（多关键词空格分隔、大小写不敏感，'
             '返回可直接用于 remove 的序号）；digest 查看精简摘要；list 列出全部；'
             'add 新增一条（自动去重，最多 500 字）；remove 按序号删除。'
             '适合记录用户长期偏好、固定角色设定、创作习惯。'
             '开始任务时先 search，任务结束再把稳定结论 add 回来。',
         parameters: {
           'type': 'object',
           'properties': {
             'action': {
               'type': 'string',
               'enum': ['list', 'search', 'digest', 'add', 'remove'],
               'description': '操作类型',
             },
             'text': {'type': 'string', 'description': 'add 时的记忆内容（最多 500 字）'},
             'query': {
               'type': 'string',
               'description': 'search 的关键词，多个关键词用空格或逗号分隔（需同时命中）',
             },
             'keywords': {
               'type': 'array',
               'items': {'type': 'string'},
               'description': 'search 的多个关键词（与 query 合并使用）',
             },
             'limit': {
               'type': 'integer',
               'minimum': 1,
               'maximum': 50,
               'description':
                   'list/search/digest 返回条数上限，默认 list 50、search/digest 20',
             },
             'index': {
               'type': 'integer',
               'description': 'remove 时的序号（从 1 开始，来自 list/search 输出）',
             },
           },
           'required': ['action'],
         },
       );

  /// 系统提示词中默认注入的最大条数，避免 prompt 爆炸。
  static const int maxPromptEntries = 20;

  /// digest / 检索预览中单条记忆的最大字符数。
  static const int maxPreviewChars = 200;

  /// 单条记忆允许的最大字符数（与 StudioViewModel 的存储上限一致）。
  static const int maxTextLength = 500;

  final List<String> Function() getEntries;
  final Future<void> Function(String text) addEntry;
  final Future<void> Function(int index) removeEntry;

  /// 把记忆条目格式化为带序号的精简多行文本。
  ///
  /// 序号始终对应 [getEntries] 中的真实位置（1 起），因此可以直接用于 remove；
  /// 空条目会被跳过，超长条目按 [previewChars] 截断，最多输出 [limit] 条。
  static String formatDigest(
    List<String> entries, {
    int limit = maxPromptEntries,
    int previewChars = maxPreviewChars,
  }) {
    if (limit <= 0) return '';
    final buffer = StringBuffer();
    var shown = 0;
    for (var index = 0; index < entries.length; index += 1) {
      final preview = _preview(entries[index], previewChars);
      if (preview.isEmpty) continue;
      buffer.writeln('${index + 1}. $preview');
      shown += 1;
      if (shown >= limit) break;
    }
    return buffer.toString().trimRight();
  }

  @override
  Future<ToolResult> execute(
    String toolCallId,
    Map<String, dynamic> args,
  ) async {
    final action = args['action'] as String? ?? 'list';
    try {
      final String content;
      switch (action) {
        case 'list':
          content = _list(args);
        case 'search':
          content = _search(args);
        case 'digest':
          content = _digest(args);
        case 'add':
          content = await _add(args);
        case 'remove':
          content = await _remove(args);
        default:
          return ToolResult(
            toolCallId: toolCallId,
            content: '未知 action：$action',
            isError: true,
          );
      }
      return ToolResult(toolCallId: toolCallId, content: content);
    } on ArgumentError catch (error) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '${error.message}',
        isError: true,
      );
    }
  }

  String _list(Map<String, dynamic> args) {
    final entries = getEntries();
    if (entries.isEmpty) return '还没有长期记忆。';
    final limit = _readLimit(args, fallback: 50);
    final lines = <String>['长期记忆：'];
    final visible = entries.length > limit ? limit : entries.length;
    for (var index = 0; index < visible; index += 1) {
      lines.add('${index + 1}. ${entries[index]}');
    }
    if (entries.length > limit) {
      lines.add('……还有 ${entries.length - limit} 条未显示，可用 search 缩小范围或调大 limit。');
    }
    return lines.join('\n');
  }

  String _digest(Map<String, dynamic> args) {
    final entries = getEntries();
    if (entries.isEmpty) return '还没有长期记忆。';
    final limit = _readLimit(args, fallback: maxPromptEntries);
    final buffer = StringBuffer(
      '长期记忆摘要：共 ${entries.length} 条'
      '${entries.length > limit ? '，以下显示最近 $limit 条' : ''}'
      '（序号对应 list，可用 remove 删除）：\n',
    );
    buffer.write(formatDigest(entries, limit: limit));
    return buffer.toString().trimRight();
  }

  String _search(Map<String, dynamic> args) {
    final keywords = _parseKeywords(args);
    if (keywords.isEmpty) {
      throw ArgumentError('search 需要 query 或 keywords（多个关键词用空格分隔）。');
    }
    final entries = getEntries();
    if (entries.isEmpty) return '还没有长期记忆，无法检索。';

    final tokens = keywords.map(_normalize).toList(growable: false);
    var matched = <int>[];
    for (var index = 0; index < entries.length; index += 1) {
      final haystack = _normalize(entries[index]);
      if (tokens.every(haystack.contains)) matched.add(index);
    }
    // 多关键词按 AND 优先；全不命中时退化为 OR 部分命中，避免模型空手而归。
    var partial = false;
    if (matched.isEmpty) {
      partial = true;
      for (var index = 0; index < entries.length; index += 1) {
        final haystack = _normalize(entries[index]);
        if (tokens.any(haystack.contains)) matched.add(index);
      }
    }
    if (matched.isEmpty) {
      return '没有找到包含「${keywords.join(' ')}」的长期记忆。';
    }

    final limit = _readLimit(args, fallback: maxPromptEntries);
    final buffer = StringBuffer();
    if (partial) {
      buffer.writeln(
        '没有同时包含全部关键词的记忆；以下是包含部分关键词的命中'
        '（序号对应 list，可用 remove 删除）：',
      );
    } else {
      buffer.writeln(
        '长期记忆检索「${keywords.join(' ')}」：命中 ${matched.length} 条'
        '（序号对应 list，可用 remove 删除）：',
      );
    }
    for (final index in matched.take(limit)) {
      // 检索命中的条目直接给全文：条目本身已有 500 字上限，
      // 提前截断会让 agent 误以为内容缺失。
      final text = entries[index].trim();
      buffer.writeln('${index + 1}. $text');
    }
    if (matched.length > limit) {
      buffer.writeln('……还有 ${matched.length - limit} 条未显示，可缩小关键词或调大 limit。');
    }
    return buffer.toString().trimRight();
  }

  Future<String> _add(Map<String, dynamic> args) async {
    final raw = args['text'];
    if (raw is! String) throw ArgumentError('add 需要 text。');
    final trimmed = raw.trim();
    if (trimmed.isEmpty) throw ArgumentError('add 需要非空的 text。');
    final overLimit = trimmed.runes.length > maxTextLength;
    // 存储时直接按码点截断（不加省略号），与 StudioViewModel 的 500 字上限一致。
    final text = overLimit
        ? String.fromCharCodes(trimmed.runes.take(maxTextLength))
        : trimmed;

    final entries = getEntries();
    final normalized = _normalize(text);
    for (var index = 0; index < entries.length; index += 1) {
      if (_normalize(entries[index]) == normalized) {
        return '已存在相同的长期记忆（第 ${index + 1} 条），未重复添加。';
      }
    }
    await addEntry(text);
    final note = overLimit ? '（超过 $maxTextLength 字已截断）' : '';
    return '已记住$note：$text';
  }

  Future<String> _remove(Map<String, dynamic> args) async {
    final raw = args['index'];
    final index = switch (raw) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value.trim()) ?? 0,
      _ => 0,
    };
    final entries = getEntries();
    if (index < 1 || index > entries.length) {
      throw ArgumentError('序号无效，请先用 list 或 search 查看（从 1 开始）。');
    }
    final removed = entries[index - 1];
    await removeEntry(index - 1);
    return '已删除：$removed';
  }

  /// 收集 query 字符串与 keywords 数组中的关键词，去重并保持顺序。
  static List<String> _parseKeywords(Map<String, dynamic> args) {
    final collected = <String>[];
    final query = args['query'];
    if (query != null) {
      if (query is! String) throw ArgumentError('query 必须是字符串。');
      for (final part in query.split(RegExp(r'[\s,，、;；|]+'))) {
        final token = part.trim();
        if (token.isNotEmpty) collected.add(token);
      }
    }
    final many = args['keywords'];
    if (many != null) {
      if (many is! List) throw ArgumentError('keywords 必须是字符串数组。');
      for (final item in many) {
        if (item is! String) throw ArgumentError('keywords 必须是字符串数组。');
        final token = item.trim();
        if (token.isNotEmpty) collected.add(token);
      }
    }
    final seen = <String>{};
    final result = <String>[];
    for (final token in collected) {
      if (seen.add(_normalize(token))) result.add(token);
    }
    return result;
  }

  /// 大小写不敏感 + 多余空白归一化，用于去重与检索匹配。
  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 单行截断预览，避免换行破坏工具输出与系统提示结构。
  static String _preview(String value, int maxChars) {
    final oneLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.isEmpty) return '';
    return _clampRunes(oneLine, maxChars);
  }

  /// 按 Unicode 码点截断，避免切断代理对；超长时补省略号。
  static String _clampRunes(String value, int maxChars) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= maxChars) return value;
    return '${String.fromCharCodes(runes.take(maxChars))}…';
  }

  static int _readLimit(Map<String, dynamic> args, {required int fallback}) {
    final raw = args['limit'];
    final value = switch (raw) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value.trim()) ?? fallback,
      _ => fallback,
    };
    if (value < 1) return 1;
    if (value > 50) return 50;
    return value;
  }
}
