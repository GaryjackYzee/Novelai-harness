/// AITag (aitag.win) work search and metadata import.
///
/// Search returns lightweight rows; the real prompt and NovelAI parameters are
/// parsed from the work detail's `images[0].ai_json` (`Comment` JSON).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/aitag_models.dart';
import 'network_proxy_service.dart';

/// Raised when AITag is unreachable or returns an unexpected payload.
class AitagException implements Exception {
  const AitagException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'AitagException($message)';
}

/// Stateless HTTP client for aitag.win.
class AitagService {
  AitagService._()
    : this._raw(
        NetworkProxyService.instance.createClient(NetworkFeature.gallery),
        _defaultBaseUrl,
      );

  AitagService.forTesting({required http.Client client, String? baseUrl})
    : this._raw(client, baseUrl ?? _defaultBaseUrl);

  AitagService._raw(this._client, this._baseUrl);

  static const String _defaultBaseUrl = 'https://aitag.win';

  static const Map<String, String> _jsonHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    'Referer': 'https://aitag.win/',
    'Origin': 'https://aitag.win',
    'Accept': 'application/json, text/plain, */*',
  };

  /// AITag 列表里的原图多来自 Pixiv (i.pximg.net)，必须带 Pixiv Referer，
  /// 否则会被防盗链返回 403；其他 CDN 仍使用 AITag Referer。
  /// 把 Pixiv 原图地址转换成 540 缩略图，避免列表直接拉数 MB 原图。
  static String thumbnailUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.host.toLowerCase().endsWith('pximg.net')) {
      return url;
    }
    if (!uri.path.contains('/img-original/')) return url;
    var path = uri.path.replaceFirst(
      '/img-original/',
      '/c/540x540_70/img-master/',
    );
    path = path.replaceFirstMapped(
      RegExp(r'_(p\d+)\.(png|jpg|jpeg)$', caseSensitive: false),
      (match) => '_${match.group(1)}_master1200.jpg',
    );
    return uri.replace(path: path).toString();
  }

  static Map<String, String> _imageHeadersFor(Uri uri) {
    final host = uri.host.toLowerCase();
    final referer = host.endsWith('pximg.net')
        ? 'https://www.pixiv.net/'
        : 'https://aitag.win/';
    return <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
      'Referer': referer,
      'Accept':
          'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Sec-Fetch-Dest': 'image',
      'Sec-Fetch-Mode': 'no-cors',
      'Sec-Fetch-Site': 'cross-site',
    };
  }

  static final AitagService instance = AitagService._();

  final http.Client _client;
  final String _baseUrl;
  final Map<String, AitagWorkDetail> _workCache = <String, AitagWorkDetail>{};
  final Map<String, String> _modelBadges = <String, String>{};

  /// Search works by free text; empty queries fall back to `1girl`.
  Future<List<AitagWork>> search(String query, {int page = 1}) async {
    final term = query.trim().isEmpty ? '1girl' : query.trim();
    final uri = Uri.parse('$_baseUrl/api/ai_works_search').replace(
      queryParameters: <String, String>{
        'sensitive_policy': '1',
        'q': term,
        'page': '${page < 1 ? 1 : page}',
      },
    );
    final http.Response response;
    try {
      response = await _client.get(uri, headers: _jsonHeaders);
    } on Exception catch (error) {
      throw AitagException('AITag 不可达：$error');
    }
    if (response.statusCode == 404) {
      throw AitagException('AITag 没有找到「$term」的结果', statusCode: 404);
    }
    if (response.statusCode != 200) {
      throw AitagException(
        'AITag 返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final data = _decodeObject(response.bodyBytes, 'search');
    final rawItems = data['items'];
    if (rawItems is! List) return const <AitagWork>[];
    return rawItems
        .whereType<Map>()
        .map((item) => AitagWork.fromJson(Map<String, dynamic>.from(item)))
        .where((work) => work.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Fetch one work and parse its full NovelAI metadata.
  Future<AitagWorkDetail> work(String id) async {
    final key = id.trim();
    if (key.isEmpty) throw const AitagException('缺少作品 id');
    final cached = _workCache[key];
    if (cached != null) return cached;
    final uri = Uri.parse('$_baseUrl/api/work/$key');
    final http.Response response;
    try {
      response = await _client.get(uri, headers: _jsonHeaders);
    } on Exception catch (error) {
      throw AitagException('AITag 不可达：$error');
    }
    if (response.statusCode != 200) {
      throw AitagException(
        'AITag 作品返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final data = _decodeObject(response.bodyBytes, 'work');
    final rawImages = data['images'];
    Map<String, dynamic>? image;
    if (rawImages is List && rawImages.isNotEmpty && rawImages.first is Map) {
      image = Map<String, dynamic>.from(rawImages.first as Map);
    }
    final promptText = '${image?['prompt_text'] ?? ''}'.trim();
    final parsed = _parseAiJson('${image?['ai_json'] ?? ''}');
    final characters = parsed.characters;
    final prompt = dedupePrompt(
      prompt: promptText,
      basePrompt: parsed.basePrompt,
      characters: characters,
    );
    final result = AitagWorkDetail(
      id: key,
      prompt: prompt,
      negative: parsed.negative,
      modelName: parsed.modelName,
      width: parsed.width,
      height: parsed.height,
      steps: parsed.steps,
      scale: parsed.scale,
      sampler: parsed.sampler,
      noiseSchedule: parsed.noiseSchedule,
      seed: parsed.seed,
      characters: characters,
    );
    _workCache[key] = result;
    if (_workCache.length > 240) {
      _workCache.remove(_workCache.keys.first);
    }
    return result;
  }

  /// 批量解析 NAI 作品的细分模型徽标（与 DSH 插件一致，4 个并发）。
  Future<Map<String, String>> resolveModelBadges(List<String> ids) async {
    final wanted = ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && !_modelBadges.containsKey(id))
        .toSet()
        .toList(growable: false);
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < wanted.length) {
        final id = wanted[cursor++];
        try {
          final detail = await work(id);
          _modelBadges[id] = badgeForModel(detail.modelName);
        } on Object {
          _modelBadges[id] = 'NAI';
        }
      }
    }

    await Future.wait(<Future<void>>[worker(), worker(), worker(), worker()]);
    return <String, String>{
      for (final id in ids)
        if (_modelBadges[id] != null) id: _modelBadges[id]!,
    };
  }

  static String badgeForModel(String model) {
    final text = model.toLowerCase();
    if (RegExp(r'diffusion v5|v5|nai5').hasMatch(text)) return 'NAI5';
    if (RegExp(r'4\.5|v4\.5').hasMatch(text)) return 'NAI4.5';
    if (RegExp(r'diffusion v4|v4\b').hasMatch(text)) return 'NAI4';
    if (RegExp(r'v3|furry').hasMatch(text)) return 'NAI3';
    return 'NAI';
  }

  /// Download a pixiv image through AITag's referer requirement.
  static const int _maxImageRequests = 4;
  int _activeImageRequests = 0;
  final List<({int priority, Completer<void> completer})> _imageWaiters =
      <({int priority, Completer<void> completer})>[];

  Future<T> _withImageSlot<T>(int priority, Future<T> Function() action) async {
    while (_activeImageRequests >= _maxImageRequests) {
      final waiter = Completer<void>();
      _imageWaiters.add((priority: priority, completer: waiter));
      _imageWaiters.sort((a, b) => a.priority.compareTo(b.priority));
      await waiter.future;
    }
    _activeImageRequests += 1;
    try {
      return await action();
    } finally {
      _activeImageRequests -= 1;
      if (_imageWaiters.isNotEmpty) {
        _imageWaiters.removeAt(0).completer.complete();
      }
    }
  }

  Future<Uint8List> fetchImage(String url, {int priority = 0}) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return Future<Uint8List>.error(const AitagException('缺少图片地址'));
    }
    return _withImageSlot(priority, () async {
      Object? lastError;
      for (var attempt = 0; attempt < 2; attempt += 1) {
        try {
          final uri = Uri.parse(trimmed);
          final response = await _client
              .get(uri, headers: _imageHeadersFor(uri))
              .timeout(const Duration(seconds: 20));
          if (response.statusCode == 200) return response.bodyBytes;
          if (response.statusCode >= 500 && attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            continue;
          }
          throw AitagException(
            'AITag 图片返回 HTTP ${response.statusCode}',
            statusCode: response.statusCode,
          );
        } on AitagException {
          rethrow;
        } on Object catch (error) {
          lastError = error;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
        }
      }
      throw AitagException('AITag 图片不可达：$lastError');
    });
  }

  /// Keep character captions out of the main prompt when they were inlined.
  static String dedupePrompt({
    required String prompt,
    required String basePrompt,
    required List<AitagCharacter> characters,
  }) {
    final text = prompt.trim();
    final base = basePrompt.trim();
    if (characters.isEmpty) return text;
    final captions = characters
        .map((character) => character.prompt.trim())
        .where((caption) => caption.isNotEmpty)
        .toList(growable: false);
    if (captions.isEmpty) return text;
    if (captions.any(text.contains) && base.isNotEmpty) return base;
    var stripped = text;
    for (final caption in captions) {
      stripped = stripped.replaceAll(caption, ' ');
    }
    return stripped
        .replaceAll(RegExp(r',\s*,+'), ', ')
        .replaceAll(RegExp(r'^\s*,\s*|\s*,\s*$'), '')
        .trim();
  }

  Map<String, dynamic> _decodeObject(Uint8List bytes, String scope) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      throw AitagException('AITag $scope 数据解析失败：$error');
    }
    throw AitagException('AITag $scope 数据格式未知');
  }

  _ParsedMeta _parseAiJson(String raw) {
    if (raw.trim().isEmpty) return const _ParsedMeta();
    try {
      final outer = jsonDecode(raw);
      if (outer is! Map) return const _ParsedMeta();
      final rawComment = outer['Comment'];
      final comment = rawComment is String
          ? jsonDecode(rawComment)
          : rawComment;
      if (comment is! Map) return const _ParsedMeta();
      return _ParsedMeta.fromComment(comment);
    } on FormatException {
      return const _ParsedMeta();
    }
  }
}

