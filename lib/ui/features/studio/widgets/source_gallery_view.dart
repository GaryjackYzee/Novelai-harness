import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../data/models/aitag_models.dart';
import '../../../../data/models/danbooru_models.dart';
import '../../../../data/models/nai_image_result.dart';
import '../../../../data/models/codex_models.dart';
import '../../../../data/models/reflection_entry.dart';
import '../../../../data/models/nai_catalog.dart';
import '../../../../data/models/nai_character_prompt.dart';
import '../../../../data/models/source_favorite.dart';
import '../../../../data/services/aitag_service.dart';
import '../../../../data/services/danbooru_favorite_store.dart';
import '../../../../data/services/danbooru_gallery_service.dart';
import '../../../../data/services/source_favorite_store.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/network_proxy_service.dart';
import '../../../../data/services/codex_service.dart';
import '../../../core/context_l10n.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/theme_context_extensions.dart';
import '../../../core/widgets/app_confirm_dialog.dart';
import 'chat_image_attachment.dart';
import 'image_lightbox.dart';
import 'proxy_feature_switch.dart';
import '../view_models/studio_view_model.dart';

/// 卡片缩略图解码宽度：避免每张图都按原始分辨率进 ImageCache。
const int _kThumbDecodeWidth = 600;

/// 图源画廊：AITag 作品与社区法典的瀑布流浏览，支持一键套用到工作台。
class SourceGalleryView extends StatefulWidget {
  const SourceGalleryView({
    super.key,
    required this.viewModel,
    required this.onClose,
    this.aitagService,
    this.codexService,
    this.danbooruService,
    this.sourceFavoriteStore,
    this.danbooruFavoriteStore,
  });

  final StudioViewModel viewModel;
  final VoidCallback onClose;

  /// 以下服务/收藏库仅用于测试注入；为空时使用全局单例。
  final AitagService? aitagService;
  final CodexService? codexService;
  final DanbooruGalleryService? danbooruService;
  final SourceFavoriteStore? sourceFavoriteStore;
  final DanbooruFavoriteStore? danbooruFavoriteStore;

  @override
  State<SourceGalleryView> createState() => _SourceGalleryViewState();
}

class _SourceGalleryViewState extends State<SourceGalleryView> {
  late final AitagService _aitag;
  late final CodexService _codex;
  late final DanbooruGalleryService _danbooru;
  late final DanbooruFavoriteStore _danbooruFavorites;
  late final SourceFavoriteStore _sourceFavorites;
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Map<String, Future<Uint8List>> _thumbs = <String, Future<Uint8List>>{};
  final Map<String, Future<Uint8List>> _codexThumbs =
      <String, Future<Uint8List>>{};
  final Map<String, Future<Uint8List>> _danbooruThumbs =
      <String, Future<Uint8List>>{};

  /// 缩略图缓存上限：无限滚动 + 永久缓存会让内存持续增长。
  static const int _maxCachedThumbs = 120;
  static const int _maxLoadedWorks = 600;

  int _aitagRequestEpoch = 0;
  int _codexRequestEpoch = 0;
  int _danbooruRequestEpoch = 0;

  List<DanbooruPost> _danbooruPosts = <DanbooruPost>[];
  int _danbooruPage = 1;
  bool _danbooruMore = true;
  String _danbooruRating = 'general';
  String _danbooruSize = 'large';
  final Set<int> _danbooruBusy = <int>{};
  final Set<String> _sourceBusy = <String>{};

  /// 发送到聊天框进行中的条目 (scope:id)，避免重复点击叠加请求。
  final Set<String> _chatBusy = <String>{};

  Future<Uint8List> _thumbFor(AitagWork work) {
    final existing = _thumbs.remove(work.id);
    if (existing != null) {
      _thumbs[work.id] = existing;
      return existing;
    }
    final future = _aitag.fetchImage(work.thumbUrl);
    _thumbs[work.id] = future;
    while (_thumbs.length > _maxCachedThumbs) {
      _thumbs.remove(_thumbs.keys.first);
    }
    return future;
  }

  Future<Uint8List> _codexThumbFor(String url) {
    final existing = _codexThumbs.remove(url);
    if (existing != null) {
      _codexThumbs[url] = existing;
      return existing;
    }
    final future = _codex.fetchImage(url);
    _codexThumbs[url] = future;
    while (_codexThumbs.length > _maxCachedThumbs) {
      _codexThumbs.remove(_codexThumbs.keys.first);
    }
    return future;
  }

  Future<Uint8List> _danbooruThumbFor(DanbooruPost post) {
    final key = '${post.id}|$_danbooruSize';
    final existing = _danbooruThumbs.remove(key);
    if (existing != null) {
      _danbooruThumbs[key] = existing;
      return existing;
    }
    final url = switch (_danbooruSize) {
      'thumb' => post.thumbnailUrl,
      'orig' => post.fileUrl ?? post.largeFileUrl ?? post.previewUrl,
      _ => post.largeFileUrl ?? post.fileUrl ?? post.previewUrl,
    };
    final future = url == null
        ? _danbooru.fetchThumbnailBytes(post)
        : _danbooru.fetchUrlBytes(url);
    _danbooruThumbs[key] = future;
    while (_danbooruThumbs.length > _maxCachedThumbs) {
      _danbooruThumbs.remove(_danbooruThumbs.keys.first);
    }
    return future;
  }

  int _tab = 0;

  /// 收藏 tab 内按来源拆分的子页：aitag / codex / danbooru。
  String _favoritesSource = 'aitag';
  bool _loading = false;
  String? _error;

  List<AitagWork> _aitagWorks = <AitagWork>[];
  final Map<String, String> _aitagBadges = <String, String>{};
  int _aitagPage = 1;
  bool _aitagMore = true;

  List<CodexPack> _packs = <CodexPack>[];
  String _packId = 'nai5_community_pack';
  int _localShown = 60;
  bool _favoritesOnly = false;
  List<LibraryMatch>? _libraryMatches;
  bool _librarySearching = false;
  List<CodexEntry> _codexEntries = <CodexEntry>[];
  List<CodexCategory> _codexCategories = <CodexCategory>[];
  String _codexCategory = '';
  int _codexTotal = 0;
  int _codexPage = 1;
  int _codexPages = 1;

