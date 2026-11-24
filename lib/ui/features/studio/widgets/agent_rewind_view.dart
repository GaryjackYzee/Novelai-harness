import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/context_l10n.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../../../core/widgets/app_action_button.dart';
import '../../../core/widgets/app_badge.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_icon_button.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/smooth_scroll_controller.dart';
import '../view_models/chat_checkpoints.dart';
import '../view_models/studio_view_model.dart';
import 'agent_rewind_tree.dart';

/// 全屏覆盖 Agent Card 的历史时刻回溯视图 (按两次 ESC 调出，参考 Pi 的对话时刻回溯)
///
/// Notion 极简时间线布局：柔和无框浅底卡片、默认定位到最新轮次、
/// 支持上下方向键选择 + Enter 确认回溯 + ESC 退出。
class AgentRewindView extends StatefulWidget {
  final StudioViewModel viewModel;
  final VoidCallback onBack;

  /// 窄屏/触屏紧凑形态：隐藏「Esc 退出」徽章 (移动端通常无物理键盘)
  final bool compact;

  const AgentRewindView({
    super.key,
    required this.viewModel,
    required this.onBack,
    this.compact = false,
  });

  @override
  State<AgentRewindView> createState() => _AgentRewindViewState();
}

class _AgentRewindViewState extends State<AgentRewindView> {
  int? _selectedCheckpointIndex;
  final FocusNode _focusNode = FocusNode();
  final SmoothWheelScrollController _scrollController =
      SmoothWheelScrollController();
  final Map<int, GlobalKey> _itemKeys = {};
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      if (_scrollController.hasClients &&
          _scrollController.position.hasContentDimensions) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  List<ChatCheckpoint> _extractCheckpoints() =>
      extractChatCheckpoints(widget.viewModel.messages);

  void _scrollToCheckpoint(int index) {
    final key = _itemKeys[index];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: AppMotion.resolveDuration(context, AppMotionDurations.quick),
        curve: AppMotionCurves.smoothOut,
        alignment: 0.5,
      );
    }
  }

  Future<void> _confirmRewind(List<ChatCheckpoint> checkpoints) async {
    if (_confirming ||
        _selectedCheckpointIndex == null ||
        _selectedCheckpointIndex! < 0 ||
        _selectedCheckpointIndex! >= checkpoints.length) {
      return;
    }

    final target = checkpoints[_selectedCheckpointIndex!];
    setState(() => _confirming = true);
    try {
      // 截断到该条用户消息之前，内容放回输入框，不发送。
      await widget.viewModel.rewindToMessage(target.userMessage.id);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (!mounted) return;
    widget.onBack();
  }

  KeyEventResult _handleKeyEvent(
    FocusNode node,
    KeyEvent event,
    List<ChatCheckpoint> checkpoints,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) widget.onBack();
      return KeyEventResult.handled;
    }
    if (checkpoints.isEmpty) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final current = _selectedCheckpointIndex;
      final next = current == null
          ? checkpoints.length - 1
          : (current - 1).clamp(0, checkpoints.length - 1);
      setState(() => _selectedCheckpointIndex = next);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCheckpoint(next),
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final current = _selectedCheckpointIndex;
      final next = current == null
          ? 0
          : (current + 1).clamp(0, checkpoints.length - 1);
      setState(() => _selectedCheckpointIndex = next);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCheckpoint(next),
      );
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        _selectedCheckpointIndex != null) {
      _confirmRewind(checkpoints);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final checkpoints = _extractCheckpoints();
    final selected = _selectedCheckpointIndex;
    final hasSelection =
        selected != null && selected >= 0 && selected < checkpoints.length;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) => _handleKeyEvent(node, event, checkpoints),
      child: Card(
        margin: EdgeInsets.zero,
        color: colors.cardBackground,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部导航栏
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: colors.cardBackground,
                border: Border(bottom: BorderSide(color: colors.borderSubtle)),
              ),
              child: Row(
                children: [
                  AppIconButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    tooltip: l10n.rewindBackTooltip,
                    size: 28,
                    iconSize: 14,
                    variant: AppIconButtonVariant.ghost,
                    onPressed: widget.onBack,
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.history_rounded, size: 15, color: colors.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            l10n.rewindTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        if (checkpoints.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          AppBadge.pill(
                            label: '${checkpoints.length}',
                            variant: AppBadgeVariant.neutral,
                            fontSize: 10,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (!widget.compact)
                    AppBadge(
                      label: l10n.rewindEscExit,
                      variant: AppBadgeVariant.neutral,
                      shape: AppBadgeShape.pill,
                      fontSize: 10,
                    ),
                ],
              ),
            ),

            // 轻量说明提示条 (柔底无框，复用已有的 rewindDescription)
            if (checkpoints.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colors.elevatedBackground,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1.5),
                        child: Icon(
                          Icons.info_outline_rounded,
                          size: 13,
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          l10n.rewindDescription,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.textSecondary,
                            height: 1.38,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // 轮次列表区域
            Expanded(
              child: checkpoints.isEmpty
                  ? AppEmptyState(
                      icon: Icons.history_toggle_off_rounded,
                      iconSize: 32,
                      title: l10n.rewindEmptyTitle,
                      actionLabel: l10n.rewindBackAction,
                      actionIcon: Icons.arrow_back,
                      onActionPressed: widget.onBack,
                      isCompact: true,
                    )
                  : _buildCheckpointList(context, checkpoints),
            ),

            // 底部操作坞
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: colors.cardBackground,
                border: Border(top: BorderSide(color: colors.borderSubtle)),
              ),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppTextSwap(
                      text: hasSelection
                          ? l10n.rewindSelectedTurn(checkpoints[selected].index)
                          : (checkpoints.isNotEmpty
                                ? l10n.rewindSelectPrompt
                                : ''),
                      enableBlur: false,
                      duration: AppMotionDurations.quick,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: hasSelection
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: hasSelection
                            ? colors.primary
                            : colors.textMuted,
                      ),
                    ),
                    Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AppActionButton(
                          label: l10n.rewindCancelButton,
                          variant: AppActionButtonVariant.ghost,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          onPressed: widget.onBack,
                        ),
                        AppActionButton(
                          label: l10n.rewindConfirmButton,
                          variant: AppActionButtonVariant.primary,
                          isLoading: _confirming,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          onPressed: hasSelection && !_confirming
                              ? () => _confirmRewind(checkpoints)
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restoreBranch(ChatBranch branch) async {
    await widget.viewModel.restoreChatBranch(branch.id);
    if (mounted) widget.onBack();
  }

  Widget _buildCheckpointList(
    BuildContext context,
    List<ChatCheckpoint> checkpoints,
  ) {
    return AgentRewindTree(
      checkpoints: checkpoints,
      branches: widget.viewModel.chatBranches,
      sessionId: widget.viewModel.currentSessionId ?? '',
      selectedIndex: _selectedCheckpointIndex,
      itemKeys: _itemKeys,
      onSelectCheckpoint: (index) {
        _focusNode.requestFocus();
        setState(() => _selectedCheckpointIndex = index);
      },
      onConfirmCheckpoint: (index) {
        setState(() => _selectedCheckpointIndex = index);
        _confirmRewind(checkpoints);
      },
      onRestoreBranch: _restoreBranch,
      scrollController: _scrollController,
    );
  }

}

/// 回溯时刻卡片：柔底无框低噪质感，悬停平滑高光与微抬升，选中态主色描边。
