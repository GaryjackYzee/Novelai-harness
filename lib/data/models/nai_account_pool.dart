import 'dart:convert';

/// 订阅账号池中的一个 NovelAI 账号。
class NaiAccount {
  const NaiAccount({
    required this.id,
    required this.label,
    required this.apiKey,
    this.tierName = '',
    this.anlas = 0,
    this.v5Energy = 100,
    this.updatedAt,
  });

  final String id;
  final String label;
  final String apiKey;
  final String tierName;
  final int anlas;
  final int v5Energy;
  final DateTime? updatedAt;

  NaiAccount copyWith({
    String? label,
    String? apiKey,
    String? tierName,
    int? anlas,
    int? v5Energy,
    DateTime? updatedAt,
  }) {
    return NaiAccount(
      id: id,
      label: label ?? this.label,
      apiKey: apiKey ?? this.apiKey,
      tierName: tierName ?? this.tierName,
      anlas: anlas ?? this.anlas,
      v5Energy: v5Energy ?? this.v5Energy,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'apiKey': apiKey,
    'tierName': tierName,
    'anlas': anlas,
    'v5Energy': v5Energy,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

  factory NaiAccount.fromJson(Map<String, dynamic> json) {
    return NaiAccount(
      id: '${json['id'] ?? ''}',
      label: '${json['label'] ?? '账号'}',
      apiKey: '${json['apiKey'] ?? ''}',
      tierName: '${json['tierName'] ?? ''}',
      anlas: (json['anlas'] as num?)?.toInt() ?? 0,
      v5Energy: (json['v5Energy'] as num?)?.toInt() ?? 100,
      updatedAt: DateTime.tryParse('${json['updatedAt'] ?? ''}'),
    );
  }

  String encode() => jsonEncode(toJson());

  factory NaiAccount.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('invalid account');
    return NaiAccount.fromJson(Map<String, dynamic>.from(decoded));
  }
}
