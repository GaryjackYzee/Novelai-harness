import 'package:flutter/material.dart';

import '../../../../data/services/network_proxy_service.dart';
import '../../../core/context_l10n.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/app_setting_tile.dart';
import 'general_settings_tab.dart';

/// 网络代理独立设置页：入口不再埋在“通用”页深处。
class NetworkSettingsTab extends StatefulWidget {
  const NetworkSettingsTab({super.key, required this.draft});

  final GeneralSettingsDraft draft;

  @override
  State<NetworkSettingsTab> createState() => _NetworkSettingsTabState();
}

class _NetworkSettingsTabState extends State<NetworkSettingsTab> {
  bool _testing = false;

  Future<void> _testProxy() async {
    if (_testing) return;
    setState(() => _testing = true);
    final draft = widget.draft;
    final host = draft.proxyHostController.text.trim();
    final port =
        int.tryParse(draft.proxyPortController.text.trim()) ?? 7890;
    final result = await NetworkProxyService.probeNovelAi(
      host: host,
      port: port,
    );
    if (!mounted) return;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${context.l10n.settingsProxyTestResult} $result')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final draft = widget.draft;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 600;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            isNarrow ? 14 : 28,
            8,
            isNarrow ? 14 : 28,
            28,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSectionHeader(title: l10n.settingsSectionNetwork),
              Text(
                l10n.settingsProxyIntro,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: context.colors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              AppSettingTile.switchTile(
                title: l10n.settingsProxyEnabledTitle,
                subtitle: l10n.settingsProxyEnabledSubtitle,
                value: draft.proxyEnabled,
                onChanged: (value) =>
                    setState(() => draft.proxyEnabled = value),
              ),
              AppSettingTile(
                title: l10n.settingsProxyHostTitle,
                subtitle: l10n.settingsProxyHostHint,
                control: SizedBox(
                  width: 250,
                  child: TextField(
                    controller: draft.proxyHostController,
                    enabled: draft.proxyEnabled,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: '127.0.0.1',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
              ),
              AppSettingTile(
                title: l10n.settingsProxyPortTitle,
                subtitle: l10n.settingsProxyRestartHint,
                control: SizedBox(
                  width: 110,
                  child: TextField(
                    controller: draft.proxyPortController,
                    enabled: draft.proxyEnabled,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: '7890',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              AppSectionHeader(title: l10n.settingsProxyPerFeatureTitle),
              Text(
                draft.proxyEnabled
                    ? l10n.settingsProxyPerFeatureHint
                    : l10n.settingsProxyDisabledHint,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: context.colors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              IgnorePointer(
                ignoring: !draft.proxyEnabled,
                child: Opacity(
                  opacity: draft.proxyEnabled ? 1 : 0.45,
                  child: Column(
                    children: [
                      AppSettingTile.switchTile(
                        title: l10n.settingsProxyUseNovelAiTitle,
                        subtitle: l10n.settingsProxyUseNovelAiSubtitle,
                        value: draft.proxyUseNovelAi,
                        onChanged: (value) =>
                            setState(() => draft.proxyUseNovelAi = value),
                      ),
                      AppSettingTile.switchTile(
                        title: l10n.settingsProxyUseAgentTitle,
                        subtitle: l10n.settingsProxyUseAgentSubtitle,
                        value: draft.proxyUseAgent,
                        onChanged: (value) =>
                            setState(() => draft.proxyUseAgent = value),
                      ),
                      AppSettingTile.switchTile(
                        title: l10n.settingsProxyUseGalleryTitle,
                        subtitle: l10n.settingsProxyUseGallerySubtitle,
                        value: draft.proxyUseGallery,
                        onChanged: (value) =>
                            setState(() => draft.proxyUseGallery = value),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _testProxy,
                  icon: const Icon(Icons.network_check, size: 16),
                  label: Text(
                    _testing
                        ? l10n.settingsProxyTestRunning
                        : l10n.settingsProxyTest,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
