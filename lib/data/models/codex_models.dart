/// Community codex (法典) models from the quicktagcloud data CDN.
library;

/// One published codex.
class CodexPack {
  const CodexPack({
    required this.id,
    required this.title,
    required this.version,
    required this.entryCount,
    required this.coverFile,
  });

  final String id;
  final String title;
  final String version;
  final int entryCount;
  final String? coverFile;

  factory CodexPack.fromJson(Map<String, dynamic> json) {
    return CodexPack(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? json['id'] ?? ''}',
      version: '${json['version'] ?? ''}',
      entryCount: _asInt(json['entryCount']) ?? 0,
      coverFile: json['cover'] is String && '${json['cover']}'.isNotEmpty
          ? '${json['cover']}'
          : null,
    );
  }
}

/// One category row from the pack tree.
class CodexCategory {
  const CodexCategory({
    required this.name,
    required this.path,
    required this.count,
    required this.depth,
  });

  final String name;
  final String path;
  final int count;
  final int depth;
}

/// One codex entry (a prompt recipe with one or more images).
class CodexEntry {
  const CodexEntry({
    required this.id,
    required this.title,
    required this.tags,
    required this.negative,
    required this.rating,
    required this.note,
    required this.width,
    required this.height,
    required this.imageFiles,
  });

  final String id;
  final String title;
  final String tags;
  final String negative;
  final String rating;
  final String note;
  final int? width;
  final int? height;
  final List<String> imageFiles;
}

/// Paged search result for one pack.
class CodexSearchResult {
  const CodexSearchResult({
    required this.packId,
    required this.title,
    required this.version,
    required this.total,
    required this.page,
    required this.pages,
    required this.categories,
    required this.entries,
  });

  final String packId;
  final String title;
  final String version;
  final int total;
  final int page;
  final int pages;
  final List<CodexCategory> categories;
  final List<CodexEntry> entries;
}

int? _asInt(Object? value) {
  final number = value is num ? value : num.tryParse('$value');
  return number?.toInt();
}