class _ParsedMeta {
  const _ParsedMeta({
    this.basePrompt = '',
    this.negative = '',
    this.modelName = '',
    this.width,
    this.height,
    this.steps,
    this.scale,
    this.sampler = '',
    this.noiseSchedule = '',
    this.seed,
    this.characters = const <AitagCharacter>[],
  });

  factory _ParsedMeta.fromComment(Map<dynamic, dynamic> comment) {
    final v4 = comment['v4_prompt'];
    final caption = v4 is Map ? v4['caption'] : null;
    final basePrompt = caption is Map ? '${caption['base_caption'] ?? ''}' : '';
    final rawCharacters = caption is Map ? caption['char_captions'] : null;
    final characters = <AitagCharacter>[];
    if (rawCharacters is List) {
      for (final entry in rawCharacters.whereType<Map>()) {
        final centers = entry['centers'];
        var x = 0.5;
        var y = 0.5;
        if (centers is List && centers.isNotEmpty && centers.first is Map) {
          final center = centers.first as Map;
          x = _toDouble(center['x']) ?? 0.5;
          y = _toDouble(center['y']) ?? 0.5;
        }
        final prompt = '${entry['char_caption'] ?? ''}'.trim();
        if (prompt.isNotEmpty) {
          characters.add(AitagCharacter(prompt: prompt, x: x, y: y));
        }
      }
    }
    final negative = '${comment['uc'] ?? ''}'.trim();
    return _ParsedMeta(
      basePrompt: basePrompt.trim(),
      negative: negative,
      modelName: '${comment['model_name'] ?? ''}'.trim(),
      width: _toInt(comment['width']),
      height: _toInt(comment['height']),
      steps: _toInt(comment['steps']),
      scale: _toDouble(comment['scale']),
      sampler: '${comment['sampler'] ?? ''}'.trim(),
      noiseSchedule: '${comment['noise_schedule'] ?? ''}'.trim(),
      seed: _toInt(comment['seed']),
      characters: List<AitagCharacter>.unmodifiable(characters),
    );
  }

  final String basePrompt;
  final String negative;
  final String modelName;
  final int? width;
  final int? height;
  final int? steps;
  final double? scale;
  final String sampler;
  final String noiseSchedule;
  final int? seed;
  final List<AitagCharacter> characters;
}

int? _toInt(Object? value) {
  final number = value is num ? value : num.tryParse('$value');
  return number?.toInt();
}

double? _toDouble(Object? value) {
  final number = value is num ? value : num.tryParse('$value');
  return number?.toDouble();
}
