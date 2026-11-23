import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../../../data/models/novelai_models.dart';
import '../../../../data/services/prompt_token_counter_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/context_l10n.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../../../../data/services/wd14_online_service.dart';
import '../../../../data/models/style_preset.dart';
import 'img2img_section.dart';
import 'precise_reference_section.dart';
import '../../../core/widgets/app_collapsible_section.dart';
import '../../../core/widgets/app_icon_button.dart';
import '../../../core/widgets/app_segmented_controls.dart';
import '../../../core/widgets/app_transitions.dart';
import '../view_models/studio_view_model.dart';
import 'fixed_affixes_panel.dart';
import 'prompt_editor_card.dart';
import 'prompt_extension_deck.dart';
import 'prompt_panel_shared.dart';
import 'rich_prompt_text_controller.dart';
import 'studio_shared.dart';

/// 侧边栏页面二：提示词管理
/// 支持官方双模式：垂直堆叠模式与标签页切换模式，共用同一套编辑卡。
class PromptsPage extends StatefulWidget {
  final StudioViewModel viewModel;

  const PromptsPage({super.key, required this.viewModel});

  @override
  State<PromptsPage> createState() => _PromptsPageState();
}

class _PromptsPageState extends State<PromptsPage> {
  late final RichPromptTextController _promptController;
  late final RichPromptTextController _negativeController;
  late final RichPromptTextController _prefixController;
  late final RichPromptTextController _suffixController;

  bool _isTabbedMode = false;
  int _activeTab = 0; // 0: Prompt, 1: Undesired Content

  @override
  void initState() {
    super.initState();
    final params = widget.viewModel.params;
    _isTabbedMode = widget.viewModel.promptTabbedMode;
    _activeTab = widget.viewModel.promptActiveTab;
    _promptController = RichPromptTextController(text: params.prompt);
    _prefixController = RichPromptTextController(
      text: params.prefixPrompt ?? '',
    );
    _suffixController = RichPromptTextController(
      text: params.suffixPrompt ?? '',
    );
    _negativeController = RichPromptTextController(text: params.negativePrompt);
  }

  @override
  void didUpdateWidget(covariant PromptsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFromViewModel();
  }

