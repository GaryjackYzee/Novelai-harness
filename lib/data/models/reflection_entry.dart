import 'dart:convert';

/// 一条「梳理串」：agent 复盘/梦境整理的结构化记录。
class ReflectionEntry {
  const ReflectionEntry({
    required this.id,
    required this.title,
    required this.source,
    required this.summary,
    required this.lessons,
    required this.createdAt,
    this.sessionId = '',
  });

  final String id;
  final String title;

  /// auto / reflect / dream
  final String source;
  final String summary;
  final List<String> lessons;
  final DateTime createdAt;

  /// 产生该条目的会话 id；旧数据为空。
  final String sessionId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'summary': summary,
    'lessons': lessons,
    'createdAt': createdAt.toIso8601String(),
    'sessionId': sessionId,
  };

  factory ReflectionEntry.fromJson(Map<String, dynamic> json) {
    return ReflectionEntry(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      source: '${json['source'] ?? 'reflect'}',
      summary: '${json['summary'] ?? ''}',
      lessons:
          (json['lessons'] as List?)?.whereType<String>().toList(
            growable: false,
          ) ??
          const <String>[],
      createdAt:
          DateTime.tryParse('${json['createdAt'] ?? ''}') ?? DateTime.now(),
      sessionId: '${json['sessionId'] ?? ''}',
    );
  }

  String encode() => jsonEncode(toJson());

  factory ReflectionEntry.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('invalid reflection');
    return ReflectionEntry.fromJson(Map<String, dynamic>.from(decoded));
  }
}
