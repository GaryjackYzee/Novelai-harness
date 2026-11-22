// ignore_for_file: prefer_initializing_formals

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// 资料库中的一个可读文档。
class LibraryFile {
  const LibraryFile({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
  });

  /// 相对资料库根目录的路径 (显示与读取都用它)。
  final String name;

  /// 绝对路径。
  final String path;

  final int size;
  final DateTime modified;
}

/// 分页读取结果。
class LibraryRead {
  const LibraryRead({
    required this.name,
    required this.text,
    required this.offset,
    required this.total,
    required this.truncated,
  });

  final String name;
  final String text;
  final int offset;
  final int total;
  final bool truncated;
}

/// 关键词搜索结果。
///
/// [text] / [line] / [file] 为既有字段，保持兼容；
/// [snippet] 是命中位置附近的上下文片段，供 Agent 与 UI 直接展示。
class LibraryMatch {
  const LibraryMatch({
    required this.file,
    required this.line,
    required this.text,
    this.snippet = '',
    this.score = 0,
    this.pathHit = false,
  });

  final String file;

  /// 命中行号 (从 1 开始)；为 0 表示仅文件名/路径命中。
  final int line;

  /// 命中行原文 (最多 240 字符)。
  final String text;

  /// 命中位置附近的上下文，长行会自动截断并补省略号。
  final String snippet;

  /// 相关度分数，仅用于排序与排查。
  final double score;

  /// 是否包含文件名/路径命中加权。
  final bool pathHit;

  /// 优先展示 snippet，缺失时回退到命中行原文。
  String get displayText => snippet.trim().isEmpty ? text : snippet;
}

/// 单个文档的概览，供 Agent 在通读全文前先判断文档大致内容。
class LibraryDigest {
  const LibraryDigest({
    required this.file,
    required this.size,
    required this.modified,
    required this.headings,
    required this.summary,
    required this.totalChars,
    this.error,
  });

  final String file;
  final int size;
  final DateTime modified;

  /// 前若干个 Markdown 标题 (保留 # 前缀)。
  final List<String> headings;

  /// 首个正文段落摘要 (已去除 Markdown 标记，可能被截断)。
  final String summary;

  /// 提取出的文本总字符数。
  final int totalChars;

  /// 文本提取失败时的原因；成功时为 null。
  final String? error;
}

class _CachedText {
  const _CachedText({
    required this.text,
    required this.modifiedMicros,
    required this.size,
  });

  final String text;
  final int modifiedMicros;
  final int size;
}

/// 一个查询词及其 CJK 匹配片段。
class _SearchTerm {
  _SearchTerm({
    required this.text,
    required this.bigrams,
    required this.chars,
    required this.hasCjk,
  });

  final String text;

  /// 相邻双字，用于中文「双字匹配」。
  final List<String> bigrams;

  /// 去重后的单字，用于中文「字符匹配」。
  final Set<String> chars;

  final bool hasCjk;
}

/// 只读资料库：列出、读取与搜索本地文本类文档。
///
/// 支持深层目录、docx/pdf 文本提取，以及 xlsx/pptx 的纯文本提取。
/// 提取结果按「绝对路径 + 修改时间 + 大小」缓存在进程内，避免重复解压。
class LibraryService {
  LibraryService({int maxFileBytes = 4 * 1024 * 1024})
    : _maxFileBytes = maxFileBytes;

  static const Set<String> _supportedExtensions = <String>{
    '.txt',
    '.md',
    '.markdown',
    '.json',
    '.csv',
    '.log',
    '.yaml',
    '.yml',
    '.docx',
    '.pdf',
    '.xlsx',
    '.pptx',
  };

  static const int _maxCacheEntries = 64;
  static const int _maxCacheChars = 8 * 1024 * 1024;
  static final LinkedHashMap<String, _CachedText> _textCache =
      LinkedHashMap<String, _CachedText>();
  static int _textCacheChars = 0;

  static final RegExp _headingPattern = RegExp(
    r'^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$',
  );

  /// 目录缺失或不可读时返回空列表。
  final int _maxFileBytes;

  /// 当前进程内缓存的文档数 (测试与排查用)。
  static int get textCacheEntryCount => _textCache.length;