  void _syncFromViewModel() {
    final params = widget.viewModel.params;
    if (_isTabbedMode != widget.viewModel.promptTabbedMode) {
      _isTabbedMode = widget.viewModel.promptTabbedMode;
    }
    if (_activeTab != widget.viewModel.promptActiveTab) {
      _activeTab = widget.viewModel.promptActiveTab;
    }
    if (_promptController.text != params.prompt) {
      _promptController.text = params.prompt;
    }
    if (_prefixController.text != (params.prefixPrompt ?? '')) {
      _prefixController.text = params.prefixPrompt ?? '';
    }
    if (_suffixController.text != (params.suffixPrompt ?? '')) {
      _suffixController.text = params.suffixPrompt ?? '';
    }
    if (_negativeController.text != params.negativePrompt) {
      _negativeController.text = params.negativePrompt;
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    _negativeController.dispose();
    _prefixController.dispose();
    _suffixController.dispose();
    super.dispose();
  }

  void _updatePrompt(String value) {
    widget.viewModel.updateParams(
      widget.viewModel.params.copyWith(prompt: value),
    );
  }

  void _updateNegative(String value) {
    widget.viewModel.updateParams(
      widget.viewModel.params.copyWith(negativePrompt: value),
    );
  }

  // --- 只读灰色标签与工具条组装 (堆叠 / 标签页两种模式共用) ---

  /// 当前是否处于 ComfyUI 模式 (质量词/UC 预设与 Token 上限不生效)
  bool get viewModelIsComfyUi => widget.viewModel.isComfyUiMode;

  List<GrayTag> _promptHeaderTags(NaiGenerationParams params) {
    final hasPrefix =
        params.applyFixedPrompts &&
        (params.prefixPrompt?.trim().isNotEmpty ?? false);
    return [
      if (hasPrefix)
        GrayTag(context.l10n.promptsPrefixBadge, params.prefixPrompt!.trim()),
    ];
  }

  List<GrayTag> _promptFooterTags(NaiGenerationParams params) {
    final hasSuffix =
        params.applyFixedPrompts &&
        (params.suffixPrompt?.trim().isNotEmpty ?? false);
    final qualityTags = viewModelIsComfyUi
        ? ''
        : NovelAiQualityTagsHelper.getQualityTags(
            params.model,
            resolveQualityPreset(params),
          );
    return [
      if (hasSuffix)
        GrayTag(context.l10n.promptsSuffixBadge, params.suffixPrompt!.trim()),
      if (qualityTags.isNotEmpty)
        GrayTag(context.l10n.promptsQualityTags, qualityTags),
      // 透明背景为 NovelAI 专属标签，ComfyUI 模式不拼接也不展示
      if (params.transparentBg && !viewModelIsComfyUi)
        GrayTag(
          context.l10n.promptsTransparentBackground,
          'transparent background',
        ),
    ];
  }

  List<GrayTag> _negativeFooterTags(NaiGenerationParams params) {
    if (viewModelIsComfyUi || params.isMediumEffort) return const [];
    final ucPresetStr = NovelAiUndesiredContentHelper.getUndesiredContent(
      params.model,
      params.ucPresetKey,
    );
    return [
      if (ucPresetStr.isNotEmpty)
        GrayTag(
          '${context.l10n.promptsUcPreset}: ${promptPresetLabel(context, params.ucPresetKey)}',
          ucPresetStr,
        ),
    ];
  }

  Widget? _promptToolbar() => buildPositivePromptToolbar(
    context,
    widget.viewModel,
    _promptController,
  );

  Widget? _negativeToolbar() =>
      buildNegativePromptToolbar(context, widget.viewModel);

  // --- 布局 ---

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // 保活隐藏页暂停订阅；切回提示词页时自动读取最新参数。
      listenable: Listenable.merge([
        if (TickerMode.valuesOf(context).enabled) widget.viewModel,
      ]),
      builder: (context, _) {
        final l10n = context.l10n;
        final viewModel = widget.viewModel;
        _syncFromViewModel();

        // 同步设置项：标签分类着色开关 (设置弹窗保存后 viewModel 通知重建)
        final showCategoryColors = viewModel.config.showTagCategoryColors;
        for (final c in [
          _promptController,
          _negativeController,
          _prefixController,
          _suffixController,
        ]) {
          c.setHighlightOptions(categoryColors: showCategoryColors);
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: PageHeader(
                    title: l10n.promptsPageTitle,
                    subtitle: l10n.promptsPageSubtitle,
                  ),
                ),
                // 本地 fork：WD14 在线反推快捷入口
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text(context.l10n.wd14Title),
                      content: SizedBox(
                        width: 480,
                        child: _Wd14QuickCard(viewModel: viewModel),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: Text(dialogContext.l10n.commonClose),
                        ),
                      ],
                    ),
                  ),
                  icon: const Icon(Icons.sell_outlined, size: 16),
                  label: Text(context.l10n.wd14Title),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_isTabbedMode)
              _buildTabbedSection(l10n)
            else
              _buildStackedSection(l10n),

            // 提示词扩展甲板：多角色提示词 → 固定词缀左右滑动切换
            const SizedBox(height: 18),
            PromptExtensionDeck(
              viewModel: viewModel,
              prefixController: _prefixController,
              suffixController: _suffixController,
            ),

            const SizedBox(height: 18),
            AppCollapsibleSection(
              title: l10n.promptsImg2imgSection,
              initiallyExpanded: true,
              child: Img2imgSection(viewModel: viewModel),
            ),

            const SizedBox(height: 18),
            AppCollapsibleSection(
              title: l10n.promptsPreciseReference,
              initiallyExpanded: true,
              child: PreciseReferenceSection(viewModel: viewModel),
            ),

            const SizedBox(height: 18),
            // 本地 fork：画风串预设与输出选项 (元数据 / 水印开关)
            _StylePresetCard(viewModel: viewModel),
            const SizedBox(height: 18),
            _OutputOptionsCard(viewModel: viewModel),

            // 排除违禁词：作用于全部提示词的助手读取脱敏，独立置于页尾
            const SizedBox(height: 14),
            BannedWordsCard(viewModel: viewModel),
          ],
        );
      },
    );
  }

  /// 垂直堆叠模式：Prompt 卡与 Undesired Content 卡上下排列
  Widget _buildStackedSection(AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final params = viewModel.params;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: SectionHeader(l10n.promptsPositiveTitle)),
            if (params.prompt.trim().isNotEmpty)
              ClearTextLink(
                onTap: () {
                  _promptController.clear();
                  _updatePrompt('');
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        PromptEditorCard(
          controller: _promptController,
          onChanged: _updatePrompt,
          hintText: l10n.promptsCorePromptHint,
          minLines: 4,
          maxLines: 10,
          initialHeight: viewModel.promptHeightStacked,
          onHeightChanged: viewModel.updatePromptHeightStacked,
          headerTags: _promptHeaderTags(params),
          footerTags: _promptFooterTags(params),
          toolbar: _promptToolbar(),
          enableAutocomplete: viewModel.config.enableTagAutocomplete,
          showTranslation: viewModel.config.showTagTranslations,
          tokenUsage: viewModelIsComfyUi
              ? null
              : PromptTokenCounterService.instance.countPositive(params),
        ),
        _StyleTagsRow(tags: viewModel.activeStylePreset?.positive ?? ''),

        const SizedBox(height: 16),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: SectionHeader(l10n.promptsNegativeTitle)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!params.isMediumEffort &&
                    params.negativePrompt.trim().isNotEmpty)
                  ClearTextLink(
                    onTap: () {
                      _negativeController.clear();
                      _updateNegative('');
                    },
                  ),
                const SizedBox(width: 6),
                AppIconButton(
                  icon: Icons.splitscreen_rounded,
                  tooltip: l10n.promptsSwitchToTabbedMode,
                  size: 26,
                  iconSize: 15,
                  radius: 6,
                  onPressed: () {
                    setState(() {
                      _isTabbedMode = true;
                      _activeTab = 1;
                    });
                    viewModel.setPromptTabbedMode(true);
                    viewModel.setPromptActiveTab(1);
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        PromptEditorCard(
          controller: _negativeController,
          onChanged: _updateNegative,
          readOnly: params.isMediumEffort,
          hintText: params.isMediumEffort
              ? l10n.promptsMediumUcLocked
              : l10n.promptsCustomUndesiredHint,
          minLines: 3,
          maxLines: 8,
          initialHeight: viewModel.negativePromptHeightStacked,
          onHeightChanged: viewModel.updateNegativePromptHeightStacked,
          footerTags: _negativeFooterTags(params),
          toolbar: _negativeToolbar(),
          enableAutocomplete: viewModel.config.enableTagAutocomplete,
          showTranslation: viewModel.config.showTagTranslations,
          tokenUsage: viewModelIsComfyUi
              ? null
              : PromptTokenCounterService.instance.countNegative(params),
        ),
        _StyleTagsRow(tags: viewModel.activeStylePreset?.negative ?? ''),
      ],
    );
  }


  /// 标签页模式：Prompt 与 Undesired Content 胶囊切换，单卡高空间输入
  Widget _buildTabbedSection(AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final params = viewModel.params;
    final activeTab = _activeTab == 1 ? 1 : 0;
    final isPromptTab = activeTab == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: AppSegmentedCardBar<String>(
                scrollable: true,
                items: [
                  AppSegmentedItem(
                    value: 'prompt',
                    label: l10n.promptsPositiveTitle,
                  ),
                  AppSegmentedItem(
                    value: 'undesired',
                    label: l10n.promptsNegativeTitle,
                  ),
                ],
                selectedValue: isPromptTab ? 'prompt' : 'undesired',
                onValueChanged: (v) {
                  final tab = v == 'prompt' ? 0 : 1;
                  setState(() => _activeTab = tab);
                  viewModel.setPromptActiveTab(tab);
                },
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((isPromptTab && params.prompt.trim().isNotEmpty) ||
                    (!isPromptTab &&
                        !params.isMediumEffort &&
                        params.negativePrompt.trim().isNotEmpty))
                  ClearTextLink(
                    onTap: () {
                      if (isPromptTab) {
                        _promptController.clear();
                        _updatePrompt('');
                      } else {
                        _negativeController.clear();
                        _updateNegative('');
                      }
                    },
                  ),
                const SizedBox(width: 4),
                AppIconButton(
                  icon: Icons.view_agenda_outlined,
                  tooltip: l10n.promptsSwitchToStackedMode,
                  size: 26,
                  iconSize: 15,
                  radius: 6,
                  onPressed: () {
                    setState(() => _isTabbedMode = false);
                    viewModel.setPromptTabbedMode(false);
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),

        AppPageSideBySide(
          index: activeTab,
          enableBlur: false,
          child: isPromptTab
              ? PromptEditorCard(
                  controller: _promptController,
                  onChanged: _updatePrompt,
                  hintText: l10n.promptsTabbedPromptHint,
                  minLines: 8,
                  maxLines: 16,
                  initialHeight: viewModel.promptHeightTabbed,
                  onHeightChanged: viewModel.updatePromptHeightTabbed,
                  headerTags: _promptHeaderTags(params),
                  footerTags: _promptFooterTags(params),
                  toolbar: _promptToolbar(),
                  enableAutocomplete: viewModel.config.enableTagAutocomplete,
                  showTranslation: viewModel.config.showTagTranslations,
                  tokenUsage: viewModelIsComfyUi
                      ? null
                      : PromptTokenCounterService.instance.countPositive(
                          params,
                        ),
                )
              : PromptEditorCard(
                  controller: _negativeController,
                  onChanged: _updateNegative,
                  readOnly: params.isMediumEffort,
                  hintText: params.isMediumEffort
                      ? l10n.promptsMediumUcLocked
                      : l10n.promptsTabbedUndesiredHint,
                  minLines: 8,
                  maxLines: 16,
                  initialHeight: viewModel.negativePromptHeightTabbed,
                  onHeightChanged: viewModel.updateNegativePromptHeightTabbed,
                  footerTags: _negativeFooterTags(params),
                  toolbar: _negativeToolbar(),
                  enableAutocomplete: viewModel.config.enableTagAutocomplete,
                  showTranslation: viewModel.config.showTagTranslations,
                  tokenUsage: viewModelIsComfyUi
                      ? null
                      : PromptTokenCounterService.instance.countNegative(
                          params,
                        ),
                ),
        ),
      ],
    );
  }
}

