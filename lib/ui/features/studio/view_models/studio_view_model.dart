import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color, Locale, Offset, Rect;
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../../core/harness/agent_harness.dart';
import '../../../../core/harness/context_memory.dart';
import '../../../../core/harness/mcp/mcp_manager.dart';
import '../../../../core/harness/mcp/mcp_models.dart';
import '../../../../core/harness/tools/context_memory_tool.dart';
import '../../../../core/harness/tools/reflection_tools.dart';
import '../../../../core/harness/tools/wd14_tag_tool.dart';
import '../../../../core/harness/tools/character_tag_tool.dart';
import '../../../../core/harness/tools/grep_tool.dart';
import '../../../../core/harness/tools/memory_tool.dart';
import '../../../../core/harness/presets/agent_preset.dart';
import '../../../../core/harness/providers/llm_provider_factory.dart';
import '../../../../core/harness/providers/openai_provider.dart';
import '../../../../core/harness/skills/skills.dart';
import '../../../../core/harness/tools/agent_tool.dart';
// AiEditImageTool 在 part 分部 studio_vm_harness.dart 中注册使用
import '../../../../core/harness/tools/ai_edit_image_tool.dart';
import 'chat_checkpoints.dart';
import '../../../core/locale/app_locale_controller.dart';
import '../../../core/theme/app_accent_controller.dart';
import '../../../core/theme/frame_rate_controller.dart';
import '../../../core/theme/theme_mode_controller.dart';
import '../../../core/theme/ui_zoom_controller.dart';
import '../../../../core/harness/tools/annotation_tools.dart';
import '../../../../core/harness/tools/anysearch_tools.dart';
import '../../../../core/harness/tools/ask_user_tool.dart';
import '../../../../core/harness/tools/library_tools.dart';
import '../../../../core/harness/tools/canvas_view_tool.dart';
import '../../../../core/harness/tools/character_prompt_tools.dart';
import '../../../../core/harness/tools/danbooru_search_tools.dart';
import '../../../../core/harness/tools/describe_tools_tool.dart';
import '../../../../core/harness/tools/load_skill_tool.dart';
import '../../../../core/harness/tools/novelai_inpaint_tool.dart';
import '../../../../core/harness/tools/novelai_tools.dart';
import '../../../../core/harness/tools/pipeline_tool.dart';
import '../../../../core/harness/tools/prompt_library_tools.dart';
import '../../../../core/harness/tools/studio_params_tool.dart';
import '../../../../core/harness/tools/tool_path_guard.dart';
import '../../../../core/harness/types.dart';
import '../../../../data/models/novelai_models.dart';
import '../../../../data/models/reflection_entry.dart';
import '../../../../data/models/nai_account_pool.dart';
import '../../../../data/models/comfyui_models.dart';
import '../../../../data/models/prompt_library_models.dart';
import '../../../../data/models/prompt_library_sync_models.dart';
import '../../../../data/models/skill_package.dart';
import '../../../../data/repositories/novelai_repository.dart';
import '../../../../data/services/anlas_calculator.dart';
import '../../../../data/services/annotation_overlay_renderer.dart';
import '../../../../data/services/config_service.dart';
import '../../../../data/services/network_proxy_service.dart';
import '../../../../data/services/novelai_service.dart';
import '../../../../data/services/image_edit_service.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/account_store.dart';
import '../../../../data/services/chat_queue_store.dart';
import '../../../../data/services/image_privacy_settings.dart';
import '../../../../data/models/style_preset.dart';
import '../../../../data/services/wd14_online_service.dart';
import '../../../../data/services/reflection_store.dart';
import '../../../../data/services/comfyui_service.dart';
import '../../../../data/services/image_file_store.dart';
import '../../../../data/services/image_metadata_service.dart';
import '../../../../data/services/image_save_path_service.dart';
import '../../../../data/services/media_store_service.dart';
import '../../../../data/services/notification_history_service.dart';
import '../../../../data/services/palette_service.dart';
import '../../../../data/services/rtx_upscale_service.dart';
import '../../../../data/services/prompt_token_counter_service.dart';
import '../../../../data/services/inpaint_service.dart';
import '../../../../data/services/watermark_service.dart';
import '../../../../data/services/prompt_library_mention.dart';
import '../../../../data/services/prompt_library_service.dart';
import '../../../../data/services/prompt_library_sync_service.dart';
import '../../../../data/services/session_log_service.dart';
import '../../../../data/services/skill_package_service.dart';
import '../../../../data/services/tag_dictionary_service.dart';
import '../../../../data/services/tag_dictionary_update_service.dart';
import '../../../../data/services/usage_ledger_service.dart';
import '../../../../l10n/app_localizations.dart'
    show AppLocalizations, lookupAppLocalizations;
import '../../../core/widgets/app_toast.dart';
import 'param_snapshot_journal.dart';
import 'board/board_controller.dart';
import 'slash_command_dispatcher.dart';
import 'streaming_controllers.dart';

part 'studio_vm_characters.dart';
part 'studio_vm_chat.dart';
part 'studio_vm_comfyui.dart';
part 'studio_vm_generation.dart';
part 'studio_vm_harness.dart';
part 'studio_vm_inpaint.dart';
part 'studio_vm_layout.dart';
part 'studio_vm_library.dart';
part 'studio_vm_sessions.dart';
part 'studio_vm_slash.dart';

enum StudioSidebarTab { parameters, prompts, inpaint, library, sources }

