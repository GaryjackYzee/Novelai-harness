import 'dart:convert';

/// 画风串固定选项：一组正负面 tag + 出图后的元数据/隐写处理偏好。
class StylePreset {
  const StylePreset({
    required this.id,
    required this.name,
    required this.positive,
    required this.negative,
    this.stripMetadata = false,
    this.stripStealth = false,
    this.styleInMetadata = true,
  });

  final String id;
  final String name;
  final String positive;
  final String negative;
  final bool stripMetadata;
  final bool stripStealth;

  /// 画风串 tag 是否写入导出元数据。
  final bool styleInMetadata;

  StylePreset copyWith({
    String? name,
    String? positive,
    String? negative,
    bool? stripMetadata,
    bool? stripStealth,
    bool? styleInMetadata,
  }) {
    return StylePreset(
      id: id,
      name: name ?? this.name,
      positive: positive ?? this.positive,
      negative: negative ?? this.negative,
      stripMetadata: stripMetadata ?? this.stripMetadata,
      stripStealth: stripStealth ?? this.stripStealth,
      styleInMetadata: styleInMetadata ?? this.styleInMetadata,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'positive': positive,
        'negative': negative,
        'stripMetadata': stripMetadata,
        'stripStealth': stripStealth,
        'styleInMetadata': styleInMetadata,
      };

  factory StylePreset.fromJson(Map<String, dynamic> json) {
    return StylePreset(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '画风'}',
      positive: '${json['positive'] ?? ''}',
      negative: '${json['negative'] ?? ''}',
      stripMetadata: json['stripMetadata'] == true,
      stripStealth: json['stripStealth'] == true,
      styleInMetadata: json['styleInMetadata'] != false,
    );
  }

  String encode() => jsonEncode(toJson());

  factory StylePreset.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('invalid style preset');
    return StylePreset.fromJson(Map<String, dynamic>.from(decoded));
  }
}
