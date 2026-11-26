import 'dart:convert';

import '../../../data/models/nai_generation_params.dart';
import '../types.dart';
import 'agent_tool.dart';

typedef PreciseRefList = List<NaiPreciseReference> Function();
typedef PreciseRefSupported = bool Function();
typedef PreciseRefAddFromCanvas =
    Future<bool> Function({
      required NaiPreciseRefType type,
      required double strength,
      required double fidelity,
      required bool preferSameOutfit,
      required bool fromChat,
      required int imageIndex,
      required String? libraryEntryId,
    });
typedef PreciseRefUpdate =
    void Function(
      int index, {
      NaiPreciseRefType? type,
      double? strength,
      double? fidelity,
      bool? preferSameOutfit,
      bool? enabled,
    });

/// Agent 工具：查看和管理工作台的精准参考图。
class PreciseReferenceTool extends AgentTool {
  final PreciseRefList list;
  final PreciseRefSupported supported;
  final PreciseRefAddFromCanvas addFromCanvas;
  final PreciseRefUpdate update;
  final void Function(int index) remove;
  final void Function() clear;
  final Future<bool> Function(String entryId, {double? strength})?
  addVibeFromLibrary;

  PreciseReferenceTool({
    required this.list,
    required this.supported,
    required this.addFromCanvas,
    required this.update,
    required this.remove,
    required this.clear,
    this.addVibeFromLibrary,
  }) : super(
         name: 'precise_reference',
         label: '精准参考',
         description:
             '查看、添加、修改、删除精准参考图。每张参考图每张生成额外消耗 5 Anlas。'
             'add 支持 source=canvas（画板当前图）或 source=chat（聊天附图）；view 返回参考图；'
             'update 可修改类型、强度、Fidelity、优先同服装和启用状态。',
         parameters: const {
           'type': 'object',
           'properties': {
             'action': {
               'type': 'string',
               'enum': ['list', 'add', 'add_vibe_library', 'update', 'remove', 'clear', 'view'],
             },
             'index': {'type': 'integer'},
             'type': {
               'type': 'string',
               'enum': ['character', 'style', 'character&style', 'outfit'],
             },
             'strength': {'type': 'number'},
             'fidelity': {'type': 'number'},
             'prefer_same_outfit': {'type': 'boolean'},
             'enabled': {'type': 'boolean'},
             'source': {
               'type': 'string',
               'enum': ['canvas', 'chat', 'library'],
               'description': 'canvas = 画板当前图；chat = 最近一条带图聊天消息；library = 词库条目展示图',
             },
             'library_entry_id': {
               'type': 'string',
               'description': 'source=library 时的词库条目 ID',
             },
             'image_index': {
               'type': 'integer',
               'description': 'source=chat 时的附件序号，0 开始；-1 表示最后一张',
             },
           },
           'required': ['action'],
         },
       );

  NaiPreciseRefType? _type(Object? value) => switch ('$value') {
    'character' => NaiPreciseRefType.character,
    'style' => NaiPreciseRefType.style,
    'character&style' => NaiPreciseRefType.characterAndStyle,
    'outfit' => NaiPreciseRefType.outfit,
    _ => null,
  };