  /// 清空文档文本缓存。
  static void clearTextCache() {
    _textCache.clear();
    _textCacheChars = 0;
  }

  bool isSupported(String path) =>
      _supportedExtensions.contains(p.extension(path).toLowerCase());

  Future<void> ensureDir(String dir) async {
    if (dir.trim().isEmpty) return;
    await Directory(dir).create(recursive: true);
  }

  /// 复制外部文档进资料库目录；重名自动追加 _2、_3。
  Future<List<String>> importFiles(String dir, List<String> paths) async {
    if (dir.trim().isEmpty) return const <String>[];
    await ensureDir(dir);
    final imported = <String>[];
    for (final source in paths) {
      if (!isSupported(source)) continue;
      final file = File(source);
      if (!await file.exists()) continue;
      final baseName = p.basenameWithoutExtension(source);
      final extension = p.extension(source);
      var name = '$baseName$extension';
      var counter = 1;
      while (await File(p.join(dir, name)).exists()) {
        counter += 1;
        name = '${baseName}_$counter$extension';
      }
      await file.copy(p.join(dir, name));
      imported.add(name);
    }
    return imported;
  }

  Future<void> deleteFile(String dir, String path) async {
    final root = p.normalize(dir);
    final target = p.normalize(path);
    if (!p.isWithin(root, target)) return;
    await File(target).delete().catchError((_) => File(target));
  }

  Future<List<LibraryFile>> list(
    String dir, {
    int maxDepth = 4,
    int maxFiles = 500,
    String prefix = '',
  }) async {
    final root = Directory(dir);
    if (dir.trim().isEmpty || !await root.exists()) {
      return const <LibraryFile>[];
    }
    final normalizedPrefix = prefix.trim().replaceAll('\\', '/');
    final startPath = normalizedPrefix.isEmpty
        ? dir
        : p.normalize(p.join(dir, normalizedPrefix));
    final rootPath = p.normalize(dir);
    if (p.normalize(startPath) != rootPath &&
        !p.isWithin(rootPath, p.normalize(startPath))) {
      return const <LibraryFile>[];
    }
    final start = Directory(startPath);
    if (!await start.exists()) return const <LibraryFile>[];
    final files = <LibraryFile>[];
    await _walk(
      start,
      normalizedPrefix,
      files,
      depth: 0,
      maxDepth: maxDepth,
      maxFiles: maxFiles,
    );
    files.sort((left, right) => right.modified.compareTo(left.modified));
    return List<LibraryFile>.unmodifiable(files);
  }