  @override
  void initState() {
    super.initState();
    _aitag = widget.aitagService ?? AitagService.instance;
    _codex = widget.codexService ?? CodexService.instance;
    _danbooru = widget.danbooruService ?? DanbooruGalleryService.instance;
    _danbooruFavorites =
        widget.danbooruFavoriteStore ?? DanbooruFavoriteStore.instance;
    _sourceFavorites =
        widget.sourceFavoriteStore ?? SourceFavoriteStore.instance;
    _scroll.addListener(_onScroll);
    _loadFirst();
    _loadDanbooruFavorites();
    _loadSourceFavorites();
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadFirst() async {
    _aitagRequestEpoch += 1;
    _codexRequestEpoch += 1;
    _danbooruRequestEpoch += 1;
    _thumbs.clear();
    _codexThumbs.clear();
    _danbooruThumbs.clear();
    if (_tab == 0) {
      _aitagWorks = <AitagWork>[];
      _aitagPage = 1;
      _aitagMore = true;
      await _loadAitagPage(1, replace: true);
    } else if (_tab == 1) {
      await _loadCodexFirst();
    } else if (_tab == 2) {
      setState(() => _localShown = 60);
    } else if (_tab == 5) {
      _danbooruPosts = <DanbooruPost>[];
      _danbooruPage = 1;
      _danbooruMore = true;
      await _loadDanbooruFirst();
    } else if (_tab == 6) {
      // 收藏 tab 直接读本地收藏库，不发起网络请求。
      setState(() {});
    } else {
      await widget.viewModel.refreshLibrary();
    }
  }

  Future<void> _loadMore() async {
    if (_tab == 0) {
      if (!_aitagMore) return;
      await _loadAitagPage(_aitagPage + 1);
    } else if (_tab == 1 && _codexPage < _codexPages) {
      await _loadCodexPage(_codexPage + 1);
    } else if (_tab == 5 && _danbooruMore && !_favoritesOnly) {
      await _loadDanbooruPage(_danbooruPage + 1);
    }
  }

  Future<void> _loadAitagPage(int page, {bool replace = false}) async {
    final epoch = _aitagRequestEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final works = await _aitag.search(_search.text, page: page);
      if (!mounted || epoch != _aitagRequestEpoch) return;
      setState(() {
        final merged = replace ? works : <AitagWork>[..._aitagWorks, ...works];
        _aitagWorks = merged.length > _maxLoadedWorks
            ? merged.sublist(0, _maxLoadedWorks)
            : merged;
        _aitagPage = page;
        _aitagMore = works.isNotEmpty && _aitagWorks.length < _maxLoadedWorks;
        _loading = false;
      });
      unawaited(_resolveAitagBadges(works));
    } on Object catch (error) {
      if (!mounted || epoch != _aitagRequestEpoch) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _resolveAitagBadges(List<AitagWork> works) async {
    final ids = works
        .where(
          (work) =>
              work.aiType.toUpperCase() == 'NAI' &&
              !_aitagBadges.containsKey(work.id),
        )
        .map((work) => work.id)
        .toList(growable: false);
    if (ids.isEmpty) return;
    try {
      final badges = await _aitag.resolveModelBadges(ids);
      if (!mounted || badges.isEmpty) return;
      setState(() => _aitagBadges.addAll(badges));
    } on Object {
      // 徽标失败不影响画廊主体
    }
  }

  String? _aitagBadgeFor(AitagWork work) {
    final type = work.aiType.toUpperCase();
    if (type == 'COMFYUI') return 'ComfyUI';
    if (type == 'SD') return 'SD';
    if (type == 'NAI') return _aitagBadges[work.id] ?? 'NAI';
    return null;
  }

  Future<void> _loadCodexFirst() async {
    final epoch = _codexRequestEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_packs.isEmpty) {
        _packs = await _codex.listPacks();
        if (_packs.isNotEmpty) _packId = _packs.first.id;
      }
      final result = await _codex.search(
        packId: _packId,
        query: _search.text,
        category: _codexCategory,
        page: 1,
      );
      if (!mounted || epoch != _codexRequestEpoch) return;
      setState(() {
        _codexEntries = result.entries;
        _codexCategories = result.categories;
        _codexTotal = result.total;
        _codexPage = result.page;
        _codexPages = result.pages;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || epoch != _codexRequestEpoch) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _loadCodexPage(int page) async {
    final epoch = _codexRequestEpoch;
    setState(() => _loading = true);
    try {
      final result = await _codex.search(
        packId: _packId,
        query: _search.text,
        category: _codexCategory,
        page: page,
      );
      if (!mounted || epoch != _codexRequestEpoch) return;
      setState(() {
        final merged = <CodexEntry>[..._codexEntries, ...result.entries];
        _codexEntries = merged.length > _maxLoadedWorks
            ? merged.sublist(0, _maxLoadedWorks)
            : merged;
        _codexTotal = result.total;
        _codexCategories = result.categories;
        _codexPage = result.page;
        _codexPages = result.pages;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || epoch != _codexRequestEpoch) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _loadDanbooruFirst() async {
    final epoch = _danbooruRequestEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final posts = await _danbooru.search(
        _search.text,
        page: 1,
        rating: _danbooruRating,
      );
      if (!mounted || epoch != _danbooruRequestEpoch) return;
      setState(() {
        _danbooruPosts = posts;
        _danbooruPage = 1;
        _danbooruMore = posts.length >= 40;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || epoch != _danbooruRequestEpoch) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _loadDanbooruPage(int page) async {
    final epoch = _danbooruRequestEpoch;
    setState(() => _loading = true);
    try {
      final posts = await _danbooru.search(
        _search.text,
        page: page,
        rating: _danbooruRating,
      );
      if (!mounted || epoch != _danbooruRequestEpoch) return;
      setState(() {
        final merged = <DanbooruPost>[..._danbooruPosts, ...posts];
        _danbooruPosts = merged.length > _maxLoadedWorks
            ? merged.sublist(0, _maxLoadedWorks)
            : merged;
        _danbooruPage = page;
        _danbooruMore = posts.length >= 40;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || epoch != _danbooruRequestEpoch) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _loadSourceFavorites() async {
    try {
      await _sourceFavorites.load();
    } on Object catch (error) {
      debugPrint('图源本地收藏加载失败: $error');
    }
    if (mounted) setState(() {});
  }

  bool _isAitagFavorite(AitagWork work) =>
      _sourceFavorites.contains('aitag', work.id) ||
      widget.viewModel.isFavoriteSource('aitag', work.id);

  bool _isCodexFavorite(CodexEntry entry) =>
      _sourceFavorites.contains('codex', entry.id) ||
      widget.viewModel.isFavoriteSource('codex', entry.id);

  Future<void> _toggleAitagFavorite(AitagWork work) async {
    if (_sourceBusy.contains('aitag:${work.id}')) return;
    if (_isAitagFavorite(work)) {
      await _sourceFavorites.remove('aitag', work.id);
      if (widget.viewModel.isFavoriteSource('aitag', work.id)) {
        await widget.viewModel.toggleFavoriteSource('aitag', work.id);
      }
      if (mounted) setState(() {});
      return;
    }
    await _saveSourceFavorite(
      scope: 'aitag',
      id: work.id,
      title: work.title,
      metadata: <String, dynamic>{
        'title': work.title,
        'tags': work.tags,
        'date': work.date,
        'imageCount': work.imageCount,
        'thumbUrl': work.thumbUrl,
        'aiType': work.aiType,
      },
      download: () {
        if (work.thumbUrl.trim().isEmpty) {
          throw const SourceFavoriteException('该作品没有可下载的图片地址');
        }
        return _aitag.fetchImage(work.thumbUrl);
      },
    );
  }

  Future<void> _toggleCodexFavorite(CodexEntry entry) async {
    if (_sourceBusy.contains('codex:${entry.id}')) return;
    if (_isCodexFavorite(entry)) {
      await _sourceFavorites.remove('codex', entry.id);
      if (widget.viewModel.isFavoriteSource('codex', entry.id)) {
        await widget.viewModel.toggleFavoriteSource('codex', entry.id);
      }
      if (mounted) setState(() {});
      return;
    }
    final imageUrl = entry.imageFiles.isEmpty
        ? null
        : _codex.imageUrl(_packId, entry.imageFiles.first);
    await _saveSourceFavorite(
      scope: 'codex',
      id: entry.id,
      title: entry.title,
      metadata: <String, dynamic>{
        'title': entry.title,
        'tags': entry.tags,
        'negative': entry.negative,
        'rating': entry.rating,
        'note': entry.note,
        'width': entry.width,
        'height': entry.height,
        'imageFiles': entry.imageFiles,
        'packId': _packId,
      },
      download: () {
        if (imageUrl == null) {
          throw const SourceFavoriteException('该条目没有可下载的图片');
        }
        return _codex.fetchImage(imageUrl);
      },
    );
  }

  Future<void> _saveSourceFavorite({
    required String scope,
    required String id,
    required String title,
    required Map<String, dynamic> metadata,
    required Future<Uint8List> Function() download,
  }) async {
    final busyKey = '$scope:$id';
    setState(() => _sourceBusy.add(busyKey));
    try {
      final bytes = await download();
      await _sourceFavorites.save(
        scope: scope,
        id: id,
        title: title,
        bytes: bytes,
        metadata: metadata,
      );
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sourcesFavoriteSaved)),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sourcesFavoriteFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _sourceBusy.remove(busyKey));
    }
  }

  AitagWork _aitagWorkFromFavorite(SourceFavorite favorite) {
    final tags = favorite.metadata['tags'];
    return AitagWork(
      id: favorite.id,
      title: favorite.title,
      tags: tags is List
          ? tags.whereType<String>().toList(growable: false)
          : const <String>[],
      date: favorite.metadata['date'] as String?,
      imageCount: (favorite.metadata['imageCount'] as num?)?.toInt() ?? 1,
      thumbUrl: (favorite.metadata['thumbUrl'] as String?) ?? '',
      aiType: (favorite.metadata['aiType'] as String?) ?? '',
    );
  }

  CodexEntry _codexEntryFromFavorite(SourceFavorite favorite) {
    final files = favorite.metadata['imageFiles'];
    return CodexEntry(
      id: favorite.id,
      title: favorite.title,
      tags: (favorite.metadata['tags'] as String?) ?? '',
      negative: (favorite.metadata['negative'] as String?) ?? '',
      rating: (favorite.metadata['rating'] as String?) ?? '',
      note: (favorite.metadata['note'] as String?) ?? '',
      width: (favorite.metadata['width'] as num?)?.toInt(),
      height: (favorite.metadata['height'] as num?)?.toInt(),
      imageFiles: files is List
          ? files.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }

  String? _codexImageUrlFor(CodexEntry entry) {
    if (entry.imageFiles.isEmpty) return null;
    final favorite = _sourceFavorites.byId('codex', entry.id);
    final savedPackId = (favorite?.metadata['packId'] as String?)?.trim();
    final packId = savedPackId == null || savedPackId.isEmpty
        ? _packId
        : savedPackId;
    return _codex.imageUrl(packId, entry.imageFiles.first);
  }

  Future<void> _loadDanbooruFavorites() async {
    try {
      await _danbooruFavorites.load();
    } on Object catch (error) {
      debugPrint('Danbooru 收藏加载失败: $error');
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleDanbooruFavorite(DanbooruPost post) async {
    if (_danbooruBusy.contains(post.id)) return;
    if (_danbooruFavorites.contains(post.id)) {
      await _danbooruFavorites.remove(post.id);
      if (mounted) setState(() {});
      return;
    }
    setState(() => _danbooruBusy.add(post.id));
    try {
      final bytes = await _danbooru.fetchImageBytes(post);
      await _danbooruFavorites.save(post, bytes);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sourcesDanbooruFavoriteSaved)),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.sourcesDanbooruFavoriteFailed('$error')),
        ),
      );
    } finally {
      if (mounted) setState(() => _danbooruBusy.remove(post.id));
    }
  }

  String _danbooruTags(DanbooruPost post) => post.tagString
      .split(' ')
      .where((tag) => tag.isNotEmpty)
      .map((tag) => tag.replaceAll('_', ' '))
      .join(', ');

  Future<void> _handleDanbooruAction(DanbooruPost post, String action) async {
    if (action == 'details') {
      await _openDanbooruDetail(post);
      return;
    }
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: _danbooruTags(post)));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.sourcesActionDone)));
      return;
    }
    if (action == 'tags') {
      final params = widget.viewModel.params;
      widget.viewModel.updateParams(
        params.copyWith(prompt: _danbooruTags(post)),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.sourcesApply)));
      return;
    }
    if (_danbooruBusy.contains(post.id)) return;
    setState(() => _danbooruBusy.add(post.id));
    try {
      final bytes = await _danbooru.fetchImageBytes(post);
      if (action == 'source') {
        widget.viewModel.setImg2imgSource(bytes);
      } else if (action == 'reference') {
        widget.viewModel.addReferenceImage(bytes);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.sourcesApply)));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sourcesActionFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _danbooruBusy.remove(post.id));
    }
  }

  void _showSentToChat() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.sourcesSentToChat)));
  }

  void _showNothingToSend() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.sourcesSendToChatFailed(
            context.l10n.sourcesNothingToSend,
          ),
        ),
      ),
    );
  }

  void _showSendFailed(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.sourcesSendToChatFailed('$error'))),
    );
  }

  /// 立即把文本填入聊天框（不发送），返回是否已填入内容。
  bool _publishChatText(String text) {
    if (!mounted || text.trim().isEmpty) return false;
    widget.viewModel.attachSourceToAgentComposer(text: text);
    _showSentToChat();
    return true;
  }

  /// 文本已填入后补一张图片：解码成功且草稿未被用户改动时再升级为图文草稿。
  Future<void> _upgradeChatImage(String text, Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) return;
    final image = await processImageAttachment(bytes);
    if (!mounted || image == null) return;
    if (widget.viewModel.chatDraft != text) return;
    widget.viewModel.attachSourceToAgentComposer(text: text, image: image);
  }

  Future<void> _sendAitagToAgent(AitagWork work) async {
    final key = 'aitag:${work.id}';
    if (_chatBusy.contains(key)) return;
    setState(() => _chatBusy.add(key));
    try {
      // 先用作品标签立刻填入聊天框，详情返回后再升级为完整提示词。
      final fallback = work.tags.join(', ');
      _publishChatText(fallback);
      var text = fallback;
      try {
        final detail = await _aitag.work(work.id);
        if (detail.prompt.trim().isNotEmpty) text = detail.prompt;
      } on Object {
        // 详情不可用时退化为作品标签，仍然可以发送到聊天框。
      }
      if (text != fallback && mounted) {
        final canUpgradeText =
            fallback.trim().isEmpty || widget.viewModel.chatDraft == fallback;
        if (canUpgradeText) {
          widget.viewModel.attachSourceToAgentComposer(text: text);
          if (fallback.trim().isEmpty) _showSentToChat();
        }
      }
      Uint8List? bytes;
      try {
        bytes = await _sourceFavorites.readBytes('aitag', work.id);
        bytes ??= await _thumbFor(work);
      } on Object {
        // 图片获取失败时只发送提示词。
      }
      if (text.trim().isEmpty) {
        // 没有提示词时退化为只发送详情图片。
        final image = bytes == null
            ? null
            : await processImageAttachment(bytes);
        if (!mounted) return;
        if (image == null) {
          _showNothingToSend();
          return;
        }
        widget.viewModel.attachSourceToAgentComposer(text: '', image: image);
        _showSentToChat();
        return;
      }
      await _upgradeChatImage(text, bytes);
    } on Object catch (error) {
      _showSendFailed(error);
    } finally {
      if (mounted) setState(() => _chatBusy.remove(key));
    }
  }

  Future<void> _sendCodexToAgent(CodexEntry entry) async {
    final key = 'codex:${entry.id}';
    if (_chatBusy.contains(key)) return;
    setState(() => _chatBusy.add(key));
    try {
      final sanitized = _sanitizeCodexTags(entry.tags);
      final text = sanitized.isEmpty ? entry.tags : sanitized;
      if (!_publishChatText(text)) {
        _showNothingToSend();
        return;
      }
      Uint8List? bytes;
      try {
        final localPath = _sourceFavorites.byId('codex', entry.id)?.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          final file = File(localPath);
          if (await file.exists()) bytes = await file.readAsBytes();
        }
        if (bytes == null) {
          final url = _codexImageUrlFor(entry);
          if (url != null) bytes = await _codexThumbFor(url);
        }
      } on Object {
        // 图片获取失败时只发送提示词。
      }
      await _upgradeChatImage(text, bytes);
    } on Object catch (error) {
      _showSendFailed(error);
    } finally {
      if (mounted) setState(() => _chatBusy.remove(key));
    }
  }

  Future<void> _sendDanbooruToAgent(DanbooruPost post) async {
    if (_danbooruBusy.contains(post.id)) return;
    setState(() => _danbooruBusy.add(post.id));
    try {
      final text = _danbooruTags(post);
      final hasText = _publishChatText(text);
      Uint8List? bytes;
      try {
        bytes =
            await _danbooruFavorites.readBytes(post.id) ??
            await _danbooru.fetchImageBytes(post);
      } on Object {
        // 图片获取失败时仍把 tag 串送入聊天框。
      }
      if (!hasText) {
        // 标签为空时保持旧行为：至少把图片送入聊天框。
        if (bytes == null || bytes.isEmpty) {
          _showNothingToSend();
          return;
        }
        final image = await processImageAttachment(bytes);
        if (!mounted) return;
        if (image == null) {
          _showNothingToSend();
          return;
        }
        widget.viewModel.attachSourceToAgentComposer(text: '', image: image);
        _showSentToChat();
        return;
      }
      await _upgradeChatImage(text, bytes);
    } on Object catch (error) {
      _showSendFailed(error);
    } finally {
      if (mounted) setState(() => _danbooruBusy.remove(post.id));
    }
  }

  /// 详情弹窗里的「发送到聊天框」：当前页图片字节可选。
  Future<void> _sendDetailToAgent(String text, Uint8List? bytes) async {
    try {
      if (_publishChatText(text)) {
        await _upgradeChatImage(text, bytes);
        return;
      }
      if (bytes == null || bytes.isEmpty) {
        _showNothingToSend();
        return;
      }
      final image = await processImageAttachment(bytes);
      if (!mounted) return;
      if (image == null) {
        _showNothingToSend();
        return;
      }
      widget.viewModel.attachSourceToAgentComposer(text: text, image: image);
      _showSentToChat();
    } on Object catch (error) {
      _showSendFailed(error);
    }
  }

  void _switchTab(int tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _error = null;
      _search.clear();
    });
    _loadFirst();
  }

  void _submitSearch() {
    _loadFirst();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return ColoredBox(
      color: colors.canvasBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                l10n.sourcesLoadFailed(_error!),
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ),
          Expanded(
            child: switch (_tab) {
              0 => _buildAitagGrid(context),
              1 => _buildCodexGrid(context),
              2 => _buildLocalGrid(context),
              3 => _buildLibraryTab(context),
              4 => _buildReflectionTab(context),
              6 => _buildFavoritesTab(context),
              _ => _buildDanbooruGrid(context),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.sourcesTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: 16),
              // 窄窗口下页签横向滚动，避免新增「收藏」后整行溢出。
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text(l10n.sourcesAitag),
                        selected: _tab == 0,
                        onSelected: (_) => _switchTab(0),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(l10n.sourcesDanbooru),
                        selected: _tab == 5,
                        onSelected: (_) => _switchTab(5),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(l10n.sourcesCodex),
                        selected: _tab == 1,
                        onSelected: (_) => _switchTab(1),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(l10n.sourcesFavoritesTab),
                        selected: _tab == 6,
                        onSelected: (_) => _switchTab(6),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(l10n.sourcesLocal),
                        selected: _tab == 2,
                        onSelected: (_) => _switchTab(2),
                      ),
                      ChoiceChip(
                        label: Text(l10n.sourcesLibrary),
                        selected: _tab == 3,
                        onSelected: (_) => _switchTab(3),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(l10n.sourcesReflections),
                        selected: _tab == 4,
                        onSelected: (_) => _switchTab(4),
                      ),
                      const SizedBox(width: 12),
                      ProxyFeatureSwitch(
                        viewModel: widget.viewModel,
                        feature: NetworkFeature.gallery,
                        label: l10n.proxyFeatureGallery,
                        compact: true,
                      ),
                      const SizedBox(width: 8),
                      if (_tab != 6)
                        FilterChip(
                          label: Text(l10n.sourcesFavoritesOnly),
                          selected: _favoritesOnly,
                          onSelected: (value) =>
                              setState(() => _favoritesOnly = value),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: l10n.close,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          if (_tab == 0 || _tab == 1 || _tab == 5) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (_tab == 1 && _packs.isNotEmpty) ...[
                  DropdownButton<String>(
                    value: _packs.any((pack) => pack.id == _packId)
                        ? _packId
                        : _packs.first.id,
                    hint: Text(l10n.sourcesPickCodex),
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final pack in _packs)
                        DropdownMenuItem(
                          value: pack.id,
                          child: Text('${pack.title} (${pack.entryCount})'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _packId = value;
                        _codexCategory = '';
                      });
                      _loadCodexFirst();
                    },
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: _tab == 5
                          ? context.l10n.sourcesDanbooruHint
                          : context.l10n.sourcesSearchHint,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                    onSubmitted: (_) => _submitSearch(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: context.l10n.sourcesSearchHint,
                  onPressed: _submitSearch,
                  icon: const Icon(Icons.search, size: 18),
                ),
              ],
            ),
            if (_tab == 1) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  l10n.sourcesCodexPage(_codexPage, _codexPages, _codexTotal),
                  style: TextStyle(
                    fontSize: 11,
                    color: context.colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilterChip(
                    label: Text(l10n.sourcesCategoryAll),
                    selected: _codexCategory.isEmpty,
                    onSelected: (_) {
                      if (_codexCategory.isEmpty) return;
                      setState(() => _codexCategory = '');
                      _loadCodexFirst();
                    },
                  ),
                  for (final category in _codexCategories)
                    FilterChip(
                      label: Text('${category.name} ${category.count}'),
                      selected: _codexCategory == category.path,
                      onSelected: (_) {
                        if (_codexCategory == category.path) return;
                        setState(() => _codexCategory = category.path);
                        _loadCodexFirst();
                      },
                    ),
                ],
              ),
            ],
            if (_tab == 5) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final rating in const [
                    'general',
                    'questionable',
                    'explicit',
                    'all',
                  ]) ...[
                    FilterChip(
                      label: Text(switch (rating) {
                        'questionable' => l10n.sourcesRatingQuestionable,
                        'explicit' => l10n.sourcesRatingExplicit,
                        'all' => l10n.sourcesRatingAll,
                        _ => l10n.sourcesRatingGeneral,
                      }),
                      selected: _danbooruRating == rating,
                      onSelected: (_) {
                        if (_danbooruRating == rating) return;
                        setState(() => _danbooruRating = rating);
                        _loadDanbooruFirst();
                      },
                    ),
                    const SizedBox(width: 6),
                  ],
                  const Spacer(),
                  Text(
                    l10n.sourcesDanbooruSize,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.colors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  DropdownButton<String>(
                    value: _danbooruSize,
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    items: [
                      DropdownMenuItem(
                        value: 'thumb',
                        child: Text(l10n.sourcesSizeThumb),
                      ),
                      DropdownMenuItem(
                        value: 'large',
                        child: Text(l10n.sourcesSizeLarge),
                      ),
                      DropdownMenuItem(
                        value: 'orig',
                        child: Text(l10n.sourcesSizeOrig),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _danbooruSize = value);
                    },
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildAitagGrid(BuildContext context) {
    final l10n = context.l10n;
    if (_aitagWorks.isEmpty &&
        !(_favoritesOnly && _sourceFavorites.forScope('aitag').isNotEmpty)) {
      return Center(
        child: Text(
          _loading ? l10n.sourcesLoadMore : l10n.sourcesEmpty,
          style: TextStyle(color: context.colors.textSecondary, fontSize: 12),
        ),
      );
    }
    final localFavorites = _sourceFavorites
        .forScope('aitag')
        .map(_aitagWorkFromFavorite)
        .toList(growable: false);
    final localIds = localFavorites.map((work) => work.id).toSet();
    final works = _favoritesOnly
        ? <AitagWork>[
            ...localFavorites,
            ..._aitagWorks.where(
              (work) =>
                  !localIds.contains(work.id) &&
                  widget.viewModel.isFavoriteSource('aitag', work.id),
            ),
          ]
        : _aitagWorks;
    return _buildMasonry(
      context,
      children: [
        for (final work in works)
          _AitagCard(
            work: work,
            localPath: _sourceFavorites.byId('aitag', work.id)?.localPath,
            loadThumb: _thumbFor,
            badge: _aitagBadgeFor(work),
            favorite: _isAitagFavorite(work),
            busy: _chatBusy.contains('aitag:${work.id}'),
            onFavorite: () => _toggleAitagFavorite(work),
            onSend: () => _sendAitagToAgent(work),
            onTap: () => _openAitagDetail(work),
          ),
      ],
    );
  }

  Widget _buildCodexGrid(BuildContext context) {
    final l10n = context.l10n;
    if (_codexEntries.isEmpty &&
        !(_favoritesOnly && _sourceFavorites.forScope('codex').isNotEmpty)) {
      return Center(
        child: Text(
          _loading ? l10n.sourcesLoadMore : l10n.sourcesEmpty,
          style: TextStyle(color: context.colors.textSecondary, fontSize: 12),
        ),
      );
    }
    final localFavorites = _sourceFavorites
        .forScope('codex')
        .map(_codexEntryFromFavorite)
        .toList(growable: false);
    final localIds = localFavorites.map((entry) => entry.id).toSet();
    final entries = _favoritesOnly
        ? <CodexEntry>[
            ...localFavorites,
            ..._codexEntries.where(
              (entry) =>
                  !localIds.contains(entry.id) &&
                  widget.viewModel.isFavoriteSource('codex', entry.id),
            ),
          ]
        : _codexEntries;
    return _buildMasonry(
      context,
      children: [
        for (final entry in entries)
          _CodexCard(
            entry: entry,
            imageUrl: _codexImageUrlFor(entry),
            localPath: _sourceFavorites.byId('codex', entry.id)?.localPath,
            loadImage: _codexThumbFor,
            favorite: _isCodexFavorite(entry),
            busy: _chatBusy.contains('codex:${entry.id}'),
            onFavorite: () => _toggleCodexFavorite(entry),
            onSend: () => _sendCodexToAgent(entry),
            onTap: () => _openCodexDetail(entry),
          ),
      ],
    );
  }

  Widget _buildDanbooruGrid(BuildContext context) {
    final l10n = context.l10n;
    final favorites = _danbooruFavorites.favorites;
    final posts = _favoritesOnly
        ? favorites.map((favorite) => favorite.post).toList(growable: false)
        : _danbooruPosts;
    if (posts.isEmpty) {
      return Center(
        child: Text(
          _loading ? l10n.sourcesLoadMore : l10n.sourcesDanbooruEmpty,
          style: TextStyle(color: context.colors.textSecondary, fontSize: 12),
        ),
      );
    }
    return _buildMasonry(
      context,
      children: [
        for (final post in posts)
          _DanbooruCard(
            post: post,
            localPath: _danbooruFavorites.byId(post.id)?.localPath,
            loadThumb: _danbooruThumbFor,
            favorite: _danbooruFavorites.contains(post.id),
            busy: _danbooruBusy.contains(post.id),
            onFavorite: () => _toggleDanbooruFavorite(post),
            onSend: () => _sendDanbooruToAgent(post),
            onAction: (action) => _handleDanbooruAction(post, action),
            onTap: () => _openDanbooruDetail(post),
          ),
      ],
    );
  }

  /// 收藏 tab：直接读本地收藏库，按 AITag / 法典 / Danbooru 分来源展示。
  Widget _buildFavoritesTab(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    final counts = <String, int>{
      'aitag': _sourceFavorites.forScope('aitag').length,
      'codex': _sourceFavorites.forScope('codex').length,
      'danbooru': _danbooruFavorites.favorites.length,
    };
    const sources = <String>{'aitag', 'codex', 'danbooru'};
    final source = sources.contains(_favoritesSource)
        ? _favoritesSource
        : 'aitag';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              ChoiceChip(
                label: Text('${l10n.sourcesAitag} (${counts['aitag']})'),
                selected: source == 'aitag',
                onSelected: (_) => setState(() => _favoritesSource = 'aitag'),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text('${l10n.sourcesCodex} (${counts['codex']})'),
                selected: source == 'codex',
                onSelected: (_) => setState(() => _favoritesSource = 'codex'),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text('${l10n.sourcesDanbooru} (${counts['danbooru']})'),
                selected: source == 'danbooru',
                onSelected: (_) =>
                    setState(() => _favoritesSource = 'danbooru'),
              ),
              const Spacer(),
              Text(
                l10n.sourcesFavoritesTab,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ],
          ),
        ),
        Expanded(child: _buildFavoritesBody(context, source)),
      ],
    );
  }

  Widget _buildFavoritesBody(BuildContext context, String source) {
    final children = <Widget>[];
    if (source == 'aitag') {
      for (final favorite in _sourceFavorites.forScope('aitag')) {
        children.add(_favoriteAitagCard(favorite));
      }
    } else if (source == 'codex') {
      for (final favorite in _sourceFavorites.forScope('codex')) {
        children.add(_favoriteCodexCard(favorite));
      }
    } else {
      for (final favorite in _danbooruFavorites.favorites) {
        children.add(_favoriteDanbooruCard(favorite));
      }
    }
    if (children.isEmpty) {
      return Center(
        child: Text(
          context.l10n.sourcesFavoritesEmpty,
          style: TextStyle(color: context.colors.textSecondary, fontSize: 12),
        ),
      );
    }
    return _buildMasonry(context, children: children);
  }

  Widget _favoriteAitagCard(SourceFavorite favorite) {
    final work = _aitagWorkFromFavorite(favorite);
    return _AitagCard(
      work: work,
      localPath: favorite.localPath,
      loadThumb: _thumbFor,
      badge: _aitagBadgeFor(work),
      favorite: true,
      busy: _chatBusy.contains('aitag:${favorite.id}'),
      onFavorite: () => _toggleAitagFavorite(work),
      onSend: () => _sendAitagToAgent(work),
      onTap: () => _openAitagDetail(work),
    );
  }

  Widget _favoriteCodexCard(SourceFavorite favorite) {
    final entry = _codexEntryFromFavorite(favorite);
    return _CodexCard(
      entry: entry,
      imageUrl: _codexImageUrlFor(entry),
      localPath: favorite.localPath,
      loadImage: _codexThumbFor,
      favorite: true,
      busy: _chatBusy.contains('codex:${favorite.id}'),
      onFavorite: () => _toggleCodexFavorite(entry),
      onSend: () => _sendCodexToAgent(entry),
      onTap: () => _openCodexDetail(entry),
    );
  }

  Widget _favoriteDanbooruCard(DanbooruFavorite favorite) {
    final post = favorite.post;
    return _DanbooruCard(
      post: post,
      localPath: favorite.localPath,
      loadThumb: _danbooruThumbFor,
      favorite: true,
      busy: _danbooruBusy.contains(post.id),
      onFavorite: () => _toggleDanbooruFavorite(post),
      onSend: () => _sendDanbooruToAgent(post),
      onAction: (action) => _handleDanbooruAction(post, action),
      onTap: () => _openDanbooruDetail(post),
    );
  }

  Widget _buildMasonry(
    BuildContext context, {
    required List<Widget> children,
    Widget? footer,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columnCount = width >= 1700
            ? 6
            : width >= 1400
            ? 5
            : width >= 1100
            ? 4
            : width >= 760
            ? 3
            : 2;
        final columns = List.generate(
          columnCount,
          (_) => <Widget>[],
          growable: false,
        );
        for (var index = 0; index < children.length; index += 1) {
          columns[index % columnCount].add(children[index]);
        }
        return SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final column in columns)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Column(children: column),
                      ),
                    ),
                ],
              ),
              if (_loading)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    context.l10n.sourcesLoadMore,
                    style: TextStyle(
                      color: context.colors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ?footer,
            ],
          ),
        );
      },
    );
  }

  Widget _buildLocalGrid(BuildContext context) {
    final l10n = context.l10n;
    final viewModel = widget.viewModel;
    final all = _favoritesOnly ? viewModel.favoriteImages : viewModel.gallery;
    if (all.isEmpty) {
      return Center(
        child: Text(
          l10n.sourcesEmpty,
          style: TextStyle(color: context.colors.textSecondary, fontSize: 12),
        ),
      );
    }
    final visible = all.take(_localShown).toList(growable: false);
    return _buildMasonry(
      context,
      children: [
        for (final image in visible)
          _LocalCard(
            image: image,
            favorite: viewModel.isFavoriteImage(image.id),
            onTap: () => showImageLightbox(
              context,
              image,
              loader: () => viewModel.ensureImageLoaded(image),
            ),
            onFavorite: () => viewModel.toggleFavoriteImage(image.id),
          ),
      ],
      footer: _localShown >= all.length
          ? Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.sourcesNoMore,
                style: TextStyle(
                  color: context.colors.textSecondary,
                  fontSize: 11,
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                onPressed: () => setState(() => _localShown += 60),
                child: Text(l10n.sourcesLoadMore),
              ),
            ),
    );
  }

  Widget _buildLibraryTab(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    final viewModel = widget.viewModel;
    if (viewModel.libraryDir.trim().isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.sourcesLibraryNotSet,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: viewModel.pickLibraryDirectory,
              icon: const Icon(Icons.folder_open, size: 16),
              label: Text(l10n.sourcesLibraryPick),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  viewModel.libraryDir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final count = await viewModel.importLibraryDocuments();
                  if (context.mounted && count > 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.sourcesImportDone(count))),
                    );
                  }
                },
                icon: const Icon(Icons.upload_file, size: 14),
                label: Text(l10n.sourcesImportDocs),
              ),
              TextButton.icon(
                onPressed: viewModel.pickLibraryDirectory,
                icon: const Icon(Icons.folder_open, size: 14),
                label: Text(l10n.sourcesLibraryPick),
              ),
              if (viewModel.libraryDir.trim().isNotEmpty)
                TextButton(
                  onPressed: viewModel.resetLibraryDirectory,
                  child: Text(l10n.sourcesResetDefaults),
                ),
              TextButton.icon(
                onPressed: viewModel.refreshLibrary,
                icon: const Icon(Icons.refresh, size: 14),
                label: Text(l10n.sourcesLibraryRefresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.sourcesLibrarySearchHint,
                    prefixIcon: const Icon(Icons.search, size: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  onSubmitted: (value) async {
                    setState(() => _librarySearching = true);
                    try {
                      final matches = await viewModel.searchLibrary(value);
                      if (!mounted) return;
                      setState(() {
                        _libraryMatches = matches;
                        _librarySearching = false;
                      });
                    } on Object catch (error) {
                      if (!context.mounted) return;
                      setState(() => _librarySearching = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(l10n.sourcesLoadFailed('$error')),
                        ),
                      );
                    }
                  },
                ),
              ),
              if (_libraryMatches != null)
                IconButton(
                  tooltip: l10n.close,
                  onPressed: () => setState(() => _libraryMatches = null),
                  icon: const Icon(Icons.close, size: 16),
                ),
            ],
          ),
        ),
        Expanded(
          child: viewModel.libraryLoading || _librarySearching
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _buildLibraryBody(context, viewModel),
        ),
      ],
    );
  }

  Widget _buildLibraryBody(BuildContext context, StudioViewModel viewModel) {
    final l10n = context.l10n;
    final colors = context.colors;
    final matches = _libraryMatches;
    if (matches != null) {
      if (matches.isEmpty) {
        return Center(
          child: Text(
            l10n.sourcesEmpty,
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
        );
      }
      return ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: matches.length,
        itemBuilder: (context, index) {
          final match = matches[index];
          final snippet = match.snippet.isEmpty ? match.text : match.snippet;
          return ListTile(
            dense: true,
            leading: Icon(
              match.pathHit && match.line <= 0
                  ? Icons.insert_drive_file_outlined
                  : Icons.subject,
              size: 16,
            ),
            title: Text(snippet, maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              match.line > 0 ? '${match.file}:${match.line}' : match.file,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: colors.textSecondary),
            ),
            onTap: () {
              final file = viewModel.libraryFiles
                  .where((item) => item.name == match.file)
                  .firstOrNull;
              if (file != null) _showLibraryFile(context, file);
            },
          );
        },
      );
    }
    if (viewModel.libraryFiles.isEmpty) {
      return Center(
        child: Text(
          l10n.sourcesLibraryEmpty,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: viewModel.libraryFiles.length,
      itemBuilder: (context, index) {
        final file = viewModel.libraryFiles[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.description_outlined, size: 18),
          title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${(file.size / 1024).toStringAsFixed(1)} KB',
            style: TextStyle(fontSize: 10, color: colors.textSecondary),
          ),
          trailing: IconButton(
            tooltip: l10n.delete,
            onPressed: () async {
              final confirmed = await showAppConfirmDialog(
                context,
                title: l10n.sourcesDeleteFileTitle,
                message: l10n.sourcesDeleteFileMessage(file.name),
                confirmLabel: l10n.delete,
                isDestructive: true,
              );
              if (confirmed == true) {
                await viewModel.deleteLibraryFile(file);
              }
            },
            icon: const Icon(Icons.delete_outline, size: 16),
          ),
          onTap: () => _showLibraryFile(context, file),
        );
      },
    );
  }

  Future<void> _showLibraryFile(BuildContext context, LibraryFile file) async {
    final LibraryRead read;
    try {
      read = await widget.viewModel.readLibraryFile(file, limit: 12000);
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sourcesReadFailed('$error'))),
      );
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820, maxHeight: 760),
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
                        read.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      read.text,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                Text(
                  '${read.offset} / ${read.total}${read.truncated ? context.l10n.sourcesMorePending : ''}',
                  style: TextStyle(
                    fontSize: 10,
                    color: context.colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReflectionTab(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    final entries = widget.viewModel.reflections;
    if (entries.isEmpty) {
      return Center(
        child: Text(
          l10n.sourcesReflectionEmpty,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.auto_awesome_outlined, size: 18),
          title: Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${entry.source} · ${entry.createdAt.toLocal().toString().substring(0, 16)}',
            style: TextStyle(fontSize: 10, color: colors.textSecondary),
          ),
          trailing: IconButton(
            tooltip: l10n.close,
            onPressed: () => widget.viewModel.removeReflection(entry.id),
            icon: const Icon(Icons.delete_outline, size: 16),
          ),
          onTap: () => _showReflection(context, entry),
        );
      },
    );
  }

  Future<void> _showReflection(
    BuildContext context,
    ReflectionEntry entry,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700),
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
                        entry.title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                Text(
                  '${entry.source} · ${entry.createdAt.toLocal().toString().substring(0, 16)}',
                  style: TextStyle(
                    fontSize: 10,
                    color: context.colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          entry.summary,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        if (entry.lessons.isEmpty)
                          Text(
                            context.l10n.reflectionNoLessons,
                            style: TextStyle(
                              fontSize: 12,
                              color: context.colors.textMuted,
                            ),
                          )
                        else
                          for (
                            var index = 0;
                            index < entry.lessons.length;
                            index += 1
                          )
                            Text(
                              '${index + 1}. ${entry.lessons[index]}',
                              style: const TextStyle(fontSize: 12),
                            ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openAitagDetail(AitagWork work) async {
    final detail = await showDialog<AitagWorkDetail>(
      context: context,
      builder: (dialogContext) => _AitagDetailDialog(
        work: work,
        service: _aitag,
        onSendToChat: (detail, bytes) {
          unawaited(_sendDetailToAgent(detail.prompt, bytes));
        },
      ),
    );
    if (!mounted || detail == null) return;
    _applyAitag(detail);
  }

  void _applyAitag(AitagWorkDetail detail) {
    final params = widget.viewModel.params;
    final model = _modelFromAitag(detail.modelName);
    final characters = <NaiCharacterPrompt>[
      for (final character in detail.characters)
        NaiCharacterPrompt(
          id: NaiCharacterPrompt.generateId(),
          name: 'Character',
          prompt: character.prompt,
          useCustomPosition: true,
          positionX: character.x,
          positionY: character.y,
        ),
    ];
    widget.viewModel.updateParams(
      params.copyWith(
        prompt: detail.prompt,
        negativePrompt: detail.negative.isEmpty
            ? params.negativePrompt
            : detail.negative,
        model: model ?? params.model,
        width: detail.width ?? params.width,
        height: detail.height ?? params.height,
        steps: detail.steps ?? params.steps,
        scale: detail.scale ?? params.scale,
        sampler: detail.sampler.isEmpty
            ? params.sampler
            : NaiSampler.fromId(detail.sampler),
        noiseSchedule: detail.noiseSchedule.isEmpty
            ? params.noiseSchedule
            : NoiseSchedule.fromId(detail.noiseSchedule),
        seed: detail.seed ?? params.seed,
        seedMode: detail.seed != null ? NaiSeedMode.fixed : params.seedMode,
        characterPrompts: characters.isEmpty
            ? params.characterPrompts
            : characters,
        characterAiPosition: characters.isEmpty
            ? params.characterAiPosition
            : false,
      ),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.sourcesApply)));
  }

  Future<void> _openCodexDetail(CodexEntry entry) async {
    final favorite = _sourceFavorites.byId('codex', entry.id);
    final savedPackId = (favorite?.metadata['packId'] as String?)?.trim();
    final packId = savedPackId == null || savedPackId.isEmpty
        ? _packId
        : savedPackId;
    final imageUrls = entry.imageFiles
        .map((file) => _codex.imageUrl(packId, file))
        .toList(growable: false);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _CodexDetailDialog(
        entry: entry,
        imageUrls: imageUrls,
        localPath: favorite?.localPath,
        loadImage: _codexThumbFor,
        onSendToChat: () {
          unawaited(_sendCodexToAgent(entry));
        },
        onApply: () {
          final params = widget.viewModel.params;
          widget.viewModel.updateParams(
            params.copyWith(
              prompt: _sanitizeCodexTags(entry.tags),
              negativePrompt: entry.negative.trim().isEmpty
                  ? params.negativePrompt
                  : entry.negative,
            ),
          );
          Navigator.of(dialogContext).pop();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(context.l10n.sourcesApply)));
        },
      ),
    );
  }

  Future<void> _openDanbooruDetail(DanbooruPost post) async {
    final favorite = _danbooruFavorites.byId(post.id);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _DanbooruDetailDialog(
        post: post,
        tagsText: _danbooruTags(post),
        localPath: favorite?.localPath,
        initiallyFavorite: _danbooruFavorites.contains(post.id),
        loadImage: _danbooru.fetchImageBytes,
        onToggleFavorite: () => _toggleDanbooruFavorite(post),
        onSendToChat: () {
          Navigator.of(dialogContext).pop();
          unawaited(_sendDanbooruToAgent(post));
        },
        onAction: (action) {
          Navigator.of(dialogContext).pop();
          unawaited(_handleDanbooruAction(post, action));
        },
      ),
    );
  }

  static String _sanitizeCodexTags(String text) {
    const dropped = <String>{
      'masterpiece',
      'best quality',
      'very aesthetic',
      'amazing quality',
      'good quality',
      'absurdres',
      'highres',
      'incredibly absurdres',
    };
    return text
        .replaceAll('\n', ', ')
        .split(',')
        .map((part) => part.trim())
        .where(
          (part) => part.isNotEmpty && !dropped.contains(part.toLowerCase()),
        )
        .join(', ');
  }

  static NaiModel? _modelFromAitag(String name) {
    final text = name.toLowerCase();
    if (text.contains('furry')) return NaiModel.v3Furry;
    if (text.contains('v5') || text.contains('5.0')) return NaiModel.v5Full;
    if (text.contains('4.5') || text.contains('v4.5')) return NaiModel.v45Full;
    if (text.contains('v4')) return NaiModel.v4Full;
    if (text.contains('v3')) return NaiModel.v3;
    return null;
  }
}

