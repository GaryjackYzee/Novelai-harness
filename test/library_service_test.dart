import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/services/library_service.dart';
import 'package:path/path.dart' as p;

Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// 写入一个只包含指定条目的 zip 文件，用于构造 docx/xlsx/pptx 测试样本。
void _writeZip(String path, Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
}

void main() {
  test('search 多关键词 AND 优先、大小写不敏感、文件名/路径加权', () async {
    LibraryService.clearTextCache();
    final root = _tempDir('library-rank-');
    Directory(p.join(root.path, 'notes')).createSync(recursive: true);
    File(p.join(root.path, 'notes', '深渊笔记.md')).writeAsStringSync('只有深渊的传闻。');
    File(p.join(root.path, 'notes', '混合.md')).writeAsStringSync('深渊里的主角再次出发。');
    File(
      p.join(root.path, 'Dragon.md'),
    ).writeAsStringSync('The DRAGON sleeps in the cave.');
    File(p.join(root.path, '角色设定.md')).writeAsStringSync('这里没有出现正文关键词。');
    File(p.join(root.path, 'notes', '普通.md')).writeAsStringSync('这个角色是主角。');

    final service = LibraryService();

    final ranked = await service.search(root.path, '深渊 主角');
    expect(ranked, isNotEmpty);
    expect(ranked.first.file, 'notes/混合.md');
    expect(ranked.map((match) => match.file), contains('notes/深渊笔记.md'));

    final caseInsensitive = await service.search(root.path, 'dragon');
    expect(caseInsensitive, hasLength(1));
    expect(caseInsensitive.single.file, 'Dragon.md');

    final nameWeighted = await service.search(root.path, '角色');
    expect(nameWeighted, isNotEmpty);
    expect(nameWeighted.first.file, '角色设定.md');
    expect(nameWeighted.first.line, 0);
    expect(nameWeighted.first.pathHit, isTrue);
    expect(nameWeighted.map((match) => match.file), contains('notes/普通.md'));
  });

  test('search 中文按相邻双字与单字匹配', () async {
    LibraryService.clearTextCache();
    final root = _tempDir('library-cjk-');
    File(p.join(root.path, '剧情.md')).writeAsStringSync('深渊之中，主角缓缓走来。');
    final service = LibraryService();

    final partial = await service.search(root.path, '深渊主角');
    expect(partial, isNotEmpty);
    expect(partial.first.file, '剧情.md');
    expect(partial.first.line, 1);

    final single = await service.search(root.path, '渊');
    expect(single, isNotEmpty);

    final missing = await service.search(root.path, '完全不存在');
    expect(missing, isEmpty);
  });

  test('search 返回命中行号与行内 snippet', () async {
    LibraryService.clearTextCache();
    final root = _tempDir('library-snippet-');
    final prefix = '前文' * 60;
    final suffix = '后记' * 60;
    File(
      p.join(root.path, '长文.md'),
    ).writeAsStringSync('第一行\n第二行\n$prefix关键词$suffix\n');
    final service = LibraryService();

    final matches = await service.search(root.path, '关键词');
    expect(matches, hasLength(1));
    final match = matches.single;
    expect(match.line, 3);
    expect(match.text.length, lessThanOrEqualTo(240));
    expect(match.snippet, contains('关键词'));
    expect(match.snippet.length, lessThan(200));
    expect(match.snippet, contains('…'));
  });

  test('search 文本缓存按路径/mtime/大小失效', () async {
    LibraryService.clearTextCache();
    final root = _tempDir('library-cache-');
    final file = File(p.join(root.path, '缓存.md'))
      ..writeAsStringSync('apple first version');
    final service = LibraryService();

    expect(await service.search(root.path, 'apple'), isNotEmpty);
    final cachedEntries = LibraryService.textCacheEntryCount;
    expect(cachedEntries, greaterThan(0));
    expect(await service.search(root.path, 'apple'), isNotEmpty);
    expect(LibraryService.textCacheEntryCount, cachedEntries);

    file.writeAsStringSync('banana second version is longer');
    expect(await service.search(root.path, 'banana'), isNotEmpty);
    expect(await service.search(root.path, 'apple'), isEmpty);
  });

  test('search 支持深层目录与 docx 文本提取', () async {
    LibraryService.clearTextCache();
    final root = _tempDir('library-deep-');
    final deep = Directory(p.join(root.path, 'a', 'b', 'c', 'd', 'e'))
      ..createSync(recursive: true);
    File(p.join(deep.path, '笔记.txt')).writeAsStringSync('深层文本关键词');
    _writeZip(p.join(deep.path, '角色设定.docx'), {
      'word/document.xml':
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
          '<w:body>'
          '<w:p><w:r><w:t>深渊中的主角</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>第二段：银色长发</w:t></w:r></w:p>'
          '</w:body></w:document>',
    });
    final service = LibraryService();

    final docxMatches = await service.search(root.path, '深渊');
    expect(docxMatches, isNotEmpty);
    expect(
      docxMatches.any(
        (match) => match.file == 'a/b/c/d/e/角色设定.docx' && match.line == 1,
      ),
      isTrue,
    );
    final read = await service.read(p.join(deep.path, '角色设定.docx'));
    expect(read.text, contains('深渊中的主角'));

    final textMatches = await service.search(root.path, '深层文本');
    expect(
      textMatches.any((match) => match.file == 'a/b/c/d/e/笔记.txt'),
      isTrue,
    );
  });

  test('search 支持 xlsx/pptx 纯文本提取', () async {
    LibraryService.clearTextCache();
    final root = _tempDir('library-office-');
    _writeZip(p.join(root.path, '角色表.xlsx'), {
      'xl/sharedStrings.xml':
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<si><t>角色名称</t></si><si><t>深渊主角</t></si></sst>',
      'xl/worksheets/sheet1.xml':
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="1">'
          '<c r="A1" t="s"><v>0</v></c>'
          '<c r="B1" t="s"><v>1</v></c>'
          '</row></sheetData></worksheet>',
    });
    _writeZip(p.join(root.path, '演示.pptx'), {
      'ppt/slides/slide1.xml':
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
          'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
          '<p:cSld><p:spTree><p:sp><p:txBody>'
          '<a:p><a:r><a:t>深渊主角的设定</a:t></a:r></a:p>'
          '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
    });
    final service = LibraryService();

    final xlsxMatches = await service.search(root.path, '深渊主角');
    expect(xlsxMatches.any((match) => match.file == '角色表.xlsx'), isTrue);
    final pptxMatches = await service.search(root.path, '设定');
    expect(pptxMatches.any((match) => match.file == '演示.pptx'), isTrue);
    final read = await service.read(p.join(root.path, '角色表.xlsx'));
    expect(read.text, contains('角色名称'));
  });

  test('digest 返回文件信息、Markdown 标题与首段摘要', () async {
    LibraryService.clearTextCache();
    final root = _tempDir('library-digest-');
    File(
      p.join(root.path, '角色设定.md'),
    ).writeAsStringSync('# 角色设定\n\n## 主角\n\n深渊中的主角，拥有银色长发。\n\n## 配角\n\n暂无。\n');
    final service = LibraryService();

    final digests = await service.digest(root.path);
    expect(digests, hasLength(1));
    final digest = digests.single;
    expect(digest.file, '角色设定.md');
    expect(digest.size, greaterThan(0));
    expect(digest.headings, contains('# 角色设定'));
    expect(digest.headings, contains('## 主角'));
    expect(digest.summary, contains('深渊中的主角'));
    expect(digest.summary, isNot(contains('#')));
    expect(digest.error, isNull);
  });

  test('search 保留 limit 与 offset 分页', () async {
    LibraryService.clearTextCache();
    final root = _tempDir('library-page-');
    for (var index = 1; index <= 4; index += 1) {
      final name = index.toString().padLeft(2, '0');
      File(p.join(root.path, '$name.md')).writeAsStringSync('关键词内容 $name');
    }
    final service = LibraryService();

    final first = await service.search(root.path, '关键词', limit: 2);
    final second = await service.search(root.path, '关键词', limit: 2, offset: 2);
    expect(first, hasLength(2));
    expect(second, hasLength(2));
    final firstNameSet = first.map((match) => match.file).toSet();
    final secondNameSet = second.map((match) => match.file).toSet();
    expect(firstNameSet.intersection(secondNameSet), isEmpty);
  });
}