  Future<void> _walk(
    Directory root,
    String prefix,
    List<LibraryFile> out, {
    required int depth,
    required int maxDepth,
    required int maxFiles,
  }) async {
    if (depth > maxDepth || out.length >= maxFiles) return;
    List<FileSystemEntity> entities;
    try {
      entities = await root.list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    for (final entity in entities) {
      if (out.length >= maxFiles) return;
      final base = p.basename(entity.path);
      if (base.startsWith('.')) continue;
      if (entity is Directory) {
        await _walk(
          entity,
          prefix.isEmpty ? base : '$prefix/$base',
          out,
          depth: depth + 1,
          maxDepth: maxDepth,
          maxFiles: maxFiles,
        );
        continue;
      }
      if (entity is! File || !isSupported(entity.path)) continue;
      final info = await entity.stat().catchError(
        (_) => FileStat.statSync(entity.path),
      );
      if (info.size > _maxFileBytes) continue;
      final name = prefix.isEmpty ? base : '$prefix/$base';
      out.add(
        LibraryFile(
          name: name,
          path: entity.path,
          size: info.size,
          modified: info.modified,
        ),
      );
    }
  }

  Future<LibraryRead> read(
    String path, {
    int offset = 0,
    int limit = 6000,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FileSystemException('资料库里没有这个文件');
    }
    if (!isSupported(path)) {
      throw const FileSystemException('暂不支持这个文件格式');
    }
    final text = await _loadText(path);
    final start = offset.clamp(0, text.length).toInt();
    final size = limit.clamp(200, 12000).toInt();
    final end = (start + size).clamp(0, text.length).toInt();
    return LibraryRead(
      name: p.basename(path),
      text: text.substring(start, end),
      offset: start,
      total: text.length,
      truncated: end < text.length,
    );
  }

  /// 读取并提取文档纯文本；命中缓存且 path+mtime+size 未变时直接复用。
  Future<String> _loadText(String path) async {
    final file = File(path);
    final stat = await file.stat();
    final key = p.normalize(p.absolute(path));
    final cached = _textCache[key];
    if (cached != null &&
        cached.modifiedMicros == stat.modified.microsecondsSinceEpoch &&
        cached.size == stat.size) {
      _textCache
        ..remove(key)
        ..[key] = cached;
      return cached.text;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxFileBytes) {
      throw const FileSystemException('文件过大，无法直接读取');
    }
    final text = await _textFor(path, bytes);
    _rememberText(key, text, stat);
    return text;
  }

  static void _rememberText(String key, String text, FileStat stat) {
    final previous = _textCache.remove(key);
    if (previous != null) _textCacheChars -= previous.text.length;
    _textCache[key] = _CachedText(
      text: text,
      modifiedMicros: stat.modified.microsecondsSinceEpoch,
      size: stat.size,
    );
    _textCacheChars += text.length;
    while (_textCache.length > _maxCacheEntries ||
        (_textCacheChars > _maxCacheChars && _textCache.length > 1)) {
      final oldestKey = _textCache.keys.first;
      final removed = _textCache.remove(oldestKey);
      if (removed != null) _textCacheChars -= removed.text.length;
    }
  }

  Future<String> _textFor(String path, Uint8List bytes) async {
    final extension = p.extension(path).toLowerCase();
    if (extension == '.docx') return _docxText(bytes);
    if (extension == '.xlsx') return _xlsxText(bytes);
    if (extension == '.pptx') return _pptxText(bytes);
    if (extension == '.pdf') return _pdfText(path);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 通过外部 pdftotext（poppler）提取 PDF 文本；未安装时给出明确提示。
  Future<String> _pdfText(String path) async {
    try {
      final result = await Process.run(
        'pdftotext',
        <String>['-layout', path, '-'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode == 0) return result.stdout as String;
      throw FileSystemException('pdftotext 解析失败：${result.stderr}');
    } on ProcessException {
      throw const FileSystemException(
        '读取 PDF 需要安装 pdftotext（poppler），并把它的 bin 目录加入 PATH',
      );
    }
  }

  /// 从 docx 的 word/document.xml 里提取纯文本段落。
  String _docxText(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final entry = archive.findFile('word/document.xml');
      if (entry == null) return '';
      final xmlText = utf8.decode(
        entry.content as List<int>,
        allowMalformed: true,
      );
      final document = XmlDocument.parse(xmlText);
      final paragraphs = <String>[];
      for (final paragraph in document.findAllElements('w:p')) {
        final buffer = StringBuffer();
        for (final text in paragraph.findAllElements('w:t')) {
          buffer.write(text.innerText);
        }
        final line = buffer.toString().trim();
        if (line.isNotEmpty) paragraphs.add(line);
      }
      return paragraphs.join('\n');
    } on Object {
      return '';
    }
  }

  /// 从 xlsx 的 sharedStrings.xml 与各 worksheet 里提取单元格纯文本。
  String _xlsxText(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final sharedStrings = <String>[];
      final sharedEntry = archive.findFile('xl/sharedStrings.xml');
      if (sharedEntry != null) {
        final sharedDoc = XmlDocument.parse(
          utf8.decode(sharedEntry.content as List<int>, allowMalformed: true),
        );
        for (final item in sharedDoc.findAllElements('si')) {
          final buffer = StringBuffer();
          for (final text in item.findAllElements('t')) {
            buffer.write(text.innerText);
          }
          sharedStrings.add(buffer.toString());
        }
      }
      final sheets =
          archive.files
              .where(
                (entry) =>
                    entry.isFile &&
                    RegExp(
                      r'^xl/worksheets/sheet\d+\.xml$',
                    ).hasMatch(entry.name),
              )
              .toList()
            ..sort(
              (left, right) => _numericSuffix(
                left.name,
              ).compareTo(_numericSuffix(right.name)),
            );
      final lines = <String>[];
      for (final sheet in sheets) {
        final document = XmlDocument.parse(
          utf8.decode(sheet.content as List<int>, allowMalformed: true),
        );
        for (final row in document.findAllElements('row')) {
          final cells = <String>[];
          for (final cell in row.findElements('c')) {
            final value = _xlsxCellValue(cell, sharedStrings);
            if (value.isNotEmpty) cells.add(value);
          }
          if (cells.isNotEmpty) lines.add(cells.join(' | '));
        }
      }
      return lines.join('\n');
    } on Object {
      return '';
    }
  }

  String _xlsxCellValue(XmlElement cell, List<String> sharedStrings) {
    final type = cell.getAttribute('t');
    final rawValue = cell.findElements('v').firstOrNull?.innerText.trim() ?? '';
    if (type == 's') {
      final index = int.tryParse(rawValue);
      if (index == null || index < 0 || index >= sharedStrings.length) {
        return '';
      }
      return sharedStrings[index].trim();
    }
    if (type == 'inlineStr') {
      return cell.findElements('is').firstOrNull?.innerText.trim() ?? '';
    }
    return rawValue;
  }

  /// 从 pptx 的各页 slide XML 里按段落提取 `a:t` 文本。
  String _pptxText(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final slides =
          archive.files
              .where(
                (entry) =>
                    entry.isFile &&
                    RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(entry.name),
              )
              .toList()
            ..sort(
              (left, right) => _numericSuffix(
                left.name,
              ).compareTo(_numericSuffix(right.name)),
            );
      final lines = <String>[];
      for (final slide in slides) {
        final document = XmlDocument.parse(
          utf8.decode(slide.content as List<int>, allowMalformed: true),
        );
        for (final paragraph in document.findAllElements('a:p')) {
          final buffer = StringBuffer();
          for (final text in paragraph.findAllElements('a:t')) {
            buffer.write(text.innerText);
          }
          final line = buffer.toString().trim();
          if (line.isNotEmpty) lines.add(line);
        }
      }
      return lines.join('\n');
    } on Object {
      return '';
    }
  }

