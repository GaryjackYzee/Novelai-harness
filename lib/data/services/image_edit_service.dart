library;

import 'package:flutter/foundation.dart';

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// AI 整图编辑结果：编辑后的图片字节与模型附带的文字说明
class ImageEditResult {
  final Uint8List imageBytes;
  final String? textReply;

  const ImageEditResult({required this.imageBytes, this.textReply});
}

/// AI 整图编辑服务：把整张图片发给 OpenAI 兼容端点上的绘图 / 图像编辑模型
/// (如 nano banana / gemini-2.5-flash-image / gpt-image / seedream)，按
/// 自然语言指令重绘整张图片。
///
/// 请求走标准 /chat/completions：图片以 data URL 放进 image_url 内容块，
/// 并附 modalities: ['image', 'text'] (OpenRouter 系网关要求；其余网关会
/// 忽略该字段)。返回图片的解析兼容四种主流格式：
/// 1. message.images 数组 (OpenRouter: {type:'image_url', image_url:{url}})
/// 2. message.content 为内容块数组 (newapi: {type:'image_url'|'image', ...})
/// 3. message.content 为字符串内嵌 markdown 图片 / data URL
/// 4. 图片为 http(s) 临时链接时自动下载取回字节
class ImageEditService {
  final http.Client _client;
  final bool _ownsClient;

  /// 429 频控重试前的等待时长 (测试可注入短时长)
  final Duration retryDelay;

