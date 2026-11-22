import 'package:flutter/material.dart';

import '../../../../data/services/network_proxy_service.dart';
import '../../../core/context_l10n.dart';
import '../view_models/studio_view_model.dart';

/// 功能界面内的“走代理”开关。
///
/// 全局代理未开启时点击只提示去设置；开启后切换会立即持久化配置，
/// 底层为动态客户端，下一条请求自动改用新的代理策略。
class ProxyFeatureSwitch extends StatelessWidget {
  const ProxyFeatureSwitch({
    super.key,
    required this.viewModel,
    required this.feature,
    required this.label,
    this.compact = false,
  });

  final StudioViewModel viewModel;
  final NetworkFeature feature;
  final String label;
  final bool compact;

  bool get _proxyEnabled => viewModel.config.proxyEnabled;

  bool get _featureEnabled => switch (feature) {
    NetworkFeature.novelAi => viewModel.config.proxyUseNovelAi,
    NetworkFeature.agent => viewModel.config.proxyUseAgent,
    NetworkFeature.gallery => viewModel.config.proxyUseGallery,
    NetworkFeature.other => true,
  };

  Future<void> _toggle(BuildContext context) async {
    if (!_proxyEnabled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.proxyEnableFirst)));
      return;
    }
    final config = viewModel.config;
    final next = !_featureEnabled;
    final updated = switch (feature) {
      NetworkFeature.novelAi => config.copyWith(proxyUseNovelAi: next),
      NetworkFeature.agent => config.copyWith(proxyUseAgent: next),
      NetworkFeature.gallery => config.copyWith(proxyUseGallery: next),
      NetworkFeature.other => config,
    };
    await viewModel.updateConfig(updated);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final selected = _proxyEnabled && _featureEnabled;
        final hint = selected
            ? context.l10n.proxyFeatureOnHint(label)
            : context.l10n.proxyFeatureOffHint(label);
        return Tooltip(
          message: hint,
          child: FilterChip(
            avatar: Icon(
              selected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              size: 14,
            ),
            label: Text(
              label,
              style: TextStyle(fontSize: compact ? 10.5 : 11.5),
            ),
            selected: selected,
            showCheckmark: false,
            onSelected: (_) => _toggle(context),
            visualDensity: compact ? VisualDensity.compact : null,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6),
          ),
        );
      },
    );
  }
}
