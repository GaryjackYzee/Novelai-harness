import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/tools/library_tools.dart';
import 'package:path/path.dart' as p;

void main() {
  test('library_query 支持深层目录、按文件名查找、读取和全文搜索', () async {
    final root = Directory.systemTemp.createTempSync('library-query-');
    addTearDown(() => root.deleteSync(recursive: true));
    final deepDir = Directory(p.join(root.path, 'a', 'b', 'c', 'd', 'e', 'f'))
      ..createSync(recursive: true);
    final deepFile = File(p.join(deepDir.path, '角色设定.md'))
      ..writeAsStringSync('主角：测试角色\n关键词：深渊');

    final tool = LibraryQueryTool(getLibraryDir: () => root.path);

    final tree = await tool.execute('call-1', {'action': 'tree', 'depth': 12});
    expect(tree.isError, isFalse);
    expect(tree.content, contains('a/b/c/d/e/f/角色设定.md'));

    final find = await tool.execute('call-2', {
      'action': 'find',
      'query': '角色',
    });
    expect(find.content, contains('角色设定.md'));

    final read = await tool.execute('call-3', {
      'action': 'read',
      'path': 'a/b/c/d/e/f/角色设定.md',
    });
    expect(read.content, contains('主角：测试角色'));

    final search = await tool.execute('call-4', {
      'action': 'search',
      'query': '深渊',
    });
    expect(search.content, contains('角色设定.md'));
    expect(deepFile.existsSync(), isTrue);
  });

  test('library_query find 忽略大小写、search 返回 snippet、digest 返回标题与摘要', () async {
    final root = Directory.systemTemp.createTempSync('library-query-extra-');
    addTearDown(() => root.deleteSync(recursive: true));
    final docs = Directory(p.join(root.path, 'Docs'))
      ..createSync(recursive: true);
    final longLine = '${'前文' * 60}关键词${'后记' * 60}';
    File(
      p.join(docs.path, 'Dragon-Notes.md'),
    ).writeAsStringSync('# 龙族设定\n\n远古巨龙住在深渊。\n\n$longLine\n');

    final tool = LibraryQueryTool(getLibraryDir: () => root.path);

    final find = await tool.execute('call-find', {
      'action': 'find',
      'query': 'dragon notes',
    });
    expect(find.isError, isFalse);
    expect(find.content, contains('Docs/Dragon-Notes.md'));

    final search = await tool.execute('call-search', {
      'action': 'search',
      'query': '关键词',
    });
    expect(search.isError, isFalse);
    expect(search.content, contains('Docs/Dragon-Notes.md:5'));
    expect(search.content, contains('关键词'));
    expect(search.content, contains('…'));

    final scoped = await tool.execute('call-search-scope', {
      'action': 'search',
      'query': '深渊',
      'path': 'Docs',
    });
    expect(scoped.isError, isFalse);
    expect(scoped.content, contains('Docs/Dragon-Notes.md'));

    final digest = await tool.execute('call-digest', {'action': 'digest'});
    expect(digest.isError, isFalse);
    expect(digest.content, contains('Docs/Dragon-Notes.md'));
    expect(digest.content, contains('标题：# 龙族设定'));
    expect(digest.content, contains('摘要：远古巨龙住在深渊。'));

    final outline = await tool.execute('call-outline', {'action': 'outline'});
    expect(outline.isError, isFalse);
    expect(outline.content, contains('标题：# 龙族设定'));
  });
}
