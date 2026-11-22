/// 通用图源本地收藏记录 (AITag / 法典)。
class SourceFavorite {
  const SourceFavorite({
    required this.scope,
    required this.id,
    required this.title,
    required this.localPath,
    required this.savedAt,
    this.metadata = const <String, dynamic>{},
  });

  final String scope;
  final String id;
  final String title;
  final String localPath;
  final DateTime savedAt;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'scope': scope,
    'id': id,
    'title': title,
    'localPath': localPath,
    'savedAt': savedAt.toIso8601String(),
    'metadata': metadata,
  };

  factory SourceFavorite.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'];
    return SourceFavorite(
      scope: (json['scope'] as String?) ?? '',
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      localPath: (json['localPath'] as String?) ?? '',
      savedAt:
          DateTime.tryParse((json['savedAt'] as String?) ?? '') ??
          DateTime.now(),
      metadata: metadata is Map
          ? Map<String, dynamic>.from(metadata)
          : const <String, dynamic>{},
    );
  }

  static String sanitizeFileStem(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'favorite' : cleaned;
  }
}
