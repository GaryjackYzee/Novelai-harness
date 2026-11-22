import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../data/models/nai_generation_params.dart';
import '../../../../data/services/precise_reference_image_service.dart';
import '../../../core/context_l10n.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../../../core/widgets/app_segmented_controls.dart';
import '../view_models/studio_view_model.dart';

/// Precise Reference：角色参考 / 画风参考（仅 NAI V4.5）。
class PreciseReferenceSection extends StatelessWidget {
  const PreciseReferenceSection({super.key, required this.viewModel});

  final StudioViewModel viewModel;

  Future<void> _pickImages(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    var added = 0;
    for (final file in result.files) {
      Uint8List? raw = file.bytes;
      if (raw == null && file.path != null) {
        raw = await File(file.path!).readAsBytes();
      }
      if (raw == null) continue;
      final png = PreciseReferenceImageService.normalize(raw);
      if (png == null) continue;
      viewModel.addPreciseReference(png);
      added += 1;
    }
    if (context.mounted && added == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.preciseRefAddFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = context.l10n;
        final colors = context.colors;
        final params = viewModel.params;
        if (!params.model.supportsPreciseReference) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.preciseRefUnsupported,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          );
        }
        final references = params.preciseReferences;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.preciseRefHint,
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _pickImages(context),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                label: Text(l10n.preciseRefAdd),
              ),
            ),
            if (references.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.preciseRefEmpty,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
              )
            else
              for (var index = 0; index < references.length; index++)
                _PreciseReferenceCard(
                  key: ValueKey('precise-ref-$index'),
                  viewModel: viewModel,
                  index: index,
                  reference: references[index],
                ),
          ],
        );
      },
    );
  }
}

class _PreciseReferenceCard extends StatelessWidget {
  const _PreciseReferenceCard({
    super.key,
    required this.viewModel,
    required this.index,
    required this.reference,
  });

  final StudioViewModel viewModel;
  final int index;
  final NaiPreciseReference reference;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.cardBackground,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: Image.memory(
                  reference.bytes,
                  width: 54,
                  height: 54,
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppSegmentedPillBar<NaiPreciseRefType>(
                  items: [
                    AppSegmentedItem(
                      value: NaiPreciseRefType.character,
                      label: l10n.preciseRefCharacter,
                    ),
                    AppSegmentedItem(
                      value: NaiPreciseRefType.style,
                      label: l10n.preciseRefStyle,
                    ),
                    AppSegmentedItem(
                      value: NaiPreciseRefType.characterAndStyle,
                      label: l10n.preciseRefBoth,
                    ),
                  ],
                  selectedValue: reference.type,
                  onValueChanged: (type) =>
                      viewModel.updatePreciseReference(index, type: type),
                ),
              ),
              IconButton(
                tooltip: l10n.delete,
                onPressed: () => viewModel.removePreciseReference(index),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 17),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _ReferenceSlider(
            label: l10n.preciseRefStrength,
            value: reference.strength,
            onChanged: (value) =>
                viewModel.updatePreciseReference(index, strength: value),
          ),
          _ReferenceSlider(
            label: l10n.preciseRefFidelity,
            value: reference.fidelity,
            onChanged: (value) =>
                viewModel.updatePreciseReference(index, fidelity: value),
          ),
        ],
      ),
    );
  }
}

class _ReferenceSlider extends StatelessWidget {
  const _ReferenceSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: TextStyle(fontSize: 11, color: context.colors.textSecondary),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, 1.0),
            min: 0,
            max: 1,
            divisions: 20,
            label: value.toStringAsFixed(2),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value.toStringAsFixed(2),
            style: TextStyle(fontSize: 10, color: context.colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
