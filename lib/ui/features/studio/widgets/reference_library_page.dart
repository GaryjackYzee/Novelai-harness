import 'package:flutter/material.dart';

import '../view_models/studio_view_model.dart';
import 'reference_library_dialog.dart';

/// 参考图库整页（侧栏页栈成员）。
class ReferenceLibraryPage extends StatelessWidget {
  final StudioViewModel viewModel;
  final VoidCallback onClose;

  const ReferenceLibraryPage({
    super.key,
    required this.viewModel,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return ReferenceLibraryDialog(
      viewModel: viewModel,
      page: true,
      onClose: onClose,
    );
  }
}
