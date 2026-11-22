import 'package:flutter/material.dart';

import '../../../core/context_l10n.dart';
import '../../../core/widgets/app_confirm_dialog.dart';
import '../view_models/studio_view_model.dart';

/// 订阅账号池管理：添加 / 切换 / 删除 / 刷新多个 NovelAI 账号。
class AccountPoolDialog extends StatefulWidget {
  const AccountPoolDialog({super.key, required this.viewModel});

  final StudioViewModel viewModel;

  static Future<void> show(BuildContext context, StudioViewModel viewModel) {
    return showDialog<void>(
      context: context,
      builder: (_) => AccountPoolDialog(viewModel: viewModel),
    );
  }

  @override
  State<AccountPoolDialog> createState() => _AccountPoolDialogState();
}

class _AccountPoolDialogState extends State<AccountPoolDialog> {
  final _labelController = TextEditingController();
  final _keyController = TextEditingController();
  bool _refreshing = false;
  bool _adding = false;

  @override
  void dispose() {
    _labelController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_adding) return;
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    setState(() => _adding = true);
    try {
      await widget.viewModel.addAccount(
        label: _labelController.text,
        apiKey: key,
      );
      _labelController.clear();
      _keyController.clear();
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _refreshAll() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.viewModel.refreshAccounts();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final l10n = context.l10n;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.accountPoolTitle,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              Text(
                l10n.accountPoolSubtitle,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'fixed',
                    label: Text(l10n.accountPoolFixed),
                  ),
                  ButtonSegment(
                    value: 'rotate',
                    label: Text(l10n.accountPoolRotate),
                  ),
                ],
                selected: <String>{viewModel.accountMode},
                onSelectionChanged: (selection) async {
                  await viewModel.setAccountMode(selection.first);
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 8),
              Flexible(
                child: viewModel.accounts.isEmpty
                    ? Center(
                        child: Text(
                          l10n.accountPoolEmpty,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: viewModel.accounts.length,
                        itemBuilder: (context, index) {
                          final account = viewModel.accounts[index];
                          final active =
                              account.id == viewModel.activeAccountId;
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              active
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              size: 18,
                              color: active
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey,
                            ),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    account.label,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                if (account.id ==
                                    viewModel.defaultAccountId) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    l10n.accountPoolDefault,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.orange,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              l10n.accountPoolSummary(
                                account.tierName.isEmpty
                                    ? l10n.accountPoolTierUnknown
                                    : account.tierName,
                                account.anlas,
                                account.v5Energy,
                              ),
                              style: const TextStyle(fontSize: 10),
                            ),
                            onTap: () async {
                              await viewModel.selectAccount(account.id);
                              if (mounted) setState(() {});
                            },
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: l10n.accountPoolSetDefault,
                                  onPressed: () async {
                                    await viewModel.setDefaultAccount(
                                      account.id,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                  icon: Icon(
                                    account.id == viewModel.defaultAccountId
                                        ? Icons.star
                                        : Icons.star_border,
                                    size: 16,
                                    color: Colors.orange,
                                  ),
                                ),
                                IconButton(
                                  tooltip: l10n.delete,
                                  onPressed: () async {
                                    final confirmed =
                                        await showAppConfirmDialog(
                                          context,
                                          title: l10n.accountPoolDeleteTitle,
                                          message: l10n
                                              .accountPoolDeleteMessage(
                                                account.label,
                                              ),
                                          confirmLabel: l10n.delete,
                                          isDestructive: true,
                                        );
                                    if (confirmed != true) return;
                                    await viewModel.removeAccount(account.id);
                                    if (mounted) setState(() {});
                                  },
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 16,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const Divider(height: 20),
              Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _labelController,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: l10n.accountPoolRemark,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _keyController,
                      obscureText: true,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: l10n.accountPoolApiKey,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _adding ? null : _add,
                    child: Text(l10n.accountPoolAdd),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: _refreshing ? null : _refreshAll,
                    icon: _refreshing
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.accountPoolRefreshAll),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.close),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
