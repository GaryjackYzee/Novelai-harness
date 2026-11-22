/// Danbooru 图库帖子 (只保留画廊展示与下载需要的字段)
class DanbooruPost {
  const DanbooruPost({
    required this.id,
    required this.score,
    required this.rating,
    required this.fileExt,
    required this.width,
    required this.height,
    required this.tagString,
    required this.artistTags,
    required this.characterTags,
    required this.copyrightTags,
    this.previewUrl,
    this.fileUrl,
    this.largeFileUrl,
    this.source,
  });

  final int id;
  final int score;
  final String rating;
  final String fileExt;
  final int width;
  final int height;
  final String tagString;
  final String artistTags;
  final String characterTags;
  final String copyrightTags;
  final String? previewUrl;
  final String? fileUrl;
  final String? largeFileUrl;
  final String? source;

  /// 原图优先，其次大图，最后缩略图 (均可能为空/已失效)。
  String? get bestImageUrl =>
      _nonEmpty(fileUrl) ?? _nonEmpty(largeFileUrl) ?? _nonEmpty(previewUrl);

  String? get thumbnailUrl => _nonEmpty(previewUrl) ?? _nonEmpty(largeFileUrl);

  /// 画廊卡片标题：画师优先，其次角色/作品标签。
  String get displayTags {
    final artist = artistTags.trim();
    if (artist.isNotEmpty) return artist.replaceAll('_', ' ');
    final character = characterTags.trim();
    if (character.isNotEmpty) {
      return character.split(' ').take(2).join(' ').replaceAll('_', ' ');
    }
    return tagString
        .split(' ')
        .where((tag) => tag.isNotEmpty)
        .take(3)
        .join(' ')
        .replaceAll('_', ' ');
  }

  double get aspectRatio {
    if (width <= 0 || height <= 0) return 0.75;
    return (width / height).clamp(0.5, 2.0);
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  factory DanbooruPost.fromJson(Map<String, dynamic> json) {
    String stringOf(String key) => (json[key] as String?)?.trim() ?? '';
    int intOf(String key) => (json[key] as num?)?.toInt() ?? 0;
    return DanbooruPost(
      id: intOf('id'),
      score: intOf('score'),
      rating: stringOf('rating'),
      fileExt: stringOf('file_ext').toLowerCase(),
      width: intOf('image_width'),
      height: intOf('image_height'),
      tagString: stringOf('tag_string'),
      artistTags: stringOf('tag_string_artist'),
      characterTags: stringOf('tag_string_character'),
      copyrightTags: stringOf('tag_string_copyright'),
      previewUrl: _nonEmpty(json['preview_file_url'] as String?),
      fileUrl: _nonEmpty(json['file_url'] as String?),
      largeFileUrl: _nonEmpty(json['large_file_url'] as String?),
      source: _nonEmpty(json['source'] as String?),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'score': score,
    'rating': rating,
    'file_ext': fileExt,
    'image_width': width,
    'image_height': height,
    'tag_string': tagString,
    'tag_string_artist': artistTags,
    'tag_string_character': characterTags,
    'tag_string_copyright': copyrightTags,
    'preview_file_url': previewUrl,
    'file_url': fileUrl,
    'large_file_url': largeFileUrl,
    'source': source,
  };
}

/// 本地收藏记录：图片已下载到应用目录，离线也能查看/发送。
class DanbooruFavorite {
  const DanbooruFavorite({
    required this.post,
    required this.localPath,
    required this.savedAt,
  });

  final DanbooruPost post;
  final String localPath;
  final DateTime savedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'post': post.toJson(),
    'localPath': localPath,
    'savedAt': savedAt.toIso8601String(),
  };

  factory DanbooruFavorite.fromJson(Map<String, dynamic> json) {
    final postJson = json['post'];
    if (postJson is! Map) {
      throw const FormatException('收藏记录缺少 post');
    }
    return DanbooruFavorite(
      post: DanbooruPost.fromJson(Map<String, dynamic>.from(postJson)),
      localPath: (json['localPath'] as String?) ?? '',
      savedAt:
          DateTime.tryParse((json['savedAt'] as String?) ?? '') ??
          DateTime.now(),
    );
  }
}