/// 输出选项：元数据保留开关 + 私有 stripTags。
class _OutputOptionsCard extends StatefulWidget {
  const _OutputOptionsCard({required this.viewModel});

  final StudioViewModel viewModel;

  @override
  State<_OutputOptionsCard> createState() => _OutputOptionsCardState();
}

class _OutputOptionsCardState extends State<_OutputOptionsCard> {
  late final TextEditingController _stripController;
  late final TextEditingController _negativeStripController;
  late final TextEditingController _bannedWordsController;
  late final FocusNode _stripFocusNode;
  late final FocusNode _negativeStripFocusNode;

  @override
  void initState() {
    super.initState();
    _stripController = TextEditingController(
      text: widget.viewModel.params.stripTags,
    );
    _negativeStripController = TextEditingController(
      text: widget.viewModel.params.stripNegativeTags,
    );
    _bannedWordsController = TextEditingController(
      text: widget.viewModel.params.bannedWords,
    );
    // 失焦视为一次输入提交：把当前内容并入历史缓存 (去重 + 最新在前)。
    _stripFocusNode = FocusNode()..addListener(_onStripFocusChanged);
    _negativeStripFocusNode = FocusNode()
      ..addListener(_onNegativeStripFocusChanged);
  }

  void _onStripFocusChanged() {
    if (!_stripFocusNode.hasFocus) _commitStripHistory();
  }

