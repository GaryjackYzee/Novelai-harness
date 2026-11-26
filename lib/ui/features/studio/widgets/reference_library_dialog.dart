import 'package:flutter/material.dart';

import '../../../core/context_l10n.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../../../../data/models/nai_generation_params.dart';
import '../../../../data/services/studio_reference_store.dart';
import '../view_models/studio_view_model.dart';

/// 参考图库：统一管理精准参考与 Vibe 参考。
class ReferenceLibraryDialog extends StatefulWidget {
  final StudioViewModel viewModel;
  final bool page;
  final VoidCallback? onClose;

  const ReferenceLibraryDialog({
    super.key,
    required this.viewModel,
    this.page = false,
    this.onClose,
  });

  static Future<void> show(
    BuildContext context, {
    required StudioViewModel viewModel,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => ReferenceLibraryDialog(viewModel: viewModel),
    );
  }

  @override
  State<ReferenceLibraryDialog> createState() => _ReferenceLibraryDialogState();
}

class _ReferenceLibraryDialogState extends State<ReferenceLibraryDialog> {
  int _tab = 0;

  Future<void> _addPrecise() async {
    final ok = await widget.viewModel.addSelectedImageAsPreciseReference();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.paramsCanvasEmpty)),
      );
    }
  }

  Future<void> _addVibe() async {
    final ok = await widget.viewModel.useSelectedImageAsReference();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.paramsCanvasEmpty)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final content = SafeArea(
      child: ListenableBuilder(
          listenable: widget.viewModel,
          builder: (context, _) {
            final params = widget.viewModel.params;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        l10n.referenceLibraryTitle,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: widget.onClose ??
                            () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    _tabButton(0, l10n.promptsPreciseReference),
                    _tabButton(1, 'Vibe Transfer'),
                  ],
                ),
                if (StudioReferenceStore.instance.lastError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '参考图缓存异常：${StudioReferenceStore.instance.lastError}',
                      style: TextStyle(fontSize: 11, color: colors.error),
                    ),
                  ),
                const Divider(height: 1),
                Expanded(
                  child: _tab == 0
                      ? _buildPrecise(params)
                      : _buildVibe(params),
                ),
              ],
            );
          },
        ),
      );
    return widget.page
        ? content
        : Dialog.fullscreen(
            backgroundColor: colors.elevatedBackground,
            child: content,
          );
  }

  Widget _tabButton(int index, String label) {
    final colors = context.colors;
    final selected = _tab == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: TextButton(
        onPressed: () => setState(() => _tab = index),
        style: TextButton.styleFrom(
          backgroundColor: selected ? colors.primaryTint : Colors.transparent,
          foregroundColor: selected ? colors.primary : colors.textSecondary,
        ),
        child: Text(label),
      ),
    );
  }

  Widget _buildPrecise(NaiGenerationParams params) {
    final l10n = context.l10n;
    final colors = context.colors;
    if (params.preciseReferences.isEmpty) {
      return Center(child: Text(l10n.referenceLibraryEmpty));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (var i = 0; i < params.preciseReferences.length; i += 1)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      params.preciseReferences[i].bytes,
                      width: 64,
                      height: 80,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${l10n.promptsPreciseReference} #${i + 1}',
                              style: TextStyle(color: colors.textPrimary),
                            ),
                            const Spacer(),
                            DropdownButton<NaiPreciseRefType>(
                              value: params.preciseReferences[i].type,
                              underline: const SizedBox.shrink(),
                              items: NaiPreciseRefType.values
                                  .map(
                                    (type) => DropdownMenuItem(
                                      value: type,
                                      child: Text(
                                        type.name,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (type) {
                                if (type == null) return;
                                widget.viewModel.updatePreciseReference(
                                  i,
                                  type: type,
                                );
                              },
                            ),
                          ],
                        ),
                        Slider(
                          value: params.preciseReferences[i].strength.clamp(0, 5),
                          min: 0,
                          max: 5,
                          divisions: 50,
                          onChanged: (value) =>
                              widget.viewModel.updatePreciseReference(
                                i,
                                strength: value,
                              ),
                        ),
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            context.l10n.preciseRefPreferOutfit,
                            style: const TextStyle(fontSize: 11),
                          ),
                          value: params.preciseReferences[i].preferSameOutfit,
                          onChanged: (value) =>
                              widget.viewModel.updatePreciseReference(
                                i,
                                preferSameOutfit: value,
                              ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        widget.viewModel.removePreciseReference(i),
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _addPrecise,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
            label: Text(l10n.referenceAddCanvas),
          ),
        ),
      ],
    );
  }

  Widget _buildVibe(NaiGenerationParams params) {
    final l10n = context.l10n;
    final colors = context.colors;
    if (params.referenceImages.isEmpty) {
      return Center(child: Text(l10n.referenceLibraryEmpty));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (var i = 0; i < params.referenceImages.length; i += 1)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      params.referenceImages[i].bytes,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Vibe #${i + 1} · ${params.referenceImages[i].strength.toStringAsFixed(2)}',
                          style: TextStyle(color: colors.textSecondary),
                        ),
                        Slider(
                          value: params.referenceImages[i].strength.clamp(0, 1),
                          onChanged: (value) =>
                              widget.viewModel.updateReferenceImage(
                                i,
                                strength: value,
                              ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        widget.viewModel.removeReferenceImage(i),
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _addVibe,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
            label: Text(l10n.referenceAddCanvas),
          ),
        ),
      ],
    );
  }
}
