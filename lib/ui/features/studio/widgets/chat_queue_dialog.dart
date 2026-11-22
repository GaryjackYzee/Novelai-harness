import 'package:flutter/material.dart';

import '../../../../data/services/chat_queue_store.dart';
import '../../../core/context_l10n.dart';
import '../view_models/studio_view_model.dart';

/// 对话消息队列管理：暂停发送 / 拖动排序 / 编辑 / 立即发送 / 删除。
class ChatQueueDialog extends StatefulWidget {
  const ChatQueueDialog({super.key, required this.viewModel});

  final StudioViewModel viewModel;

  static Future<void> show(BuildContext context, StudioViewModel viewModel) {
    return showDialog<void>(
      context: context,
      builder: (_) => ChatQueueDialog(viewModel: viewModel),
    );
  }

  @override
  State<ChatQueueDialog> createState() => _ChatQueueDialogState();
}

class _ChatQueueDialogState extends State<ChatQueueDialog> {
  Future<void> _edit(int index, QueuedChatMessage message) async {
    final controller = TextEditingController(text: message.content);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.queueEditTitle),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            minLines: 3,
            maxLines: 8,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(dialogContext.l10n.commonSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value.trim().isNotEmpty) {
      await widget.viewModel.editQueuedMessage(index, value);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final queue = viewModel.queuedChatMessages;
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    l10n.queueTitle,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${queue.length}',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await viewModel.toggleChatQueuePaused();
                      if (mounted) setState(() {});
                    },
                    icon: Icon(
                      viewModel.chatQueuePaused
                          ? Icons.play_arrow
                          : Icons.pause,
                      size: 16,
                    ),
                    label: Text(
                      viewModel.chatQueuePaused
                          ? l10n.queueResume
                          : l10n.queuePause,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              Text(
                l10n.queueHint,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: queue.isEmpty
                    ? Center(
                        child: Text(l10n.queueEmpty,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      )
                    : ReorderableListView.builder(
                        shrinkWrap: true,
                        buildDefaultDragHandles: false,
                        itemCount: queue.length,
                        onReorderItem: (oldIndex, newIndex) async {
                          await viewModel.moveQueuedMessage(oldIndex, newIndex);
                          if (mounted) setState(() {});
                        },
                        itemBuilder: (context, index) {
                          final message = queue[index];
                          return Container(
                            key: ValueKey('chat_queue_$index'),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.only(top: 8, right: 6),
                                    child: Icon(Icons.drag_indicator, size: 16),
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        message.content.isEmpty
                                            ? l10n.queueOnlyImages
                                            : message.content,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      if (message.images.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Row(
                                            children: [
                                              const Icon(Icons.attach_file,
                                                  size: 12),
                                              const SizedBox(width: 2),
                                              Text(
                                                l10n.queueImagesCount(
                                                    message.images.length),
                                                style: const TextStyle(
                                                    fontSize: 10,
                                                    color: Colors.grey),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: l10n.commonEdit,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _edit(index, message),
                                  icon:
                                      const Icon(Icons.edit_outlined, size: 16),
                                ),
                                IconButton(
                                  tooltip: l10n.queueSendNow,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () async {
                                    await viewModel.sendQueuedMessageNow(index);
                                    if (mounted) setState(() {});
                                  },
                                  icon: const Icon(Icons.send, size: 16),
                                ),
                                IconButton(
                                  tooltip: l10n.commonDelete,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () async {
                                    await viewModel.removeQueuedMessage(index);
                                    if (mounted) setState(() {});
                                  },
                                  icon:
                                      const Icon(Icons.delete_outline, size: 16),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