  void _onNegativeStripFocusChanged() {
    if (!_negativeStripFocusNode.hasFocus) _commitNegativeStripHistory();
  }

  void _applyHistoryValue(TextEditingController controller, String value) {
    controller.text = value;
    controller.selection = TextSelection.collapsed(offset: value.length);
  }

  Future<List<String>> _commitStripHistory() async {
    final value = _stripController.text.trim();
    if (value.isEmpty) return widget.viewModel.loadStripTagHistory();
    return widget.viewModel.recordStripTagHistory(value);
  }

  Future<void> _applyStripHistory(String value) async {
    _applyHistoryValue(_stripController, value);
    widget.viewModel.updateParams(
      widget.viewModel.params.copyWith(stripTags: value),
    );
  }

  Future<void> _clearStripHistory() async {
    await widget.viewModel.clearStripTagHistory();
  }

  Future<List<String>> _commitNegativeStripHistory() async {
    final value = _negativeStripController.text.trim();
    if (value.isEmpty) {
      return widget.viewModel.loadStripTagHistory(negative: true);
    }
    return widget.viewModel.recordStripTagHistory(value, negative: true);
  }

  Future<void> _applyNegativeStripHistory(String value) async {
    _applyHistoryValue(_negativeStripController, value);
    widget.viewModel.updateParams(
      widget.viewModel.params.copyWith(stripNegativeTags: value),
    );
  }

