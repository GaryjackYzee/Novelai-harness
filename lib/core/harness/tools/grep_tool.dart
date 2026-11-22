import 'dart:convert';

import '../../../data/services/library_service.dart';
import '../types.dart';
import 'agent_tool.dart';

/// 在资料库文档里按正则 / 关键词检索，返回 文件:行号:内容。
///
/// 与 library 工具的 search 相比，这里支持正则、包含过滤与逐行结果，
/// 更适合 agent 精确查找设定、标签或代码片段。
class GrepTool extends AgentTool {
  GrepTool({
    required this.listFiles,
    required this.readFile,
  }) : super(
          name: 'grep',
          label: '正则检索',
          description:
              '在资料库文档中按正则检索文本，返回「文件:行号: 内容」。支持 include 过滤（如 *.md）、ignore_case 与 max_results。适合查找设定、标签、角色名等。',
          parameters: {
            'type': 'object',
            'properties': {
              'pattern': {
                'type': 'string',
                'description': '正则表达式或普通关键词',
              },
              'include': {
                'type': 'string',
                'description': '可选文件名过滤，如 *.md / *.txt',
              },
              'ignore_case': {
                'type': 'boolean',
                'description': '忽略大小写，默认 true',
              },
              'max_results': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 200,
                'description': '最多返回条数，默认 50',
              },
            },
            'required': ['pattern'],
          },
        );

  final Future<List<LibraryFile>> Function() listFiles;
  final Future<String> Function(LibraryFile file) readFile;

  @override
  Future<ToolResult> execute(
    String toolCallId,
    Map<String, dynamic> args,
  ) async {
    final pattern = (args['pattern'] as String? ?? '').trim();
    if (pattern.isEmpty) {
      return ToolResult(
        toolCallId: toolCallId,
        content: 'grep 需要 pattern。',
        isError: true,
      );
    }
    final ignoreCase = args['ignore_case'] != false;
    final maxResults = ((args['max_results'] as num?)?.toInt() ?? 50)
        .clamp(1, 200)
        .toInt();
    final include = (args['include'] as String? ?? '').trim().toLowerCase();
    final RegExp regExp;
    try {
      regExp = RegExp(pattern, caseSensitive: !ignoreCase);
    } on FormatException catch (error) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '正则无效：${error.message}',
        isError: true,
      );
    }

    final List<LibraryFile> files;
    try {
      files = await listFiles();
    } on Object catch (error) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '资料库不可用：$error',
        isError: true,
      );
    }
    if (files.isEmpty) {
      return ToolResult(toolCallId: toolCallId, content: '资料库为空。');
    }

    final hits = <String>[];
    var scanned = 0;
    for (final file in files) {
      if (hits.length >= maxResults) break;
      if (include.isNotEmpty && !_matchesInclude(file.name, include)) {
        continue;
      }
      scanned += 1;
      String text;
      try {
        text = await readFile(file);
      } on Object catch (error) {
        hits.add('${file.name}: <读取失败：$error>');
        continue;
      }
      final lines = const LineSplitter().convert(text);
      for (var index = 0; index < lines.length; index += 1) {
        if (!regExp.hasMatch(lines[index])) continue;
        final line = lines[index].trim();
        final clipped = line.length > 300 ? '${line.substring(0, 300)}…' : line;
        hits.add('${file.name}:${index + 1}: $clipped');
        if (hits.length >= maxResults) break;
      }
    }

    if (hits.isEmpty) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '没有匹配「$pattern」（扫描 $scanned 个文件）。',
      );
    }
    final header = '匹配 ${hits.length}${hits.length >= maxResults ? '+' : ''} 条'
        '（扫描 $scanned 个文件）：';
    return ToolResult(
      toolCallId: toolCallId,
      content: '$header\n${hits.join('\n')}',
    );
  }

  bool _matchesInclude(String name, String include) {
    final lower = name.toLowerCase();
    if (include.startsWith('*.')) {
      return lower.endsWith(include.substring(1));
    }
    return lower.contains(include);
  }
}
