import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../data/services/library_service.dart';
import '../types.dart';
import 'agent_tool.dart';

/// 只读资料库查询工具（支持深层目录）：
/// - tree：列出指定目录下深层文档
/// - find：按文件名片段查找（大小写不敏感）
/// - read：按相对路径分页读取（docx/pdf/xlsx/pptx 会提取文本）
/// - search：多关键词全文搜索（AND 优先，返回命中行与 snippet）
/// - digest/outline：逐文件返回标题、大小、修改时间与内容概要
class LibraryQueryTool extends AgentTool {
  LibraryQueryTool({required this.getLibraryDir})
    : super(
        name: 'library_query',
        label: '资料库查询',
        description:
            '只读查询资料库（支持深层目录与 docx/pdf/xlsx/pptx）：tree 列出目录下文档（可指定 path/depth）；find 按文件名片段查找（大小写不敏感，空格分隔的多个片段需同时命中）；read 按相对路径分页读取；search 多关键词全文搜索（空格分隔，AND 优先，返回命中行号与上下文）；digest/outline 逐文件返回标题、大小、修改时间、Markdown 标题与首段摘要。资料库文件名可能带多级目录，先用 tree 或 find 确认路径再 read。',
        parameters: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'tree',
                'list',
                'find',
                'read',
                'search',
                'digest',
                'outline',
              ],
              'description': '操作类型',
            },
            'path': {
              'type': 'string',
              'description':
                  '相对资料库根目录的子目录（tree/find/search/digest 过滤）或文件路径（read），如 角色设定/主角.md',
            },
            'name': {'type': 'string', 'description': 'read 的兼容字段；等同 path'},
            'query': {
              'type': 'string',
              'description':
                  'find 的文件名片段（可空格分隔多个片段）；search 的正文关键词（空格分隔，AND 优先）',
            },
            'depth': {
              'type': 'integer',
              'description': 'tree/find/search/digest 最大递归深度，默认 12，最大 20',
            },
            'limit': {
              'type': 'integer',
              'description':
                  'tree/find 返回文件数上限，默认 200；read 为字符数；search 为命中条数上限（最多 80）；digest/outline 为文件数上限（最多 60）',
            },
            'offset': {
              'type': 'integer',
              'description': 'read 的起始字符偏移；search 的结果分页偏移，默认 0',
            },
          },
          'required': ['action'],
        },
      );

  final String Function() getLibraryDir;
  final LibraryService _service = LibraryService();

  @override
  Future<ToolResult> execute(
    String toolCallId,
    Map<String, dynamic> args,
  ) async {
    final dir = getLibraryDir().trim();
    if (dir.isEmpty) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '资料库还没有设置目录，请先在「图源 → 资料库」里选择文件夹。',
        isError: true,
      );
    }
    final action = args['action'] as String? ?? 'tree';
    final path = (args['path'] as String? ?? args['name'] as String? ?? '')
        .trim()
        .replaceAll('\\', '/');
    final depth = ((args['depth'] as num?)?.toInt() ?? 12).clamp(1, 20).toInt();
    final limit = ((args['limit'] as num?)?.toInt() ?? 200)
        .clamp(20, 1000)
        .toInt();
    try {
      switch (action) {
        case 'tree':
        case 'list':
        case 'find':
          final files = await _service.list(
            dir,
            maxDepth: depth,
            maxFiles: limit,
            prefix: path,
          );
          if (files.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: path.isEmpty ? '资料库目录里没有可读文档。' : '「$path」下没有可读文档。',
            );
          }
          final query = (args['query'] as String? ?? '').trim().toLowerCase();
          final findTerms = query
              .split(RegExp(r'\s+'))
              .where((term) => term.isNotEmpty)
              .toList(growable: false);
          final matched = action == 'find'
              ? files
                    .where((file) {
                      if (findTerms.isEmpty) return true;
                      final lowerName = file.name.toLowerCase();
                      return findTerms.every(lowerName.contains);
                    })
                    .toList(growable: false)
              : files;
          if (matched.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '没有找到文件名包含「$query」的文档。',
            );
          }
          final lines = <String>[
            '资料库：$dir',
            if (path.isNotEmpty) '范围：$path',
            '共 ${matched.length} 个文件（深度上限 $depth）：',
          ];
          for (final file in matched) {
            lines.add(
              '- ${file.name} (${(file.size / 1024).toStringAsFixed(1)} KB)',
            );
          }
          return ToolResult(toolCallId: toolCallId, content: lines.join('\n'));
        case 'read':
          final target = p.normalize(p.join(dir, path));
          if (!p.isWithin(p.normalize(dir), target)) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '文件路径不合法。',
              isError: true,
            );
          }
          try {
            final realRoot = await Directory(dir).resolveSymbolicLinks();
            final realFile = await File(target).resolveSymbolicLinks();
            if (!p.isWithin(realRoot, realFile)) {
              return ToolResult(
                toolCallId: toolCallId,
                content: '文件路径越界（符号链接指向资料库外），已拒绝读取。',
                isError: true,
              );
            }
          } on FileSystemException {
            return ToolResult(
              toolCallId: toolCallId,
              content: '资料库里没有这个文件。',
              isError: true,
            );
          }
          if (!await File(target).exists()) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '资料库里没有这个文件。',
              isError: true,
            );
          }
          final read = await _service.read(
            target,
            offset: (args['offset'] as num?)?.toInt() ?? 0,
            limit: ((args['limit'] as num?)?.toInt() ?? 6000).clamp(200, 12000),
          );
          return ToolResult(
            toolCallId: toolCallId,
            content:
                '文件：${read.name}\n进度：${read.offset}/${read.total}${read.truncated ? '（还有更多）' : ''}\n\n${read.text}',
          );
        case 'search':
          final query = (args['query'] as String? ?? '').trim();
          if (query.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: 'search 需要 query。',
              isError: true,
            );
          }
          final offset = ((args['offset'] as num?)?.toInt() ?? 0)
              .clamp(0, 100000)
              .toInt();
          final matches = await _service.search(
            dir,
            query,
            limit: limit.clamp(1, 80).toInt(),
            maxDepth: depth,
            offset: offset,
            prefix: path,
          );
          if (matches.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '没有找到包含「$query」的内容。',
            );
          }
          final lines = <String>[
            '包含「$query」的匹配（按相关度排序${offset > 0 ? '，offset $offset' : ''}）：',
          ];
          for (final match in matches) {
            final snippet = match.snippet.isEmpty ? match.text : match.snippet;
            if (match.line <= 0) {
              lines.add('- ${match.file}（文件名/路径命中）');
            } else {
              lines.add('- ${match.file}:${match.line} $snippet');
            }
          }
          return ToolResult(toolCallId: toolCallId, content: lines.join('\n'));
        case 'digest':
        case 'outline':
          final digests = await _service.digest(
            dir,
            maxDepth: depth,
            maxFiles: limit.clamp(1, 60).toInt(),
            prefix: path,
          );
          if (digests.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: path.isEmpty ? '资料库目录里没有可读文档。' : '「$path」下没有可读文档。',
            );
          }
          final lines = <String>[
            '资料库：$dir',
            if (path.isNotEmpty) '范围：$path',
            '文件概要 ${digests.length} 个：',
          ];
          for (final digest in digests) {
            final size = (digest.size / 1024).toStringAsFixed(1);
            final modified = digest.modified.toLocal().toString().substring(
              0,
              16,
            );
            lines.add('- ${digest.file} ($size KB, $modified)');
            if (digest.headings.isNotEmpty) {
              lines.add('  标题：${digest.headings.join(' / ')}');
            }
            if (digest.summary.isNotEmpty) {
              final summary = digest.summary.replaceAll(RegExp(r'\s+'), ' ');
              lines.add('  摘要：$summary');
            } else if (digest.error == null) {
              lines.add('  摘要：（无正文段落）');
            }
            if (digest.error != null) {
              lines.add('  无法提取正文：${digest.error}');
            }
          }
          return ToolResult(toolCallId: toolCallId, content: lines.join('\n'));
        default:
          return ToolResult(
            toolCallId: toolCallId,
            content: '未知 action：$action',
            isError: true,
          );
      }
    } on Object catch (error) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '资料库查询失败：$error',
        isError: true,
      );
    }
  }
}
