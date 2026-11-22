import 'dart:convert';

import 'package:http/http.dart' as http;

/// 在线 WD14 反推结果。
class Wd14Tag {
  const Wd14Tag({required this.name, required this.score});

  final String name;
  final double score;

  Map<String, dynamic> toJson() => {'name': name, 'score': score};

  factory Wd14Tag.fromJson(Map<String, dynamic> json) {
    final rawLabel =
        '${json['name'] ?? json['label'] ?? json['tag'] ?? ''}';
    final name = rawLabel.replaceAll('_', ' ').trim();
    final score = (json['score'] ?? json['confidence'] ?? 0).toDouble();
    return Wd14Tag(name: name, score: score);
  }
}

class Wd14Exception implements Exception {
  Wd14Exception(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 在线 WD14：把图片 POST 到兼容的推理端点并解析标签。
///
/// 默认端点走 Hugging Face Inference API 的 WD14 模型；
/// 也可以换成任意返回 `[{label, score}]` 或 `{"tags": {...}}` 的服务。
class Wd14OnlineService {
  Wd14OnlineService({http.Client? client}) : _client = client ?? http.Client();

  /// 默认使用 deepghs 的 WD14 Gradio Space（无需 Token）。
  static const String defaultEndpoint =
      'https://deepghs-wd14-tagging-online.hf.space/api/predict';

  final http.Client _client;

  Future<List<Wd14Tag>> tag({
    required List<int> imageBytes,
    String endpoint = defaultEndpoint,
    String token = '',
    double threshold = 0.35,
    int maxTags = 40,
  }) async {
    final trimmed = endpoint.trim();
    if (trimmed.isEmpty) {
      throw Wd14Exception('WD14 端点为空');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      throw Wd14Exception('WD14 端点不是合法 URL：$trimmed');
    }
    final gradio = _isGradio(uri);
    final headers = <String, String>{
      'Content-Type': gradio ? 'application/json' : 'image/png',
      'Accept': 'application/json',
      if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
    };
    final Object body;
    if (gradio) {
      final base64Data = 'data:image/png;base64,'
          '${_base64Encode(imageBytes)}';
      body = jsonEncode({
        'data': [
          base64Data,
          'wd14-vit',
          threshold,
          true,
          false,
          false,
          true,
        ],
        'fn_index': 0,
        'session_hash': 'dsh-wd14-${DateTime.now().millisecondsSinceEpoch}',
        'event_data': null,
      });
    } else {
      body = imageBytes;
    }
    http.Response? response;
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt += 1) {
      try {
        response = await _client
            .post(uri, headers: headers, body: body)
            .timeout(const Duration(seconds: 180));
        final code = response.statusCode;
        if (attempt == 1 && (code == 429 || code >= 500)) {
          await Future.delayed(const Duration(milliseconds: 800));
          continue;
        }
        break;
      } on Object catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 800));
        }
      }
    }
    if (response == null) {
      throw Wd14Exception('请求 WD14 失败：$lastError');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Wd14Exception(
        'WD14 返回 ${response.statusCode}：${_shortBody(response.body)}',
      );
    }
    final tags = _parse(response.body);
    if (tags.isEmpty) {
      throw Wd14Exception('WD14 没有返回可用标签，检查端点/模型/Token');
    }
    final filtered = tags
        .where((tag) => tag.name.isNotEmpty && tag.score >= threshold)
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return filtered.take(maxTags).toList(growable: false);
  }

  bool _isGradio(Uri uri) =>
      uri.host.contains('hf.space') ||
      uri.path.endsWith('/api/predict') ||
      uri.path.endsWith('/run/predict');

  String _base64Encode(List<int> bytes) {
    const chunk = 3;
    final codes = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final out = StringBuffer();
    for (var i = 0; i < bytes.length; i += chunk) {
      final remaining = bytes.length - i;
      final b0 = bytes[i];
      final b1 = remaining > 1 ? bytes[i + 1] : 0;
      final b2 = remaining > 2 ? bytes[i + 2] : 0;
      out.write(codes[b0 >> 2]);
      out.write(codes[((b0 & 0x03) << 4) | (b1 >> 4)]);
      out.write(remaining > 1 ? codes[((b1 & 0x0F) << 2) | (b2 >> 6)] : '=');
      out.write(remaining > 2 ? codes[b2 & 0x3F] : '=');
    }
    return out.toString();
  }

  List<Wd14Tag> _parseGradio(Map decoded) {
    final data = decoded['data'];
    if (data is! List) return const <Wd14Tag>[];
    const ratingLabels = {'general', 'sensitive', 'questionable', 'explicit'};
    List<Wd14Tag>? best;
    for (final item in data) {
      if (item is! Map || item['confidences'] is! List) continue;
      final confidences = item['confidences'] as List;
      final tags = confidences
          .whereType<Map>()
          .map((entry) => Wd14Tag(
                name: '${entry['label'] ?? ''}'.replaceAll('_', ' ').trim(),
                score: (entry['confidence'] as num?)?.toDouble() ?? 0,
              ))
          .where((tag) =>
              tag.name.isNotEmpty && !ratingLabels.contains(tag.name))
          .toList(growable: false);
      if (tags.isEmpty) continue;
      if (best == null || tags.length > best.length) best = tags;
    }
    if (best != null) return best;
    // 兼容 data[1] 的逗号分隔字符串。
    for (final item in data) {
      if (item is String && item.contains(',')) {
        return item
            .split(',')
            .map((part) => part.trim().replaceAll('_', ' '))
            .where((part) => part.isNotEmpty)
            .map((name) => Wd14Tag(name: name, score: 1))
            .toList(growable: false);
      }
    }
    return const <Wd14Tag>[];
  }

  List<Wd14Tag> _parse(String body) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on Object {
      throw Wd14Exception('WD14 返回的不是 JSON：${_shortBody(body)}');
    }
    if (decoded is Map && decoded['data'] is List) {
      return _parseGradio(decoded);
    }
    if (decoded is Map) {
      final error = decoded['error'];
      if (error != null) throw Wd14Exception('WD14 错误：$error');
      final tags = decoded['tags'] ?? decoded['labels'];
      if (tags is Map) {
        return tags.entries
            .map((entry) => Wd14Tag(
                  name: '${entry.key}'.replaceAll('_', ' ').trim(),
                  score: (entry.value as num?)?.toDouble() ?? 0,
                ))
            .toList(growable: false);
      }
      if (tags is List) return _parseList(tags);
      return const <Wd14Tag>[];
    }
    if (decoded is List) return _parseList(decoded);
    return const <Wd14Tag>[];
  }

  List<Wd14Tag> _parseList(List<dynamic> raw) {
    final flattened = <Wd14Tag>[];
    for (final item in raw) {
      if (item is Map) {
        flattened.add(Wd14Tag.fromJson(Map<String, dynamic>.from(item)));
      } else if (item is List) {
        flattened.addAll(_parseList(item));
      }
    }
    return flattened;
  }

  String _shortBody(String body) =>
      body.length > 200 ? '${body.substring(0, 200)}…' : body;
}
