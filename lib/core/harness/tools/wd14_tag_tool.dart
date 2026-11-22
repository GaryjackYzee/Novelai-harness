import '../../../data/services/wd14_online_service.dart';
import '../types.dart';
import 'agent_tool.dart';

/// 在线 WD14 反推当前画布图片，返回标签并可选择写入正面提示词。
class Wd14TagTool extends AgentTool {
  Wd14TagTool({
    required this.tagImage,
    required this.applyTags,
  }) : super(
          name: 'wd14_tag',
          label: '在线 WD14',
          description:
              '调用在线 WD14 模型反推图片标签。source=canvas 反推画布当前图，source=chat 反推聊天里最近一条用户附图。apply=true 时把标签追加到工作台正面提示词。返回标签与置信度。',
          parameters: {
            'type': 'object',
            'properties': {
              'apply': {
                'type': 'boolean',
                'description': '是否把反推标签追加到正面提示词，默认 false',
              },
              'source': {
                'type': 'string',
                'enum': ['canvas', 'chat'],
                'description': '图片来源：canvas=画布当前图（默认），chat=聊天最近附图',
              },
              'threshold': {
                'type': 'number',
                'description': '置信度阈值，默认使用设置值（0.35）',
              },
            },
          },
        );

  final Future<List<Wd14Tag>> Function({
    required String source,
    double? threshold,
  }) tagImage;
  final Future<void> Function(List<Wd14Tag> tags) applyTags;

  @override
  Future<ToolResult> execute(String toolCallId, Map<String, dynamic> args) async {
    final threshold = (args['threshold'] as num?)?.toDouble();
    final source = args['source'] == 'chat' ? 'chat' : 'canvas';
    final List<Wd14Tag> tags;
    try {
      tags = await tagImage(source: source, threshold: threshold);
    } on Wd14Exception catch (error) {
      return ToolResult(
        toolCallId: toolCallId,
        content: 'WD14 反推失败：${error.message}',
        isError: true,
      );
    }
    if (tags.isEmpty) {
      return ToolResult(
        toolCallId: toolCallId,
        content: 'WD14 没有返回超过阈值的标签。',
      );
    }
    final apply = args['apply'] == true;
    if (apply) await applyTags(tags);
    final lines = <String>[
      if (apply) '已写入正面提示词：',
      for (final tag in tags)
        '${tag.name} (${(tag.score * 100).toStringAsFixed(1)}%)',
    ];
    return ToolResult(toolCallId: toolCallId, content: lines.join('\n'));
  }
}
