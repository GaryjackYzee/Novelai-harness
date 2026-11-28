import '../../../data/services/reference_library_service.dart';
import '../types.dart';
import 'agent_tool.dart';

typedef RefLibList = Future<List<ReferenceLibraryEntry>> Function();
typedef RefLibAddHistory =
    Future<bool> Function(String imageId, ReferenceLibraryKind kind);
typedef RefLibAddCanvas =
    Future<bool> Function(ReferenceLibraryKind kind);
typedef RefLibApply = Future<bool> Function(String entryId);

/// Agent 工具：持久参考图库的存取与应用。
class ReferenceLibraryTool extends AgentTool {
  final RefLibList list;
  final RefLibAddHistory addHistory;
  final RefLibAddCanvas addCanvas;
  final RefLibApply apply;
  final Future<bool> Function(String entryId) remove;

  ReferenceLibraryTool({
    required this.list,
    required this.addHistory,
    required this.addCanvas,
    required this.apply,
    required this.remove,
  }) : super(
         name: 'reference_library',
         label: '参考图库',
         description:
             '管理持久参考图库：list 列出；add_history 把历史图片存入；'
             'add_canvas 把画板当前图存入；apply 加入当前工作台；remove 删除。',
         parameters: const {
           'type': 'object',
           'properties': {
             'action': {
               'type': 'string',
               'enum': ['list', 'add_history', 'add_canvas', 'apply', 'remove'],
             },
             'kind': {
               'type': 'string',
               'enum': ['precise', 'vibe'],
               'description': 'add_history/add_canvas 时必填',
             },
             'image_id': {
               'type': 'string',
               'description': 'add_history 时的历史图片 ID',
             },
             'entry_id': {
               'type': 'string',
               'description': 'apply/remove 时的图库条目 ID',
             },
           },
           'required': ['action'],
         },
       );

  ReferenceLibraryKind _kind(Object? raw) =>
      '$raw' == 'vibe'
          ? ReferenceLibraryKind.vibe
          : ReferenceLibraryKind.precise;

  @override
  Future<ToolResult> execute(
    String toolCallId,
    Map<String, dynamic> args,
  ) async {
    final action = '${args['action'] ?? 'list'}';
    final entries = await list();
    if (action == 'list') {
      if (entries.isEmpty) {
        return ToolResult(toolCallId: toolCallId, content: '参考图库为空。');
      }
      final buffer = StringBuffer('参考图库（${entries.length} 张）：\n');
      for (final entry in entries) {
        buffer.writeln(
          '- ${entry.id} | ${entry.kind.name} | ${entry.name} | '
          '${entry.strength.toStringAsFixed(2)}',
        );
      }
      return ToolResult(toolCallId: toolCallId, content: buffer.toString());
    }
    if (action == 'add_history') {
      final id = '${args['image_id'] ?? ''}'.trim();
      if (id.isEmpty) {
        return ToolResult(
          toolCallId: toolCallId,
          content: 'add_history 必须提供 image_id。',
          isError: true,
        );
      }
      final ok = await addHistory(id, _kind(args['kind']));
      return ToolResult(
        toolCallId: toolCallId,
        content: ok ? '已把历史图片加入参考图库。' : '历史图片不存在或读取失败。',
        isError: !ok,
      );
    }
    if (action == 'add_canvas') {
      final ok = await addCanvas(_kind(args['kind']));
      return ToolResult(
        toolCallId: toolCallId,
        content: ok ? '已把画板当前图加入参考图库。' : '画板没有可用图片。',
        isError: !ok,
      );
    }
    final entryId = '${args['entry_id'] ?? ''}'.trim();
    if (entryId.isEmpty) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '$action 必须提供 entry_id。',
        isError: true,
      );
    }
    if (action == 'apply') {
      final ok = await apply(entryId);
      return ToolResult(
        toolCallId: toolCallId,
        content: ok ? '已应用到当前工作台。' : '参考图库中不存在该条目。',
        isError: !ok,
      );
    }
    if (action == 'remove') {
      final ok = await remove(entryId);
      return ToolResult(
        toolCallId: toolCallId,
        content: ok ? '已从参考图库删除。' : '参考图库中不存在该条目。',
        isError: !ok,
      );
    }
    return ToolResult(
      toolCallId: toolCallId,
      content: '未知操作：$action',
      isError: true,
    );
  }
}
