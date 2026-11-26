import 'package:flutter/material.dart';

import '../../../../data/models/prompt_library_models.dart';
import '../../../core/context_l10n.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/theme_context_extensions.dart';

enum PromptApplyAction {
  appendPrompt,
  replacePrompt,
  addCharacter,
  applyStyleAppend,
  applyStyleReplace,
  sendToAgent,
  usePreviewAsPrecise,
  attachCurrentReferences,
  applySavedReferences,
}

/// 词库条目应用方式选择。
class PromptComboApplyDialog extends StatelessWidget {
  final PromptComboEntry combo;

  const PromptComboApplyDialog({super.key, required this.combo});

  static Future<PromptApplyAction?> show(
    BuildContext context, {
    required PromptComboEntry combo,
  }) {
    return showDialog<PromptApplyAction>(
      context: context,
      builder: (_) => PromptComboApplyDialog(combo: combo),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    final actions = <({IconData icon, String label, PromptApplyAction action})>[
      (
        icon: Icons.playlist_add_outlined,
        label: l10n.libraryMenuAppendToPrompt,
        action: PromptApplyAction.appendPrompt,
      ),
      (
        icon: Icons.swap_horiz_outlined,
        label: l10n.libraryMenuReplacePrompt,
        action: PromptApplyAction.replacePrompt,
      ),
      if (combo.isCharacter)
        (
          icon: Icons.person_add_alt_1_outlined,
          label: l10n.libraryMenuAddAsCharacter,
          action: PromptApplyAction.addCharacter,
        ),
      if (combo.isStyle) ...[
        (
          icon: Icons.palette_outlined,
          label: l10n.libraryMenuApplyStyleAppend,
          action: PromptApplyAction.applyStyleAppend,
        ),
        (
          icon: Icons.palette_outlined,
          label: l10n.libraryMenuApplyStyleReplace,
          action: PromptApplyAction.applyStyleReplace,
        ),
      ],
      (
        icon: Icons.chat_bubble_outline_rounded,
        label: l10n.libraryMenuSendToAgent,
        action: PromptApplyAction.sendToAgent,
      ),
      if (combo.previewImagePath != null &&
          combo.previewImagePath!.trim().isNotEmpty)
        (
          icon: Icons.center_focus_strong_outlined,
          label: l10n.libraryUsePreviewAsReference,
          action: PromptApplyAction.usePreviewAsPrecise,
        ),
      (
        icon: Icons.link_outlined,
        label: l10n.libraryAttachCurrentReferences,
        action: PromptApplyAction.attachCurrentReferences,
      ),
      if (combo.preciseReferencePaths.isNotEmpty ||
          combo.vibeReferencePaths.isNotEmpty)
        (
          icon: Icons.download_outlined,
          label: l10n.libraryApplySavedReferences,
          action: PromptApplyAction.applySavedReferences,
        ),
    ];
    return Dialog(
      backgroundColor: colors.elevatedBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: SizedBox(
        width: 360,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                combo.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              for (final item in actions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(item.icon, size: 18, color: colors.textSecondary),
                  title: Text(item.label, style: const TextStyle(fontSize: 13)),
                  onTap: () => Navigator.of(context).pop(item.action),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