  int _numericSuffix(String name) {
    final match = RegExp(r'(\d+)\.xml$').firstMatch(name);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// 多关键词全文检索。
  ///
  /// - 关键词以空白分隔，全部命中 (AND) 的行优先，部分命中仍会返回；
  /// - 大小写不敏感；中文额外按相邻双字与单字做模糊匹配；
  /// - 文件名/路径命中会加权，整段查询短语精确命中额外加权；
  /// - 结果按相关度排序，返回命中行号与行内上下文 snippet；
  /// - [offset] / [limit] 用于分页，[prefix] 可限定子目录或单个文件。
  Future<List<LibraryMatch>> search(
    String dir,
    String query, {
    int limit = 40,
    int maxDepth = 12,
    int offset = 0,
    String prefix = '',
  }) async {
    final terms = _termsOf(query);
    if (terms.isEmpty) return const <LibraryMatch>[];
    final phrase = query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final normalizedPrefix = prefix.trim().replaceAll('\\', '/');
    final files = await list(dir, maxDepth: maxDepth, maxFiles: 1000);
    final matches = <LibraryMatch>[];
    for (final file in files) {
      if (normalizedPrefix.isNotEmpty &&
          !_matchesPrefix(file.name, normalizedPrefix)) {
        continue;
      }
      String text;
      try {
        text = await _loadText(file.path);
      } on Object {
        continue;
      }
      final pathScore = _pathScore(file.name, terms);
      var contentHit = false;
      final lines = const LineSplitter().convert(text);
      for (var index = 0; index < lines.length; index += 1) {
        final rawLine = lines[index];
        if (rawLine.trim().isEmpty) continue;
        final lineScore = _lineScore(rawLine, terms, phrase);
        if (lineScore <= 0) continue;
        contentHit = true;
        final trimmed = rawLine.trim();
        matches.add(
          LibraryMatch(
            file: file.name,
            line: index + 1,
            text: trimmed.length > 240 ? trimmed.substring(0, 240) : trimmed,
            snippet: _snippetFor(trimmed, terms),
            score: lineScore + pathScore,
            pathHit: pathScore > 0,
          ),
        );
      }
      if (!contentHit && pathScore > 0) {
        matches.add(
          LibraryMatch(
            file: file.name,
            line: 0,
            text: file.name,
            snippet: file.name,
            score: pathScore,
            pathHit: true,
          ),
        );
      }
    }
    matches.sort(_compareMatches);
    if (offset > 0 && offset >= matches.length) return const <LibraryMatch>[];
    final start = offset < 0 ? 0 : offset;
    final take = limit.clamp(1, 400).toInt();
    final end = (start + take) < matches.length ? start + take : matches.length;
    return List<LibraryMatch>.unmodifiable(matches.sublist(start, end));
  }

  /// 逐文件生成概览：大小、修改时间、前若干个 Markdown 标题与首段摘要。
  Future<List<LibraryDigest>> digest(
    String dir, {
    int maxDepth = 12,
    int maxFiles = 50,
    String prefix = '',
    int maxHeadings = 8,
    int summaryLength = 240,
  }) async {
    final normalizedPrefix = prefix.trim().replaceAll('\\', '/');
    final allFiles = await list(
      dir,
      maxDepth: maxDepth,
      maxFiles: normalizedPrefix.isEmpty ? maxFiles : 1000,
    );
    final files = allFiles
        .where((file) => _matchesPrefix(file.name, normalizedPrefix))
        .take(maxFiles)
        .toList(growable: false);
    final digests = <LibraryDigest>[];
    for (final file in files) {
      try {
        final text = await _loadText(file.path);
        digests.add(
          LibraryDigest(
            file: file.name,
            size: file.size,
            modified: file.modified,
            headings: List<String>.unmodifiable(_headingsOf(text, maxHeadings)),
            summary: _summaryOf(text, summaryLength),
            totalChars: text.length,
          ),
        );
      } on Object catch (error) {
        digests.add(
          LibraryDigest(
            file: file.name,
            size: file.size,
            modified: file.modified,
            headings: const <String>[],
            summary: '',
            totalChars: 0,
            error: '$error',
          ),
        );
      }
    }
    return List<LibraryDigest>.unmodifiable(digests);
  }

  bool _matchesPrefix(String name, String prefix) {
    if (prefix.isEmpty) return true;
    return name == prefix || name.startsWith('$prefix/');
  }

  List<_SearchTerm> _termsOf(String query) {
    final raw = query.trim().toLowerCase();
    if (raw.isEmpty) return const <_SearchTerm>[];
    final seen = <String>{};
    final terms = <_SearchTerm>[];
    for (final piece in raw.split(RegExp(r'\s+'))) {
      final text = piece.trim();
      if (text.isEmpty || !seen.add(text)) continue;
      final bigrams = <String>[];
      for (var index = 0; index + 1 < text.length; index += 1) {
        bigrams.add(text.substring(index, index + 2));
      }
      terms.add(
        _SearchTerm(
          text: text,
          bigrams: bigrams,
          chars: text.split('').toSet(),
          hasCjk: text.runes.any(_isCjkRune),
        ),
      );
    }
    return terms;
  }

  static bool _isCjkRune(int rune) =>
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0xF900 && rune <= 0xFAFF);

