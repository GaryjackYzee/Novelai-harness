/// AITag (aitag.win) work models.
///
/// The search endpoint returns lightweight works; the real prompt and
/// generation parameters live in the work detail (`images[0].ai_json`).
library;

import 'dart:convert';

/// One character caption recovered from a work's NovelAI `v4_prompt`.
class AitagCharacter {
  const AitagCharacter({required this.prompt, this.x = 0.5, this.y = 0.5});

  final String prompt;
  final double x;
  final double y;
}

/// A work row from `/api/ai_works_search`.
class AitagWork {
  const AitagWork({
    required this.id,
    required this.title,
    required this.tags,
    required this.date,
    required this.imageCount,
    required this.thumbUrl,
    this.imageUrls = const <String>[],
    this.aiType = '',
  });

  final String id;
  final String title;
  final List<String> tags;
  final String? date;
  final int imageCount;

  /// 第一张原图；保留旧字段名兼容现有卡片。
  final String thumbUrl;

  /// 作品的全部原图地址。
  final List<String> imageUrls;

  /// AITag 列表接口的 AI_type（NAI / SD / ComfyUI）。
  final String aiType;

  factory AitagWork.fromJson(Map<String, dynamic> json) {
    final originals = _stringList(json['original_urls']);
    final id = '${json['id'] ?? ''}';
    return AitagWork(
      id: id,
      title: '${json['title'] ?? ''}',
      tags: _stringList(json['tags']),
      date: json['create_date'] is String
          ? json['create_date'] as String
          : null,
      imageCount: _asInt(json['image_count']) ?? 1,
      thumbUrl: originals.isNotEmpty ? originals.first : '',
      imageUrls: originals,
      aiType: json['AI_type'] is String ? json['AI_type'] as String : '',
    );
  }
}

/// Full metadata for one work, parsed from `ai_json`.
class AitagWorkDetail {
  const AitagWorkDetail({
    required this.id,
    required this.prompt,
    required this.negative,
    required this.modelName,
    required this.width,
    required this.height,
    required this.steps,
    required this.scale,
    required this.sampler,
    required this.noiseSchedule,
    required this.seed,
    required this.characters,
  });

  final String id;
  final String prompt;
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

List<String> _stringList(Object? value) {
  if (value is List) {
    return value
        .whereType<Object>()
        .map((item) => '$item'.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  if (value is String) {
    final text = value.trim();
    if (text.startsWith('[') && text.endsWith(']')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) return _stringList(decoded);
      } on Object {
        // ignore malformed JSON strings
      }
    }
  }
  return const <String>[];
}

int? _asInt(Object? value) {
  final number = value is num ? value : num.tryParse('$value');
  return number?.toInt();
}
