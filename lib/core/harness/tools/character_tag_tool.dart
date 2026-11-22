import '../../../data/services/character_tag_service.dart';
import '../types.dart';
import 'agent_tool.dart';

/// 人物 tag 查询与维护：基于内置 Danbooru / e621 角色表。
class CharacterTagTool extends AgentTool {
  CharacterTagTool({
    required this.confirmChange,
    CharacterTagService? service,
  }) : _service = service ?? CharacterTagService.instance,
       super(
         name: 'character_tags',
         label: '人物 tag 库',
         description:
             '查询 Danbooru / e621 内置人物 tag 表，返回角色名、作品、触发 tag、'
             '核心外观 tag、作品数与单图数。action=search 按关键词搜索，'
             'action=get 精确查询角色，action=upsert 新增/修改自定义人物 tag（需要用户确认）。'
             '写库前必须先把改动摘要告诉用户并取得同意，用户拒绝时不要写入。',
         parameters: {
           'type': 'object',
           'properties': {
             'action': {
               'type': 'string',
               'enum': ['search', 'get', 'upsert'],
               'description': 'search=搜索，get=精确查询，upsert=新增/修改',
             },
             'query': {
               'type': 'string',
               'description': 'search 的关键词（角色名、作品名或触发词）',
             },
             'character': {
               'type': 'string',
               'description': 'get/upsert 的角色名；upsert 时作为唯一键',
             },
             'source': {
               'type': 'string',
               'enum': ['danbooru', 'e621', 'all'],
               'description': '数据来源，默认 all',
             },
             'limit': {
               'type': 'integer',
               'description': 'search 返回条数，默认 10，最大 30',
             },
             'copyright': {
               'type': 'string',
               'description': 'upsert：作品/版权名',
             },
             'trigger': {
               'type': 'string',
               'description': 'upsert：触发 tag（多个用逗号分隔）',
             },
             'core_tags': {
               'type': 'string',
               'description': 'upsert：核心外观 tag（多个用逗号分隔）',
             },
             'count': {
               'type': 'integer',
               'description': 'upsert：作品数，默认沿用旧值或 0',
             },
             'solo_count': {
               'type': 'integer',
               'description': 'upsert：单人图数量，默认沿用旧值或 0',
             },
             'url': {
               'type': 'string',
               'description': 'upsert：参考链接',
             },
           },
           'required': ['action'],
         },
       );

  final CharacterTagService _service;

  /// 写入前请求用户确认；返回 false 时工具直接结束，不写库。
  final Future<bool> Function(String summary) confirmChange;

  static Set<CharacterTagSource> _sources(Object? raw) {
    return switch (raw) {
      'danbooru' => {CharacterTagSource.danbooru},
      'e621' => {CharacterTagSource.e621},
      _ => CharacterTagSource.values.toSet(),
    };
  }

  static String _format(CharacterTagEntry entry) {
    final lines = <String>[
      '[${entry.source.name}] ${entry.character}',
      if (entry.copyright.isNotEmpty) '  作品: ${entry.copyright}',
      if (entry.trigger.isNotEmpty) '  触发 tag: ${entry.trigger}',
      if (entry.coreTags.isNotEmpty) '  核心 tag: ${entry.coreTags}',
      '  作品数: ${entry.count} / 单人: ${entry.soloCount}',
      if (entry.url.isNotEmpty) '  链接: ${entry.url}',
    ];
    return lines.join('\n');
  }

  @override
  Future<ToolResult> execute(String toolCallId, Map<String, dynamic> args) async {
    final action = (args['action'] as String?)?.trim() ?? 'search';
    try {
      switch (action) {
        case 'get':
          final character = (args['character'] as String?)?.trim() ?? '';
          if (character.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '错误：get 需要 character。',
              isError: true,
            );
          }
          final entries = await _service.lookup(
            character: character,
            sources: _sources(args['source']),
          );
          if (entries.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '未找到角色「$character」。可以先用 action=search 搜关键词。',
            );
          }
          return ToolResult(
            toolCallId: toolCallId,
            content: entries.map(_format).join('\n\n'),
          );

        case 'upsert':
          final character = (args['character'] as String?)?.trim() ?? '';
          if (character.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '错误：upsert 需要 character。',
              isError: true,
            );
          }
          final sourceName = args['source'] as String? ?? 'danbooru';
          if (sourceName != 'danbooru' && sourceName != 'e621') {
            return ToolResult(
              toolCallId: toolCallId,
              content: '错误：upsert 的 source 只能是 danbooru 或 e621。',
              isError: true,
            );
          }
          final source = sourceName == 'e621'
              ? CharacterTagSource.e621
              : CharacterTagSource.danbooru;
          final existing = await _service.lookup(
            character: character,
            sources: {source},
          );
          final old = existing.isEmpty ? null : existing.first;
          final entry = CharacterTagEntry(
            source: source,
            character: character,
            copyright:
                (args['copyright'] as String?)?.trim() ?? old?.copyright ?? '',
            trigger: (args['trigger'] as String?)?.trim() ?? old?.trigger ?? '',
            coreTags:
                (args['core_tags'] as String?)?.trim() ?? old?.coreTags ?? '',
            count:
                (args['count'] as num?)?.toInt() ?? old?.count ?? 0,
            soloCount:
                (args['solo_count'] as num?)?.toInt() ?? old?.soloCount ?? 0,
            url: (args['url'] as String?)?.trim() ?? old?.url ?? '',
          );
          final summary = [
            '${old == null ? '新增' : '修改'}人物 tag：${entry.character}',
            '来源：${entry.source.name}',
            '作品：${entry.copyright}',
            '触发：${entry.trigger}',
            '核心：${entry.coreTags}',
          ].join('\n');
          if (!await confirmChange(summary)) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '用户未同意，未写入人物 tag。',
            );
          }
          await _service.upsert(entry);
          return ToolResult(
            toolCallId: toolCallId,
            content: '已写入：\n${_format(entry)}',
          );

        default:
          final query = (args['query'] as String?)?.trim() ?? '';
          if (query.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '错误：search 需要 query。',
              isError: true,
            );
          }
          final limit = ((args['limit'] as num?)?.toInt() ?? 10).clamp(1, 30);
          final entries = await _service.search(
            query: query,
            sources: _sources(args['source']),
            limit: limit,
          );
          if (entries.isEmpty) {
            return ToolResult(
              toolCallId: toolCallId,
              content: '没有匹配「$query」的人物 tag。',
            );
          }
          return ToolResult(
            toolCallId: toolCallId,
            content: entries.map(_format).join('\n\n'),
          );
      }
    } on Object catch (error) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '人物 tag 查询失败：$error',
        isError: true,
      );
    }
  }
}