  ImageEditService({
    http.Client? client,
    this.retryDelay = const Duration(milliseconds: 2500),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// 关闭内部自建的 HTTP 客户端；外部注入时保持原生命周期不变。
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  /// 计算 /chat/completions 完整端点 (复用 LlmProviderConfig 的拼接语义)
  static String chatCompletionsEndpoint(String baseUrl) {
    var base = baseUrl.trim();
    if (base.isEmpty) return '';
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

  /// 校验字节是否为受支持的图片格式 (PNG / JPEG / WebP / GIF)
  static bool looksLikeImage(Uint8List bytes) {
    if (bytes.length < 12) return false;
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // WebP: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // GIF: GIF8
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true;
    }
    return false;
  }

  /// 执行整图编辑
  ///
  /// [aspectRatio] 生图比例 (如 "16:9"，空 = 跟随原图)；[imageResolution]
  /// 分辨率档位 ("1K" / "2K" / "4K"，空 = 默认)。同时适配 OpenRouter 的
  /// 顶层 image_config 与 new-api 的 extra_body.google.image_config；
  /// 只写顶层字段会被 new-api 的 Gemini 转换器忽略，退回默认输出档位。
  Future<ImageEditResult> editImage({
    required String baseUrl,
    required String apiKey,
    required String modelId,
    required String prompt,
    required Uint8List imageBytes,
    String aspectRatio = '',
    String imageResolution = '',
    Duration timeout = const Duration(seconds: 240),
  }) async {
    final endpoint = chatCompletionsEndpoint(baseUrl);
    if (endpoint.isEmpty) {
      throw Exception('请先在设置中配置绘图模型供应商的基础 URL');
    }

    final dataUrl = 'data:image/png;base64,${base64Encode(imageBytes)}';
    final imageConfig = <String, String>{
      if (aspectRatio.isNotEmpty) 'aspect_ratio': aspectRatio,
      if (imageResolution.isNotEmpty) 'image_size': imageResolution,
    };
    final body = jsonEncode({
      'model': modelId,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            },
          ],
        },
      ],
      'modalities': ['image', 'text'],
      if (imageConfig.isNotEmpty) ...{
        // OpenRouter 的 /chat/completions 图像输出扩展。
        'image_config': imageConfig,
        // new-api: relaykit/relayconvert/internal/oai_chat/to_gemini_chat_req.go
        // 仅从此层级提取配置并转换为 generationConfig.imageConfig。
        // 这里是直接发送的 HTTP JSON，不是 OpenAI SDK 的 extra_body 合并参数。
        'extra_body': {
          'google': {'image_config': imageConfig},
        },
      },
      // 保留旧代理的比例别名；new-api 的 chat 转换不依赖这两个字段
      // (其 size 比例处理属于 /images 的 imagen 分支，不能代替上述配置)。
      if (aspectRatio.isNotEmpty) ...{
        'aspect_ratio': aspectRatio,
        'size': aspectRatio,
      },
    });

    final headers = <String, String>{
      // 必须显式声明 utf-8：http 包对字符串请求体默认 Latin-1 编码，
      // 中文指令会直接抛 "Contains invalid characters"
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
    };
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $trimmedKey';
    }

    final endpointUri = Uri.parse(endpoint);
    http.Response response;
    try {
      response = await _client
          .post(endpointUri, headers: headers, body: body)
          .timeout(timeout);
    } catch (e) {
      throw Exception('网络连接失败 ($endpoint): $e');
    }

    // 429 频控：等待后单次重试 (与 NovelAI 请求同策略)
    if (response.statusCode == 429) {
      await Future<void>.delayed(retryDelay);
      try {
        response = await _client
            .post(endpointUri, headers: headers, body: body)
            .timeout(timeout);
      } catch (e) {
        throw Exception('网络连接失败 ($endpoint): $e');
      }
    }

    if (response.statusCode != 200) {
      final errBody = utf8.decode(response.bodyBytes, allowMalformed: true);
      String? serverMessage;
      try {
        final decoded = jsonDecode(errBody);
        if (decoded is Map<String, dynamic>) {
          final err = decoded['error'];
          if (err is Map<String, dynamic> && err['message'] is String) {
            serverMessage = err['message'] as String;
          } else if (decoded['message'] is String) {
            serverMessage = decoded['message'] as String;
          }
        }
      } catch (error) {
    debugPrint('[ignored] $error');}
      throw Exception(
        serverMessage != null
            ? '服务端响应错误 (HTTP ${response.statusCode}): $serverMessage'
            : '服务端响应错误 (HTTP ${response.statusCode}): ${errBody.length > 200 ? errBody.substring(0, 200) : errBody}',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } catch (e) {
      throw Exception('响应不是有效的 JSON: $e');
    }

    final candidates = extractImageCandidates(decoded);
    if (candidates.isEmpty) {
      throw Exception(
        '绘图模型未返回图片。请确认所选模型具备图像输出能力 (如 nano banana / gpt-image)，'
        '或查看模型文字回复: ${_extractPlainText(decoded)}',
      );
    }

    for (final candidate in candidates) {
      final bytes = await _resolveCandidate(
        candidate,
        headers: headers,
        timeout: timeout,
        providerUri: endpointUri,
      );
      if (bytes != null) {
        return ImageEditResult(
          imageBytes: bytes,
          textReply: _extractPlainText(decoded),
        );
      }
    }

    throw Exception('绘图模型返回的图片数据无法解析或下载。');
  }

  /// 单张图片下载上限 (防止恶意/异常响应把内存打满)
  static const int maxDownloadBytes = 32 * 1024 * 1024;

  /// 是否为回环/内网/元数据地址。跨域下载时禁止访问，避免 SSRF。
  static bool isPrivateHost(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return true;
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    if (h == 'metadata.google.internal') return true;
    if (h == '::1' || h == '[::1]' || h == '0.0.0.0') return true;
    final parts = h.split('.');
    if (parts.length != 4) return false;
    final nums = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return false;
      nums.add(n);
    }
    if (nums[0] == 10 || nums[0] == 127 || nums[0] == 0) return true;
    if (nums[0] == 169 && nums[1] == 254) return true;
    if (nums[0] == 172 && nums[1] >= 16 && nums[1] <= 31) return true;
    if (nums[0] == 192 && nums[1] == 168) return true;
    return false;
  }

  /// 下载候选图片。**只允许向与配置端点同源的主机发送鉴权头**；
  /// 跨域链接只做无凭据的匿名下载，且禁止内网/回环/非 https 目标。
  Future<Uint8List?> _resolveCandidate(
    String candidate, {
    required Map<String, String> headers,
    required Duration timeout,
    required Uri providerUri,
  }) async {
    if (candidate.startsWith('data:')) {
      // data URL 先做长度上限，避免超长 base64 在 base64Decode 前就把内存打满。
      if (candidate.length > maxDownloadBytes * 4 ~/ 3 + 1024) return null;
      final commaIdx = candidate.indexOf(',');
      if (commaIdx < 0) return null;
      final bytes = base64TryDecode(candidate.substring(commaIdx + 1));
      if (bytes == null ||
          bytes.length > maxDownloadBytes ||
          !looksLikeImage(bytes)) {
        return null;
      }
      return bytes;
    }
    if (candidate.startsWith('http://') || candidate.startsWith('https://')) {
      try {
        final targetUri = Uri.parse(candidate);
        final sameOrigin =
            targetUri.scheme == providerUri.scheme &&
            targetUri.host.toLowerCase() == providerUri.host.toLowerCase() &&
            targetUri.port == providerUri.port;
        if (!sameOrigin) {
          if (targetUri.scheme != 'https') return null;
          if (isPrivateHost(targetUri.host)) return null;
        }
        final downloadHeaders = <String, String>{'Accept': 'image/*'};
        if (sameOrigin) {
          // 仅复制鉴权相关头；不要把 JSON 的 Content-Type 带到图片 GET 上。
          for (final entry in headers.entries) {
            final key = entry.key.toLowerCase();
            if (key == 'authorization' ||
                key == 'x-api-key' ||
                key == 'x-goog-api-key') {
              downloadHeaders[entry.key] = entry.value;
            }
          }
        }
        final resp = await _client
            .get(targetUri, headers: downloadHeaders)
            .timeout(timeout);
        if (resp.statusCode != 200) return null;
        final body = resp.bodyBytes;
        if (body.length > maxDownloadBytes) return null;
        if (!looksLikeImage(body)) return null;
        return body;
      } catch (error) {
    debugPrint('[ignored] $error');
        return null;
      }
    }
    return null;
  }

  /// 从完整响应 JSON 中提取全部图片 URL 候选 (data URL 与 http 链接)
  ///
  /// 兼容四种返回格式，按可信度从高到低排序：
  /// 1. choices[0].message.images 数组 (OpenRouter)
  /// 2. choices[0].message.content 内容块数组 (image_url / output_image)
  /// 3. choices[0].message.content 字符串 (markdown 图片 / 裸 data URL)
  static List<String> extractImageCandidates(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) return const [];
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return const [];
    final first = choices[0];
    if (first is! Map<String, dynamic>) return const [];
    final message = first['message'];
    if (message is! Map<String, dynamic>) return const [];

    final candidates = <String>[];

    // 1. message.images 数组
    final images = message['images'];
    if (images is List) {
      for (final item in images) {
        final url = _urlOfImageEntry(item);
        if (url != null && !candidates.contains(url)) candidates.add(url);
      }
    }

    // 2. content 内容块数组
    final content = message['content'];
    if (content is List) {
      for (final part in content) {
        if (part is Map<String, dynamic>) {
          final url = _urlOfImageEntry(part);
          if (url != null && !candidates.contains(url)) candidates.add(url);
        }
      }
    }

    // 3. content 字符串：markdown 图片 + 裸 data URL
    if (content is String && content.isNotEmpty) {
      candidates.addAll(_extractUrlsFromText(content, candidates));
    }

    return candidates;
  }

  /// 从 message 中提取模型附带的纯文字回复 (去掉图片 URL，供结果摘要展示)
  static String? _extractPlainText(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices[0];
    if (first is! Map<String, dynamic>) return null;
    final message = first['message'];
    if (message is! Map<String, dynamic>) return null;

    final content = message['content'];
    if (content is String) {
      final text = content
          .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
          .replaceAll(RegExp(r'data:image/[^;\s]+;base64,[A-Za-z0-9+/=]+'), '')
          .trim();
      return text.isEmpty ? null : text;
    }
    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map<String, dynamic> && part['type'] == 'text') {
          final text = part['text'];
          if (text is String) buffer.write(text);
        }
      }
      final text = buffer.toString().trim();
      return text.isEmpty ? null : text;
    }
    return null;
  }

  /// 解析单个图片条目 / 内容块的 URL 字段
  static String? _urlOfImageEntry(dynamic item) {
    if (item is! Map) return null;
    final type = item['type'];
    if (type is String &&
        type != 'image_url' &&
        type != 'image' &&
        type != 'output_image') {
      return null;
    }
    // {image_url: {url}} 或 {url: ...} 或 {b64_json: ...}
    final imageurl = item['image_url'];
    if (imageurl is Map<String, dynamic>) {
      final url = imageurl['url'];
      if (url is String && url.isNotEmpty) return url;
    }
    if (imageurl is String && imageurl.isNotEmpty) return imageurl;
    final url = item['url'];
    if (url is String && url.isNotEmpty) return url;
    final b64 = item['b64_json'];
    if (b64 is String && b64.isNotEmpty) return 'data:image/png;base64,$b64';
    return null;
  }

  /// 从文本中提取 markdown 图片与裸 data URL
  static List<String> _extractUrlsFromText(String text, List<String> existing) {
    final result = <String>[];
    void add(String url) {
      if (url.isNotEmpty && !existing.contains(url) && !result.contains(url)) {
        result.add(url);
      }
    }

    // markdown: ![alt](url)
    for (final match in RegExp(r'!\[[^\]]*\]\(([^)]+)\)').allMatches(text)) {
      add(match.group(1)?.trim() ?? '');
    }
    // 裸 data URL
    for (final match in RegExp(
      r'data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+',
    ).allMatches(text)) {
      add(match.group(0) ?? '');
    }
    return result;
  }

  static Uint8List? base64TryDecode(String input) {
    try {
      return base64Decode(input.trim());
    } catch (error) {
    debugPrint('[ignored] $error');
      return null;
    }
  }
}