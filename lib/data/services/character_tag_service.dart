import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'isolated_compute.dart';

/// 人物 tag 数据来源。
enum CharacterTagSource { danbooru, e621 }

/// 一条人物 tag 记录。
class CharacterTagEntry {
  final CharacterTagSource source;
  final String character;
  final String copyright;
  final String trigger;
  final String coreTags;
  final int count;
  final int soloCount;
  final String url;

  const CharacterTagEntry({
    required this.source,
    required this.character,
    required this.copyright,
    required this.trigger,
    required this.coreTags,
    required this.count,
    required this.soloCount,
    required this.url,
  });

  String get _normalizedCharacter =>
      character.toLowerCase().replaceAll('_', ' ').trim();

  String get id => '${source.name}|$_normalizedCharacter';

  Map<String, dynamic> toJson() => {
    'source': source.name,
    'character': character,
    'copyright': copyright,
    'trigger': trigger,
    'coreTags': coreTags,
    'count': count,
    'soloCount': soloCount,
    'url': url,
    'custom': true,
  };

  factory CharacterTagEntry.fromJson(Map<String, dynamic> json) {
    final sourceName = json['source'] as String? ?? 'danbooru';
    return CharacterTagEntry(
      source: CharacterTagSource.values.firstWhere(
        (s) => s.name == sourceName,
        orElse: () => CharacterTagSource.danbooru,
      ),
      character: json['character'] as String? ?? '',
      copyright: json['copyright'] as String? ?? '',
      trigger: json['trigger'] as String? ?? '',
      coreTags: json['coreTags'] as String? ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      soloCount: (json['soloCount'] as num?)?.toInt() ?? 0,
      url: json['url'] as String? ?? '',
    );
  }
}

/// 内置人物 tag 索引 + 用户自定义覆盖。
///
/// CSV 首次查询时在后台 isolate 解析，不阻塞 UI；自定义条目存为
/// `<应用支持目录>/character_tags.json`，查询时覆盖同名内置记录。
class CharacterTagService {
  CharacterTagService._();

  static final CharacterTagService instance = CharacterTagService._();

  final Map<CharacterTagSource, List<CharacterTagEntry>> _cache = {};
  Map<String, CharacterTagEntry>? _custom;
  Future<Map<String, CharacterTagEntry>>? _customLoading;

  static const Map<CharacterTagSource, String> assetPaths = {
    CharacterTagSource.danbooru:
        'assets/character_tags/danbooru_character_webui.csv',
    CharacterTagSource.e621: 'assets/character_tags/e621_character_webui.csv',
  };

  Future<File> _customFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/character_tags.json');
  }

  Future<Map<String, CharacterTagEntry>> _loadCustom() {
    return _customLoading ??= () async {
      final map = <String, CharacterTagEntry>{};
      File? file;
      try {
        file = await _customFile();
      } on Object {
        return _custom = map;
      }
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is List) {
            for (final item in decoded) {
              if (item is! Map<String, dynamic>) continue;
              final entry = CharacterTagEntry.fromJson(item);
              map[entry.id] = entry;
            }
          }
        } on Object {
          // 损坏时按空自定义处理，不阻塞内置查询。
        }
      }
      return _custom = map;
    }();
  }

  Future<void> _saveCustom() async {
    final map = _custom;
    if (map == null) return;
    final File file;
    try {
      file = await _customFile();
    } on Object {
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(map.values.map((e) => e.toJson()).toList()),
      flush: true,
    );
  }

  Future<List<CharacterTagEntry>> _loadBuiltIn(CharacterTagSource source) async {
    final cached = _cache[source];
    if (cached != null) return cached;
    final data = await rootBundle.load(assetPaths[source]!);
    final bytes = data.buffer.asUint8List();
    final entries = await runIsolated(
      _parseCharacterCsv,
      (bytes: bytes, sourceName: source.name),
    );
    _cache[source] = entries;
    return entries;
  }

  /// 跨来源搜索；自定义条目优先展示，并覆盖同名内置记录。
  Future<List<CharacterTagEntry>> search({
    required String query,
    Set<CharacterTagSource>? sources,
    int limit = 20,
  }) async {
    final keyword = query.trim().toLowerCase().replaceAll('_', ' ');
    if (keyword.isEmpty) return const [];
    final selected = sources ?? CharacterTagSource.values.toSet();
    final custom = await _loadCustom();
    final results = <String, CharacterTagEntry>{};

    // 自定义命中先占位，后面的内置结果不再覆盖。
    for (final entry in custom.values) {
      if (!selected.contains(entry.source)) continue;
      final matches =
          entry.character.toLowerCase().contains(keyword) ||
          entry.copyright.toLowerCase().contains(keyword) ||
          entry.trigger.toLowerCase().contains(keyword);
      if (matches) results[entry.id] = entry;
    }

    for (final source in selected) {
      final entries = await _loadBuiltIn(source);
      for (final entry in entries) {
        if (results.containsKey(entry.id)) continue;
        if (entry.character.toLowerCase().contains(keyword) ||
            entry.copyright.toLowerCase().contains(keyword) ||
            entry.trigger.toLowerCase().contains(keyword)) {
          results[entry.id] = entry;
        }
      }
    }

    final list = results.values.toList()
      ..sort((a, b) {
        final aCustom = custom.containsKey(a.id);
        final bCustom = custom.containsKey(b.id);
        if (aCustom != bCustom) return aCustom ? -1 : 1;
        return b.count.compareTo(a.count);
      });
    return list.take(limit).toList(growable: false);
  }

  /// 精确查询某个角色（支持带空格/下划线的写法）。
  Future<List<CharacterTagEntry>> lookup({
    required String character,
    Set<CharacterTagSource>? sources,
  }) async {
    final key = character.trim().toLowerCase().replaceAll('_', ' ');
    if (key.isEmpty) return const [];
    final selected = sources ?? CharacterTagSource.values.toSet();
    final custom = await _loadCustom();
    final results = <CharacterTagEntry>[];
    for (final source in selected) {
      final customEntry = custom['${source.name}|$key'];
      if (customEntry != null) {
        results.add(customEntry);
        continue;
      }
      final entries = await _loadBuiltIn(source);
      for (final entry in entries) {
        if (entry._normalizedCharacter == key) {
          results.add(entry);
          break;
        }
      }
    }
    return results;
  }

  /// 新增或修改一条自定义人物 tag（调用方负责先取得用户同意）。
  Future<CharacterTagEntry> upsert(CharacterTagEntry entry) async {
    await _loadCustom();
    final previous = Map<String, CharacterTagEntry>.from(_custom!);
    _custom![entry.id] = entry;
    try {
      await _saveCustom();
    } on Object {
      _custom = previous;
      rethrow;
    }
    return entry;
  }
}