  Future<void> _clearNegativeStripHistory() async {
    await widget.viewModel.clearStripTagHistory(negative: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final viewModel = widget.viewModel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.promptOutputTitle),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.promptStripAllTitle,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Checkbox(
              value: viewModel.effectiveStripAll,
              onChanged: (value) => viewModel.setStripAll(value ?? false),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: SectionHeader(l10n.promptStripTags)),
            _StripTagHistoryButton(
              key: const Key('strip_tags_history_button'),
              onCommit: _commitStripHistory,
              onSelected: _applyStripHistory,
              onClear: _clearStripHistory,
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('strip_tags_field'),
          controller: _stripController,
          focusNode: _stripFocusNode,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'silver hair, blue eyes, 1girl',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          // 桌面端鼠标点击框外默认不失焦；显式失焦以便提交历史。
          onTapOutside: (_) => _stripFocusNode.unfocus(),
          onChanged: (value) => viewModel.updateParams(
            viewModel.params.copyWith(stripTags: value),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: SectionHeader(l10n.promptStripNegativeTags)),
            _StripTagHistoryButton(
              key: const Key('strip_negative_tags_history_button'),
              onCommit: _commitNegativeStripHistory,
              onSelected: _applyNegativeStripHistory,
              onClear: _clearNegativeStripHistory,
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('strip_negative_tags_field'),
          controller: _negativeStripController,
          focusNode: _negativeStripFocusNode,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'lowres, bad anatomy',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          // 桌面端鼠标点击框外默认不失焦；显式失焦以便提交历史。
          onTapOutside: (_) => _negativeStripFocusNode.unfocus(),
          onChanged: (value) => viewModel.updateParams(
            viewModel.params.copyWith(stripNegativeTags: value),
          ),
        ),

        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.bannedWordsTitle,
                      style: const TextStyle(fontSize: 12)),
                  Text(l10n.bannedWordsSubtitle,
                      style: const TextStyle(fontSize: 10)),
                ],
              ),
            ),
            Switch(
              value: viewModel.params.stripBannedWords,
              onChanged: (value) => viewModel.updateParams(
                viewModel.params.copyWith(stripBannedWords: value),
              ),
            ),
          ],
        ),
        TextField(
          controller: _bannedWordsController,
          minLines: 2,
          maxLines: 5,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            hintText: l10n.bannedWordsHint,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (value) => viewModel.updateParams(
            viewModel.params.copyWith(bannedWords: value),
          ),
        ),


      ],
    );
  }
}

/// 擦除 tag 输入框旁的历史入口：下拉展示最近记录，点选填入当前输入。
///
/// 打开前先提交当前输入，保证刚输入的内容无需失焦也能出现在下拉里；
/// 文案复用通用 `history` / `clear` / `canvasHistoryEmpty`，不新增 ARB。
class _StripTagHistoryButton extends StatefulWidget {
  const _StripTagHistoryButton({
    super.key,
    required this.onCommit,
    required this.onSelected,
    required this.onClear,
  });

  /// 打开下拉前提交当前输入，返回提交后的最新历史。
  final Future<List<String>> Function() onCommit;

  final Future<void> Function(String value) onSelected;

  final Future<void> Function() onClear;

  @override
  State<_StripTagHistoryButton> createState() => _StripTagHistoryButtonState();
}

class _StripTagHistoryButtonState extends State<_StripTagHistoryButton> {
  static const String _clearValue = '__clear_strip_tag_history__';