  /// 单个查询词在一段文本里的命中强度：1 为完整命中，0 为未命中。
  double _termScore(String lowerText, _SearchTerm term) {
    if (lowerText.contains(term.text)) return 1;
    if (!term.hasCjk) return 0;
    var bigramHits = 0;
    for (final bigram in term.bigrams) {
      if (lowerText.contains(bigram)) bigramHits += 1;
    }
    var charHits = 0;
    for (final char in term.chars) {
      if (lowerText.contains(char)) charHits += 1;
    }
    final bigramCoverage = term.bigrams.isEmpty
        ? 0.0
        : bigramHits / term.bigrams.length;
    final charCoverage = term.chars.isEmpty
        ? 0.0
        : charHits / term.chars.length;
    // 中文按「双字优先、单字兜底」：双字覆盖一半以上视为模糊命中。
    final partial = bigramCoverage > charCoverage * 0.5
        ? bigramCoverage
        : charCoverage * 0.5;
    return partial >= 0.5 ? partial : 0;
  }

  double _lineScore(String rawLine, List<_SearchTerm> terms, String phrase) {
    final lower = rawLine.toLowerCase();
    var matched = 0;
    var exact = 0;
    var sum = 0.0;
    for (final term in terms) {
      final score = _termScore(lower, term);
      if (score <= 0) continue;
      matched += 1;
      sum += score;
      if (score >= 1) exact += 1;
    }
    if (matched == 0) return 0;
    var score = sum * 100;
    if (exact > 0) score += 20 * exact;
    // 多关键词查询才额外奖励「全部命中」与精确短语，避免单关键词正文命中
    // 压过文件名/路径命中。
    if (terms.length > 1 && exact == terms.length) score += 160;
    if (terms.length > 1 && matched == terms.length) {
      score += 120 + 20 * terms.length;
    }
    if (terms.length > 1 && phrase.isNotEmpty && lower.contains(phrase)) {
      score += 180;
    }
    return score;
  }

