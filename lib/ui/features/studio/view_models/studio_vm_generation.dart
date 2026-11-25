
part of 'studio_view_model.dart';

/// 生图 / 超分 / 实时预览 / 账号信息
mixin _StudioGenerationMixin on _StudioCore {
  /// 生成完成后统一落图 (手动生成与 Agent 工具共用)。
  ///
  /// [wasViewingLatest] 由调用方决定取值时机：手动生图与 Agent 工具
  /// (经 onBeforeGenerate 回调) 都在发起前捕获，但完成时会叠加当时的
  /// 实时 isViewingLatest (用户生成期间滚回顶部看预览时视为正在看最新，
  /// 避免画面已跳到新图却残留“有新图”横幅与旧选中框)。
  @override
  void _applyGeneratedImage(
    NaiGeneratedImage image, {
    required bool wasViewingLatest,
  }) {
    // 成品落图即本轮生成结束：无论手动/Agent/ComfyUI 路径，后台标记都必须复位，
    // 避免下一轮生成误判为一直在后台。
    _generationBackgrounded = false;
    unawaited(stripStealthFromFile(image.localFilePath));
    if (wasViewingLatest) {
      _selectedImage = image;
      _scheduleAdaptiveAccent(image);
      _hasUnseenLatest = false;
    } else {
      _hasUnseenLatest = true;
    }
    _statusMessage = image.localFilePath == null
        ? vmL10n.vmGenCacheFailed
        : image.isUnsaved
        ? vmL10n.vmGenDoneUnsaved
        : vmL10n.vmGenDoneSavedTo(image.localFilePath ?? vmL10n.vmGenLocalPath);
  }

  /// 手动保存当前选中的未保存 (缓存) 图片到本地存储目录 (可指定自定义目录)。
  ///
  /// 自动保存关闭时画板右下角保存按钮调用；按全局导出设置处理元数据与
  /// 水印后落盘，删除旧缓存文件。返回是否保存成功。
  @override
  Future<bool> saveCurrentImageToDisk({String? customDir}) async {
    final image = _selectedImage;
    if (image == null || !image.isUnsaved) return false;

    await ensureImageLoaded(image);

    final targetDir = (customDir != null && customDir.isNotEmpty)
        ? customDir
        : _config.saveDirectory;
    if (targetDir.isEmpty) {
      reportError(vmL10n.vmGenNoSaveDir, source: AppNoticeSource.generation);
      return false;
    }

    try {
      final saved = await _repository.saveUnsavedImageToDisk(
        imageId: image.id,
        imageSaveTemplate: _config.imageSaveTemplate,
        saveDir: targetDir,
        enablePersistence: _config.enableImagePersistence,
        maxImages: _config.maxPersistentImages,
        stripMetadata: effectiveStripMetadata,
        enableWatermark: _config.enableWatermark,
        keepOriginalImage: _config.keepOriginalImage,
        watermarkConfig: _config.watermarkConfig,
        watermarkBytes: _config.watermarkConfig.imageBytes,
      );
      if (saved == null) {
        reportError(
          vmL10n.vmGenSaveFailedNoTarget,
          source: AppNoticeSource.generation,
        );
        return false;
      }
      await stripStealthFromFile(saved.localFilePath);
      if (_selectedImage?.id == saved.id) {
        _selectedImage = saved;
      }
      _statusMessage = vmL10n.vmGenSavedTo(saved.localFilePath!);
      notifyListeners();
      return true;
    } catch (e) {
      reportError(
        vmL10n.vmGenSaveFailed('$e'),
        source: AppNoticeSource.generation,
      );
      return false;
    }
  }

  /// 导出任意图片到指定文件夹 (由原生文件选择器挑选)。
  ///
  /// 与常规导出共用命名单一事实源 (ImageSavePathService) 与无覆盖落盘
  /// (ImageFileStore)：遵守全局命名模板与分目录、不覆盖同名文件、不改写图片自身状态。
  @override
  Future<bool> exportImageToDirectory(
    NaiGeneratedImage image,
    String targetDir,
  ) async {
    if (targetDir.isEmpty) return false;
    try {
      final bytes = await getExportImageBytes(image, raw: false);
      if (bytes.isEmpty) return false;
      final path = await ImageFileStore.writeAsync(
        root: targetDir,
        relativePath: ImageSavePathService.resolve(
          _config.imageSaveTemplate,
          ImageSaveContext.fromImage(image),
        ),
        bytes: bytes,
      );
      _statusMessage = vmL10n.vmGenSavedTo(path);
      notifyListeners();
      return true;
    } catch (e) {
      reportError(
        vmL10n.vmGenSaveFailed('$e'),
        source: AppNoticeSource.generation,
      );
      return false;
    }
  }

  /// 解析当前命名模板下的导出相对子目录 (空 = 模板未分目录)，
  /// 供安卓 MediaStore 图库导出拼 Pictures/subDir 使用。
  @override
  String resolveExportSubDir(NaiGeneratedImage image) {
    final relative = ImageSavePathService.resolve(
      _config.imageSaveTemplate,
      ImageSaveContext.fromImage(image),
    );
    return p.dirname(relative);
  }

  @override
  String resolveExportFileName(NaiGeneratedImage image) => p.basename(
    ImageSavePathService.resolve(
      _config.imageSaveTemplate,
      ImageSaveContext.fromImage(image),
    ),
  );

  /// 强行中止当前正在执行的生图流
  Future<void> abortGeneration() async {
    _batchAborted = true;
    if (!_isGenerating) return;
    // 终止后不再保留后台态：画布/侧栏与恢复入口都必须立即复位。
    _generationBackgrounded = false;
    if (_isRtxUpscaling) {
      _repository.cancelRtxUpscale();
      return;
    }
    // ComfyUI 模式：置中止标记，由轮询循环自行收尾
    if (isComfyUiMode) {
      _requestComfyAbort();
      notifyListeners();
      return;
    }
    // cancel() 不会触发 onDone：主动完成等待信号，否则 generateImage 永久挂起。
    // 不等待 cancel 的 Future (底层取消可能依赖真实 IO 事件循环)：subscription
    // 在 cancel 调用时已同步标记失效，不会再有事件投递；UI 复位必须立即生效。
    final subscription = _generationSubscription;
    _generationSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    final pending = _generationCompleter;
    if (pending != null && !pending.isCompleted) pending.complete();
    _generationCompleter = null;
    _isGenerating = false;
    _liveProgressController.clear();
    _statusMessage = vmL10n.vmGenAborted;
    notifyListeners();
  }

  /// 把当前生成转入后台：请求与流式进度继续接收，但画布与历史侧栏隐藏
  /// 实时预览占位卡；生成坞/画布空态/历史侧栏会展示「查看生成」恢复入口。
  void backgroundGeneration() {
    if (!_isGenerating || _generationBackgrounded) return;
    _generationBackgrounded = true;
    _statusMessage = vmL10n.vmGenMovedToBackground;
    notifyListeners();
  }

  /// 从后台恢复到前台：画布重新展示实时预览占位卡与去噪进度。
  void foregroundGeneration() {
    if (!_generationBackgrounded) return;
    _generationBackgrounded = false;
    notifyListeners();
  }

  /// 手动快速生图 (使用左侧面板参数，支持实时流式去噪步数预览)
  /// 批量生图：种子从当前值开始逐张 +1，按顺序串行生成。
  Future<void> generateBatch() async {
    final count = _batchCount.clamp(1, 20);
    if (count <= 1) {
      await generateImage();
      return;
    }
    if (_isGenerating || _isStartingGeneration) return;
    if (_params.prompt.trim().isEmpty) {
      await generateImage(); // 复用空提示词报错
      return;
    }
    final originalSeedMode = _params.seedMode;
    final originalSeedTiming = _params.seedTiming;
    final baseSeed = _params.seed >= 0 ? _params.seed : generateRandomSeed();
    _batchTotal = count;
    _batchCurrent = 0;
    _batchAborted = false;
    notifyListeners();
    try {
      for (var index = 0; index < count; index += 1) {
        if (_batchAborted) break;
        _batchCurrent = index + 1;
        // 固定模式 + 显式种子，避免用户原有定时策略把序列打乱。
        _params = _params.copyWith(
          seed: (baseSeed + index) % 4294967295,
          seedMode: NaiSeedMode.fixed,
          seedTiming: NaiSeedTiming.after,
        );
        notifyListeners();
        await generateImage();
        if (_errorMessage != null && _errorMessage!.isNotEmpty) break;
      }
    } finally {
      _params = _params.copyWith(
        seed: (baseSeed + count) % 4294967295,
        seedMode: originalSeedMode,
        seedTiming: originalSeedTiming,
      );
      _batchTotal = 0;
      _batchCurrent = 0;
      _batchAborted = false;
      notifyListeners();
      _scheduleParameterSave();
    }
  }

  @override
  Future<void> generateImage() async {
    // 同步占位必须在任何 await 之前，否则双击/斜杠命令会在窗口期重复扣费。
    if (_isGenerating || _isStartingGeneration) return;
    if (_params.prompt.trim().isEmpty) {
      reportError(vmL10n.vmGenEmptyPrompt, source: AppNoticeSource.generation);
      return;
    }

    // 新一轮生成默认在前台开始，清掉上一轮可能残留的后台标记。
    _generationBackgrounded = false;

    // ComfyUI 模式：改走 PromptToolkit AI Bridge 驱动流水线
    if (isComfyUiMode) {
      await generateImageViaComfyUi();
      return;
    }

    _isStartingGeneration = true;
    try {
      // 本地 fork：账号池轮转（生图前按账号策略切换活动账号）
      await rotateAccountForGeneration();

      if (_config.novelAiKey.trim().isEmpty) {
        reportError(vmL10n.vmGenNoApiKey, source: AppNoticeSource.generation);
        return;
      }

      // 用户手动生图不再弹付费确认：生成坞按钮已实时显示预计点数
      // (需点数/生成图片 (N Anlas) 警示色)，足够的 UI 提醒已前置；
      // 点数消耗申请卡片只保留给 Agent (模型主动调用生图工具) 场景。
      if (_accountInfo == null) {
        await refreshAccountInfo();
      }

      final wasViewingLatest = isViewingLatest;

      // 种子生成控制：生图前变更种子 (若 timing == before)
      if (_params.seedTiming == NaiSeedTiming.before) {
        _applySeedMutationBefore();
      }

      _isGenerating = true;
      _liveProgressController.begin(_params.effectiveSteps, DateTime.now());
      _errorMessage = null;
      _statusMessage = vmL10n.vmGenRequesting(
        _params.width,
        _params.height,
        _params.effectiveSteps,
      );
      notifyListeners();

      if (_config.enableStreamPreview) {
        final completer = Completer<void>();
        _generationCompleter = completer;
        try {
          final stream = _repository.generateStream(
            apiKey: _config.novelAiKey,
            params: _params,
            saveDir: _config.saveDirectory,
            enablePersistence: _config.enableImagePersistence,
            maxImages: _config.maxPersistentImages,
            stripMetadata: effectiveStripMetadata,
            enableWatermark: _config.enableWatermark,
            keepOriginalImage: _config.keepOriginalImage,
            watermarkConfig: _config.watermarkConfig,
            watermarkBytes: _config.watermarkConfig.imageBytes,
            autoSave: _config.autoSaveImages,
            imageSaveTemplate: _config.imageSaveTemplate,
          );

          _generationSubscription = stream.listen(
            (progress) {
              if (progress.errorMessage != null &&
                  progress.errorMessage!.isNotEmpty) {
                reportError(
                  progress.errorMessage!,
                  source: AppNoticeSource.generation,
                );
                return;
              }

              if (progress.isFinal) {
                final newImage = progress.generatedImage;
                if (newImage != null) {
                  _applyGeneratedImage(
                    newImage,
                    // 发起前在看最新，或生成期间已滚回顶部看预览，都视为正在看最新
                    wasViewingLatest: wasViewingLatest || isViewingLatest,
                  );
                  // 种子生成控制：生图后变更种子 (若 timing == after)
                  if (_params.seedTiming == NaiSeedTiming.after) {
                    _applySeedMutationAfter(newImage.seed);
                  }
                }
                _liveProgressController.complete();
                notifyListeners();
              } else {
                // 中间去噪帧：只驱动画板占位卡/历史缩略图/生成熔按钮局部刷新，
                // 不触发全局 notifyListeners()，主工作台零重绘
                _liveProgressController.updateFrame(
                  previewBytes: progress.previewImage,
                  currentStep: progress.currentStep,
                  totalSteps: progress.totalSteps,
                  progress: progress.progress,
                );
              }
            },
            onError: (e) {
              reportError(
                vmL10n.vmGenFailed('$e'),
                source: AppNoticeSource.generation,
                notify: false,
              );
              _statusMessage = null;
              if (!completer.isCompleted) completer.complete();
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            cancelOnError: true,
          );

          await completer.future;
        } catch (e) {
          reportError(
            vmL10n.vmGenFailed('$e'),
            source: AppNoticeSource.generation,
            notify: false,
          );
          _statusMessage = null;
        } finally {
          _generationSubscription = null;
          _generationCompleter = null;
          _isGenerating = false;
          _generationBackgrounded = false;
          _liveProgressController.clear();
          notifyListeners();
          unawaited(refreshAccountInfo());
        }
      } else {
        try {
          final results = await _repository.generate(
            apiKey: _config.novelAiKey,
            params: _params,
            saveDir: _config.saveDirectory,
            enablePersistence: _config.enableImagePersistence,
            maxImages: _config.maxPersistentImages,
            stripMetadata: effectiveStripMetadata,
            enableWatermark: _config.enableWatermark,
            keepOriginalImage: _config.keepOriginalImage,
            watermarkConfig: _config.watermarkConfig,
            watermarkBytes: _config.watermarkConfig.imageBytes,
            autoSave: _config.autoSaveImages,
            imageSaveTemplate: _config.imageSaveTemplate,
          );

          if (results.isNotEmpty) {
            _applyGeneratedImage(
              results.first,
              wasViewingLatest: wasViewingLatest || isViewingLatest,
            );
            // 种子生成控制：生图后变更种子 (若 timing == after)
            if (_params.seedTiming == NaiSeedTiming.after) {
              _applySeedMutationAfter(results.first.seed);
            }
          }
        } catch (e) {
          reportError(
            vmL10n.vmGenFailed('$e'),
            source: AppNoticeSource.generation,
            notify: false,
          );
          _statusMessage = null;
        } finally {
          _isGenerating = false;
          _generationBackgrounded = false;
          _liveProgressController.clear();
          notifyListeners();
          unawaited(refreshAccountInfo());
        }
      }
    } finally {
      _isStartingGeneration = false;
    }
  }

  /// 生图前根据种子模式更新种子 (当 timing == before 时触发)
  @override
  void _applySeedMutationBefore() {
    switch (_params.seedMode) {
      case NaiSeedMode.random:
        final newSeed = generateRandomSeed();
        _params = _params.copyWith(seed: newSeed);
        break;
      case NaiSeedMode.increase:
        final current = _params.seed;
        final next = current < 0
            ? generateRandomSeed()
            : (current + 1) % 4294967295;
        _params = _params.copyWith(seed: next);
        break;
      case NaiSeedMode.fixed:
        break;
    }
    if (_params.seedMode != NaiSeedMode.fixed) _scheduleParameterSave();
  }

  /// 生图后根据种子模式更新种子 (当 timing == after 时触发)
  @override
  void _applySeedMutationAfter(int generatedSeed) {
    switch (_params.seedMode) {
      case NaiSeedMode.random:
        final nextSeed = generateRandomSeed();
        _params = _params.copyWith(seed: nextSeed);
        break;
      case NaiSeedMode.increase:
        final base = generatedSeed >= 0
            ? generatedSeed
            : (_params.seed >= 0 ? _params.seed : 0);
        final nextSeed = (base + 1) % 4294967295;
        _params = _params.copyWith(seed: nextSeed);
        break;
      case NaiSeedMode.fixed:
        break;
    }
    if (_params.seedMode != NaiSeedMode.fixed) _scheduleParameterSave();
  }

  /// 超分放大当前图片 (官方新超分模型，固定倍率输出)
  @override
  Future<void> upscaleSelected() async {
    // /upscale 与画板操作条都可能在生成中被触发；付费操作必须互斥。
    if (_isGenerating || _isStartingGeneration) return;
    if (_selectedImage == null) {
      reportError(
        vmL10n.vmUpscaleNoImage,
        source: AppNoticeSource.generation,
      );
      return;
    }

    if (_config.novelAiKey.trim().isEmpty) {
      reportError(
        vmL10n.vmUpscaleNoApiKey,
        source: AppNoticeSource.generation,
      );
      return;
    }

    // 官方超分按输入面积分档计费；用户手动超分不弹付费确认，
    // 画板操作条与账号栏已展示点数信息，付费确认卡片只保留给 Agent 场景。

    _isGenerating = true;
    _generationBackgrounded = false;
    _errorMessage = null;
    _statusMessage = vmL10n.vmUpscaleRunning;
    notifyListeners();

    try {
      final loaded = await ensureImageLoaded(_selectedImage!);
      if (loaded != null && _selectedImage!.bytes.isEmpty) {
        _selectedImage = _selectedImage!.copyWith(bytes: loaded);
      }
      final upscaled = await _repository.upscale(
        apiKey: _config.novelAiKey,
        sourceImage: _selectedImage!,
        saveDir: _config.saveDirectory,
        enablePersistence: _config.enableImagePersistence,
        maxImages: _config.maxPersistentImages,
        stripMetadata: effectiveStripMetadata,
        enableWatermark: _config.enableWatermark,
        keepOriginalImage: _config.keepOriginalImage,
        watermarkConfig: _config.watermarkConfig,
        watermarkBytes: _config.watermarkConfig.imageBytes,
        autoSave: _config.autoSaveImages,
        imageSaveTemplate: _config.imageSaveTemplate,
      );
      _selectedImage = upscaled;
      _statusMessage = upscaled.isUnsaved
          ? vmL10n.vmUpscaleDoneUnsaved(
              upscaled.params.width,
              upscaled.params.height,
            )
          : vmL10n.vmUpscaleDone(upscaled.params.width, upscaled.params.height);
    } catch (e) {
      reportError(
        vmL10n.vmUpscaleFailed('$e'),
        source: AppNoticeSource.generation,
        notify: false,
      );
      _statusMessage = null;
    } finally {
      _isGenerating = false;
      _generationBackgrounded = false;
      notifyListeners();
      unawaited(refreshAccountInfo());
    }
  }

  /// Windows 本地 RTX 放大：冻结菜单目标，不读取执行期间切换的选中图。
  Future<void> _upscaleRtxImage(NaiGeneratedImage image) async {
    if (_isGenerating || _rtxDisposed || !supportsRtxUpscale) return;
    _isGenerating = true;
    _generationBackgrounded = false;
    _isRtxUpscaling = true;
    _errorMessage = null;
    _statusMessage = vmL10n.vmUpscaleRunning;
    notifyListeners();
    // 配置也取快照，避免处理期间切换目录造成混用。
    final config = _config;
    try {
      final result = await _repository.upscale(
        apiKey: '',
        rtxScale: config.rtxUpscaleScale,
        sourceImage: image,
        saveDir: config.saveDirectory,
        enablePersistence: config.enableImagePersistence,
        maxImages: config.maxPersistentImages,
        stripMetadata: config.stripMetadata,
        enableWatermark: config.enableWatermark,
        keepOriginalImage: config.keepOriginalImage,
        watermarkConfig: config.watermarkConfig,
        watermarkBytes: config.watermarkConfig.imageBytes,
        autoSave: config.autoSaveImages,
        imageSaveTemplate: config.imageSaveTemplate,
      );
      if (_rtxDisposed) return;
      _applyGeneratedImage(result, wasViewingLatest: true);
      _statusMessage = result.isUnsaved
          ? vmL10n.vmUpscaleDoneUnsaved(
              result.params.width,
              result.params.height,
            )
          : vmL10n.vmUpscaleDone(result.params.width, result.params.height);
    } on RtxUpscaleException catch (e) {
      if (_rtxDisposed) return;
      if (e.cancelled) {
        _statusMessage = vmL10n.vmGenAborted;
      } else {
        reportError(
          vmL10n.vmUpscaleFailed('$e'),
          source: AppNoticeSource.generation,
          notify: false,
        );
        _statusMessage = null;
      }
    } catch (e) {
      if (_rtxDisposed) return;
      reportError(
        vmL10n.vmUpscaleFailed('$e'),
        source: AppNoticeSource.generation,
        notify: false,
      );
      _statusMessage = null;
    } finally {
      _isRtxUpscaling = false;
      _isGenerating = false;
      _generationBackgrounded = false;
      if (!_rtxDisposed) notifyListeners();
    }
  }

  /// 获取用于导出/复制的图像字节 (根据全局设置决定是否去元数据或添加水印)
  @override
  Future<Uint8List> getExportImageBytes(
    NaiGeneratedImage image, {
    bool raw = false,
  }) async {
    final bytes = await ensureImageLoaded(image) ?? image.bytes;
    final rawBytes = ImageMetadataService.embedNovelAiMetadata(
      pngBytes: bytes,
      params: image.params,
      seed: image.seed,
    );
    if (raw) return rawBytes;

    return WatermarkService.processExportImage(
      rawBytes: rawBytes,
      stripMetadata: effectiveStripMetadata,
      enableWatermark: _config.enableWatermark,
      watermarkConfig: _config.watermarkConfig,
      watermarkBytes: _config.watermarkConfig.imageBytes,
    );
  }

  /// 图生图：设置或清除源图 (null 表示回到纯文生图)。
  @override
  void setImg2imgSource(Uint8List? bytes) {
    updateParams(
      bytes == null
          ? _params.copyWith(clearImg2img: true)
          : _params.copyWith(img2imgBytes: bytes),
    );
  }

  void setImg2imgStrength(double value) {
    updateParams(
      _params.copyWith(img2imgStrength: value.clamp(0.01, 0.99).toDouble()),
    );
  }

  void setImg2imgNoise(double value) {
    updateParams(
      _params.copyWith(img2imgNoise: value.clamp(0.0, 0.99).toDouble()),
    );
  }

  /// 把当前画板选中的图片设为图生图源图。
  @override
  Future<bool> useSelectedImageAsImg2imgSource() async {
    final image = _selectedImage;
    if (image == null) return false;
    final bytes = await ensureImageLoaded(image);
    if (bytes == null || bytes.isEmpty) return false;
    setImg2imgSource(bytes);
    return true;
  }

  /// 把当前画板选中的图片追加为一张 Vibe Transfer 参考图。
  @override
  Future<bool> useSelectedImageAsReference() async {
    final image = _selectedImage;
    if (image == null) return false;
    final bytes = await ensureImageLoaded(image);
    if (bytes == null || bytes.isEmpty) return false;
    addReferenceImage(bytes);
    return true;
  }

  void addReferenceImage(Uint8List bytes) {
    updateParams(
      _params.copyWith(
        referenceImages: <NaiReferenceImage>[
          ..._params.referenceImages,
          NaiReferenceImage(bytes: bytes),
        ],
      ),
    );
  }

  void updateReferenceImage(
    int index, {
    double? strength,
    double? informationExtracted,
  }) {
    final list = List<NaiReferenceImage>.from(_params.referenceImages);
    if (index < 0 || index >= list.length) return;
    final current = list[index];
    list[index] = NaiReferenceImage(
      bytes: current.bytes,
      strength: strength ?? current.strength,
      informationExtracted:
          informationExtracted ?? current.informationExtracted,
    );
    updateParams(_params.copyWith(referenceImages: list));
  }

  void removeReferenceImage(int index) {
    final list = List<NaiReferenceImage>.from(_params.referenceImages);
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    updateParams(_params.copyWith(referenceImages: list));
  }

  @override
  void clearReferenceImages() {
    updateParams(_params.copyWith(clearReferenceImages: true));
  }

  /// 添加一张 Precise Reference（角色 / 画风参考，仅 V4.5）。
  void addPreciseReference(
    Uint8List bytes, {
    NaiPreciseRefType type = NaiPreciseRefType.characterAndStyle,
    double strength = 1.0,
    double fidelity = 1.0,
    bool preferSameOutfit = false,
  }) {
    if (!_params.model.supportsPreciseReference ||
        bytes.isEmpty ||
        _params.preciseReferences.length >= 16) {
      return;
    }
    updateParams(
      _params.copyWith(
        preciseReferences: <NaiPreciseReference>[
          ..._params.preciseReferences,
          NaiPreciseReference(
            bytes: bytes,
            type: type,
            strength: strength,
            fidelity: fidelity,
            preferSameOutfit: preferSameOutfit,
          ),
        ],
      ),
    );
  }

  Future<bool> addSelectedImageAsPreciseReference({
    NaiPreciseRefType type = NaiPreciseRefType.characterAndStyle,
    double strength = 1.0,
    double fidelity = 1.0,
    bool preferSameOutfit = false,
  }) async {
    final image = _selectedImage;
    if (image == null) return false;
    final bytes = await ensureImageLoaded(image);
    if (bytes == null || bytes.isEmpty) return false;
    addPreciseReference(
      bytes,
      type: type,
      strength: strength,
      fidelity: fidelity,
      preferSameOutfit: preferSameOutfit,
    );
    return true;
  }

  void updatePreciseReference(
    int index, {
    NaiPreciseRefType? type,
    double? strength,
    double? fidelity,
    bool? preferSameOutfit,
    bool? enabled,
  }) {
    final list = List<NaiPreciseReference>.from(_params.preciseReferences);
    if (index < 0 || index >= list.length) return;
    list[index] = list[index].copyWith(
      type: type,
      strength: strength,
      fidelity: fidelity,
      preferSameOutfit: preferSameOutfit,
      enabled: enabled,
    );
    updateParams(_params.copyWith(preciseReferences: list));
  }

  void removePreciseReference(int index) {
    final list = List<NaiPreciseReference>.from(_params.preciseReferences);
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    updateParams(_params.copyWith(preciseReferences: list));
  }

  void clearPreciseReferences() {
    updateParams(_params.copyWith(clearPreciseReferences: true));
  }

  @override
  Future<void> refreshAccountInfo({bool showError = false}) async {
    if (_config.novelAiKey.trim().isEmpty) {
      if (_accountInfo != null) {
        _accountInfo = null;
        notifyListeners();
      }
      return;
    }

    _isLoadingAccount = true;
    notifyListeners();

    try {
      _accountInfo = await _repository.fetchAccountInfo(
        apiKey: _config.novelAiKey,
      );
      // 本地 fork：账号池同步当前账号可用点数等元信息
      await _syncActiveAccountInfo();
    } catch (e) {
      if (showError) {
        _accountInfo = null;
        reportError(
          vmL10n.vmAccountRefreshFailed('$e'),
          source: AppNoticeSource.account,
          notify: false,
        );
      }
    } finally {
      _isLoadingAccount = false;
      notifyListeners();
    }
  }
}