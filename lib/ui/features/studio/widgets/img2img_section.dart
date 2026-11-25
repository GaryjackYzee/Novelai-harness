import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/context_l10n.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../../../../data/services/clipboard_image_service.dart';
import '../view_models/studio_view_model.dart';
import 'image_paste_area.dart';

/// 图生图源图与 Vibe Transfer 参考图设置 (仅 NovelAI 后端)。
class Img2imgSection extends StatelessWidget {
  const Img2imgSection({super.key, required this.viewModel});

  final StudioViewModel viewModel;

  Future<void> _useCanvas(
    BuildContext context, {
    required bool reference,
  }) async {
    if (reference && viewModel.params.referenceImages.length >= 16) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.paramsVibeLimitReached)),
        );
      }
      return;
    }
    final ok = reference
        ? await viewModel.useSelectedImageAsReference()
        : await viewModel.useSelectedImageAsImg2imgSource();
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.paramsCanvasEmpty)));
    }
  }

  Future<void> _pickFile(
    BuildContext context, {
    required bool reference,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null || bytes.isEmpty) return;
    if (reference) {
      if (viewModel.params.referenceImages.length >= 16) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.paramsVibeLimitReached)),
          );
        }
        return;
      }
      viewModel.addReferenceImage(bytes);
    } else {
      viewModel.setImg2imgSource(bytes);
    }
  }

  Future<void> _pasteReference(BuildContext context) async {
    if (viewModel.params.referenceImages.length >= 16) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.paramsVibeLimitReached)),
      );
      return;
    }
    final bytes = await ClipboardImageService.read();
    if (bytes == null || bytes.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.paramsVibeClipboardEmpty)),
        );
      }
      return;
    }
    viewModel.addReferenceImage(bytes);
  }

  Widget _thumb(Uint8List bytes) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        bytes,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final params = viewModel.params;
    final small = TextStyle(fontSize: 11, color: context.colors.textSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (params.img2imgBytes == null)
          Text(l10n.paramsImg2imgEmpty, style: small)
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _thumb(params.img2imgBytes!),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${l10n.paramsImg2imgStrength} ${params.img2imgStrength.toStringAsFixed(2)}',
                      style: small,
                    ),
                    Slider(
                      value: params.img2imgStrength,
                      min: 0.01,
                      max: 0.99,
                      onChanged: viewModel.setImg2imgStrength,
                    ),
                    Text(
                      '${l10n.paramsImg2imgNoise} ${params.img2imgNoise.toStringAsFixed(2)}',
                      style: small,
                    ),
                    Slider(
                      value: params.img2imgNoise,
                      min: 0,
                      max: 0.99,
                      onChanged: viewModel.setImg2imgNoise,
                    ),
                  ],
                ),
              ),
            ],
          ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () => _useCanvas(context, reference: false),
              icon: const Icon(Icons.image_outlined, size: 14),
              label: Text(l10n.paramsImg2imgUseCanvas),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () => _pickFile(context, reference: false),
              icon: const Icon(Icons.folder_open, size: 14),
              label: Text(l10n.paramsSelectFile),
            ),
            if (params.img2imgBytes != null)
              TextButton(
                onPressed: () => viewModel.setImg2imgSource(null),
                child: Text(l10n.paramsImg2imgClear),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ImagePasteArea(
          onPaste: () => _pasteReference(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            if (params.referenceImages.isEmpty)
              Text(l10n.paramsVibeEmpty, style: small)
            else
              for (var index = 0; index < params.referenceImages.length; index += 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      _thumb(params.referenceImages[index].bytes),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${l10n.paramsVibeStrength} ${params.referenceImages[index].strength.toStringAsFixed(2)}',
                              style: small,
                            ),
                            Slider(
                              value: params.referenceImages[index].strength,
                              min: 0,
                              max: 1,
                              onChanged: (value) => viewModel.updateReferenceImage(
                                index,
                                strength: value,
                              ),
                            ),
                            Text(
                              '${l10n.paramsVibeInfo} ${params.referenceImages[index].informationExtracted.toStringAsFixed(2)}',
                              style: small,
                            ),
                            Slider(
                              value: params
                                  .referenceImages[index]
                                  .informationExtracted,
                              min: 0,
                              max: 1,
                              onChanged: (value) => viewModel.updateReferenceImage(
                                index,
                                informationExtracted: value,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.close,
                        onPressed: () => viewModel.removeReferenceImage(index),
                        icon: const Icon(Icons.delete_outline, size: 16),
                      ),
                    ],
                  ),
                ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: () => _useCanvas(context, reference: true),
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 14),
                  label: Text(l10n.paramsVibeAdd),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: () => _pickFile(context, reference: true),
                  icon: const Icon(Icons.folder_open, size: 14),
                  label: Text(l10n.paramsSelectFile),
                ),
                if (params.referenceImages.isNotEmpty)
                  TextButton(
                    onPressed: viewModel.clearReferenceImages,
                    child: Text(l10n.paramsVibeClear),
                  ),
            ],
          ),
            ],
          ),
        ),
      ],
    );
  }
}
