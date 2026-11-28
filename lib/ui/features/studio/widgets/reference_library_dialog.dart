import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/context_l10n.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../../../../data/services/clipboard_image_service.dart';
import '../../../../data/models/nai_generation_params.dart';
import '../../../../data/services/reference_library_service.dart';
import '../view_models/studio_view_model.dart';

/// 参考图库：持久化管理精准参考与 Vibe 图片。
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
  bool _loading = true;
  List<ReferenceLibraryEntry> _entries = const [];

  ReferenceLibraryKind get _kind =>
      _tab == 0 ? ReferenceLibraryKind.precise : ReferenceLibraryKind.vibe;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await ReferenceLibraryService.instance.load();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _addCurrentCanvas() async {
    final entry = await widget.viewModel.saveCurrentCanvasToReferenceLibrary(
      _kind,
    );
    if (!mounted) return;
    if (entry == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.paramsCanvasEmpty)),
      );
      return;
    }
    await _reload();
  }

  Future<void> _importFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.paramsCanvasEmpty)),
        );
      }
      return;
    }
    await ReferenceLibraryService.instance.add(
      kind: _kind,
      name: result?.files.firstOrNull?.name ?? 'reference',
      bytes: bytes,
    );
    await _reload();
  }

  Future<void> _paste() async {
    final bytes = await ClipboardImageService.read();
    if (bytes == null || bytes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.paramsVibeClipboardEmpty)),
        );
      }
      return;
    }
    await ReferenceLibraryService.instance.add(
      kind: _kind,
      name: 'clipboard',
      bytes: bytes,
    );
    await _reload();
  }

  Future<void> _delete(ReferenceLibraryEntry entry) async {
    await ReferenceLibraryService.instance.remove(entry);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final visible = _entries.where((entry) => entry.kind == _kind).toList();
    final content = SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text(
                  l10n.referenceLibraryTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _importFile,
                  icon: const Icon(Icons.file_open_outlined, size: 16),
                  label: Text(l10n.paramsSelectFile),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _paste,
                  icon: const Icon(Icons.content_paste, size: 16),
                  label: Text(l10n.pasteDialogTitle),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _addCurrentCanvas,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                  label: Text(l10n.referenceAddCanvas),
                ),
                const SizedBox(width: 8),
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
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                ? Center(child: Text(l10n.referenceLibraryEmpty))
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisExtent: 230,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: visible.length,
                    itemBuilder: (context, index) =>
                        _entryCard(context, visible[index]),
                  ),
          ),
        ],
      ),
    );
    return widget.page
        ? ColoredBox(color: colors.elevatedBackground, child: content)
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

  Future<void> _edit(ReferenceLibraryEntry entry) async {
    var next = entry;
    final strengthController = TextEditingController(
      text: entry.strength.toStringAsFixed(2),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(context.l10n.libraryMenuEdit),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: next.name,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (value) => next = next.copyWith(name: value),
              ),
              if (next.kind == ReferenceLibraryKind.precise)
                DropdownButtonFormField<NaiPreciseRefType>(
                  key: ValueKey(next.preciseType),
                  initialValue: next.preciseType,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: NaiPreciseRefType.values
                      .map(
                        (type) => DropdownMenuItem(
                          value: type,
                          child: Text(type.name),
                        ),
                      )
                      .toList(),
                  onChanged: (type) =>
                      setState(() => next = next.copyWith(preciseType: type)),
                ),
              if (next.kind == ReferenceLibraryKind.precise)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.preciseRefPreferOutfit),
                  value: next.preferSameOutfit,
                  onChanged: (value) => setState(
                    () => next = next.copyWith(preferSameOutfit: value),
                  ),
                ),
              TextFormField(
                controller: strengthController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Strength'),
                onChanged: (value) {
                  final parsed = double.tryParse(value);
                  if (parsed == null) return;
                  final max = next.kind == ReferenceLibraryKind.precise ? 5.0 : 1.0;
                  next = next.copyWith(strength: parsed.clamp(0.0, max));
                },
              ),
              Slider(
                value: next.strength.clamp(
                  0,
                  next.kind == ReferenceLibraryKind.precise ? 5 : 1,
                ),
                min: 0,
                max: next.kind == ReferenceLibraryKind.precise ? 5 : 1,
                onChanged: (value) {
                  strengthController.text = value.toStringAsFixed(2);
                  setState(() => next = next.copyWith(strength: value));
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );
    strengthController.dispose();
    if (saved == true) {
      await ReferenceLibraryService.instance.update(next);
      await _reload();
    }
  }

  Widget _entryCard(BuildContext context, ReferenceLibraryEntry entry) {
    final colors = context.colors;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Image.memory(
              entry.thumbnailBytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.textPrimary),
                ),
                Text(
                  entry.kind == ReferenceLibraryKind.precise
                      ? '${entry.preciseType.name} · ${entry.strength.toStringAsFixed(2)}'
                      : 'Vibe · ${entry.strength.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 10.5, color: colors.textMuted),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: context.l10n.libraryCardApply,
                      onPressed: () =>
                          widget.viewModel.applyReferenceLibraryEntry(entry),
                      icon: const Icon(Icons.bolt_outlined, size: 16),
                    ),
                    IconButton(
                      tooltip: context.l10n.libraryMenuEdit,
                      onPressed: () => _edit(entry),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                    ),
                    IconButton(
                      tooltip: context.l10n.delete,
                      onPressed: () => _delete(entry),
                      icon: const Icon(Icons.delete_outline, size: 16),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