  Future<void> _showHistoryMenu() async {
    final entries = await widget.onCommit();
    if (!mounted) return;
    final anchor = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (anchor == null || overlay == null) return;
    final l10n = context.l10n;
    final items = entries.isEmpty
        ? <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              enabled: false,
              child: Text(
                l10n.canvasHistoryEmpty,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ]
        : <PopupMenuEntry<String>>[
            for (final entry in entries)
              PopupMenuItem<String>(
                value: entry,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(
                    entry,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: _clearValue,
              child: Text(l10n.clear, style: const TextStyle(fontSize: 12)),
            ),
          ];
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          anchor.localToGlobal(Offset.zero, ancestor: overlay),
          anchor.localToGlobal(
            anchor.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (selected == null) return;
    if (selected == _clearValue) {
      await widget.onClear();
    } else {
      await widget.onSelected(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppIconButton(
      icon: Icons.history,
      tooltip: context.l10n.history,
      size: 22,
      iconSize: 14,
      radius: 6,
      variant: AppIconButtonVariant.ghost,
      onPressed: _showHistoryMenu,
    );
  }
}

/// 提示词页顶部的在线 WD14 快捷卡：反推当前图片并一键写入提示词。
class _Wd14QuickCard extends StatefulWidget {
  const _Wd14QuickCard({required this.viewModel});

  final StudioViewModel viewModel;

  @override
  State<_Wd14QuickCard> createState() => _Wd14QuickCardState();
}

class _Wd14QuickCardState extends State<_Wd14QuickCard> {
  bool _busy = false;
  List<Wd14Tag> _tags = const <Wd14Tag>[];
  late final TextEditingController _endpointController;
  late final TextEditingController _tokenController;
  double _threshold = 0.35;

  @override
  void initState() {
    super.initState();
    _endpointController =
        TextEditingController(text: widget.viewModel.wd14Endpoint);
    _tokenController = TextEditingController(text: widget.viewModel.wd14Token);
    _threshold = widget.viewModel.wd14Threshold;
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _pickAndTag() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.first.bytes;
    if (bytes == null) return;
    setState(() => _busy = true);
    try {
      final tags = await widget.viewModel.tagImageBytesWithWd14(bytes);
      if (mounted) setState(() => _tags = tags);
    } on Wd14Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      final tags = await widget.viewModel.tagCurrentCanvasWithWd14();
      if (mounted) setState(() => _tags = tags);
    } on Wd14Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.wd14Title),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _run,
                icon: _busy
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sell_outlined, size: 16),
                label: Text(_busy ? l10n.wd14Running : l10n.wd14Run),
              ),
            ),
            const SizedBox(width: 8),
            if (_tags.isNotEmpty)
              TextButton.icon(
                onPressed: () async {
                  await widget.viewModel.applyWd14Tags(_tags);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.wd14Applied)),
                    );
                  }
                },
                icon: const Icon(Icons.playlist_add, size: 16),
                label: Text(l10n.wd14Apply),
              ),
          ],
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: _busy ? null : _pickAndTag,
          icon: const Icon(Icons.image_outlined, size: 16),
          label: Text(l10n.wd14Pick),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 6),
          title: Text(l10n.wd14Settings, style: const TextStyle(fontSize: 12)),
          children: [
            TextField(
              controller: _endpointController,
              style: const TextStyle(fontSize: 11),
              decoration: InputDecoration(
                isDense: true,
                labelText: l10n.wd14Endpoint,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => widget.viewModel.setWd14Endpoint(value),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _tokenController,
              obscureText: true,
              style: const TextStyle(fontSize: 11),
              decoration: InputDecoration(
                isDense: true,
                labelText: l10n.wd14Token,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => widget.viewModel.setWd14Token(value),
            ),
            Row(
              children: [
                Text(l10n.wd14Threshold(_threshold.toStringAsFixed(2)),
                    style: const TextStyle(fontSize: 11)),
                Expanded(
                  child: Slider(
                    value: _threshold,
                    min: 0.05,
                    max: 0.95,
                    divisions: 18,
                    onChanged: (value) => setState(() => _threshold = value),
                    onChangeEnd: (value) =>
                        widget.viewModel.setWd14Threshold(value),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (_tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final tag in _tags)
                Chip(
                  label: Text(
                    '${tag.name} ${(tag.score * 100).round()}%',
                    style: const TextStyle(fontSize: 10),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 画风串固定选项：一组正/负 tag，按组选择，可配置出图后去除元数据/隐写。
class _StylePresetCard extends StatelessWidget {
  const _StylePresetCard({required this.viewModel});

  final StudioViewModel viewModel;

  Future<void> _edit(BuildContext context, {StylePreset? preset}) async {
    final nameController = TextEditingController(text: preset?.name ?? '');
    final positiveController =
        TextEditingController(text: preset?.positive ?? '');
    final negativeController =
        TextEditingController(text: preset?.negative ?? '');
    var styleInMetadata = preset?.styleInMetadata ?? true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocalState) => AlertDialog(
          title: Text(preset == null
              ? dialogContext.l10n.styleAddTitle
              : dialogContext.l10n.styleEditTitle),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(labelText: dialogContext.l10n.styleName),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: positiveController,
                    minLines: 2,
                    maxLines: 5,
                    decoration:
                        InputDecoration(labelText: dialogContext.l10n.stylePositive),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: negativeController,
                    minLines: 2,
                    maxLines: 5,
                    decoration:
                        InputDecoration(labelText: dialogContext.l10n.styleNegative),
                  ),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: styleInMetadata,
                    onChanged: (value) =>
                        setLocalState(() => styleInMetadata = value ?? true),
                    title: Text(dialogContext.l10n.styleInMetadata),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogContext.l10n.commonSave),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final name = nameController.text;
    final positive = positiveController.text;
    final negative = negativeController.text;
    if (preset == null) {
      await viewModel.addStylePreset(
        name: name,
        positive: positive,
        negative: negative,
        styleInMetadata: styleInMetadata,
      );
    } else {
      await viewModel.updateStylePreset(
        preset.copyWith(
          name: name,
          positive: positive,
          negative: negative,
          styleInMetadata: styleInMetadata,
        ),
      );
    }
    nameController.dispose();
    positiveController.dispose();
    negativeController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final presets = viewModel.stylePresets;
    final selected = viewModel.activeStylePreset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.styleCardTitle),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue:
              viewModel.activeStylePresetId.isEmpty ? null : viewModel.activeStylePresetId,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            hintText: l10n.styleSelectHint,
          ),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(l10n.styleNone,
                  style: const TextStyle(fontSize: 12)),
            ),
            for (final preset in presets)
              DropdownMenuItem(
                value: preset.id,
                child: Text(preset.name, style: const TextStyle(fontSize: 12)),
              ),
          ],
          onChanged: (id) {
            if (id == null) return;
            if (id.isEmpty) {
              viewModel.clearStylePreset();
            } else {
              viewModel.selectStylePreset(id);
            }
          },
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => _edit(context),
              icon: const Icon(Icons.add, size: 14),
              label: Text(l10n.commonAdd),
            ),
            TextButton.icon(
              onPressed: selected == null ? null : () => _edit(context, preset: selected),
              icon: const Icon(Icons.edit_outlined, size: 14),
              label: Text(l10n.commonEdit),
            ),
            TextButton.icon(
              onPressed: selected == null
                  ? null
                  : () => viewModel.removeStylePreset(selected.id),
              icon: const Icon(Icons.delete_outline, size: 14),
              label: Text(l10n.commonDelete),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.styleStripAll,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Checkbox(
              value: selected != null &&
                  (selected.stripMetadata || selected.stripStealth),
              onChanged: selected == null
                  ? null
                  : (value) => viewModel.updateStylePreset(
                        selected.copyWith(
                          stripMetadata: value ?? false,
                          stripStealth: value ?? false,
                        ),
                      ),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ],
    );
  }
}

/// 提示词框下方的画风串只读标签，默认折叠为一行，可展开/收起。
class _StyleTagsRow extends StatefulWidget {
  const _StyleTagsRow({required this.tags});

  final String tags;

  @override
  State<_StyleTagsRow> createState() => _StyleTagsRowState();
}

class _StyleTagsRowState extends State<_StyleTagsRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final trimmed = widget.tags.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colors.mutedBackground,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              context.l10n.styleTagLabel,
              style: TextStyle(fontSize: 10, color: colors.textSecondary),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              trimmed,
              maxLines: _expanded ? null : 1,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.textSecondary),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