/// isolate 入口：解析整份 CSV，返回可跨 isolate 传输的条目列表。
List<CharacterTagEntry> _parseCharacterCsv(
  ({Uint8List bytes, String sourceName}) task,
) {
  final source = CharacterTagSource.values.firstWhere(
    (s) => s.name == task.sourceName,
    orElse: () => CharacterTagSource.danbooru,
  );
  final text = utf8.decode(task.bytes, allowMalformed: true);
  final rows = _parseCsvRows(text);
  if (rows.isEmpty) return const [];
  final entries = <CharacterTagEntry>[];
  for (final fields in rows.skip(1)) {
    if (fields.length < 4) continue;
    final character = fields[0].trim();
    if (character.isEmpty) continue;
    final isDanbooru = source == CharacterTagSource.danbooru;
    final coreIndex = isDanbooru ? 3 : -1;
    final countIndex = isDanbooru ? 4 : 3;
    final soloIndex = isDanbooru ? 5 : 4;
    final urlIndex = isDanbooru ? 6 : 5;
    entries.add(
      CharacterTagEntry(
        source: source,
        character: character.replaceAll('_', ' '),
        copyright: fields[1].trim().replaceAll('_', ' '),
        trigger: fields[2].trim(),
        coreTags: coreIndex >= 0 && fields.length > coreIndex
            ? fields[coreIndex].trim()
            : '',
        count: countIndex < fields.length
            ? int.tryParse(fields[countIndex].trim()) ?? 0
            : 0,
        soloCount: soloIndex < fields.length
            ? int.tryParse(fields[soloIndex].trim()) ?? 0
            : 0,
        url: urlIndex < fields.length ? fields[urlIndex].trim() : '',
      ),
    );
  }
  return entries;
}

/// CSV 行解析：支持引号、转义引号与字段内换行。
List<List<String>> _parseCsvRows(String text) {
  final rows = <List<String>>[];
  var fields = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i += 1) {
    final char = text[i];
    if (inQuotes) {
      if (char == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          buffer.write('"');
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        buffer.write(char);
      }
    } else if (char == '"') {
      inQuotes = true;
    } else if (char == ',') {
      fields.add(buffer.toString());
      buffer.clear();
    } else if (char == '\n' || char == '\r') {
      if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
        i += 1;
      }
      fields.add(buffer.toString());
      buffer.clear();
      if (fields.length > 1 || fields.first.trim().isNotEmpty) {
        rows.add(fields);
      }
      fields = <String>[];
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty || fields.isNotEmpty) {
    fields.add(buffer.toString());
    if (fields.length > 1 || fields.first.trim().isNotEmpty) rows.add(fields);
  }
  return rows;
}