  double _number(Object? value, double fallback) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed ?? fallback;
  }

  @override
  Future<ToolResult> execute(
    String toolCallId,
    Map<String, dynamic> args,
  ) async {
    final action = '${args['action'] ?? 'list'}';
    final entries = list();
    if (action == 'list') {
      if (entries.isEmpty) {
        return ToolResult(toolCallId: toolCallId, content: '当前没有精准参考图。');
      }
      final buffer = StringBuffer('精准参考（${entries.length} 张）：\n');
      for (var i = 0; i < entries.length; i += 1) {
        final entry = entries[i];
        buffer.writeln(
          '- [${entry.id ?? i}] ${entry.type.apiValue} strength=${entry.strength.toStringAsFixed(2)} '
          'fidelity=${entry.fidelity.toStringAsFixed(2)} '
          'prefer_same_outfit=${entry.preferSameOutfit} enabled=${entry.enabled}',
        );
      }
      return ToolResult(toolCallId: toolCallId, content: buffer.toString());
    }
    if (action == 'view') {
      final index = (args['index'] as num?)?.toInt() ?? -1;
      if (index < 0 || index >= entries.length) {
        return ToolResult(
          toolCallId: toolCallId,
          content: '精准参考索引无效：$index',
          isError: true,
        );
      }
      return ToolResult(
        toolCallId: toolCallId,
        content: '精准参考 #$index',
        imageBase64: base64Encode(entries[index].bytes),
      );
    }
    if (action == 'clear') {
      clear();
      return ToolResult(toolCallId: toolCallId, content: '已清空精准参考。');
    }
    if (action == 'remove') {
      final index = (args['index'] as num?)?.toInt() ?? -1;
      if (index < 0 || index >= entries.length) {
        return ToolResult(
          toolCallId: toolCallId,
          content: '精准参考索引无效：$index',
          isError: true,
        );
      }
      remove(index);
      return ToolResult(
        toolCallId: toolCallId,
        content: '已删除精准参考 #$index。',
      );
    }
    if (action == 'add_vibe_library') {
      final entryId = '${args['library_entry_id'] ?? ''}'.trim();
      if (entryId.isEmpty) {
        return ToolResult(
          toolCallId: toolCallId,
          content: 'add_vibe_library 必须提供 library_entry_id。',
          isError: true,
        );
      }
      final callback = addVibeFromLibrary;
      if (callback == null) {
        return ToolResult(
          toolCallId: toolCallId,
          content: '当前环境未接入 Vibe 参考库。',
          isError: true,
        );
      }
      final ok = await callback(
        entryId,
        strength: args['strength'] == null
            ? null
            : _number(args['strength'], 0.6),
      );
      return ToolResult(
        toolCallId: toolCallId,
        content: ok ? '已将词库展示图加入 Vibe Transfer。' : '词库条目没有展示图或读取失败。',
        isError: !ok,
      );
    }
    if (action == 'add') {
      if (entries.length >= 16) {
        return ToolResult(
          toolCallId: toolCallId,
          content: '精准参考最多 16 张，已达上限。',
          isError: true,
        );
      }
      if (!supported()) {
        return ToolResult(
          toolCallId: toolCallId,
          content: '当前模型不支持精准参考，请切换到 V5 或 V4.5。',
          isError: true,
        );
      }
      final type = _type(args['type']) ?? NaiPreciseRefType.characterAndStyle;
      final strength = _number(args['strength'], 1.0);
      final fidelity = _number(args['fidelity'], 1.0);
      final source = '${args['source'] ?? 'canvas'}';
      final fromChat = source == 'chat';
      final libraryEntryId = source == 'library'
          ? '${args['library_entry_id'] ?? ''}'.trim()
          : null;
      if (source == 'library' && (libraryEntryId == null || libraryEntryId.isEmpty)) {
        return ToolResult(
          toolCallId: toolCallId,
          content: 'source=library 时必须提供 library_entry_id。',
          isError: true,
        );
      }
      final ok = await addFromCanvas(
        type: type,
        strength: strength,
        fidelity: fidelity,
        preferSameOutfit: args['prefer_same_outfit'] == true,
        fromChat: fromChat,
        imageIndex: (args['image_index'] as num?)?.toInt() ?? -1,
        libraryEntryId: libraryEntryId,
      );
      return ToolResult(
        toolCallId: toolCallId,
        content: ok
            ? (fromChat
                ? '已将聊天最新附图加入精准参考。'
                : libraryEntryId != null
                ? '已将词库展示图加入精准参考。'
                : '已将画板当前图加入精准参考。')
            : (fromChat
                ? '聊天消息里没有图片。'
                : libraryEntryId != null
                ? '词库条目没有展示图或读取失败。'
                : '画板没有可用图片。'),
        isError: !ok,
      );
    }
    if (action == 'update') {
      final index = (args['index'] as num?)?.toInt() ?? -1;
      if (index < 0 || index >= entries.length) {
        return ToolResult(
          toolCallId: toolCallId,
          content: '精准参考索引无效：$index',
          isError: true,
        );
      }
      update(
        index,
        type: _type(args['type']),
        strength: args['strength'] == null ? null : _number(args['strength'], 1),
        fidelity: args['fidelity'] == null ? null : _number(args['fidelity'], 1),
        preferSameOutfit: args['prefer_same_outfit'] as bool?,
        enabled: args['enabled'] as bool?,
      );
      return ToolResult(
        toolCallId: toolCallId,
        content: '已更新精准参考 #$index。',
      );
    }
    return ToolResult(
      toolCallId: toolCallId,
      content: '未知操作：$action',
      isError: true,
    );
  }
}
