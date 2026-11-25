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

/// Agent tool: inspect and manage precise reference images on the workbench.
class PreciseReferenceTool extends AgentTool {
  final PreciseRefList list;
  final PreciseRefSupported supported;
  final PreciseRefAddFromCanvas addFromCanvas;
  final PreciseRefUpdate update;
  final void Function(int index) remove;
  final void Function() clear;

  PreciseReferenceTool({
    required this.list,
    required this.supported,
    required this.addFromCanvas,
    required this.update,
    required this.remove,
    required this.clear,
  }) : super(
         name: 'precise_reference',
         label: 'Precise Reference',
         description:
             'View, add, update or remove Precise Reference images. Each reference costs +5 Anlas per generated image. '
             'add uses the current canvas image; view returns the reference image; '
             'update changes type / strength / fidelity / prefer_same_outfit / enabled.',
         parameters: const {
           'type': 'object',
           'properties': {
             'action': {
               'type': 'string',
               'enum': ['list', 'add', 'update', 'remove', 'clear', 'view'],
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
        return ToolResult(toolCallId: toolCallId, content: 'No precise references.');
      }
      final buffer = StringBuffer('Precise references (${entries.length}):\n');
      for (var i = 0; i < entries.length; i += 1) {
        final entry = entries[i];
        buffer.writeln(
          '- [$i] ${entry.type.apiValue} strength=${entry.strength.toStringAsFixed(2)} '
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
          content: 'Invalid reference index: $index',
          isError: true,
        );
      }
      return ToolResult(
        toolCallId: toolCallId,
        content: 'Precise reference #$index',
        imageBase64: base64Encode(entries[index].bytes),
      );
    }
    if (action == 'clear') {
      clear();
      return ToolResult(toolCallId: toolCallId, content: 'Cleared precise references.');
    }
    if (action == 'remove') {
      final index = (args['index'] as num?)?.toInt() ?? -1;
      if (index < 0 || index >= entries.length) {
        return ToolResult(
          toolCallId: toolCallId,
          content: 'Invalid reference index: $index',
          isError: true,
        );
      }
      remove(index);
      return ToolResult(
        toolCallId: toolCallId,
        content: 'Removed precise reference #$index.',
      );
    }
    if (action == 'add') {
      if (entries.length >= 16) {
        return ToolResult(
          toolCallId: toolCallId,
          content: 'Precise reference limit reached (max 16).',
          isError: true,
        );
      }
      if (!supported()) {
        return ToolResult(
          toolCallId: toolCallId,
          content: 'Current model does not support Precise Reference. Switch to V5 or V4.5.',
          isError: true,
        );
      }
      final type = _type(args['type']) ?? NaiPreciseRefType.characterAndStyle;
      final strength = _number(args['strength'], 1.0);
      final fidelity = _number(args['fidelity'], 1.0);
      final ok = await addFromCanvas(
        type: type,
        strength: strength,
        fidelity: fidelity,
        preferSameOutfit: args['prefer_same_outfit'] == true,
      );
      return ToolResult(
        toolCallId: toolCallId,
        content: ok
            ? 'Added current canvas image to precise references.'
            : 'No canvas image available.',
        isError: !ok,
      );
    }
    if (action == 'update') {
      final index = (args['index'] as num?)?.toInt() ?? -1;
      if (index < 0 || index >= entries.length) {
        return ToolResult(
          toolCallId: toolCallId,
          content: 'Invalid reference index: $index',
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
        content: 'Updated precise reference #$index.',
      );
    }
    return ToolResult(
      toolCallId: toolCallId,
      content: 'Unknown action: $action',
      isError: true,
    );
  }
}
