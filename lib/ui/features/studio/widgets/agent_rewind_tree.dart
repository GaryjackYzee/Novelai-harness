import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/context_l10n.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../view_models/chat_checkpoints.dart';

/// 回溯树节点：checkpoint / 分支 / 根。
class _TreeNode {
  final ChatCheckpoint? checkpoint;
  final ChatBranch? branch;
  final List<_TreeNode> children = [];
  double x = 0;
  double width = 0;

  _TreeNode.checkpoint(this.checkpoint) : branch = null;
  _TreeNode.branch(this.branch) : checkpoint = null;
  _TreeNode.root()
      : checkpoint = null,
        branch = null;
}

/// 从上往下生长的回溯树：主时间线在左，分支从对应节点向右展开。
class AgentRewindTree extends StatelessWidget {
  final List<ChatCheckpoint> checkpoints;
  final List<ChatBranch> branches;
  final String sessionId;
  final int? selectedIndex;
  final Map<int, GlobalKey> itemKeys;
  final ValueChanged<int> onSelectCheckpoint;
  final ValueChanged<int> onConfirmCheckpoint;
  final ValueChanged<ChatBranch> onRestoreBranch;
  final ScrollController? scrollController;

  const AgentRewindTree({
    super.key,
    required this.checkpoints,
    required this.branches,
    required this.sessionId,
    required this.selectedIndex,
    required this.itemKeys,
    required this.onSelectCheckpoint,
    required this.onConfirmCheckpoint,
    required this.onRestoreBranch,
    this.scrollController,
  });

