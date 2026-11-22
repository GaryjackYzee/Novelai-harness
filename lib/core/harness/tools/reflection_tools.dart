import '../../../data/models/reflection_entry.dart';
import '../types.dart';
import 'agent_tool.dart';

/// 梳理串工具：add / list / search / read / remove。
///
/// - search：在标题、摘要与 lessons 中做多关键词、大小写不敏感检索，
///   命中项带 id，可直接交给 read 查看详情；
/// - list：最近在前，支持 limit 控制输出条数；
/// - add / read / remove 保持原有语义。
class ReflectionTool extends AgentTool {
  ReflectionTool({
    required this.listEntries,
    required this.addEntry,
    required this.removeEntry,
  }) : super(
         name: 'reflection',
         label: '梳理串',
         description:
             '录制与查阅「梳理串」：add 写入一条结构化复盘（标题/摘要/经验列表/source）；'
             'search 按关键词检索历史复盘的标题、摘要与经验；list 列出最近记录（可 limit）；'
             'read 按 id 读取详情；remove 按 id 删除。'
             '适合 /reflect、/dream 与自动复盘归档；开任务前可先 search 既往经验。',
         parameters: {
           'type': 'object',
           'properties': {
             'action': {
               'type': 'string',
               'enum': ['add', 'list', 'search', 'read', 'remove'],
               'description': '操作类型',
             },
             'title': {'type': 'string', 'description': 'add 时的标题'},
             'summary': {'type': 'string', 'description': 'add 时的摘要'},
             'lessons': {
               'type': 'array',
               'items': {'type': 'string'},
               'description': 'add 时的经验/教训列表',
             },
             'source': {
               'type': 'string',
               'enum': ['reflect', 'dream', 'auto'],
               'description': '来源，默认 reflect',
             },
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
               'description': 'list/search 返回条数上限，默认 20',
             },
             'id': {'type': 'string', 'description': 'read/remove 时的记录 id'},
           },
           'required': ['action'],
         },
       );

  /// list/search 默认返回的最大条数，避免历史复盘撑爆上下文。
  static const int defaultListLimit = 20;

  /// 检索结果中每条摘要/经验片段的最大字符数。
  static const int maxExcerptChars = 160;

  final List<ReflectionEntry> Function() listEntries;
  final Future<void> Function({
    required String title,
    required String summary,
    required List<String> lessons,
    required String source,
  })
  addEntry;
  final Future<void> Function(String id) removeEntry;

  @override
  Future<ToolResult> execute(
    String toolCallId,
    Map<String, dynamic> args,
  ) async {
    final action = args['action'] as String? ?? 'list';
    try {
      final String content;
      switch (action) {
        case 'add':
          content = await _add(args);
        case 'list':
          content = _list(args);
        case 'search':
          content = _search(args);
        case 'read':
          content = _read(args);
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

  Future<String> _add(Map<String, dynamic> args) async {
    final title = (args['title'] as String? ?? '').trim();
    final summary = (args['summary'] as String? ?? '').trim();
    if (title.isEmpty && summary.isEmpty) {
      throw ArgumentError('add 需要 title 或 summary。');
    }
    final lessons =
        (args['lessons'] as List?)
            ?.whereType<String>()
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final source = switch (args['source']) {
      'dream' => 'dream',
      'auto' => 'auto',
      _ => 'reflect',
    };
    await addEntry(
      title: title.isEmpty ? '复盘' : title,
      summary: summary,
      lessons: lessons,
      source: source,
    );
    return '已写入梳理串：${title.isEmpty ? '复盘' : title}';
  }

  String _list(Map<String, dynamic> args) {
    final entries = listEntries();
    if (entries.isEmpty) return '还没有梳理串记录。';
    final limit = _readLimit(args);
    final lines = <String>['梳理串（最近在前）：'];
    for (final entry in entries.take(limit)) {
      lines.add('- [${entry.source}] ${entry.title} (${entry.id})');
    }
    if (entries.length > limit) {
      lines.add('……还有 ${entries.length - limit} 条未显示；可用 search 缩小范围或调大 limit。');
    }
    return lines.join('\n');
  }

  String _search(Map<String, dynamic> args) {
    final keywords = _parseKeywords(args);
    if (keywords.isEmpty) {
      throw ArgumentError('search 需要 query 或 keywords（多个关键词用空格分隔）。');
    }
    final entries = listEntries();
    if (entries.isEmpty) return '还没有梳理串记录，无法检索。';

    final tokens = keywords.map(_normalize).toList(growable: false);
    var matched = <ReflectionEntry>[];
    for (final entry in entries) {
      final haystack = _searchable(entry);
      if (tokens.every(haystack.contains)) matched.add(entry);
    }
    // 多关键词按 AND 优先；全不命中时退化为 OR 部分命中。
    var partial = false;
    if (matched.isEmpty) {
      partial = true;
      for (final entry in entries) {
        final haystack = _searchable(entry);
        if (tokens.any(haystack.contains)) matched.add(entry);
      }
    }
    if (matched.isEmpty) {
      return '没有找到包含「${keywords.join(' ')}」的梳理串记录。';
    }

    final limit = _readLimit(args);
    final buffer = StringBuffer();
    if (partial) {
      buffer.writeln(
        '没有同时包含全部关键词的记录；以下是包含部分关键词的命中'
        '（用 read + id 查看详情）：',
      );
    } else {
      buffer.writeln(
        '梳理串检索「${keywords.join(' ')}」：命中 ${matched.length} 条'
        '（用 read + id 查看详情）：',
      );
    }
    for (final entry in matched.take(limit)) {
      final date = entry.createdAt.toIso8601String().split('T').first;
      buffer.writeln(
        '- [${entry.source}] ${entry.title} (${entry.id}) · $date',
      );
      final excerpt = _excerpt(entry, tokens);
      if (excerpt != null) buffer.writeln('  命中：$excerpt');
    }
    if (matched.length > limit) {
      buffer.writeln('……还有 ${matched.length - limit} 条未显示，可缩小关键词或调大 limit。');
    }
    return buffer.toString().trimRight();
  }

  String _read(Map<String, dynamic> args) {
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) throw ArgumentError('read 需要 id。');
    final entry = listEntries().where((item) => item.id == id).firstOrNull;
    if (entry == null) throw ArgumentError('没有找到该记录。');
    final lines = <String>[
      '标题：${entry.title}',
      '来源：${entry.source}',
      '时间：${entry.createdAt.toIso8601String()}',
      '摘要：${entry.summary}',
      if (entry.lessons.isNotEmpty) '经验：',
      for (var index = 0; index < entry.lessons.length; index += 1)
        '${index + 1}. ${entry.lessons[index]}',
    ];
    return lines.join('\n');
  }

  Future<String> _remove(Map<String, dynamic> args) async {
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) throw ArgumentError('remove 需要 id。');
    await removeEntry(id);
    return '已删除记录 $id';
  }

  /// 标题 + 摘要 + lessons 拼成小写检索文本。
  static String _searchable(ReflectionEntry entry) =>
      _normalize([entry.title, entry.summary, ...entry.lessons].join('\n'));

  /// 取第一条命中关键词的摘要/经验片段（前后各留一点上下文）。
  static String? _excerpt(ReflectionEntry entry, List<String> tokens) {
    final fields = <String>[entry.summary, ...entry.lessons];
    for (final field in fields) {
      final normalized = _normalize(field);
      if (normalized.isEmpty) continue;
      for (final token in tokens) {
        final position = normalized.indexOf(token);
        if (position < 0) continue;
        final start = position - 30 < 0 ? 0 : position - 30;
        final end = position + token.length + 90;
        final sliced = normalized.substring(
          start,
          end > normalized.length ? normalized.length : end,
        );
        return '${start > 0 ? '…' : ''}$sliced'
            '${end < normalized.length ? '…' : ''}';
      }
    }
    return null;
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

  /// 大小写不敏感 + 多余空白归一化。
  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static int _readLimit(Map<String, dynamic> args) {
    final raw = args['limit'];
    final value = switch (raw) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value.trim()) ?? defaultListLimit,
      _ => defaultListLimit,
    };
    if (value < 1) return 1;
    if (value > 50) return 50;
    return value;
  }
}