class _DanbooruCard extends StatelessWidget {
  const _DanbooruCard({
    required this.post,
    required this.localPath,
    required this.loadThumb,
    required this.favorite,
    required this.busy,
    required this.onFavorite,
    required this.onSend,
    required this.onAction,
    required this.onTap,
  });

  final DanbooruPost post;
  final String? localPath;
  final Future<Uint8List> Function(DanbooruPost post) loadThumb;
  final bool favorite;
  final bool busy;
  final VoidCallback onFavorite;
  final VoidCallback onSend;
  final ValueChanged<String> onAction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: colors.cardBackground,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: colors.borderDefault),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: onTap,
              child: AspectRatio(
                aspectRatio: post.aspectRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (localPath != null)
                      Image.file(
                        File(localPath!),
                        fit: BoxFit.cover,
                        cacheWidth: _kThumbDecodeWidth,
                        errorBuilder: (_, _, _) => _placeholder(context),
                      )
                    else if (post.thumbnailUrl != null)
                      FutureBuilder<Uint8List>(
                        future: loadThumb(post),
                        builder: (context, snapshot) {
                          final bytes = snapshot.data;
                          if (snapshot.hasError || bytes == null) {
                            return snapshot.hasError
                                ? _placeholder(context)
                                : ColoredBox(
                                    color: colors.cardBackground,
                                    child: const Center(
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  );
                          }
                          return Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            cacheWidth: _kThumbDecodeWidth,
                          );
                        },
                      )
                    else
                      _placeholder(context),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${post.rating.toUpperCase()} · ${post.score}',
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      post.displayTags.isEmpty
                          ? '#${post.id}'
                          : post.displayTags,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else ...[
                    PopupMenuButton<String>(
                      tooltip: l10n.sourcesMoreActions,
                      icon: Icon(
                        Icons.more_horiz,
                        size: 16,
                        color: colors.textSecondary,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onSelected: onAction,
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'details',
                          child: Text(l10n.sourcesDetails),
                        ),
                        PopupMenuItem(
                          value: 'copy',
                          child: Text(l10n.sourcesCopyTags),
                        ),
                        PopupMenuItem(
                          value: 'tags',
                          child: Text(l10n.sourcesUseTags),
                        ),
                        PopupMenuItem(
                          value: 'source',
                          child: Text(l10n.sourcesUseAsSource),
                        ),
                        PopupMenuItem(
                          value: 'reference',
                          child: Text(l10n.sourcesUseAsReference),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: favorite
                          ? l10n.sourcesUnfavorite
                          : l10n.sourcesFavorite,
                      onPressed: onFavorite,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        favorite ? Icons.favorite : Icons.favorite_border,
                        size: 15,
                        color: favorite ? colors.primary : colors.textSecondary,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.sourcesSendToChat,
                      onPressed: onSend,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.send_outlined,
                        size: 15,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) => ColoredBox(
    color: context.colors.cardBackground,
    child: Center(
      child: Icon(
        Icons.broken_image_outlined,
        size: 20,
        color: context.colors.textSecondary,
      ),
    ),
  );
}

class _AitagCard extends StatelessWidget {
  const _AitagCard({
    required this.work,
    required this.localPath,
    required this.loadThumb,
    required this.favorite,
    required this.busy,
    required this.onFavorite,
    required this.onSend,
    required this.onTap,
    this.badge,
  });

  final AitagWork work;
  final String? localPath;
  final Future<Uint8List> Function(AitagWork work) loadThumb;
  final String? badge;
  final bool favorite;
  final bool busy;
  final VoidCallback onFavorite;
  final VoidCallback onSend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          decoration: BoxDecoration(
            color: colors.cardBackground,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: colors.borderDefault),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 0.8,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (localPath != null)
                      Image.file(
                        File(localPath!),
                        fit: BoxFit.cover,
                        cacheWidth: _kThumbDecodeWidth,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: colors.cardBackground,
                          child: Icon(
                            Icons.broken_image_outlined,
                            size: 20,
                            color: colors.textSecondary,
                          ),
                        ),
                      )
                    else
                      FutureBuilder<Uint8List>(
                        future: loadThumb(work),
                        builder: (context, snapshot) {
                          final bytes = snapshot.data;
                          if (snapshot.hasError) {
                            return ColoredBox(
                              color: colors.cardBackground,
                              child: Icon(
                                Icons.broken_image_outlined,
                                size: 20,
                                color: colors.textSecondary,
                              ),
                            );
                          }
                          if (bytes == null) {
                            return ColoredBox(
                              color: colors.cardBackground,
                              child: const Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          return Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            cacheWidth: _kThumbDecodeWidth,
                          );
                        },
                      ),
                    if (badge != null)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: switch (badge) {
                              'NAI5' => const Color(0xFF6C5CE7),
                              'NAI4.5' => const Color(0xFF0984E3),
                              'NAI4' => const Color(0xFF00B894),
                              'NAI3' => const Color(0xFFE17055),
                              'ComfyUI' => const Color(0xFF8E44AD),
                              'SD' => const Color(0xFFD35400),
                              _ => Colors.black54,
                            },
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            badge!,
                            style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        work.title.trim().isEmpty ? work.id : work.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else ...[
                      IconButton(
                        tooltip: context.l10n.sourcesSendToChat,
                        onPressed: onSend,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.send_outlined,
                          size: 15,
                          color: colors.textSecondary,
                        ),
                      ),
                      IconButton(
                        tooltip: favorite
                            ? context.l10n.sourcesUnfavorite
                            : context.l10n.sourcesFavorite,
                        onPressed: onFavorite,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          favorite ? Icons.favorite : Icons.favorite_border,
                          size: 15,
                          color: favorite
                              ? colors.primary
                              : colors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CodexCard extends StatelessWidget {
  const _CodexCard({
    required this.entry,
    required this.imageUrl,
    required this.localPath,
    required this.loadImage,
    required this.favorite,
    required this.busy,
    required this.onFavorite,
    required this.onSend,
    required this.onTap,
  });

  final CodexEntry entry;
  final String? imageUrl;
  final String? localPath;
  final Future<Uint8List> Function(String url) loadImage;
  final bool favorite;
  final bool busy;
  final VoidCallback onFavorite;
  final VoidCallback onSend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final ratio =
        (entry.width != null && entry.height != null && entry.width! > 0)
        ? entry.width! / entry.height!
        : 0.75;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          decoration: BoxDecoration(
            color: colors.cardBackground,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: colors.borderDefault),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: ratio.clamp(0.72, 1.45),
                child: localPath != null
                    ? Image.file(
                        File(localPath!),
                        fit: BoxFit.cover,
                        cacheWidth: _kThumbDecodeWidth,
                        errorBuilder: (_, _, _) =>
                            ColoredBox(color: colors.cardBackground),
                      )
                    : imageUrl == null
                    ? ColoredBox(color: colors.cardBackground)
                    : FutureBuilder<Uint8List>(
                        future: loadImage(imageUrl!),
                        builder: (context, snapshot) {
                          final bytes = snapshot.data;
                          if (snapshot.hasError || bytes == null) {
                            return ColoredBox(color: colors.cardBackground);
                          }
                          return Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            cacheWidth: _kThumbDecodeWidth,
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.title.trim().isEmpty ? entry.id : entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else ...[
                      IconButton(
                        tooltip: context.l10n.sourcesSendToChat,
                        onPressed: onSend,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.send_outlined,
                          size: 15,
                          color: colors.textSecondary,
                        ),
                      ),
                      IconButton(
                        tooltip: favorite
                            ? context.l10n.sourcesUnfavorite
                            : context.l10n.sourcesFavorite,
                        onPressed: onFavorite,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          favorite ? Icons.favorite : Icons.favorite_border,
                          size: 15,
                          color: favorite
                              ? colors.primary
                              : colors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalCard extends StatelessWidget {
  const _LocalCard({
    required this.image,
    required this.favorite,
    required this.onTap,
    required this.onFavorite,
  });

  final NaiGeneratedImage image;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final ratio = image.params.width > 0
        ? image.params.width / image.params.height
        : 0.75;
    final bytes = image.bytes.isNotEmpty ? image.bytes : image.thumbnailBytes;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          decoration: BoxDecoration(
            color: colors.cardBackground,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: colors.borderDefault),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: ratio.clamp(0.4, 2.5),
                    child: bytes == null
                        ? ColoredBox(color: colors.cardBackground)
                        : Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            cacheWidth: _kThumbDecodeWidth,
                            gaplessPlayback: true,
                            errorBuilder: (context, error, stack) =>
                                ColoredBox(color: colors.cardBackground),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                    child: Text(
                      image.params.prompt.trim().isEmpty
                          ? image.id
                          : image.params.prompt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  tooltip: context.l10n.sourcesFavoritesOnly,
                  onPressed: onFavorite,
                  style: IconButton.styleFrom(
                    backgroundColor: colors.cardBackground.withValues(
                      alpha: 0.75,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: Icon(
                    favorite ? Icons.favorite : Icons.favorite_border,
                    size: 16,
                    color: favorite ? colors.primary : colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AitagDetailDialog extends StatefulWidget {
  const _AitagDetailDialog({
    required this.work,
    required this.service,
    required this.onSendToChat,
  });

  final AitagWork work;
  final AitagService service;
  final void Function(AitagWorkDetail detail, Uint8List? imageBytes)
  onSendToChat;

  @override
  State<_AitagDetailDialog> createState() => _AitagDetailDialogState();
}

class _AitagDetailDialogState extends State<_AitagDetailDialog> {
  AitagWorkDetail? _detail;
  String? _error;
  Future<Uint8List>? _image;
  Uint8List? _imageBytes;
  String? _imageUrl;
  int _imageIndex = 0;
  final Map<String, Future<Uint8List>> _thumbCache =
      <String, Future<Uint8List>>{};

  List<String> get _images {
    final urls = widget.work.imageUrls
        .where((url) => url.trim().isNotEmpty)
        .toList(growable: false);
    if (urls.isNotEmpty) return urls;
    return widget.work.thumbUrl.trim().isEmpty
        ? const <String>[]
        : <String>[widget.work.thumbUrl];
  }

  @override
  void initState() {
    super.initState();
    if (_images.isEmpty) {
      _image = Future<Uint8List>.error(const AitagException('缺少图片地址'));
    } else {
      _imageUrl = _images.first;
      _image = _fetchImage(_images.first);
    }
    _load();
  }

  /// 缓存当前大图字节，供「发送到聊天框」附带图片；加载失败只发文本。
  Future<Uint8List> _fetchImage(String url) {
    final future = widget.service.fetchImage(url);
    unawaited(
      future.then((bytes) {
        if (!mounted || _imageUrl != url) return;
        setState(() => _imageBytes = bytes);
      }, onError: (Object _) {}),
    );
    return future;
  }

  Future<Uint8List> _thumbFor(String url) =>
      _thumbCache.putIfAbsent(url, () => widget.service.fetchImage(url));

  void _selectImage(int index) {
    if (index == _imageIndex || index < 0 || index >= _images.length) return;
    setState(() {
      _imageIndex = index;
      _imageUrl = _images[index];
      _imageBytes = null;
      _image = _fetchImage(_images[index]);
    });
  }

  void _sendToChat() {
    final detail = _detail;
    if (detail == null) return;
    final bytes = _imageBytes;
    Navigator.of(context).pop();
    widget.onSendToChat(detail, bytes);
  }

  Future<void> _load() async {
    try {
      final detail = await widget.service.work(widget.work.id);
      if (!mounted) return;
      setState(() => _detail = detail);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    final detail = _detail;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: detail == null
              ? SizedBox(
                  height: 240,
                  child: Center(
                    child: Text(
                      _error ?? l10n.sourcesLoadMore,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.work.title.trim().isEmpty
                                ? widget.work.id
                                : widget.work.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 340,
                      child: FutureBuilder<Uint8List>(
                        future: _image,
                        builder: (context, snapshot) {
                          final bytes = snapshot.data;
                          if (bytes == null) {
                            return const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            );
                          }
                          return InteractiveViewer(
                            child: Image.memory(
                              bytes,
                              fit: BoxFit.contain,
                              cacheWidth: 1200,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_images.length > 1)
                      SizedBox(
                        height: 58,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _images.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (context, index) => InkWell(
                            onTap: () => _selectImage(index),
                            child: Container(
                              width: 58,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: index == _imageIndex
                                      ? colors.primary
                                      : colors.borderDefault,
                                  width: index == _imageIndex ? 2 : 1,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: FutureBuilder<Uint8List>(
                                future: _thumbFor(_images[index]),
                                builder: (context, snapshot) {
                                  final bytes = snapshot.data;
                                  if (bytes == null) {
                                    return ColoredBox(
                                      color: colors.cardBackground,
                                    );
                                  }
                                  return Image.memory(
                                    bytes,
                                    fit: BoxFit.cover,
                                    cacheWidth: 160,
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        _meta(
                          l10n.sourcesSize,
                          '${detail.width ?? '-'} × ${detail.height ?? '-'}',
                        ),
                        _meta(l10n.sourcesSteps, '${detail.steps ?? '-'}'),
                        _meta(l10n.sourcesSampler, detail.sampler),
                        _meta(l10n.sourcesSeed, '${detail.seed ?? '-'}'),
                        _meta('Model', detail.modelName),
                        _meta(l10n.sourcesDate, widget.work.date ?? '-'),
                        for (final character in detail.characters)
                          _meta('Character', character.prompt),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.sourcesPrompt,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.textSecondary,
                              ),
                            ),
                            SelectableText(
                              detail.prompt,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textPrimary,
                              ),
                            ),
                            if (detail.negative.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.sourcesNegative,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.textSecondary,
                                ),
                              ),
                              SelectableText(
                                detail.negative,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: detail.prompt),
                            );
                            Navigator.of(context).pop();
                          },
                          child: Text(l10n.copy),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _sendToChat,
                          icon: const Icon(Icons.send_outlined, size: 16),
                          label: Text(l10n.sourcesSendToChat),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(detail),
                          child: Text(l10n.sourcesApply),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _meta(String label, String value) {
    return Text(
      '$label: $value',
      style: TextStyle(fontSize: 11, color: context.colors.textSecondary),
    );
  }
}

/// Danbooru 详情弹窗：离线可看本地收藏图，在线时按需加载；集中提供
/// 收藏、复制/套用标签与「发送到聊天框」入口。
class _DanbooruDetailDialog extends StatefulWidget {
  const _DanbooruDetailDialog({
    required this.post,
    required this.tagsText,
    required this.localPath,
    required this.initiallyFavorite,
    required this.loadImage,
    required this.onToggleFavorite,
    required this.onSendToChat,
    required this.onAction,
  });

  final DanbooruPost post;
  final String tagsText;
  final String? localPath;
  final bool initiallyFavorite;
  final Future<Uint8List> Function(DanbooruPost post) loadImage;
  final Future<void> Function() onToggleFavorite;
  final VoidCallback onSendToChat;
  final ValueChanged<String> onAction;

  @override
  State<_DanbooruDetailDialog> createState() => _DanbooruDetailDialogState();
}

class _DanbooruDetailDialogState extends State<_DanbooruDetailDialog> {
  late bool _favorite = widget.initiallyFavorite;
  bool _busy = false;

  Future<void> _toggleFavorite() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onToggleFavorite();
      if (!mounted) return;
      setState(() => _favorite = !_favorite);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    final post = widget.post;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 780),
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
                      post.displayTags.isEmpty
                          ? '#${post.id}'
                          : post.displayTags,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 300,
                child: widget.localPath != null
                    ? Image.file(
                        File(widget.localPath!),
                        fit: BoxFit.contain,
                        cacheWidth: 1200,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      )
                    : FutureBuilder<Uint8List>(
                        future: widget.loadImage(post),
                        builder: (context, snapshot) {
                          final bytes = snapshot.data;
                          if (snapshot.hasError || bytes == null) {
                            return const SizedBox.shrink();
                          }
                          return Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            cacheWidth: 1200,
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    '${l10n.sourcesRating}: ${post.rating.toUpperCase()}',
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                  Text(
                    '${l10n.sourcesScore}: ${post.score}',
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                  Text(
                    '${l10n.sourcesSize}: ${post.width} × ${post.height}',
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                  if ((post.source ?? '').trim().isNotEmpty)
                    Text(
                      '${l10n.sourcesSourceUrl}: ${post.source}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sourcesTags,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                      SelectableText(
                        widget.tagsText,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: _favorite
                        ? l10n.sourcesUnfavorite
                        : l10n.sourcesFavorite,
                    onPressed: _busy ? null : _toggleFavorite,
                    icon: Icon(
                      _favorite ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                      color: _favorite ? colors.primary : colors.textSecondary,
                    ),
                  ),
                  TextButton(
                    onPressed: () => widget.onAction('copy'),
                    child: Text(l10n.sourcesCopyTags),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => widget.onAction('tags'),
                    icon: const Icon(Icons.auto_fix_high, size: 16),
                    label: Text(l10n.sourcesUseTags),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: widget.onSendToChat,
                    icon: const Icon(Icons.send_outlined, size: 16),
                    label: Text(l10n.sourcesSendToChat),
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

class _CodexDetailDialog extends StatefulWidget {
  const _CodexDetailDialog({
    required this.entry,
    required this.imageUrls,
    required this.localPath,
    required this.loadImage,
    required this.onSendToChat,
    required this.onApply,
  });

  final CodexEntry entry;
  final List<String> imageUrls;
  final String? localPath;
  final Future<Uint8List> Function(String url) loadImage;
  final VoidCallback onSendToChat;
  final VoidCallback onApply;

  @override
  State<_CodexDetailDialog> createState() => _CodexDetailDialogState();
}

class _CodexDetailDialogState extends State<_CodexDetailDialog> {
  int _index = 0;
  final Map<String, Future<Uint8List>> _cache = <String, Future<Uint8List>>{};

  CodexEntry get entry => widget.entry;

  Future<Uint8List> _imageFor(String url) =>
      _cache.putIfAbsent(url, () => widget.loadImage(url));

  void _sendToChat() {
    Navigator.of(context).pop();
    widget.onSendToChat();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 800),
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
                      entry.title.trim().isEmpty ? entry.id : entry.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              if (_index == 0 && widget.localPath != null)
                SizedBox(
                  height: 300,
                  child: Image.file(
                    File(widget.localPath!),
                    fit: BoxFit.contain,
                    cacheWidth: 1200,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                )
              else if (widget.imageUrls.isNotEmpty)
                SizedBox(
                  height: 300,
                  child: FutureBuilder<Uint8List>(
                    future: _imageFor(widget.imageUrls[_index]),
                    builder: (context, snapshot) {
                      final bytes = snapshot.data;
                      if (snapshot.hasError || bytes == null) {
                        return const SizedBox.shrink();
                      }
                      return Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        cacheWidth: 1200,
                      );
                    },
                  ),
                ),
              if (widget.imageUrls.length > 1) ...[
                const SizedBox(height: 6),
                SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.imageUrls.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (context, index) => InkWell(
                      onTap: () => setState(() => _index = index),
                      child: Container(
                        width: 56,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: index == _index
                                ? colors.primary
                                : colors.borderDefault,
                            width: index == _index ? 2 : 1,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: index == 0 && widget.localPath != null
                            ? Image.file(
                                File(widget.localPath!),
                                fit: BoxFit.cover,
                                cacheWidth: 160,
                              )
                            : FutureBuilder<Uint8List>(
                                future: _imageFor(widget.imageUrls[index]),
                                builder: (context, snapshot) {
                                  final bytes = snapshot.data;
                                  if (bytes == null) {
                                    return ColoredBox(
                                      color: colors.cardBackground,
                                    );
                                  }
                                  return Image.memory(
                                    bytes,
                                    fit: BoxFit.cover,
                                    cacheWidth: 160,
                                  );
                                },
                              ),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  if (entry.rating.isNotEmpty)
                    Text(
                      '${l10n.sourcesRating}: ${entry.rating}',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  if (entry.width != null && entry.height != null)
                    Text(
                      '${l10n.sourcesSize}: ${entry.width} × ${entry.height}',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  if (entry.note.isNotEmpty)
                    Text(
                      '${l10n.sourcesNote}: ${entry.note}',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sourcesPrompt,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                      SelectableText(
                        entry.tags,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (entry.negative.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.sourcesNegative,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.textSecondary,
                          ),
                        ),
                        SelectableText(
                          entry.negative,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: _sendToChat,
                    icon: const Icon(Icons.send_outlined, size: 16),
                    label: Text(l10n.sourcesSendToChat),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: widget.onApply,
                    child: Text(l10n.sourcesApply),
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