  static const double _cardWidth = 220;
  static const double _branchWidth = 190;
  static const double _cardHeight = 82;
  static const double _branchHeight = 66;
  static const double _levelGap = 54;
  static const double _siblingGap = 18;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final root = _buildTree();
    _measure(root);
    _place(root, 0, 0);
    final maxDepth = _maxDepth(root);
    final width = math.max(root.width, _cardWidth) + 48;
    final height = (maxDepth + 1) * (_cardHeight + _levelGap) + 48;

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: scrollController,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ConnectorPainter(root, colors.borderHover),
                  ),
                ),
                ..._widgets(context, root),
                if (scrollController != null)
                  Positioned(
                    top: 6,
                    right: 8,
                    child: Material(
                      color: colors.elevatedBackground,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      child: IconButton(
                        key: const ValueKey('rewind_tree_to_root'),
                        tooltip: l10n.rewindBackToRoot,
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => scrollController!.animateTo(
                          0,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                        ),
                        icon: const Icon(Icons.vertical_align_top_rounded),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _TreeNode _buildTree() {
    final root = _TreeNode.root();
    final byCheckpoint = <String, List<ChatBranch>>{};
    final visibleForkIds = checkpoints
        .map((checkpoint) => checkpoint.userMessage.id)
        .toSet();
    for (final branch in branches) {
      if (branch.sessionId != sessionId) continue;
      if (!visibleForkIds.contains(branch.forkMessageId)) {
        root.children.add(_TreeNode.branch(branch));
      } else {
        byCheckpoint.putIfAbsent(branch.forkMessageId, () => []).add(branch);
      }
    }
    _TreeNode? buildCheckpoint(int index) {
      if (index < 0 || index >= checkpoints.length) return null;
      final node = _TreeNode.checkpoint(checkpoints[index]);
      final next = buildCheckpoint(index + 1);
      if (next != null) node.children.add(next);
      for (final branch in byCheckpoint[checkpoints[index].userMessage.id] ?? const <ChatBranch>[]) {
        node.children.add(_TreeNode.branch(branch));
      }
      return node;
    }

    final first = buildCheckpoint(0);
    if (first != null) root.children.add(first);
    return root;
  }

  double _measure(_TreeNode node) {
    final ownWidth = node.branch != null
        ? _branchWidth
        : (node.checkpoint != null ? _cardWidth : 90.0);
    if (node.children.isEmpty) {
      node.width = ownWidth;
      return node.width;
    }
    var total = 0.0;
    for (var i = 0; i < node.children.length; i += 1) {
      total += _measure(node.children[i]);
      if (i > 0) total += _siblingGap;
    }
    node.width = math.max(ownWidth, total).toDouble();
    return node.width;
  }

  void _place(_TreeNode node, double left, int depth) {
    if (node.children.isEmpty) {
      node.x = left + node.width / 2;
      return;
    }
    var childLeft = left;
    final offsets = <double>[];
    for (final child in node.children) {
      _place(child, childLeft, depth + 1);
      offsets.add(child.x);
      childLeft += child.width + _siblingGap;
    }
    node.x = (offsets.first + offsets.last) / 2;
  }

  int _maxDepth(_TreeNode node) {
    if (node.children.isEmpty) return 0;
    return 1 + node.children.map(_maxDepth).reduce(math.max);
  }

  List<Widget> _widgets(BuildContext context, _TreeNode root) {
    final result = <Widget>[];
    void visit(_TreeNode node, int depth) {
      if (node.checkpoint != null || node.branch != null) {
        final isBranch = node.branch != null;
        final width = isBranch ? _branchWidth : _cardWidth;
        final height = isBranch ? _branchHeight : _cardHeight;
        result.add(
          Positioned(
            left: node.x - width / 2,
            top: 20 + depth * (_cardHeight + _levelGap),
            width: width,
            height: height,
            child: isBranch
                ? _BranchCard(
                    branch: node.branch!,
                    onTap: () => onRestoreBranch(node.branch!),
                  )
                : _CheckpointNodeCard(
                    checkpoint: node.checkpoint!,
                    index: checkpoints.indexOf(node.checkpoint!),
                    selected:
                        selectedIndex == checkpoints.indexOf(node.checkpoint!),
                    itemKey: itemKeys.putIfAbsent(
                      checkpoints.indexOf(node.checkpoint!),
                      GlobalKey.new,
                    ),
                    onTap: () => onSelectCheckpoint(
                      checkpoints.indexOf(node.checkpoint!),
                    ),
                    onDoubleTap: () => onConfirmCheckpoint(
                      checkpoints.indexOf(node.checkpoint!),
                    ),
                  ),
          ),
        );
      }
      for (final child in node.children) {
        visit(child, depth + 1);
      }
    }

    result.add(
      Positioned(
        left: root.x - 45,
        top: 20,
        width: 90,
        height: AgentRewindTree._cardHeight,
        child: _RootCard(label: context.l10n.rewindRootLabel),
      ),
    );
    visit(root, 0);
    return result;
  }
}

class _CheckpointNodeCard extends StatelessWidget {
  final ChatCheckpoint checkpoint;
  final int index;
  final bool selected;
  final GlobalKey itemKey;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  const _CheckpointNodeCard({
    required this.checkpoint,
    required this.index,
    required this.selected,
    required this.itemKey,
    required this.onTap,
    required this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      key: itemKey,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: selected ? colors.primaryTint : colors.cardBackground,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? colors.primary : colors.borderDefault,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  '#${checkpoint.index}',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: selected ? colors.primary : colors.textMuted,
                  ),
                ),
                const Spacer(),
                Text(
                  '${checkpoint.userMessage.createdAt.hour.toString().padLeft(2, '0')}:'
                  '${checkpoint.userMessage.createdAt.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 9.5, color: colors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              checkpoint.userMessage.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
                height: 1.25,
              ),
            ),
            if (checkpoint.assistantMessage?.content.isNotEmpty ?? false) ...[
              const SizedBox(height: 3),
              Text(
                checkpoint.assistantMessage!.content,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9.5, color: colors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BranchCard extends StatelessWidget {
  final ChatBranch branch;
  final VoidCallback onTap;

  const _BranchCard({required this.branch, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
        decoration: BoxDecoration(
          color: colors.elevatedBackground,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: colors.borderDefault),
        ),
        child: Row(
          children: [
            Icon(Icons.call_split_rounded, size: 13, color: colors.primary),
            const SizedBox(width: 5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.rewindBranchLabel,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    branch.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectorPainter extends CustomPainter {
  final _TreeNode root;
  final Color color;

  _ConnectorPainter(this.root, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    void draw(_TreeNode node, int depth) {
      if (node.children.isEmpty) return;
      final parentY = 20 + depth * (AgentRewindTree._cardHeight + AgentRewindTree._levelGap) + AgentRewindTree._cardHeight;
      final childY = 20 + (depth + 1) * (AgentRewindTree._cardHeight + AgentRewindTree._levelGap);
      final midY = (parentY + childY) / 2;
      canvas.drawLine(Offset(node.x, parentY), Offset(node.x, midY), paint);
      canvas.drawLine(
        Offset(node.children.first.x, midY),
        Offset(node.children.last.x, midY),
        paint,
      );
      for (final child in node.children) {
        canvas.drawLine(Offset(child.x, midY), Offset(child.x, childY), paint);
        draw(child, depth + 1);
      }
    }

    draw(root, 0);
  }

  @override
  bool shouldRepaint(covariant _ConnectorPainter oldDelegate) =>
      oldDelegate.root != root || oldDelegate.color != color;
}


class _RootCard extends StatelessWidget {
  final String label;

  const _RootCard({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.elevatedBackground,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.borderDefault),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}