/// 核心状态 Mixin：集中声明全部状态字段、Getters 与跨分部共享的读写入口。
///
/// StudioViewModel 的实现按职责拆分为同库 part 文件中的多个 Mixin
/// (对外公开 API 与调用点完全不变)：
/// - studio_vm_layout.dart     页面布局持久化状态 (分割线/侧栏/页签)
/// - studio_vm_harness.dart    Agent Harness 装配 / LLM 与思考强度切换 / 预设技能工具 CRUD
/// - studio_vm_generation.dart 生图 / 超分 / 实时预览 / 账号信息
/// - studio_vm_chat.dart       对话流 / ask_user 提问 / 付费确认 / Token 用量记录
/// - studio_vm_sessions.dart   会话列表 / 切换 / 新建 / 删除 / 回溯
/// - studio_vm_characters.dart 多角色提示词编辑与画板定位
/// - studio_vm_slash.dart      斜杠指令分发
///
/// 各分部之间互相调用的方法，在本 Mixin 中只声明签名 (抽象成员)，
/// 由对应分部 Mixin 提供实现；构造注入字段声明为 late final，
/// 在 StudioViewModel 构造体内赋值。
mixin _StudioCore on ChangeNotifier {
  late final ConfigService _configService;
  late final NovelAiRepository _repository;
  late final bool _ownsRepository;
  PromptLibraryService _promptLibraryService = PromptLibraryService.instance;
  late final PromptLibrarySyncService _promptLibrarySyncService;
  late final SkillPackageService _skillPackageService;
  late final McpManager _mcpManager;
  final ValueNotifier<int> mcpStateNotifier = ValueNotifier<int>(0);
  Future<void> _skillWriteQueue = Future<void>.value();
  final SessionLogService _sessionLog = SessionLogService();
  final UsageLedgerService _usageLedger = UsageLedgerService();
  final NotificationHistoryService _notificationLog =
      NotificationHistoryService();
  final AppBannerController bannerController = AppBannerController();
  late final ToolRegistry _toolRegistry;
  late final AgentHarness _harness;
  final http.Client _llmHttpClient = http.Client();

  /// 本地词组合库条目列表
  List<PromptComboEntry> _promptLibraryEntries = const [];

  /// 词库云同步状态
  bool _isSyncingPromptLibrary = false;
  String? _promptSyncStage;
  DateTime? _lastPromptSyncAt;
  PromptLibrarySyncResult? _lastPromptSyncResult;

  /// 词库条目列表独立通知器：避免工作台打字、对话流或生图进度触发词库全量重建
  final ValueNotifier<int> promptLibraryNotifier = ValueNotifier<int>(0);

  /// 本会话内各模型 (provider/model) 的累计 Token 用量 (悬停模型选择器时展示)
  Map<String, TokenUsage> _sessionModelUsage = {};

  /// 工作台参数时间轴快照账本 (回溯历史时刻时一并回滚生图参数)
  final ParamSnapshotJournal _paramJournal = ParamSnapshotJournal();

  /// 已保存的会话列表
  List<SessionInfo> _sessions = [];

  /// 当前正在进行的对话流订阅 (支持 ESC 强行终止)
  StreamSubscription<HarnessEvent>? _chatSubscription;

  AppConfig _config = const AppConfig();
  NaiGenerationParams _params = const NaiGenerationParams(prompt: '');

  /// VM 侧本地化取词入口 (阶段 4C 数据层文案解耦)：
  /// ViewModel 状态/错误/确认消息不再硬编码中文，统一经 vmL10n 生成；
  /// 初始化与保存配置时同步 localePreference。
  /// 后端原始错误、Agent prompt、用户输入仍原样透传不翻译。
  Locale _vmLocale = const Locale('zh');
  AppLocalizations get vmL10n => lookupAppLocalizations(_vmLocale);

  NaiAccountInfo? _accountInfo;
  bool _isLoadingAccount = false;
  bool _isGenerating = false;

  /// 当前生图是否已转入后台：请求与流式进度继续，但画布/历史侧栏隐藏占位卡，
  /// 由生成坞/画布空态/历史侧栏的「查看生成」恢复到前台。
  /// 仅在 [_isGenerating] 为 true 时生效，abort/完成/失败时复位。
  bool _generationBackgrounded = false;

  /// 从进入 generateImage/upscale 到真正设置 _isGenerating 之间的同步占位，
  /// 防止双击、/nai 或 Agent 在上一个 await 窗口内重复发起付费请求。
  bool _isStartingGeneration = false;

  /// 批量生图设置与进度（1 = 单张）。
  int _batchCount = 1;
  int _batchTotal = 0;
  int _batchCurrent = 0;
  bool _batchAborted = false;

  /// 当前流式生图的完成信号；abort 时主动 complete，避免 await 永久挂起。
  Completer<void>? _generationCompleter;
  bool _isRtxUpscaling = false;
  bool _rtxDisposed = false;
  Future<void>? _rtxOperation;
  bool get supportsRtxUpscale => _repository.supportsRtxUpscale;
  bool _isChatStreaming = false;

  /// 宿主已 dispose。后台刷新会话列表时不得再 notifyListeners。
  bool _disposed = false;

  /// 流式对话瞬态文本控制器：思考链/正文/重试提示增量只驱动对话气泡局部刷新
  final StreamingTextController _streamingText = StreamingTextController();

  /// 生图/修复实时进度控制器：去噪预览帧与步数只驱动占位卡/缩略图/按钮局部刷新
  final LiveProgressController _liveProgressController =
      LiveProgressController();

  /// 思考块全局展开开关 (Ctrl+O 切换，默认折叠只显示单行预览)
  bool _isThinkingExpanded = false;
  NaiGeneratedImage? _selectedImage;
  final Set<String> _favoriteImageIds = <String>{};
  final LibraryService _libraryService = LibraryService();
  String _libraryDir = '';
  List<LibraryFile> _libraryFiles = const <LibraryFile>[];
  bool _libraryLoading = false;
  String? _libraryError;
  final Set<String> _favoriteSourceIds = <String>{};
  bool _stripStealth = false;
  String _libraryFallbackDir = '';
  final Wd14OnlineService _wd14Service = Wd14OnlineService();
  String _wd14Endpoint = Wd14OnlineService.defaultEndpoint;
  String _wd14Token = '';
  double _wd14Threshold = 0.35;
  List<Wd14Tag> _lastWd14Tags = const <Wd14Tag>[];
  final List<QueuedChatMessage> _chatQueue = <QueuedChatMessage>[];
  bool _chatQueuePaused = false;
  bool _suppressQueueDrain = false;
  final List<StylePreset> _stylePresets = <StylePreset>[];
  String _activeStylePresetId = '';
  List<NaiAccount> _accounts = const <NaiAccount>[];
  String _activeAccountId = '';
  String _accountMode = 'fixed';
  String _defaultAccountId = '';
  final List<String> _memoryEntries = <String>[];
  final Map<String, Set<String>> _memoryEntrySessions = <String, Set<String>>{};
  final List<ReflectionEntry> _reflections = <ReflectionEntry>[];
  final List<ChatBranch> _chatBranches = <ChatBranch>[];
  bool _hasUnseenLatest = false;

  /// 自适应取色：最近一次已提取主色的图片 id (去重，避免重复 Isolate 提取)
  String? _lastAccentImageId;
  String? _statusMessage;
  String? _errorMessage;

  // --- 局部修复状态 ---
  InpaintParams _inpaintParams = const InpaintParams();
  bool _isExecutingInpaint = false;
  bool _isExecutingAiEdit = false;
  NaiGeneratedImage? _inpaintSourceImage;
  InpaintTool _inpaintTool = InpaintTool.rect;
  bool _previewDisposed = false;
  final ValueNotifier<Uint8List?> inpaintPreviewNotifier = ValueNotifier(null);
  Uint8List? get _inpaintPreviewBytes => inpaintPreviewNotifier.value;
  set _inpaintPreviewBytes(Uint8List? bytes) {
    if (!_previewDisposed) inpaintPreviewNotifier.value = bytes;
  }

  // --- 页面布局持久化状态 ---
  double _splitLeftWidth = 320.0;
  double _splitRightWidth = 400.0;
  StudioSidebarTab _activeSidebarTab = StudioSidebarTab.parameters;
  StudioSidebarTab _tabBeforeInpaint = StudioSidebarTab.parameters;
  bool _promptTabbedMode = false;
  int _promptActiveTab = 0;
  int _deckActiveTab = 0;
  bool _canvasHistoryOpen = false;
  bool _leftSidebarCollapsed = false;

  // 提示词输入框高度
  double _promptHeightStacked = 116.0;
  double _negativePromptHeightStacked = 92.0;
  double _promptHeightTabbed = 212.0;
  double _negativePromptHeightTabbed = 212.0;
  double _prefixPromptHeight = 88.0;
  double _suffixPromptHeight = 64.0;
  double _characterPromptHeight = 72.0;
  double _characterNegativePromptHeight = 56.0;

  /// 提示词输入框高度防抖保存计时器
  Timer? _promptHeightsSaveTimer;

  /// Agent 对话草稿输入文本
  String _chatDraft = '';

  /// Agent 对话草稿输入防抖保存计时器
  Timer? _chatDraftSaveTimer;

  /// 回溯后待放回输入框的草稿。输入栏消费后清空，避免会话切换后重复套用。
  ComposerRestore? _composerRestore;

  int _composerRestoreEpoch = 0;

  /// 词库角色快捷插入到输入框的一次文本插入事件。
  ComposerInsertion? _composerInsertion;

  int _composerInsertionEpoch = 0;

  /// 分割线宽度防抖落盘计时器 (拖动过程每帧回调，写盘必须节流)
  Timer? _splitWidthSaveTimer;

  /// UI 缩放防抖落盘计时器 (快捷键连续步进节流)
  Timer? _uiZoomSaveTimer;

  /// 实时生图预览状态 (全部委托 LiveProgressController 局部刷新)
  StreamSubscription<NaiStreamProgress>? _generationSubscription;

  ThinkingEffort _currentThinkingEffort = ThinkingEffort.high;

  AgentQuestionPrompt? _activeQuestionPrompt;

  /// 是否正在画板上交互式编辑角色位置
  bool _isEditingCharacterPositions = false;

  /// 是否正在画板上交互式编辑水印位置
  bool _isEditingWatermarkPosition = false;

  /// 当前选中的角色 ID (用于高亮锚点及左侧卡片)
  String? _selectedCharacterId;

  /// 自由大画布领域控制器 (阶段 4D 试点)：annotations 域整域迁出，
  /// 经 BoardControllerHost 最小接口回调宿主 (决策门 §7 契约)
  late final BoardController board;

  /// 参数持久化防抖计时器
  Timer? _paramSaveDebounceTimer;

  /// 全局配置防抖保存计时器
  Timer? _configSaveDebounceTimer;

  /// 参数保存按调用顺序串行，旧快照不可晚到覆盖新值。
  Future<void> _lastParameterSave = Future<void>.value();
  Future<void> _lastConfigSave = Future<void>.value();
  bool _hasRestoredParameterState = false;

  /// 测试注入用：会话日志根目录 (默认走系统 Documents/NovelAI_Sessions)
  late final String? _sessionLogBaseDir;

  // 动态注册中心
  final SkillRegistry _skillRegistry = SkillRegistry();

  // ------------------------- Getters -------------------------

  SkillRegistry get skillRegistry => _skillRegistry;
  List<Skill> get availableSkills => _skillRegistry.getAll();
  List<AgentTool> get availableTools => _toolRegistry.getAll();

  AppConfig get config => _config;
  NaiGenerationParams get params => _params;
  NaiAccountInfo? get accountInfo => _accountInfo;

  @visibleForTesting
  OpenAiCompatibleProvider? get providerForTesting =>
      _harness.provider is OpenAiCompatibleProvider
      ? _harness.provider as OpenAiCompatibleProvider
      : null;

  @visibleForTesting
  OpenAiCompatibleProvider? get compactionProviderForTesting =>
      _harness.compactionProvider is OpenAiCompatibleProvider
      ? _harness.compactionProvider as OpenAiCompatibleProvider
      : null;

  @visibleForTesting
  void setAccountInfoForTest(NaiAccountInfo? info) {
    _accountInfo = info;
    notifyListeners();
  }

  /// ComfyUI 模式开关 (开启后生图改走 PromptToolkit AI Bridge，
  /// 旁路质量词/UC 预设与 Token 上限)
  bool get isComfyUiMode => _config.comfyUiEnabled;

  /// ComfyUI Bridge 连接状态 / 节点注册快照 / 最近一次错误
  ComfyUiConnectionStatus get comfyConnectionStatus;
  ComfyUiBridgeState? get comfyBridgeState;
  String? get comfyLastError;

  /// ComfyUI 服务器实时可用选项清单 (采样器/调度器；连接成功后拉取)
  ComfyUiOptionCatalog? get comfyOptionCatalog;

  /// ComfyUI 采样器 / 噪声调度器 (空 = 跟随工作流，不下发)
  String get comfySampler;
  String get comfyScheduler;

  /// 设置 ComfyUI 采样器 / 调度器 (传空字符串回到跟随工作流)
  Future<void> setComfySampler(String value);
  Future<void> setComfyScheduler(String value);

  /// 当前工作台参数的预计 Anlas 消耗 (账号未加载时按非 Opus 保守估算)；
  /// ComfyUI 模式下本地不产生 Anlas 消耗，恒为 0
  int get estimatedGenerationCost => isComfyUiMode
      ? 0
      : AnlasCalculator.estimateGenerationCost(
          params: _params,
          isOpus: _accountInfo?.isOpus ?? false,
          opusQuotaExhausted: _accountInfo?.v5QuotaExhausted ?? false,
        );
  bool get isLoadingAccount => _isLoadingAccount;
  bool get isGenerating => _isGenerating;

  int get batchCount => _batchCount;

  bool get isBatchRunning => _batchTotal > 0;

  int get batchCurrent => _batchCurrent;

  int get batchTotal => _batchTotal;

  /// 生成中且已转入后台：画布与历史侧栏不展示生成占位卡，
  /// 生成坞/画布空态/历史侧栏改为「查看生成」恢复入口。
  bool get generationBackgrounded => _isGenerating && _generationBackgrounded;
  bool get isChatStreaming => _isChatStreaming;

  /// 流式对话瞬态文本控制器 (视图局部监听用)
  StreamingTextController get streamingText => _streamingText;

  /// 生图/修复实时进度控制器 (视图局部监听用)
  LiveProgressController get liveProgressController => _liveProgressController;

  String get currentStreamingThoughts => _streamingText.thoughts;
  String get currentStreamingContent => _streamingText.content;

  /// 流式请求重试提示 (流式气泡顶部展示)
  String? get streamingRetryNotice => _streamingText.notice;

  /// 对话卡思考块全局展开开关 (Ctrl+O 切换)
  bool get isThinkingExpanded => _isThinkingExpanded;
  NaiGeneratedImage? get selectedImage => _selectedImage;
  bool get hasUnseenLatest => _hasUnseenLatest;
  bool get isViewingLatest =>
      gallery.isEmpty ||
      _selectedImage == null ||
      _selectedImage?.id == gallery.first.id;
  List<NaiGeneratedImage> get gallery => _repository.history;
  List<AgentMessage> get messages => _harness.messages;
  ContextUsage get contextUsage => _harness.contextUsage;
  AgentPreset get currentPreset => _harness.currentPreset;
  List<AgentPreset> get presets =>
      _config.presets.isNotEmpty ? _config.presets : BuiltinPresets.all;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  List<AppNoticeRecord> get notificationHistory => _notificationLog.records;
  int get unreadNotificationCount => _notificationLog.unreadCount;

  /// 实时生图预览 Getters (委托 LiveProgressController)
  Uint8List? get livePreviewBytes => _liveProgressController.previewBytes;
  int get liveCurrentStep => _liveProgressController.currentStep;
  int get liveTotalSteps => _liveProgressController.totalSteps;
  double get liveProgress => _liveProgressController.progress;
  DateTime? get generationStartTime => _liveProgressController.startTime;

  /// 已保存的全部会话列表
  List<SessionInfo> get sessions => List.unmodifiable(_sessions);

  /// 当前活跃会话 ID
  String? get currentSessionId => _sessionLog.currentSessionId;

  /// 当前活跃会话元数据
  SessionInfo? get currentSessionInfo {
    final id = currentSessionId;
    if (id == null) return null;
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  ThinkingEffort get currentThinkingEffort => _currentThinkingEffort;

  AgentQuestionPrompt? get activeQuestionPrompt => _activeQuestionPrompt;

  /// 本会话内各模型 (provider/model) 的累计 Token 用量
  Map<String, TokenUsage> get sessionModelUsage =>
      Map.unmodifiable(_sessionModelUsage);

  /// Token 用量账本 (供设置页 Bill 页与统计使用)
  UsageLedgerService get usageLedger => _usageLedger;

  /// 将 "provider/model" 用量键中的供应商 id 映射为用户设定的供应商名称。
  /// 旧账本/旧会话记录的可能是 id (如 provider_173...)，统一按名称展示。
  String displayNameForModelKey(String key) {
    final slash = key.indexOf('/');
    if (slash <= 0) return key;
    final providerPart = key.substring(0, slash);
    for (final p in _config.llmProviders) {
      if (p.id == providerPart && p.name.isNotEmpty) {
        return '${p.name}${key.substring(slash)}';
      }
    }
    return key;
  }

  /// 按周期聚合账单 (供应商 id 自动映射为名称，同名行合并)
  BillSummary buildBillSummary(BillPeriod period) {
    final summary = _usageLedger.aggregate(period);
    if (summary.models.isEmpty) return summary;

    final merged = <String, BillModelUsage>{};
    var remapped = false;
    for (final row in summary.models) {
      final displayName = displayNameForModelKey(row.name);
      if (displayName != row.name) remapped = true;
      final existing = merged[displayName];
      merged[displayName] = BillModelUsage(
        name: displayName,
        requests: (existing?.requests ?? 0) + row.requests,
        usage: (existing?.usage ?? const TokenUsage()).add(row.usage),
      );
    }
    if (!remapped) return summary;

    final models = merged.values.toList()
      ..sort((a, b) => b.usage.total.compareTo(a.usage.total));
    return BillSummary(
      period: period,
      requests: summary.requests,
      usage: summary.usage,
      models: models,
    );
  }

  // ------------------------- 共享参数入口 -------------------------

  /// 更新侧边栏参数 (统一入口：UI 与 Agent 工具共用，含防抖持久化)
  /// 只要存在选中的画风组，就把附加段强制写回参数。
  /// 复用提示词 / 恢复快照 / agent 改参数后，避免只显示灰色文本却不参与生成。
  NaiGenerationParams _withActiveStyle(NaiGenerationParams params) {
    final preset = activeStylePreset;
    if (preset == null) return params;
    // 画风组勾选去除时，元数据里也不再写入画风串 tag（保留其他 tag）。
    final stripStyle = preset.stripMetadata || preset.stripStealth;
    return params.copyWith(
      stylePositive: preset.positive,
      styleNegative: preset.negative,
      styleTagsInMetadata: preset.styleInMetadata && !stripStyle,
    );
  }

  void updateParams(NaiGenerationParams newParams) {
    if (newParams.characterAiPosition && _isEditingCharacterPositions) {
      _isEditingCharacterPositions = false;
    }
    _params = _withActiveStyle(newParams);
    notifyListeners();

    _scheduleParameterSave();
  }

  /// UI、Agent、种子自动变更与修复偏好共用的防抖保存入口。
  void _scheduleParameterSave() {
    _paramSaveDebounceTimer?.cancel();
    _paramSaveDebounceTimer = Timer(
      const Duration(milliseconds: 300),
      _saveParameterSnapshot,
    );
  }

  Future<void> _saveParameterSnapshot() {
    _paramSaveDebounceTimer?.cancel();
    _paramSaveDebounceTimer = null;
    final generation = _params;
    final inpaint = _inpaintParams;
    final save = _lastParameterSave.then(
      (_) => _configService.saveStudioParameters(generation, inpaint),
    );
    // 防抖回调的异常被记录；显式 flush 仍返回原始 Future，使关闭流程可重试。
    _lastParameterSave = save.catchError((Object error, StackTrace stack) {
      debugPrint('工作台参数保存失败: $error');
    });
    return save;
  }

  /// 取消防抖并等待前序写入完成，关闭窗口及测试重启前使用。
  Future<void> flushPendingParameterSave() => _saveParameterSnapshot();

  /// 便捷更新主提示词
  void updatePrompt(String prompt) {
    updateParams(_params.copyWith(prompt: prompt));
  }

  /// 便捷更新负面提示词
  void updateNegativePrompt(String negativePrompt) {
    updateParams(_params.copyWith(negativePrompt: negativePrompt));
  }

  // ------------------------- 擦除 tag 输入历史 -------------------------

  /// 读取擦除 tag 输入历史 (最新在前，最多 10 条；true = 负面 tag)。
  Future<List<String>> loadStripTagHistory({bool negative = false}) =>
      _configService.loadStripTagHistory(negative: negative);

  /// 记录一次擦除 tag 输入，返回去重后的最新历史。
  Future<List<String>> recordStripTagHistory(
    String value, {
    bool negative = false,
  }) => _configService.recordStripTagHistory(value, negative: negative);

  /// 清空擦除 tag 输入历史 (true = 负面 tag)。
  Future<void> clearStripTagHistory({bool negative = false}) =>
      _configService.clearStripTagHistory(negative: negative);

  /// 收藏的图片 ID 集合。
  Set<String> get favoriteImageIds =>
      Set<String>.unmodifiable(_favoriteImageIds);

  bool isFavoriteImage(String id) => _favoriteImageIds.contains(id);

  /// 已收藏的历史图片。
  List<NaiGeneratedImage> get favoriteImages => gallery
      .where((image) => _favoriteImageIds.contains(image.id))
      .toList(growable: false);

  /// 外部图源收藏 (AITag / 法典)。
  bool isFavoriteSource(String scope, String id) =>
      _favoriteSourceIds.contains('$scope:$id');

  Future<void> toggleFavoriteSource(String scope, String id) async {
    final key = '$scope:$id';
    if (!_favoriteSourceIds.remove(key)) {
      _favoriteSourceIds.add(key);
    }
    notifyListeners();
    await _configService.saveFavoriteSourceIds(
      _favoriteSourceIds.toList(growable: false),
    );
  }

  List<StylePreset> get stylePresets =>
      List<StylePreset>.unmodifiable(_stylePresets);
  String get activeStylePresetId => _activeStylePresetId;
  StylePreset? get activeStylePreset => _stylePresets
      .where((preset) => preset.id == _activeStylePresetId)
      .firstOrNull;

  /// 清理 7 天前的内部缓存图片，避免失败回退积累孤儿文件。
  Future<void> _cleanupStaleCache() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dirs = <Directory>[
        Directory('${docs.path}/NovelAI_Harness/cache'),
        Directory('${Directory.systemTemp.path}/NovelAI_Harness/cache'),
      ];
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final dir in dirs) {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          try {
            final stat = await entity.stat();
            if (stat.modified.isBefore(cutoff)) {
              await entity.delete();
            }
          } on Object {
            // 单个文件失败不影响其他
          }
        }
      }
    } on Object {
      // 目录不可用时忽略
    }
  }

  Future<void> _applyPresetPrivacy(bool strip) async {
    // 画风组只决定「导出元数据是否包含画风串 tag」，不清其他元数据/隐写。
    updateParams(_params.copyWith(styleTagsInMetadata: !strip));
    notifyListeners();
  }

  Future<void> _persistStylePresets() async {
    await _configService.saveStylePresets(
      _stylePresets.map((preset) => preset.encode()).toList(growable: false),
    );
    notifyListeners();
  }

  Future<void> addStylePreset({
    required String name,
    required String positive,
    required String negative,
    bool stripMetadata = false,
    bool stripStealth = false,
    bool styleInMetadata = true,
  }) async {
    final preset = StylePreset(
      id: 'style_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? '画风' : name.trim(),
      positive: positive.trim(),
      negative: negative.trim(),
      stripMetadata: stripMetadata,
      stripStealth: stripStealth,
      styleInMetadata: styleInMetadata,
    );
    _stylePresets.add(preset);
    await _persistStylePresets();
  }

  Future<void> updateStylePreset(StylePreset preset) async {
    final index = _stylePresets.indexWhere((item) => item.id == preset.id);
    if (index < 0) return;
    _stylePresets[index] = preset;
    if (_activeStylePresetId == preset.id) {
      updateParams(_params.copyWith(
        stylePositive: preset.positive,
        styleNegative: preset.negative,
        styleTagsInMetadata: preset.styleInMetadata,
      ));
      await _applyPresetPrivacy(
        preset.stripMetadata || preset.stripStealth,
      );
    }
    await _persistStylePresets();
  }

  Future<void> removeStylePreset(String id) async {
    _stylePresets.removeWhere((item) => item.id == id);
    if (_activeStylePresetId == id) {
      _activeStylePresetId = '';
      updateParams(_params.copyWith(
        stylePositive: '',
        styleNegative: '',
        styleTagsInMetadata: true,
      ));
    }
    await _configService.saveStylePresetId(_activeStylePresetId);
    await _persistStylePresets();
  }

  /// 选择画风组：立即把该组正/负 tag 追加到工作台，并同步脱敏开关。
  Future<void> selectStylePreset(String id) async {
    final preset = _stylePresets.where((item) => item.id == id).firstOrNull;
    if (preset == null) return;
    _activeStylePresetId = id;
    await _configService.saveStylePresetId(id);
    // 画风串不写进可编辑文本框，而是作为只读附加段参与生成与元数据。
    updateParams(_params.copyWith(
      stylePositive: preset.positive,
      styleNegative: preset.negative,
      styleTagsInMetadata: preset.styleInMetadata,
    ));
    // 选中组的脱敏开关直接作用于本次出图（元数据 + 隐写一并处理）。
    await _applyPresetPrivacy(preset.stripMetadata || preset.stripStealth);
    notifyListeners();
  }

  Future<void> clearStylePreset() async {
    _activeStylePresetId = '';
    await _configService.saveStylePresetId('');
    updateParams(_params.copyWith(
      stylePositive: '',
      styleNegative: '',
      styleTagsInMetadata: true,
    ));
    notifyListeners();
  }


  List<QueuedChatMessage> get queuedChatMessages =>
      List<QueuedChatMessage>.unmodifiable(_chatQueue);
  bool get chatQueuePaused => _chatQueuePaused;

  /// 流式期间把消息加入持久化队列，本轮结束后自动发送。
  Future<void> queueChatMessage(
    String text, {
    List<AgentMessageImage>? images,
  }) async {
    final trimmed = text.trim();
    final attachments = images ?? const <AgentMessageImage>[];
    if (trimmed.isEmpty && attachments.isEmpty) return;
    final message = QueuedChatMessage(content: trimmed, images: attachments);
    _chatQueue.add(message);
    try {
      await ChatQueueStore.instance.add(message);
    } on Object {
      // 存储失败仍保留内存队列
    }
    _harness.addInfoMessage('已加入队列（${_chatQueue.length} 条），本轮结束后自动发送');
    notifyListeners();
  }

  Future<void> setBatchCount(int value) async {
    _batchCount = value.clamp(1, 20);
    await _configService.saveBatchCount(_batchCount);
    notifyListeners();
  }

  Future<void> toggleChatQueuePaused() async {
    _chatQueuePaused = !_chatQueuePaused;
    await _configService.saveChatQueuePaused(_chatQueuePaused);
    _harness.addInfoMessage(_chatQueuePaused ? '已暂停发送队列' : '已恢复发送队列');
    notifyListeners();
  }

  Future<void> moveQueuedMessage(int from, int to) async {
    if (from < 0 || from >= _chatQueue.length) return;
    var target = to;
    if (target < 0) target = 0;
    if (target >= _chatQueue.length) target = _chatQueue.length - 1;
    if (from == target) return;
    final message = _chatQueue.removeAt(from);
    _chatQueue.insert(target, message);
    await _persistChatQueue();
  }

  Future<void> _persistChatQueue() async {
    try {
      await ChatQueueStore.instance.replaceAll(_chatQueue);
    } on Object {
      // 忽略存储失败
    }
    notifyListeners();
  }

  /// 编辑队列中的一条消息。
  Future<void> editQueuedMessage(int index, String text) async {
    if (index < 0 || index >= _chatQueue.length) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _chatQueue[index] = QueuedChatMessage(
      content: trimmed,
      images: _chatQueue[index].images,
    );
    await _persistChatQueue();
  }

  /// 删除队列中的一条消息。
  Future<void> removeQueuedMessage(int index) async {
    if (index < 0 || index >= _chatQueue.length) return;
    _chatQueue.removeAt(index);
    await _persistChatQueue();
  }

  /// 立即发送队列中的一条消息。
  Future<void> sendQueuedMessageNow(int index) async {
    if (index < 0 || index >= _chatQueue.length) return;
    final message = _chatQueue.removeAt(index);
    await _persistChatQueue();
    if (_isChatStreaming) {
      // 立即发送 = 中断当前输出并马上发这条，而不是等本轮结束。
      _suppressQueueDrain = true;
      try {
        await abortChat();
        // abortChat 只保证完成信号，等 finally 真正把流式状态复位。
        for (var attempt = 0; attempt < 100; attempt += 1) {
          if (!_isChatStreaming) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } finally {
        _suppressQueueDrain = false;
      }
    }
    await sendChatMessage(message.content, images: message.images);
  }

  String get wd14Endpoint => _wd14Endpoint;
  String get wd14Token => _wd14Token;
  double get wd14Threshold => _wd14Threshold;
  List<Wd14Tag> get lastWd14Tags => List<Wd14Tag>.unmodifiable(_lastWd14Tags);

  Future<void> setWd14Endpoint(String value) async {
    _wd14Endpoint = value.trim().isEmpty
        ? Wd14OnlineService.defaultEndpoint
        : value.trim();
    await _configService.saveWd14Endpoint(_wd14Endpoint);
    notifyListeners();
  }

  Future<void> setWd14Token(String value) async {
    _wd14Token = value.trim();
    await _configService.saveWd14Token(_wd14Token);
    notifyListeners();
  }

  Future<void> setWd14Threshold(double value) async {
    _wd14Threshold = value.clamp(0.05, 0.95).toDouble();
    await _configService.saveWd14Threshold(_wd14Threshold);
    notifyListeners();
  }

  /// 对任意图片字节执行在线 WD14 反推。
  Future<List<Wd14Tag>> tagImageBytesWithWd14(
    List<int> bytes, {
    double? threshold,
  }) async {
    if (bytes.isEmpty) throw Wd14Exception('图片为空');
    // WD14 只需要小图；大图先缩到 1024，减少上传体积与耗时。
    var payload = bytes;
    try {
      final decoded = img.decodeImage(Uint8List.fromList(bytes));
      if (decoded != null &&
          (decoded.width > 1024 || decoded.height > 1024)) {
        final resized = decoded.width >= decoded.height
            ? img.copyResize(decoded, width: 1024)
            : img.copyResize(decoded, height: 1024);
        payload = img.encodePng(resized);
      }
    } on Object {
      // 解码失败时按原图上传
    }
    final tags = await _wd14Service.tag(
      imageBytes: payload,
      endpoint: _wd14Endpoint,
      token: _wd14Token,
      threshold: threshold ?? _wd14Threshold,
    );
    _lastWd14Tags = tags;
    notifyListeners();
    return tags;
  }

  /// 在线 WD14 反推当前画布图片。
  Future<List<Wd14Tag>> tagCurrentCanvasWithWd14({double? threshold}) async {
    final image = _selectedImage ?? (gallery.isEmpty ? null : gallery.first);
    if (image == null) {
      throw Wd14Exception('画布还没有图片可反推');
    }
    final bytes = await getExportImageBytes(image, raw: true);
    return tagImageBytesWithWd14(bytes, threshold: threshold);
  }

  /// 反推聊天里最近一条用户附图。
  Future<List<Wd14Tag>> tagLastChatImageWithWd14({double? threshold}) async {
    final messages = _harness.messages;
    for (var i = messages.length - 1; i >= 0; i -= 1) {
      final message = messages[i];
      if (message.role != AgentRole.user || message.images.isEmpty) continue;
      return tagImageBytesWithWd14(message.images.first.bytes,
          threshold: threshold);
    }
    throw Wd14Exception('聊天里没有找到可反推的图片');
  }

  Future<void> applyWd14Tags(List<Wd14Tag> tags) async {
    if (tags.isEmpty) return;
    final existing = _params.prompt.trim();
    final additions = tags
        .map((tag) => tag.name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    final merged = existing.isEmpty
        ? additions.join(', ')
        : '$existing, ${additions.join(', ')}';
    updateParams(_params.copyWith(prompt: merged));
  }

  bool get effectiveStripMetadata => _config.stripMetadata;

  bool get effectiveStripStealth => _stripStealth;

  /// 单开关：是否清除全部数据（元数据 + 隐写）。
  bool get effectiveStripAll =>
      effectiveStripMetadata && effectiveStripStealth;

  Future<void> setStripAll(bool strip) async {
    _config = _config.copyWith(stripMetadata: strip);
    _stripStealth = strip;
    ImagePrivacySettings.stripMetadata = strip;
    ImagePrivacySettings.stripStealth = strip;
    await _configService.saveConfig(_config);
    await _configService.saveStripStealth(strip);
    notifyListeners();
  }

  String get accountMode => _accountMode;

  Future<void> setAccountMode(String mode) async {
    if (mode != 'fixed' && mode != 'rotate') return;
    _accountMode = mode;
    await _persistAccounts();
    notifyListeners();
  }

  /// 轮换模式：生图前切到下一个账号；固定模式保持当前账号。
  Future<void> rotateAccountForGeneration() async {
    if (_accountMode != 'rotate' || _accounts.length < 2) return;
    final index = _accounts.indexWhere((item) => item.id == _activeAccountId);
    final next = _accounts[(index + 1) % _accounts.length];
    _activeAccountId = next.id;
    _config = _config.copyWith(novelAiKey: next.apiKey);
    await _persistAccounts();
    await _saveConfigForAccounts();
    notifyListeners();
  }

  Future<void> _persistAccounts() async {
    try {
      await AccountStore.instance.save(
        accounts: _accounts,
        activeId: _activeAccountId,
        mode: _accountMode,
        defaultId: _defaultAccountId,
      );
    } on AccountStoreException catch (error) {
      // 存储不可用时保持内存状态，至少本次会话可继续使用账号。
      debugPrint('账号池保存失败: $error');
    }
  }

  /// 账号切换后立即把工作台 Key 落盘。
  /// Agent 工具通过 configService.loadConfig() 读取当前 Key；若只改内存，
  /// 同会话内 Agent 生图会继续使用上一个账号，导致计费到错误账号。
  Future<void> _saveConfigForAccounts() async {
    try {
      await _configService.saveConfig(_config);
    } on Object catch (error) {
      debugPrint('账号切换后保存配置失败: $error');
    }
  }

  /// 把工作台账号信息同步回账号池当前条目。
  Future<void> _syncActiveAccountInfo() async {
    final info = _accountInfo;
    if (info == null) return;
    final index = _accounts.indexWhere((item) => item.id == _activeAccountId);
    if (index < 0) return;
    final updated = _accounts[index].copyWith(
      tierName: info.tierName,
      anlas: info.totalAnlas,
      v5Energy: info.staminaPercent.round(),
      updatedAt: DateTime.now(),
    );
    _accounts = List<NaiAccount>.from(_accounts)..[index] = updated;
    await _persistAccounts();
  }

  String get defaultAccountId => _defaultAccountId;

  Future<void> setDefaultAccount(String id) async {
    if (_accounts.every((item) => item.id != id)) return;
    _defaultAccountId = id;
    await _persistAccounts();
    notifyListeners();
  }

  List<NaiAccount> get accounts => List<NaiAccount>.unmodifiable(_accounts);
  String get activeAccountId => _activeAccountId;
  NaiAccount? get activeAccount =>
      _accounts.where((item) => item.id == _activeAccountId).firstOrNull;

  Future<void> addAccount({
    required String label,
    required String apiKey,
  }) async {
    final account = NaiAccount(
      id: 'a${DateTime.now().millisecondsSinceEpoch}',
      label: label.trim().isEmpty ? '账号' : label.trim(),
      apiKey: apiKey.trim(),
    );
    _accounts = <NaiAccount>[..._accounts, account];
    if (_defaultAccountId.isEmpty) _defaultAccountId = account.id;
    _activeAccountId = account.id;
    _config = _config.copyWith(novelAiKey: account.apiKey);
    await _persistAccounts();
    await _saveConfigForAccounts();
    notifyListeners();
  }

  Future<void> removeAccount(String id) async {
    _accounts = _accounts.where((item) => item.id != id).toList();
    if (_defaultAccountId == id) {
      _defaultAccountId = _accounts.isEmpty ? '' : _accounts.first.id;
    }
    if (_activeAccountId == id) {
      if (_accounts.isEmpty) {
        _activeAccountId = '';
        _config = _config.copyWith(novelAiKey: '');
      } else {
        _activeAccountId = _accounts.first.id;
        _config = _config.copyWith(novelAiKey: _accounts.first.apiKey);
      }
    }
    await _persistAccounts();
    await _saveConfigForAccounts();
    notifyListeners();
  }

  Future<void> selectAccount(String id) async {
    final account = _accounts.where((item) => item.id == id).firstOrNull;
    if (account == null) return;
    _activeAccountId = id;
    _config = _config.copyWith(novelAiKey: account.apiKey);
    await _persistAccounts();
    await _saveConfigForAccounts();
    notifyListeners();
    await refreshAccountInfo();
  }

  /// 逐个刷新账号池的档位/点数/体力。
  Future<void> refreshAccounts() async {
    for (var index = 0; index < _accounts.length; index += 1) {
      final account = _accounts[index];
      if (account.apiKey.trim().isEmpty) continue;
      try {
        final info = await _repository.fetchAccountInfo(apiKey: account.apiKey);
        _accounts[index] = account.copyWith(
          tierName: info.tierName,
          anlas: info.totalAnlas,
          v5Energy: info.staminaPercent.round(),
          updatedAt: DateTime.now(),
        );
      } on Object {
        // 单个账号失败不影响其他
      }
    }
    await _persistAccounts();
    notifyListeners();
  }

  bool get stripStealth => _stripStealth;

  /// 按开关清除已保存图片的 Alpha LSB 隐写（保留文本元数据）。
  Future<void> stripStealthFromFile(String? path) async {
    if (!_stripStealth || path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final stripped = await ImageMetadataService.stripPngStealthAsync(bytes);
      if (!identical(stripped, bytes)) {
        // 原子替换：缩略图/画板可能正在读缓存文件，直接 writeAsBytes
        // 会留下半截 PNG 或与读取方发生 Windows 共享冲突。
        final temp = File(
          '$path.strip-${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        await temp.writeAsBytes(stripped, flush: true);
        try {
          await temp.rename(path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      }
    } on Object {
      // 隐写清除失败不影响主流程
    }
  }

  Future<void> setStripStealth(bool value) async {
    // 先同步全局设置，即使值没变也要保证导出管道拿到最新开关。
    ImagePrivacySettings.stripStealth = value;
    if (_stripStealth == value) {
      notifyListeners();
      return;
    }
    _stripStealth = value;
    notifyListeners();
    await _configService.saveStripStealth(value);
  }

  /// 梳理串（复盘/梦境记录）。
  List<ChatBranch> get chatBranches =>
      List<ChatBranch>.unmodifiable(_chatBranches);

  List<ReflectionEntry> get reflections =>
      List<ReflectionEntry>.unmodifiable(_reflections);

  Future<ReflectionEntry> addReflection({
    required String title,
    required String summary,
    List<String> lessons = const <String>[],
    String source = 'reflect',
  }) async {
    final entry = ReflectionEntry(
      id: 'r-${DateTime.now().millisecondsSinceEpoch}',
      title: title.trim().isEmpty ? '未命名复盘' : title.trim(),
      source: source,
      summary: summary.trim(),
      lessons: lessons
          .where((item) => item.trim().isNotEmpty)
          .map((item) => item.trim())
          .toList(growable: false),
      createdAt: DateTime.now(),
      sessionId: currentSessionId ?? '',
    );
    _reflections.insert(0, entry);
    if (_reflections.length > 200) _reflections.removeLast();
    notifyListeners();
    await ReflectionStore.instance.upsert(entry);
    return entry;
  }

  Future<void> removeReflection(String id) async {
    _reflections.removeWhere((item) => item.id == id);
    notifyListeners();
    await ReflectionStore.instance.remove(id);
  }

  /// 跨会话长期记忆。
  List<String> get memoryEntries => List<String>.unmodifiable(_memoryEntries);

  Future<void> addMemoryEntry(String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    final stored = value.length > 500 ? value.substring(0, 500) : value;
    _memoryEntries.insert(0, stored);
    final sessionId = currentSessionId;
    if (sessionId != null && sessionId.isNotEmpty) {
      _memoryEntrySessions.putIfAbsent(stored, () => <String>{}).add(sessionId);
    }
    while (_memoryEntries.length > 100) {
      final removed = _memoryEntries.removeLast();
      _memoryEntrySessions.remove(removed);
    }
    notifyListeners();
    await _configService.saveMemoryEntries(_memoryEntries);
    await _configService.saveMemoryEntrySessions(_memoryEntrySessions);
  }

  Future<void> removeMemoryEntry(int index) async {
    if (index < 0 || index >= _memoryEntries.length) return;
    final removed = _memoryEntries.removeAt(index);
    _memoryEntrySessions.remove(removed);
    notifyListeners();
    await _configService.saveMemoryEntries(_memoryEntries);
    await _configService.saveMemoryEntrySessions(_memoryEntrySessions);
  }

  Future<void> updateMemoryEntry(int index, String text) async {
    final value = text.trim();
    if (index < 0 || index >= _memoryEntries.length || value.isEmpty) return;
    final old = _memoryEntries[index];
    final stored = value.length > 500 ? value.substring(0, 500) : value;
    final sessionIds = _memoryEntrySessions.remove(old);
    _memoryEntries[index] = stored;
    if (sessionIds != null && sessionIds.isNotEmpty) {
      _memoryEntrySessions[stored] = sessionIds;
    }
    notifyListeners();
    await _configService.saveMemoryEntries(_memoryEntries);
    await _configService.saveMemoryEntrySessions(_memoryEntrySessions);
  }

  Future<void> clearMemoryEntries() async {
    _memoryEntries.clear();
    _memoryEntrySessions.clear();
    notifyListeners();
    await _configService.saveMemoryEntries(const <String>[]);
    await _configService.saveMemoryEntrySessions(const <String, Set<String>>{});
  }

  /// 某个会话产生的记忆条数（用于删除确认）。
  int sessionMemoryCount(String sessionId) {
    final target = sessionId.trim();
    if (target.isEmpty) return 0;
    final memory = _memoryEntries.where((entry) {
      final sessionIds = _memoryEntrySessions[entry];
      return sessionIds != null &&
          sessionIds.length == 1 &&
          sessionIds.contains(target);
    }).length;
    final reflections = _reflections
        .where((entry) => entry.sessionId == target)
        .length;
    return memory + reflections;
  }

  /// 丢弃某个会话产生的长期记忆、梳理串与上下文笔记。
  Future<({int removed, bool contextCleared})> discardSessionMemory(
    String sessionId,
  ) async {
    final target = sessionId.trim();
    if (target.isEmpty) return (removed: 0, contextCleared: true);
    final previousEntries = List<String>.from(_memoryEntries);
    final previousSessions = {
      for (final entry in _memoryEntrySessions.entries)
        entry.key: Set<String>.from(entry.value),
    };
    final previousReflections = List<ReflectionEntry>.from(_reflections);
    var removedCount = 0;
    final remaining = <String>[];
    for (final entry in _memoryEntries) {
      final sessionIds = _memoryEntrySessions[entry];
      if (sessionIds == null || !sessionIds.contains(target)) {
        remaining.add(entry);
        continue;
      }
      sessionIds.remove(target);
      if (sessionIds.isEmpty) {
        _memoryEntrySessions.remove(entry);
        removedCount += 1;
      }
      remaining.add(entry);
    }
    _memoryEntries
      ..clear()
      ..addAll(remaining);
    final removedReflections = _reflections
        .where((entry) => entry.sessionId == target)
        .toList(growable: false);
    if (removedReflections.isNotEmpty) {
      _reflections.removeWhere((entry) => entry.sessionId == target);
      removedCount += removedReflections.length;
    }
    try {
      await ReflectionStore.instance.removeBySession(target);
      await _configService.saveMemoryEntries(_memoryEntries);
      await _configService.saveMemoryEntrySessions(_memoryEntrySessions);
    } on Object {
      _memoryEntries
        ..clear()
        ..addAll(previousEntries);
      _memoryEntrySessions
        ..clear()
        ..addAll(previousSessions);
      _reflections
        ..clear()
        ..addAll(previousReflections);
      for (final entry in removedReflections) {
        try {
          await ReflectionStore.instance.upsert(entry);
        } on Object {
          // 回滚尽力而为
        }
      }
      rethrow;
    }
    final contextCleared = await _sessionLog.clearSessionContextState(target);
    if (target == currentSessionId) {
      _harness.memory.clear();
      _harness.memoryChanged();
      _sessionLog.saveContextState(_harness.exportContextState());
    }
    notifyListeners();
    return (removed: removedCount, contextCleared: contextCleared);
  }

  /// 资料库目录与文件状态。
  String get libraryDir => libraryEffectiveDir;

  /// Agent 只允许读取这些目录内的本地图片（保存目录 + 资料库）。
  List<String> get _agentReadableRoots => <String>[
    if (_config.saveDirectory.trim().isNotEmpty) _config.saveDirectory,
    if (libraryEffectiveDir.trim().isNotEmpty) libraryEffectiveDir,
  ];
  List<LibraryFile> get libraryFiles => _libraryFiles;
  bool get libraryLoading => _libraryLoading;
  String? get libraryError => _libraryError;

  /// 选择资料库文件夹并立即刷新。
  Future<void> pickLibraryDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择资料库文件夹',
    );
    if (path == null || path.trim().isEmpty) return;
    _libraryDir = path;
    await _configService.saveLibraryDir(path);
    await refreshLibrary();
  }

  /// 恢复为内部默认目录（清除用户配置的路径）。
  Future<void> resetLibraryDirectory() async {
    _libraryDir = '';
    await _configService.saveLibraryDir('');
    await refreshLibrary();
  }

  /// 重新列出资料库文件。
  Future<void> refreshLibrary() async {
    await ensureLibraryDir();
    _libraryLoading = true;
    _libraryError = null;
    notifyListeners();
    try {
      _libraryFiles = await _libraryService.list(libraryEffectiveDir);
    } on Object catch (error) {
      _libraryError = '$error';
      _libraryFiles = const <LibraryFile>[];
    } finally {
      _libraryLoading = false;
      notifyListeners();
    }
  }

  /// 确保资料库目录存在；未配置时默认为「文档/NovelAI_Library」。
  /// 资料库实际目录：用户配置过就用配置的绝对路径，否则用内部默认目录。
  String get libraryEffectiveDir =>
      _libraryDir.trim().isEmpty ? _libraryFallbackDir : _libraryDir;

  Future<void> ensureLibraryDir() async {
    try {
      if (_libraryDir.trim().isEmpty) {
        if (_libraryFallbackDir.isEmpty) {
          final docs = await getApplicationDocumentsDirectory();
          // 内部默认目录，不写进配置；只有用户手动选择时才保存绝对路径。
          _libraryFallbackDir = '${docs.path}/NovelAI_Library';
        }
      }
      await _libraryService.ensureDir(libraryEffectiveDir);
    } on Object {
      // 测试或受限环境下没有可写目录：保持空库，不影响其他功能。
    }
  }

  /// 从系统文件选择器导入文档到资料库。
  Future<int> importLibraryDocuments() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );
    if (result == null) return 0;
    final paths = result.files
        .map((file) => file.path)
        .whereType<String>()
        .toList(growable: false);
    if (paths.isEmpty) return 0;
    final imported = await _libraryService.importFiles(
      libraryEffectiveDir,
      paths,
    );
    await refreshLibrary();
    return imported.length;
  }

  Future<void> deleteLibraryFile(LibraryFile file) async {
    await _libraryService.deleteFile(libraryEffectiveDir, file.path);
    await refreshLibrary();
  }

  /// 分页读取一个资料库文件。
  Future<LibraryRead> readLibraryFile(
    LibraryFile file, {
    int offset = 0,
    int limit = 6000,
  }) {
    return _libraryService.read(file.path, offset: offset, limit: limit);
  }

  /// 在资料库中搜索关键词。
  Future<List<LibraryMatch>> searchLibrary(String query) {
    return _libraryService.search(libraryEffectiveDir, query);
  }

  /// 切换图片收藏状态并持久化。
  Future<void> toggleFavoriteImage(String id) async {
    if (!_favoriteImageIds.remove(id)) {
      _favoriteImageIds.add(id);
    }
    notifyListeners();
    await _configService.saveFavoriteImageIds(
      _favoriteImageIds.toList(growable: false),
    );
  }

  /// 便捷设置种子模式
  void setSeedMode(NaiSeedMode mode) {
    updateParams(_params.copyWith(seedMode: mode));
  }

  /// 便捷设置种子生成控制时机
  void setSeedTiming(NaiSeedTiming timing) {
    updateParams(_params.copyWith(seedTiming: timing));
  }

  // ------------- 跨分部方法签名 (由各分部 Mixin 实现) -------------

  /// 应用并持久化新配置 (类体实现；各分部可调用)
  Future<void> updateConfig(AppConfig newConfig);

  // 图生图 / Vibe 参考 (studio_vm_generation.dart 实现)
  Future<bool> useSelectedImageAsImg2imgSource();
  void setImg2imgSource(Uint8List? bytes);
  Future<bool> useSelectedImageAsReference();
  void clearReferenceImages();

  /// 装配 Harness、注册全部工具并配置 LLM Provider
  void _setupHarnessAndTools();

  /// 切换 Agent 当前预设
  void selectPreset(AgentPreset preset);

  /// 手动快速生图
  Future<void> generateImage();

  /// ComfyUI 模式生图 (经 PromptToolkit AI Bridge 驱动)
  Future<void> generateImageViaComfyUi();

  /// 刷新 ComfyUI Bridge 连接状态与节点注册快照
  Future<void> refreshComfyUiStatus();

  /// 重新拉取 ComfyUI 可用采样器/调度器清单 (失败静默保持旧值)
  Future<void> refreshComfyUiOptions();

  /// 测试钩子：直接注入模拟的采样器/调度器清单 (绕过网络)
  @visibleForTesting
  void setComfyOptionCatalogForTesting(ComfyUiOptionCatalog? catalog);

  /// 切换 ComfyUI 模式开关
  Future<void> setComfyUiMode(bool enabled);

  /// 标记中止当前 ComfyUI 出图等待
  void _requestComfyAbort();

  /// 种子生成控制：生图前变更种子
  void _applySeedMutationBefore();

  /// 种子生成控制：生图后变更种子
  void _applySeedMutationAfter(int generatedSeed);

  /// 超分放大当前图片 (官方新超分模型，固定倍率)
  Future<void> upscaleSelected();

  Future<void> upscaleRtx(NaiGeneratedImage image);

  /// 刷新账号与体力信息
  Future<void> refreshAccountInfo({bool showError = false});

  /// 获取用于导出/复制的图像字节 (根据全局设置决定是否去元数据或添加水印)
  Future<Uint8List> getExportImageBytes(
    NaiGeneratedImage image, {
    bool raw = false,
  });

  /// 生成完成后统一落图 (手动生成与 Agent 工具共用)
  void _applyGeneratedImage(
    NaiGeneratedImage image, {
    required bool wasViewingLatest,
  });

  /// 自适应取色：后台提取指定图片主色并注入主题强调色
  /// (仅 accentMode == adaptive 时生效，选图/生图/删图后调用)
  void _scheduleAdaptiveAccent(NaiGeneratedImage image);

  /// 手动保存当前选中的未保存 (缓存) 图片到本地存储目录 (支持自定义目录)
  Future<bool> saveCurrentImageToDisk({String? customDir});

  /// 导出任意图片到指定文件夹 (由原生文件选择器挑选，遵守命名模板与无覆盖落盘)
  Future<bool> exportImageToDirectory(
    NaiGeneratedImage image,
    String targetDir,
  );

  /// 解析当前命名模板下的导出文件名 (不含目录)，供系统 SAF 单文件保存使用
  String resolveExportFileName(NaiGeneratedImage image);

  /// 解析当前命名模板下的导出相对子目录 (空 = 模板未分目录)，
  /// 供安卓 MediaStore 图库导出拼 `Pictures/<subDir>` 使用
  String resolveExportSubDir(NaiGeneratedImage image);

  /// 强行中止当前对话生成与工具执行
  Future<void> abortChat();

  /// 刷新会话列表
  Future<void> refreshSessions();

  /// 创建全新会话
  Future<void> createNewSession({String? title});

  /// 重命名指定会话
  Future<void> renameSession(String sessionId, String newTitle);

  /// 回退到指定历史消息。
  ///
  /// 目标是用户消息时：截断该消息及之后的对话，把文本和图片放回输入框，不发送。
  /// 其他角色则保留该消息，只丢弃其后的内容。
  Future<void> rewindToMessage(String messageId);

  /// 从剩余消息中重新聚合本会话各模型用量
  void _recomputeSessionUsage();

  /// 分发斜杠指令
  Future<void> _handleSlashCommand(String command);

  /// 呈现 AI 提问卡片 (ask_user / 付费确认共用)
  Future<List<String>?> _presentQuestionsToUser(List<AgentQuestion> questions);

  /// 付费生图申请确认
  Future<bool> _confirmPaidGeneration({
    required NaiGenerationParams params,
    required int estimatedCost,
  });

  Future<bool> _confirmCharacterTagChange(String summary);

  /// 付费超分确认
  Future<bool> _confirmPaidUpscale({
    required int estimatedCost,
    required int inputWidth,
    required int inputHeight,
  });

  /// 整体替换角色提示词列表 (Agent 工具与 UI 卡片共用入口)
  void _setCharacterPrompts(List<NaiCharacterPrompt> characters);

  /// 当前词库条目列表 (词库 Agent 工具读取)
  List<PromptComboEntry> get promptLibraryEntries;

  /// 新增词库条目 (词库 Agent 工具写入)
  Future<PromptComboEntry> addPromptCombo(PromptComboEntry entry);

  /// 更新词库条目 (词库 Agent 工具写入)
  Future<void> updatePromptCombo(PromptComboEntry entry);

  /// 删除词库条目 (词库 Agent 工具写入)
  Future<void> deletePromptCombo(String id);

  /// 保存预览图字节到托管目录并返回路径 (词库预览图工具)
  Future<String?> savePromptPreviewFromBytes(
    Uint8List bytes, {
    String extension = 'png',
  });

  /// 从本地路径复制预览图并返回持久化路径 (词库预览图工具)
  Future<String?> savePromptPreviewFromPath(String path);

  /// 发送对话消息 (支持 Slash 命令行；[images] 为用户图片附件)
  Future<void> sendChatMessage(String text, {List<AgentMessageImage>? images});

  /// 切换侧边栏激活页签 (修复分部右键发送后跳转用；expandSidebar=false 可在不展开收起栏时切页)
  void setActiveSidebarTab(StudioSidebarTab tab, {bool expandSidebar = true});

  /// 退出修复模式并切回进入修复前的主工作台页签
  void exitInpaintMode({bool expandSidebar = false});

  /// 历史大图完整字节缓存通知器：避免大图加载逐帧触发 notifyListeners() 全局重建
  ValueNotifier<Map<String, Uint8List>> get imageBytesNotifier =>
      _repository.imageBytesNotifier;

  Uint8List? getImageBytes(NaiGeneratedImage image) {
    if (image.bytes.isNotEmpty) return image.bytes;
    if (_selectedImage?.id == image.id && _selectedImage!.bytes.isNotEmpty) {
      return _selectedImage!.bytes;
    }
    if (_inpaintSourceImage?.id == image.id &&
        _inpaintSourceImage!.bytes.isNotEmpty) {
      return _inpaintSourceImage!.bytes;
    }
    return imageBytesNotifier.value[image.id];
  }

  /// 唯一的共享缓存由仓储按张数与字节预算治理；当前查看/修复源图单独固定驻留。
  Future<Uint8List?> ensureImageLoaded(NaiGeneratedImage image) async {
    final pinned = getImageBytes(image);
    if (pinned != null) return pinned;
    final loaded = await _repository.loadHistoryImageBytes(image);
    if (loaded != null && loaded.isNotEmpty) {
      if (_selectedImage?.id == image.id) {
        _selectedImage = _selectedImage!.copyWith(bytes: loaded);
      }
      if (_inpaintSourceImage?.id == image.id) {
        _inpaintSourceImage = _inpaintSourceImage!.copyWith(bytes: loaded);
      }
    }
    return loaded;
  }

  String _noticeSourceTitle(AppNoticeSource source) => switch (source) {
    AppNoticeSource.generation => vmL10n.notificationSourceGeneration,
    AppNoticeSource.inpaint => vmL10n.notificationSourceInpaint,
    AppNoticeSource.agent => vmL10n.notificationSourceAgent,
    AppNoticeSource.account => vmL10n.notificationSourceAccount,
    AppNoticeSource.comfyUi => vmL10n.notificationSourceComfyUi,
    AppNoticeSource.storage => vmL10n.notificationSourceStorage,
    AppNoticeSource.system => vmL10n.notificationSourceSystem,
  };

  /// 统一上报错误/通知：同步更新最新 errorMessage、写入持久化历史，并推送右上角悬浮通知卡片。
  void reportError(
    String message, {
    AppNoticeSource source = AppNoticeSource.system,
    AppNoticeLevel level = AppNoticeLevel.error,
    bool notify = true,
    Duration? autoDismiss = const Duration(seconds: 6),
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    _errorMessage = trimmed;
    final record = _notificationLog.record(
      message: trimmed,
      level: level,
      source: source,
    );
    final tone = switch (level) {
      AppNoticeLevel.error => AppToastTone.error,
      AppNoticeLevel.warning => AppToastTone.warning,
      AppNoticeLevel.info => AppToastTone.info,
    };
    bannerController.push(
      id: record.id,
      title: _noticeSourceTitle(source),
      message: trimmed,
      tone: tone,
      autoDismiss: autoDismiss,
    );
    if (notify) {
      notifyListeners();
    }
  }

  void markAllNotificationsRead() {
    if (_notificationLog.markAllRead()) {
      notifyListeners();
    }
  }

  void removeNotification(String id) {
    if (_notificationLog.remove(id)) {
      bannerController.dismiss(id);
      notifyListeners();
    }
  }

  void clearNotificationHistory() {
    final hadBanner = bannerController.items.isNotEmpty;
    final clearedLog = _notificationLog.clear();
    if (hadBanner) bannerController.clear();
    if (_errorMessage != null) _errorMessage = null;
    if (hadBanner || clearedLog) {
      notifyListeners();
    }
  }

  void clearError() {
    _errorMessage = null;
    bannerController.clear();
    notifyListeners();
  }
}

/// Studio 状态管理中枢 (MVVM)。
class StudioViewModel extends ChangeNotifier
    with
        _StudioCore,
        _StudioLayoutMixin,
        _StudioHarnessMixin,
        _StudioComfyMixin,
        _StudioGenerationMixin,
        _StudioChatMixin,
        _StudioSessionsMixin,
        _StudioCharactersMixin,
        _StudioSlashMixin,
        _StudioLibraryMixin,
        _StudioInpaintMixin {
  /// 公开入口在主类实现；本地 GPU 生命周期由生图分部管理。
  @override
  Future<void> upscaleRtx(NaiGeneratedImage image) {
    if (_isRtxUpscaling) return Future<void>.value();
    return _rtxOperation = _upscaleRtxImage(image);
  }

  StudioViewModel({
    ConfigService? configService,
    NovelAiRepository? repository,
    PromptLibraryService? promptLibraryService,
    PromptLibrarySyncService? promptLibrarySyncService,
    SkillPackageService? skillPackageService,
    String? sessionLogBaseDir,
  }) {
    // Mixin 的 late final 字段无法进初始化列表，统一在构造体内注入
    _configService = configService ?? ConfigService.shared;
    _ownsRepository = repository == null;
    // 本地 fork：NovelAI 请求走可配置网络代理通道
    _repository =
        repository ??
        NovelAiRepository(
          service: NovelAiService(
            httpClient: NetworkProxyService.instance.createClient(
              NetworkFeature.novelAi,
            ),
          ),
          imageEditService: ImageEditService(
            client: NetworkProxyService.instance.createClient(
              NetworkFeature.novelAi,
            ),
          ),
        );
    _promptLibraryService =
        promptLibraryService ?? PromptLibraryService.instance;
    _promptLibrarySyncService =
        promptLibrarySyncService ??
        (promptLibraryService == null
            ? PromptLibrarySyncService.instance
            : PromptLibrarySyncService(libraryService: _promptLibraryService));
    _skillPackageService = skillPackageService ?? SkillPackageService();
    _mcpManager = McpManager(
      httpClient: _llmHttpClient,
      onStateChanged: () {
        if (_disposed) return;
        _syncMcpToolsToRegistry();
        mcpStateNotifier.value++;
      },
    );
    _sessionLogBaseDir = sessionLogBaseDir;
    _toolRegistry = ToolRegistry();
    _harness = AgentHarness(
      tools: _toolRegistry,
      skillRegistry: _skillRegistry,
      recorder: _sessionLog,
      initialPreset: BuiltinPresets.v5FullExpert,
    );
    _harness.onContextChanged = () {
      _sessionLog.saveContextState(_harness.exportContextState());
      notifyListeners();
    };
    _harness.onCompactionUsage = (usage, model) {
      final provider = _config.llmProviders
          .where((p) => p.id == _config.compactionProviderId)
          .firstOrNull;
      final label = _harness.compactionProvider == null
          ? (_harness.providerLabel ?? 'unknown')
          : (provider?.name ?? provider?.id ?? 'unknown');
      _usageLedger.record(
        key: 'compaction_${DateTime.now().microsecondsSinceEpoch}',
        provider: label,
        model: model,
        usage: usage,
      );
    };
    // 大画布领域控制器：宿主回调经 _StudioBoardHost 最小接口接入
    board = BoardController(
      host: _StudioBoardHost(this),
      repository: _repository,
    );
  }

  /// 安卓公共图库导出钩子：自动保存的成品同步写入用户可见的公共目录。
  ///
  /// 优先写入用户自选的 SAF 导出目录 (含命名模板子目录)；未选择或授权
  /// 失效时回退系统媒体库 `Pictures/NovelAI/<子目录>`。写入失败由仓储
  /// 捕获吞掉，不阻塞落图主流程。
  void _syncGalleryExportHook() {
    final mediaStore = MediaStoreService.instance;
    if (!mediaStore.isSupported || !_config.androidGalleryExport) {
      _repository.galleryExportFn = null;
      return;
    }
    final treeUri = _config.androidExportTreeUri;
    _repository.galleryExportFn = (bytes, relativePath) async {
      if (treeUri.isNotEmpty) {
        try {
          await mediaStore.saveImageToDirectory(bytes, treeUri, relativePath);
          return;
        } on MediaStoreException {
          // 自选目录授权失效或写入失败：回退默认图库，保证成品始终可见
        }
      }
      final dir = p.dirname(relativePath);
      await mediaStore.saveImage(
        bytes,
        p.basename(relativePath),
        subDir: (dir == '.' || dir.isEmpty) ? 'NovelAI' : 'NovelAI/$dir',
      );
    };
  }

  // ------------------------- 初始化 -------------------------

  /// 初始化 Studio
  Future<void> init() async {
    // 安卓存储目录探测失败时降级为容错加载，配合下方 storageDegraded 横幅提示，
    // 而不是在启动阶段直接抛出到 runApp 之前。
    var storageDegraded = false;
    try {
      _config = await _configService.loadConfig();
    } catch (_) {
      storageDegraded = true;
      try {
        _config = await _configService.loadConfigTolerant();
      } catch (_) {
        _config = const AppConfig();
      }
    }
    NetworkProxyService.instance.configureFromConfig(_config);
    _favoriteImageIds
      ..clear()
      ..addAll(await _configService.loadFavoriteImageIds());
    _libraryDir = await _configService.loadLibraryDir();
    await ensureLibraryDir();
    _favoriteSourceIds
      ..clear()
      ..addAll(await _configService.loadFavoriteSourceIds());
    _stripStealth = await _configService.loadStripStealth();
    unawaited(_cleanupStaleCache());
    ImagePrivacySettings.stripStealth = _stripStealth;
    ImagePrivacySettings.stripMetadata = _config.stripMetadata;
    var accountsLoadFailed = false;
    try {
      _accounts = await AccountStore.instance.loadAccounts();
    } on AccountStoreException catch (error) {
      // 读取失败绝不能被当成“空账号池”：保留原文件，等用户修复/确认。
      accountsLoadFailed = true;
      _accounts = const <NaiAccount>[];
      if (!error.unavailable) {
        _errorMessage = '账号池读取失败（已保留原文件，未覆盖）：${error.message}';
      }
      debugPrint('账号池读取失败: $error');
    }
    _activeAccountId = await AccountStore.instance.loadActiveId();
    _accountMode = await AccountStore.instance.loadMode();
    final savedWd14Endpoint = await _configService.loadWd14Endpoint();
    if (savedWd14Endpoint.trim().isNotEmpty) _wd14Endpoint = savedWd14Endpoint;
    _wd14Token = await _configService.loadWd14Token();
    _wd14Threshold = await _configService.loadWd14Threshold();
    _chatQueuePaused = await _configService.loadChatQueuePaused();
    _batchCount = await _configService.loadBatchCount();
    _activeStylePresetId = await _configService.loadStylePresetId();
    _stylePresets
      ..clear()
      ..addAll(
        (await _configService.loadStylePresets())
            .map(StylePreset.decode)
            .toList(growable: false),
      );
    // 重启后按已选画风组重新写入附加段，避免只显示灰色文本但不参与生成。
    final restoredStyle = activeStylePreset;
    if (restoredStyle != null) {
      _params = _params.copyWith(
        stylePositive: restoredStyle.positive,
        styleNegative: restoredStyle.negative,
        styleTagsInMetadata: restoredStyle.styleInMetadata,
      );
    }
    try {
      _chatQueue
        ..clear()
        ..addAll(await ChatQueueStore.instance.load());
    } on Object {
      // 数据库不可用时忽略（测试环境没有 path_provider）
    }
    _defaultAccountId = await AccountStore.instance.loadDefaultId();
    if (_accounts.isEmpty && !accountsLoadFailed) {
      if (_config.novelAiKey.trim().isNotEmpty) {
        _accounts = <NaiAccount>[
          NaiAccount(id: 'default', label: '默认账号', apiKey: _config.novelAiKey),
        ];
        _activeAccountId = 'default';
        await _persistAccounts();
      }
    } else if (!accountsLoadFailed) {
      final active = _accounts
          .where((item) => item.id == _activeAccountId)
          .firstOrNull;
      final fallback =
          _accounts.where((item) => item.id == _defaultAccountId).firstOrNull ??
          _accounts.first;
      final effective = active ?? fallback;
      _activeAccountId = effective.id;
      if (effective.apiKey.trim().isNotEmpty &&
          effective.apiKey != _config.novelAiKey) {
        _config = _config.copyWith(novelAiKey: effective.apiKey);
      } else if (effective.apiKey.trim().isEmpty &&
          _config.novelAiKey.trim().isNotEmpty) {
        // 旧数据没有存下密钥时，用工作台当前密钥回填账号池。
        final index = _accounts.indexWhere((item) => item.id == effective.id);
        if (index >= 0) {
          _accounts = List<NaiAccount>.from(_accounts)
            ..[index] = _accounts[index].copyWith(apiKey: _config.novelAiKey);
          await _persistAccounts();
        }
      }
    }
    _memoryEntries
      ..clear()
      ..addAll(await _configService.loadMemoryEntries());
    _memoryEntrySessions
      ..clear()
      ..addAll(await _configService.loadMemoryEntrySessions());
    _chatBranches
      ..clear()
      ..addAll(
        (await _configService.loadChatBranches())
            .map(chatBranchFromJson)
            .where((branch) => branch.id.isNotEmpty),
      );
    _memoryEntrySessions.removeWhere(
      (text, _) => !_memoryEntries.contains(text),
    );
    _reflections.clear();
    try {
      _reflections.addAll(await ReflectionStore.instance.list());
    } on Object {
      // 数据库不可用时回退为空（测试环境没有 path_provider）。
    }
    if (_reflections.isEmpty) {
      final legacy = await _configService.loadReflectionEntries();
      for (final raw in legacy) {
        try {
          final entry = ReflectionEntry.decode(raw);
          await ReflectionStore.instance.upsert(entry);
          _reflections.add(entry);
        } on Object {
          // 跳过无法迁移的旧条目
        }
      }
      if (legacy.isNotEmpty) {
        await _configService.saveReflectionEntries(const <String>[]);
      }
    }
    _syncVmLocale();
    if (storageDegraded) {
      reportError(
        vmL10n.bootStorageFallbackBanner,
        source: AppNoticeSource.storage,
        level: AppNoticeLevel.warning,
        notify: false,
      );
    }
    _syncGalleryExportHook();
    final lastPrompt = await _configService.loadLastPrompt();
    final applyFixed = await _configService.loadApplyFixedPrompts();

    // 加载页面布局状态
    final (leftWidth, rightWidth) = await _configService.loadSplitWidths();
    _splitLeftWidth = leftWidth;
    _splitRightWidth = rightWidth;

    final savedTabName = await _configService.loadSidebarActiveTab();
    _activeSidebarTab = switch (savedTabName) {
      'prompts' => StudioSidebarTab.prompts,
      'inpaint' => StudioSidebarTab.inpaint,
      'library' => StudioSidebarTab.library,
      'sources' => StudioSidebarTab.sources,
      _ => StudioSidebarTab.parameters,
    };
    if (_activeSidebarTab == StudioSidebarTab.parameters ||
        _activeSidebarTab == StudioSidebarTab.prompts) {
      _tabBeforeInpaint = _activeSidebarTab;
    }

    _promptTabbedMode = await _configService.loadPromptTabbedMode();
    _promptActiveTab = await _configService.loadPromptActiveTab();
    _deckActiveTab = await _configService.loadDeckActiveTab();
    _canvasHistoryOpen = await _configService.loadCanvasHistoryOpen();
    _leftSidebarCollapsed = await _configService.loadLeftSidebarCollapsed();

    // 加载提示词输入框高度
    final promptHeights = await _configService.loadPromptFieldHeights();
    _promptHeightStacked = promptHeights.promptStacked;
    _negativePromptHeightStacked = promptHeights.negativeStacked;
    _promptHeightTabbed = promptHeights.promptTabbed;
    _negativePromptHeightTabbed = promptHeights.negativeTabbed;
    _prefixPromptHeight = promptHeights.prefix;
    _suffixPromptHeight = promptHeights.suffix;
    _characterPromptHeight = promptHeights.characterPrompt;
    _characterNegativePromptHeight = promptHeights.characterNegative;

    // 加载 Agent 对话草稿
    _chatDraft = await _configService.loadChatDraft();

    // 加载词组合库
    await loadPromptLibrary();

    _currentThinkingEffort =
        _config.activeLlmProvider.activeModel.defaultThinkingEffort;

    final legacyParams = NaiGenerationParams(
      prompt: lastPrompt,
      negativePrompt: _config.negativePrompt,
      model: _config.defaultModel,
      width: _config.customWidth,
      height: _config.customHeight,
      steps: _config.defaultSteps,
      scale: _config.defaultScale,
      cfgRescale: _config.defaultCfgRescale,
      sampler: _config.defaultSampler,
      noiseSchedule: _config.defaultNoiseSchedule,
      prefixPrompt: _config.prefixPrompt,
      suffixPrompt: _config.suffixPrompt,
      applyFixedPrompts: applyFixed,
      characterPrompts: await _configService.loadCharacterPrompts(),
      characterAiPosition: await _configService.loadCharacterAiPosition(),
      seedMode: await _configService.loadSeedMode(),
      seedTiming: await _configService.loadSeedTiming(),
    );
    final savedParams = await _configService.loadStudioParameters(legacyParams);
    _params = _withActiveStyle(savedParams.generation);
    _inpaintParams = savedParams.inpaint;
    _hasRestoredParameterState = true;
    // 恢复模型后再预载，避免启动时错误加载出厂模型的分词器。
    unawaited(_precachePromptTokenizers());

    // 参数时间轴基线：后续每轮对话发出前再各记一次快照，供回溯时回滚
    _paramJournal.reset(_params);

    // 设置初始预设
    _harness.setPreset(_config.activePreset);

    _setupHarnessAndTools();
    unawaited(_mcpManager.syncConfigs(_config.mcpServers));

    // 初始化会话日志并续接上次对话 (Pi --continue 语义)
    // 本地 fork：会话管理上限与保留天数来自设置页
    _sessionLog
      ..maxSessions = _config.sessionMaxCount
      ..retentionDays = _config.sessionRetentionDays;
    try {
      await _sessionLog.init(baseDir: _sessionLogBaseDir);
      await _usageLedger.init(baseDir: _sessionLog.baseDirPath);
      await _notificationLog.init(baseDir: _sessionLog.baseDirPath);
      final snapshot = await _sessionLog.loadLatestSessionAsync();
      if (snapshot != null && snapshot.messages.isNotEmpty) {
        _harness.restoreMessages(snapshot.messages);
        _harness.restoreContextState(_sessionLog.loadContextState());
        _sessionModelUsage = {
          for (final e in snapshot.sessionUsage.entries)
            displayNameForModelKey(e.key): e.value,
        };
      }
      _sessionLog.recordModelChange(
        _config.activeLlmProvider.id,
        _config.activeLlmProvider.activeModel.id,
      );
      _sessionLog.recordThinkingLevelChange(_currentThinkingEffort.id);
      await refreshSessions();
    } catch (_) {
      if (!storageDegraded) rethrow;
    }

    // 加载持久化的图像历史
    if (_config.enableImagePersistence && _config.saveDirectory.isNotEmpty) {
      await _repository.loadPersistedHistory(
        saveDir: _config.saveDirectory,
        maxImages: _config.maxPersistentImages,
        includeThumbnails: false,
      );
      unawaited(
        _repository.loadHistoryThumbnails(
          saveDir: _config.saveDirectory,
          onUpdated: _notifyHistoryThumbnails,
        ),
      );
      if (_repository.history.isNotEmpty && _selectedImage == null) {
        _selectedImage = _repository.history.first;
        unawaited(ensureImageLoaded(_selectedImage!));
        _scheduleAdaptiveAccent(_selectedImage!);
      }

      // 恢复大画布布局 (节点位置尺寸/便利贴/连线/视口)
      final restoredBoard = await _repository.loadBoardLayout(
        saveDir: _config.saveDirectory,
      );
      if (restoredBoard != null &&
          (restoredBoard.imageNodes.isNotEmpty ||
              restoredBoard.noteNodes.isNotEmpty)) {
        board.restoreLayout(restoredBoard);
      }
    }

    notifyListeners();

    unawaited(_promptAndroidStoragePermissionOnce());

    // 后台加载账号信息
    if (_config.novelAiKey.isNotEmpty) {
      await refreshAccountInfo();
    }

    // 后台应用已安装的在线词库并按开关静默检查更新 (24 小时节流，不阻塞启动)
    unawaited(() async {
      await TagDictionaryUpdateService.instance.applyInstalledAtStartup();
      await TagDictionaryUpdateService.instance.maybeAutoUpdate(
        enabled: _config.enableTagDictionaryAutoUpdate,
      );
    }());
  }

  /// Android 首次启动时引导申请图片/存储运行时权限（非阻塞：拒绝仍可正常进入）。
  Future<void> _promptAndroidStoragePermissionOnce() async {
    final mediaStore = MediaStoreService.instance;
    if (!mediaStore.isSupported) return;
    try {
      if (await mediaStore.hasStoragePermission()) return;
      if (await _configService.hasPromptedAndroidStoragePermission()) return;
      await _configService.markAndroidStoragePermissionPrompted();
      await mediaStore.requestStoragePermission();
    } catch (_) {
      // 权限通道异常不阻塞工作台运行
    }
  }

  void _notifyHistoryThumbnails() {
    if (!_disposed) notifyListeners();
  }

  // ------------------------- 配置 -------------------------

  void _syncVmLocale() {
    _vmLocale = switch (_config.localePreference) {
      AppLocalePreference.zh => const Locale('zh'),
      AppLocalePreference.en => const Locale('en'),
      AppLocalePreference.system => _resolveSystemLocale(),
    };
  }

  /// 解析 system 档位下的平台首选语言 (仅支持 zh/en，未知回退 zh)
  Locale _resolveSystemLocale() {
    final platform = PlatformDispatcher.instance.locale;
    final matched = AppLocalizations.supportedLocales
        .where((l) => l.languageCode == platform.languageCode)
        .firstOrNull;
    return matched ?? const Locale('zh');
  }

  /// 保存全局配置
  @override
  Future<void> updateConfig(AppConfig newConfig) async {
    _sessionLog
      ..maxSessions = newConfig.sessionMaxCount
      ..retentionDays = newConfig.sessionRetentionDays;
    final oldConfig = _config;
    if (newConfig.saveDirectory != oldConfig.saveDirectory) {
      newConfig = newConfig.copyWith(
        saveDirectory: await _configService.resolveImageSaveDirectory(
          newConfig.saveDirectory,
        ),
      );
    }
    _config = newConfig;
    _syncGalleryExportHook();
    NetworkProxyService.instance.configureFromConfig(newConfig);
    // 主题模式即时生效：MaterialApp 根节点监听全局控制器局部刷新，
    // 200ms 平滑切色，不走 notifyListeners 全局重绘
    AppThemeModeController.instance.syncFromConfig(newConfig);
    // 强调色同步：MD3 自适应取色即时生效 (同样只重建主题层)
    AppAccentController.instance.syncFromConfig(newConfig);
    // 模式或方案变化时按当前展示图立即重取/重应用种子
    if (oldConfig.accentMode != newConfig.accentMode ||
        oldConfig.accentVariant != newConfig.accentVariant) {
      _lastAccentImageId = null;
      final current = _selectedImage;
      if (current != null) {
        _scheduleAdaptiveAccent(current);
      }
    }
    // 语言同理：根级 ValueListenableBuilder 局部接管，不全局重绘
    AppLocaleController.instance.syncFromConfig(newConfig);
    // VM 侧消息文案同步跟随语言设置 (system 跟随平台首选语言)
    _syncVmLocale();
    // UI 缩放同理：根级 ValueListenableBuilder 局部接管，不全局重绘
    AppUiZoomController.instance.syncFromConfig(newConfig);
    // 帧率上限同理：AppWidgetsFlutterBinding 监听即时生效，不触发全树重建
    AppFrameRateController.instance.syncFromConfig(newConfig);
    // ComfyUI 模式：开关或地址变化时刷新 Bridge 连接状态
    if (newConfig.comfyUiEnabled != oldConfig.comfyUiEnabled ||
        newConfig.comfyUiBaseUrl != oldConfig.comfyUiBaseUrl) {
      if (newConfig.comfyUiEnabled) {
        unawaited(refreshComfyUiStatus());
      } else {
        _comfyStatus = ComfyUiConnectionStatus.disconnected;
        _comfyBridgeState = null;
      }
    }
    _applyChangedGenerationDefaults(oldConfig, newConfig);
    notifyListeners();
    _configSaveDebounceTimer?.cancel();
    _lastConfigSave = _configService.saveConfig(newConfig);
    await _lastConfigSave;

    // 仅在生效供应商/模型真正变化时才重置思考强度；
    // 保存无关设置 (如存储目录) 不应吞掉用户在对话卡选定的强度
    final oldActive = oldConfig.activeLlmProvider;
    final newActive = newConfig.activeLlmProvider;
    final llmChanged =
        oldActive.id != newActive.id ||
        oldActive.activeModelId != newActive.activeModelId;
    if (llmChanged) {
      _currentThinkingEffort = newActive.activeModel.defaultThinkingEffort;
    }
    _setupHarnessAndTools();
    unawaited(_mcpManager.syncConfigs(_config.mcpServers));

    // 同步图片持久化状态与上限调整
    if (newConfig.enableImagePersistence != oldConfig.enableImagePersistence ||
        newConfig.maxPersistentImages != oldConfig.maxPersistentImages ||
        newConfig.saveDirectory != oldConfig.saveDirectory) {
      if (newConfig.enableImagePersistence &&
          newConfig.saveDirectory.isNotEmpty) {
        if (_repository.history.isEmpty) {
          await _repository.loadPersistedHistory(
            saveDir: newConfig.saveDirectory,
            maxImages: newConfig.maxPersistentImages,
          );
          if (_repository.history.isNotEmpty && _selectedImage == null) {
            _selectedImage = _repository.history.first;
            unawaited(ensureImageLoaded(_selectedImage!));
            _scheduleAdaptiveAccent(_selectedImage!);
          }
        } else {
          await _repository.savePersistedHistory(
            saveDir: newConfig.saveDirectory,
            maxImages: newConfig.maxPersistentImages,
            enabled: true,
          );
        }
      } else if (!newConfig.enableImagePersistence &&
          newConfig.saveDirectory.isNotEmpty) {
        // 仅停止持久化，不删除已有 image_history.json 与画布布局：
        // 关闭开关就销毁历史索引等于破坏性删除用户数据，重新打开开关后应能继续恢复
        board.discardLayout();
      }
    }

    notifyListeners();

    // 仅在 NovelAI API Key 发生变更时刷新账号，避免调整参数/水印时频繁请求网络
    final keyChanged =
        oldConfig.novelAiKey.trim() != newConfig.novelAiKey.trim();
    if (keyChanged) {
      _accountInfo = null;
      notifyListeners();
      if (_config.novelAiKey.trim().isNotEmpty) {
        await refreshAccountInfo(showError: true);
      }
    }
  }

  /// 用户显式修改默认参数时应用改动项；保存主题等无关设置不能重置工作台。
  void _applyChangedGenerationDefaults(AppConfig old, AppConfig next) {
    if (old.defaultModel == next.defaultModel &&
        old.defaultSampler == next.defaultSampler &&
        old.defaultNoiseSchedule == next.defaultNoiseSchedule &&
        old.customWidth == next.customWidth &&
        old.customHeight == next.customHeight &&
        old.defaultSteps == next.defaultSteps &&
        old.defaultScale == next.defaultScale &&
        old.defaultCfgRescale == next.defaultCfgRescale &&
        old.negativePrompt == next.negativePrompt &&
        old.prefixPrompt == next.prefixPrompt &&
        old.suffixPrompt == next.suffixPrompt) {
      return;
    }
    updateParams(
      _params.copyWith(
        model: old.defaultModel != next.defaultModel ? next.defaultModel : null,
        sampler: old.defaultSampler != next.defaultSampler
            ? next.defaultSampler
            : null,
        noiseSchedule: old.defaultNoiseSchedule != next.defaultNoiseSchedule
            ? next.defaultNoiseSchedule
            : null,
        width: old.customWidth != next.customWidth ? next.customWidth : null,
        height: old.customHeight != next.customHeight
            ? next.customHeight
            : null,
        steps: old.defaultSteps != next.defaultSteps ? next.defaultSteps : null,
        scale: old.defaultScale != next.defaultScale ? next.defaultScale : null,
        cfgRescale: old.defaultCfgRescale != next.defaultCfgRescale
            ? next.defaultCfgRescale
            : null,
        negativePrompt: old.negativePrompt != next.negativePrompt
            ? next.negativePrompt
            : null,
        prefixPrompt: old.prefixPrompt != next.prefixPrompt
            ? next.prefixPrompt
            : null,
        suffixPrompt: old.suffixPrompt != next.suffixPrompt
            ? next.suffixPrompt
            : null,
      ),
    );
  }

  /// 关闭前冲刷工作台、布局、全局配置与对话日志，不能只 cancel 防抖计时器。
  Future<void> flushPendingSaves() async {
    if (_isRtxUpscaling) {
      _repository.cancelRtxUpscale();
      // 等待子进程退出及临时原图清理，再允许销毁窗口。
      await _rtxOperation;
    }
    // 启动尚未读完偏好时直接关闭：保留磁盘原值，不用空工作台覆盖它，
    // 也不等待初始化尾部的账号网络查询才能退出。
    if (!_hasRestoredParameterState) return;
    await _skillWriteQueue;
    await flushPendingParameterSave();
    await flushPendingLayoutSave();
    _uiZoomSaveTimer?.cancel();
    await _configService.saveUiZoom(_config.uiZoom);
    _configSaveDebounceTimer?.cancel();
    await _lastConfigSave;
    await _configService.saveConfig(_config);
    await Future.wait([
      _sessionLog.flush(),
      _usageLedger.flush(),
      _notificationLog.flush(),
      _repository.flushPendingImageLoads(),
    ]);
  }

  /// 防抖保存全局配置 (避免滑块/高频拖拽频繁写盘)
  void _debounceSaveConfig() {
    _configSaveDebounceTimer?.cancel();
    _configSaveDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _lastConfigSave = _configService.saveConfig(_config);
    });
  }

  /// 切换 V5 Full 算力档位。已保存的步数、采样器、重缩放和排除词保持不变，
  /// 切回通常档后恢复；其它模型没有这个开关。
  void setEffort(NaiEffort effort) {
    if (!_params.supportsEffort || _params.effort == effort) return;
    updateParams(_params.copyWith(effort: effort));
  }

  /// 切换模型并跟随官方出厂默认值。
  ///
  /// CFG 与步数只在用户未手动调整 (仍停留在旧模型出厂默认) 时才跟随新模型默认，
  /// 手动调过的一律保留；切到 v4+ 时 Native 噪声调度不合法，自动回落 Karras。
  void selectModel(NaiModel model) {
    final old = _params;
    // 切到不同分词器家族时预载对应词表 (幂等)
    if (model.tokenizerKind != old.model.tokenizerKind) {
      unawaited(_precachePromptTokenizers(model));
    }
    final scaleUntouched = (old.scale - old.model.defaultScale).abs() < 0.001;
    // 28 为本应用历史全局默认步数，视同未手动调整
    final stepsUntouched =
        old.steps == old.model.defaultSteps || old.steps == 28;
    final nativeInvalid =
        model.isV4OrAbove && old.noiseSchedule == NoiseSchedule.native;

    updateParams(
      _params.copyWith(
        model: model,
        scale: scaleUntouched && model.defaultScale != old.model.defaultScale
            ? model.defaultScale
            : null,
        steps: stepsUntouched && model.defaultSteps != old.model.defaultSteps
            ? model.defaultSteps
            : null,
        noiseSchedule: nativeInvalid ? NoiseSchedule.karras : null,
        // 模型切换后质量词档位可能不再有效 (Light 仅 V5)
        qualityPreset: _params.qualityPreset == 'Light' && !model.isV5
            ? 'Standard'
            : null,
      ),
    );
  }

  // ------------------------- 画板选图 -------------------------

  /// 预载当前 (或指定) 模型的提示词分词器；完成后通知重建，
  /// 提示词卡片的 token 计数从启发式估算切到真分词结果。
  Future<void> _precachePromptTokenizers([NaiModel? model]) async {
    final target = model ?? _params.model;
    try {
      await PromptTokenCounterService.instance.precache(target);
    } catch (error) {
    debugPrint('[ignored] $error');
      // 词表资产缺失时不阻断启动，计数保持启发式估算
      return;
    }
    if (!_disposed && _params.model.tokenizerKind == target.tokenizerKind) {
      notifyListeners();
    }
  }

  /// 选择画板当前查看的图片
  void selectImage(NaiGeneratedImage image) {
    _selectedImage = image;
    ensureImageLoaded(image);
    _scheduleAdaptiveAccent(image);
    if (gallery.isNotEmpty && image.id == gallery.first.id) {
      _hasUnseenLatest = false;
    }
    // 批注模式下不重置大画布：
    // 重置会清空用户手工摆放的参考图、便利贴与连线布局
    notifyListeners();
  }

  /// 快速查看最新生成的图片并消除提示气泡
  void selectLatestImage() {
    if (gallery.isNotEmpty) {
      _selectedImage = gallery.first;
      ensureImageLoaded(gallery.first);
      _scheduleAdaptiveAccent(gallery.first);
      _hasUnseenLatest = false;
      notifyListeners();
    }
  }

  /// 自适应取色：后台提取指定图片主色并注入主题强调色
  ///
  /// 仅 accentMode == adaptive 时生效；按图片 id 去重 (含 LRU 缓存)，
  /// fire-and-forget 不阻塞选图/生图主流程；结果回来时校验该图
  /// 仍是当前展示图，避免快速切换图片时旧结果覆盖新种子。
  @override
  void _scheduleAdaptiveAccent(NaiGeneratedImage image) {
    if (_config.accentMode != AppAccentMode.adaptive) return;
    if (_lastAccentImageId == image.id) return;
    _lastAccentImageId = image.id;
    unawaited(() async {
      try {
        final bytes = await ensureImageLoaded(image) ?? image.bytes;
        if (bytes.isEmpty) return;
        final palette = await PaletteService.instance.extract(
          bytes,
          cacheKey: image.id,
        );
        if (palette == null) return;
        if (_disposed || _selectedImage?.id != image.id) return;
        AppAccentController.instance.applyAdaptiveSeed(Color(palette.seed));
      } catch (error) {
    debugPrint('[ignored] $error');
        // 取色失败静默降级：保持当前主题不变
      }
    }());
  }

  /// 将指定色设为手动主题强调色种子 (调色盘面板调用，立即生效并落盘)
  void setManualAccentSeed(Color seed) {
    unawaited(
      updateConfig(
        _config.copyWith(
          accentMode: AppAccentMode.manual,
          accentSeedColor: seedColorText(seed.toARGB32()),
        ),
      ),
    );
  }

  /// 关闭新图片提示气泡
  void dismissUnseenBanner() {
    _hasUnseenLatest = false;
    notifyListeners();
  }

  /// 从历史记录中删除单张图片并同步持久化
  Future<void> deleteImageFromHistory(String imageId) async {
    final deletedIndex = gallery.indexWhere((img) => img.id == imageId);
    if (deletedIndex < 0) return;

    final wasSelected = _selectedImage?.id == imageId;
    await _repository.deleteImage(
      imageId: imageId,
      saveDir: _config.saveDirectory,
      enablePersistence: _config.enableImagePersistence,
      maxImages: _config.maxPersistentImages,
    );

    if (wasSelected) {
      if (gallery.isNotEmpty) {
        final nextIndex = deletedIndex < gallery.length
            ? deletedIndex
            : gallery.length - 1;
        _selectedImage = gallery[nextIndex];
        unawaited(ensureImageLoaded(_selectedImage!));
        _scheduleAdaptiveAccent(_selectedImage!);
      } else {
        _selectedImage = null;
      }
    }

    if (gallery.isEmpty ||
        (_selectedImage != null && _selectedImage!.id == gallery.first.id)) {
      _hasUnseenLatest = false;
    }

    // 同步大画布节点 (若大画布已加载)：主图节点替换为新选中图，其余删除
    board.pruneHistoryNodes({imageId}, mainReplacement: _selectedImage);

    _statusMessage = vmL10n.vmHistoryDeleted;
    notifyListeners();
  }

  /// 一键清空全部历史图片 (右键菜单)：删除本地文件与持久化索引，
  /// 同步移除大画布上来自历史的图片节点 (保留外部导入的参考卡片与自由便利贴，
  /// 指向已删节点的连线/便签连接同步解绑)
  Future<void> clearImageHistory() async {
    if (gallery.isEmpty) return;

    final historyIds = gallery.map((img) => img.id).toSet();
    await _repository.clearAllHistory(
      saveDir: _config.saveDirectory,
      enablePersistence: _config.enableImagePersistence,
      autoSave: _config.autoSaveImages,
    );

    _selectedImage = null;
    _hasUnseenLatest = false;

    // 同步大画布：移除来自历史的图片节点 (保留外部导入的参考卡片与自由便利贴，
    // 指向已删节点的连线/便签连接同步解绑)
    board.pruneHistoryNodes(historyIds);

    _statusMessage = vmL10n.vmHistoryCleared;
    notifyListeners();
  }

  // ------------------------- 元数据与水印设置 -------------------------

  bool get stripMetadata => _config.stripMetadata;
  bool get enableWatermark => _config.enableWatermark;
  bool get autoSaveImages => _config.autoSaveImages;
  bool get keepOriginalImage => _config.keepOriginalImage;
  WatermarkConfig get watermarkConfig => _config.watermarkConfig;
  bool get isEditingWatermarkPosition => _isEditingWatermarkPosition;

  void setEditingWatermarkPosition(bool editing) {
    if (_isEditingWatermarkPosition == editing) return;
    _isEditingWatermarkPosition = editing;
    if (editing) {
      if (_isEditingCharacterPositions) {
        _isEditingCharacterPositions = false;
      }
      board.exitAnnotatingModeQuietly();
    }
    notifyListeners();
  }

  void setStripMetadata(bool value) {
    ImagePrivacySettings.stripMetadata = value;
    if (_config.stripMetadata == value) return;
    _config = _config.copyWith(stripMetadata: value);
    notifyListeners();
    _debounceSaveConfig();
  }

  void setEnableWatermark(bool value) {
    if (_config.enableWatermark == value) return;
    _config = _config.copyWith(enableWatermark: value);
    notifyListeners();
    _debounceSaveConfig();
  }

  void setKeepOriginalImage(bool value) {
    if (_config.keepOriginalImage == value) return;
    _config = _config.copyWith(keepOriginalImage: value);
    notifyListeners();
    _debounceSaveConfig();
  }

  void updateWatermarkConfig(WatermarkConfig watermarkConfig) {
    _config = _config.copyWith(watermarkConfig: watermarkConfig);
    notifyListeners();
    _debounceSaveConfig();
  }

  /// 基于当前画板图像智能计算低信息区域水印位置并应用到配置
  ///
  /// 返回是否成功 (画板无图或解析失败时返回 false)。
  Future<bool> applySmartWatermarkPosition() async {
    final source =
        _selectedImage ?? (gallery.isNotEmpty ? gallery.first : null);
    if (source == null) return false;
    final bytes = await ensureImageLoaded(source) ?? source.bytes;
    if (bytes.isEmpty) return false;
    final config = _config.watermarkConfig;
    try {
      final (
        posX,
        posY,
      ) = await WatermarkService.findLowInformationPositionAsync(
        bytes,
        scalePercent: config.scalePercent,
        marginPercent: config.marginPercent,
        watermarkBytes: config.imageBytes,
      );
      updateWatermarkConfig(config.copyWith(posX: posX, posY: posY));
      return true;
    } catch (error) {
    debugPrint('[ignored] $error');
      return false;
    }
  }

  Future<void> setWatermarkImageBytes(Uint8List bytes, {String? path}) async {
    final updated = _config.watermarkConfig.copyWith(
      imageBytes: bytes,
      imagePath: path,
    );
    _config = _config.copyWith(watermarkConfig: updated);
    notifyListeners();
    _debounceSaveConfig();
  }

  Future<void> clearWatermarkImage() async {
    final updated = _config.watermarkConfig.copyWith(clearImage: true);
    _config = _config.copyWith(watermarkConfig: updated);
    notifyListeners();
    _debounceSaveConfig();
  }

  /// 仅应用选中的有效元数据；省略选项时保持原有全部回填行为。
  void applyMetadataToWorkbench(
    ImageMetadataResult metadata, {
    Set<MetadataImportField>? fields,
  }) {
    final selected = metadata.importableFields;
    if (fields != null) selected.retainAll(fields);
    if (selected.isEmpty) return;
    bool includes(MetadataImportField field) => selected.contains(field);
    NaiModel? resolvedModel;
    if (metadata.model != null && metadata.model!.isNotEmpty) {
      try {
        resolvedModel = NaiModel.fromId(metadata.model!);
      } catch (error) {
    debugPrint('[ignored] $error');}
    }

    NaiSampler? resolvedSampler;
    if (metadata.sampler != null && metadata.sampler!.isNotEmpty) {
      try {
        resolvedSampler = NaiSampler.fromId(metadata.sampler!);
      } catch (error) {
    debugPrint('[ignored] $error');}
    }

    NoiseSchedule? resolvedSchedule;
    if (metadata.noiseSchedule != null && metadata.noiseSchedule!.isNotEmpty) {
      try {
        resolvedSchedule = NoiseSchedule.fromId(metadata.noiseSchedule!);
      } catch (error) {
    debugPrint('[ignored] $error');}
    }

    // 转换角色提示词
    List<NaiCharacterPrompt>? charPrompts;
    if (metadata.characterPrompts.isNotEmpty) {
      charPrompts = [];
      for (var i = 0; i < metadata.characterPrompts.length; i++) {
        final p = metadata.characterPrompts[i];
        final uc = (i < metadata.characterNegativePrompts.length)
            ? metadata.characterNegativePrompts[i]
            : '';
        charPrompts.add(
          NaiCharacterPrompt(
            id: 'char_${DateTime.now().millisecondsSinceEpoch}_$i',
            name: vmL10n.vmCharacterDefaultName(i + 1),
            prompt: p,
            negativePrompt: uc,
          ),
        );
      }
    }

    final newParams = _params.copyWith(
      prompt: includes(MetadataImportField.prompt) ? metadata.prompt : null,
      negativePrompt: includes(MetadataImportField.negativePrompt)
          ? metadata.negativePrompt
          : null,
      model: includes(MetadataImportField.model) ? resolvedModel : null,
      effort:
          includes(MetadataImportField.model) &&
              metadata.model != null &&
              metadata.model!.isNotEmpty
          ? NaiEffort.fromModelId(metadata.model!)
          : null,
      sampler: includes(MetadataImportField.sampler) ? resolvedSampler : null,
      noiseSchedule: includes(MetadataImportField.noiseSchedule)
          ? resolvedSchedule
          : null,
      width:
          includes(MetadataImportField.resolution) && (metadata.width ?? 0) > 0
          ? metadata.width
          : null,
      height:
          includes(MetadataImportField.resolution) && (metadata.height ?? 0) > 0
          ? metadata.height
          : null,
      steps: includes(MetadataImportField.steps) ? metadata.steps : null,
      scale: includes(MetadataImportField.scale) ? metadata.scale : null,
      cfgRescale: includes(MetadataImportField.cfgRescale)
          ? metadata.cfgRescale
          : null,
      seed: includes(MetadataImportField.seed) ? metadata.seed : null,
      qualityToggle: includes(MetadataImportField.quality)
          ? metadata.qualityToggle
          : null,
      qualityPreset: includes(MetadataImportField.quality)
          ? metadata.qualityPreset
          : null,
      ucPresetKey: includes(MetadataImportField.ucPreset)
          ? metadata.ucPreset
          : null,
      transparentBg: includes(MetadataImportField.transparentBackground)
          ? metadata.transparentBackground
          : null,
      characterPrompts: includes(MetadataImportField.characters)
          ? charPrompts
          : null,
    );

    updateParams(newParams);
    _statusMessage = vmL10n.vmMetadataApplied;
    notifyListeners();
  }

  // ------------------------- 杂项状态 -------------------------

  /// Ctrl+O: 切换对话卡思考块全局展开/折叠
  void toggleThinkingExpanded() {
    _isThinkingExpanded = !_isThinkingExpanded;
    notifyListeners();
  }

  void clearStatus() {
    _statusMessage = null;
    notifyListeners();
  }

  @visibleForTesting
  void setMessagesForTesting(List<AgentMessage> messages) {
    _harness.setMessages(messages);
    notifyListeners();
  }

  /// BoardController 宿主回调专用：借用全局广播刷新 UI。
  /// 独立适配器类不是 ChangeNotifier 子类，不能直接触 protected 的
  /// notifyListeners，统一经本转发入口。
  void _notifyFromBoard() {
    notifyListeners();
  }

  @visibleForTesting
  void setChatStreamingForTesting(bool streaming) {
    _isChatStreaming = streaming;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    // 大量异步尾部（账号刷新、生图收尾、资料库扫描）可能在 dispose 后返回；
    // 统一在这里拦截，避免 debug 断言崩溃与 release 下的无效重建。
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _previewDisposed = true;
    inpaintPreviewNotifier.dispose();
    _rtxDisposed = true;
    if (_ownsRepository) {
      _repository.dispose();
    } else {
      _repository.cancelRtxUpscale();
    }
    _comfyService?.close();
    _comfyService = null;
    unawaited(_mcpManager.dispose());
    mcpStateNotifier.dispose();
    _harness.dispose();
    _llmHttpClient.close();
    _generationSubscription?.cancel();
    _paramSaveDebounceTimer?.cancel();
    _configSaveDebounceTimer?.cancel();
    _splitWidthSaveTimer?.cancel();
    _uiZoomSaveTimer?.cancel();
    _promptHeightsSaveTimer?.cancel();
    _chatDraftSaveTimer?.cancel();
    _chatSubscription?.cancel();
    // 瞬态控制器随宿主一起释放
    _streamingText.dispose();
    _liveProgressController.dispose();
    bannerController.dispose();
    promptLibraryNotifier.dispose();
    // 大画布领域控制器：内部取消防抖并立即落盘一次 (对齐旧 dispose 契约)
    board.dispose();
    unawaited(_sessionLog.flush());
    unawaited(_notificationLog.flush());
    super.dispose();
  }
}