  double _pathScore(String relativePath, List<_SearchTerm> terms) {
    final lowerPath = relativePath.toLowerCase();
    final base = p.basename(relativePath).toLowerCase();
    var score = 0.0;
    var matched = 0;
    for (final term in terms) {
      double hit = 0;
      if (base.contains(term.text)) {
        hit = 80;
      } else if (lowerPath.contains(term.text)) {
        hit = 45;
      } else {
        final partial = _termScore(lowerPath, term);
        if (partial >= 0.5) hit = 40 * partial;
      }
      if (hit > 0) {
        score += hit;
        matched += 1;
      }
    }
    if (matched == terms.length) score += 120;
    return score;
  }

  int _compareMatches(LibraryMatch left, LibraryMatch right) {
    final byScore = right.score.compareTo(left.score);
    if (byScore != 0) return byScore;
    final byFile = left.file.compareTo(right.file);
    if (byFile != 0) return byFile;
    return left.line.compareTo(right.line);
  }

  /// 截取命中位置附近的上下文；短行原样返回，长行保留约 160 字符。
  String _snippetFor(String line, List<_SearchTerm> terms) {
    if (line.isEmpty) return '';
    final lower = line.toLowerCase();
    var hitIndex = -1;
    for (final term in terms) {
      final index = lower.indexOf(term.text);
      if (index >= 0 && (hitIndex < 0 || index < hitIndex)) hitIndex = index;
    }
    if (hitIndex < 0) {
      for (final term in terms) {
        for (final bigram in term.bigrams) {
          final index = lower.indexOf(bigram);
          if (index >= 0 && (hitIndex < 0 || index < hitIndex)) {
            hitIndex = index;
          }
        }
      }
    }
    if (hitIndex < 0) {
      for (final term in terms) {
        for (final char in term.chars) {
          final index = lower.indexOf(char);
          if (index >= 0 && (hitIndex < 0 || index < hitIndex)) {
            hitIndex = index;
          }
        }
      }
    }
    const maxLength = 160;
    if (line.length <= maxLength) return line;
    final latestStart = line.length - maxLength;
    final start = hitIndex <= 0
        ? 0
        : (hitIndex - 60).clamp(0, latestStart).toInt();
    final end = (start + maxLength).clamp(0, line.length).toInt();
    final prefix = start > 0 ? '…' : '';
    final suffix = end < line.length ? '…' : '';
    return '$prefix${line.substring(start, end).trim()}$suffix';
  }

  List<String> _headingsOf(String text, int maxHeadings) {
    final headings = <String>[];
    if (maxHeadings <= 0) return headings;
    for (final line in const LineSplitter().convert(text)) {
      final match = _headingPattern.firstMatch(line);
      if (match == null) continue;
      final title = match.group(2)?.trim() ?? '';
      if (title.isEmpty) continue;
      headings.add('${match.group(1)} $title');
      if (headings.length >= maxHeadings) break;
    }
    return headings;
  }

  String _summaryOf(String text, int summaryLength) {
    final limit = summaryLength.clamp(40, 2000).toInt();
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || _headingPattern.hasMatch(trimmed)) continue;
      final plain = trimmed
          .replaceFirst(RegExp(r'^(?:[-*+>]\s+)+'), '')
          .replaceFirst(RegExp(r'^\d+[.)、]\s*'), '')
          .trim();
      if (plain.isEmpty) continue;
      return plain.length > limit ? '${plain.substring(0, limit)}…' : plain;
    }
    return '';
  }
}
