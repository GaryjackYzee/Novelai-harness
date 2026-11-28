import '../../../data/models/nai_image_result.dart';
import '../types.dart';
import 'agent_tool.dart';

typedef HistoryImagesGetter = List<NaiGeneratedImage> Function();
typedef HistoryMetadataReuse =
    void Function(NaiGeneratedImage image, Set<String> fields);

/// Agent 工具：读取历史图片元数据，并可把指定字段复用到工作台。
class HistoryMetadataTool extends AgentTool {
  final HistoryImagesGetter getHistory;
  final HistoryMetadataReuse reuse;

  HistoryMetadataTool({
    required this.getHistory,
    required this.reuse,
  }) : super(
         name: 'history_metadata',
         label: '历史图片元数据',
         description:
             '读取历史图片的提示词、模型、尺寸、步数、CFG、采样器、种子等元数据；'
             'reuse 可把指定字段直接复用到当前工作台。',
         parameters: const {
           'type': 'object',
           'properties': {
             'action': {
               'type': 'string',
               'enum': ['list', 'get', 'reuse'],
             },
             'index': {
               'type': 'integer',
               'description': '0 = 最新一张，从新到旧递增',
             },
             'id': {'type': 'string', 'description': '图片 ID，可与 index 二选一'},
             'limit': {'type': 'integer', 'description': 'list 返回数量，默认 20'},
             'fields': {
               'type': 'array',
               'items': {'type': 'string'},
               'description':
                   'reuse 字段：prompt / negative_prompt / model / resolution / '
                   'steps / scale / cfg_rescale / sampler / noise_schedule / seed / '
                   'effort / characters',
             },
           },
           'required': ['action'],
         },
       );

  @override
  Future<ToolResult> execute(
    String toolCallId,
    Map<String, dynamic> args,
  ) async {
    final history = getHistory();
    if (history.isEmpty) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '当前没有历史图片。',
        isError: true,
      );
    }
    final action = '${args['action'] ?? 'list'}';
    if (action == 'list') {
      final limit = (args['limit'] as num?)?.toInt().clamp(1, 50) ?? 20;
      final count = limit < history.length ? limit : history.length;
      final buffer = StringBuffer('历史图片（共 ${history.length} 张，显示 $count 张）：\n');
      for (var i = 0; i < count; i += 1) {
        final image = history[i];
        final params = image.params;
        buffer.writeln(
          '- [$i] ${image.id} | ${params.width}x${params.height} | '
          '${params.model.id} | steps=${params.steps} scale=${params.scale} | '
          'seed=${image.seed} | ${params.prompt}',
        );
      }
      return ToolResult(toolCallId: toolCallId, content: buffer.toString());
    }

    final index = _resolveIndex(history, args);
    if (index == null) {
      return ToolResult(
        toolCallId: toolCallId,
        content: '未找到指定历史图片，请传 index 或 id。',
        isError: true,
      );
    }
    final image = history[index];
    if (action == 'get') {
      return ToolResult(
        toolCallId: toolCallId,
        content: _format(image, index),
      );
    }
    if (action == 'reuse') {
      final fields = _parseFields(args['fields']);
      if (fields.isEmpty) {
        return ToolResult(
          toolCallId: toolCallId,
          content: '没有可复用字段。',
          isError: true,
        );
      }
      reuse(image, fields);
      return ToolResult(
        toolCallId: toolCallId,
        content:
            '已将历史图片 [$index] 的 ${fields.join(', ')} 复用到工作台。\n'
            '${_format(image, index)}',
      );
    }
    return ToolResult(
      toolCallId: toolCallId,
      content: '未知操作：$action',
      isError: true,
    );
  }

  int? _resolveIndex(List<NaiGeneratedImage> history, Map<String, dynamic> args) {
    final id = '${args['id'] ?? ''}'.trim();
    if (id.isNotEmpty) {
      final found = history.indexWhere((image) => image.id == id);
      return found == -1 ? null : found;
    }
    final raw = args['index'];
    final index = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    if (index == null || index < 0 || index >= history.length) return null;
    return index;
  }

  Set<String> _parseFields(Object? raw) {
    const allowed = {
      'prompt',
      'negative_prompt',
      'model',
      'resolution',
      'steps',
      'scale',
      'cfg_rescale',
      'sampler',
      'noise_schedule',
      'seed',
      'effort',
      'characters',
    };
    if (raw is! List) return allowed;
    return raw
        .map((item) => '$item'.trim())
        .where(allowed.contains)
        .toSet();
  }

  String _format(NaiGeneratedImage image, int index) {
    final p = image.params;
    return '''历史图片 [$index]
id: ${image.id}
created: ${image.createdAt.toIso8601String()}
model: ${p.model.id}
size: ${p.width}x${p.height}
steps: ${p.steps}
scale: ${p.scale}
cfg_rescale: ${p.cfgRescale}
sampler: ${p.sampler.id}
noise_schedule: ${p.noiseSchedule.id}
seed: ${image.seed}
effort: ${p.effort.name}
prompt: ${p.prompt}
negative_prompt: ${p.negativePrompt}''';
  }
}