/// 大画布领域控制器的宿主适配器 (阶段 4D 试点，决策门 §7 契约)：
/// 仅暴露 BoardControllerHost 最小接口，不泄漏 StudioViewModel 全貌；
/// 共享底座 (_selectedImage/_config/字节缓存/全局广播) 经由此层单向供给。
class _StudioBoardHost implements BoardControllerHost {
  _StudioBoardHost(this._vm);

  final StudioViewModel _vm;

  @override
  NaiGeneratedImage? get boardSelectedImage => _vm._selectedImage;

  @override
  void onBoardSelectedImageChanged(NaiGeneratedImage image) {
    // 仅回写选中引用 (不加载字节/不广播)，行为对齐旧 annotations 分部直赋值
    _vm._selectedImage = image;
  }

  @override
  Future<Uint8List?> ensureBoardImageLoaded(NaiGeneratedImage image) =>
      _vm.ensureImageLoaded(image);

  @override
  Future<void> sendChatMessage(
    String text, {
    List<AgentMessageImage>? images,
  }) => _vm.sendChatMessage(text, images: images);

  @override
  void exitOtherCanvasEditModes() {
    if (_vm._isEditingCharacterPositions) {
      _vm._isEditingCharacterPositions = false;
    }
    if (_vm._isEditingWatermarkPosition) {
      _vm._isEditingWatermarkPosition = false;
    }
  }

  @override
  void onBoardStatus(String message) => _vm._statusMessage = message;

  @override
  bool get boardImagePersistenceEnabled => _vm._config.enableImagePersistence;

  @override
  String get boardSaveDirectory => _vm._config.saveDirectory;

  @override
  void requestGlobalNotify() => _vm._notifyFromBoard();
}
