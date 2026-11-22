import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/core/harness/tools/grep_tool.dart';
import 'package:novelai_harness/data/services/library_service.dart';

LibraryFile _file(String name) => LibraryFile(
    name: name,
    path: '/lib/$name',
    size: 10,
    modified: DateTime(2026, 1, 1),
  );

void main() {
  final contents = <String, String>{
    'a.md': 'Tsaritsa 冰神\n蓝色眼睛\nringlets',
    'b.txt': 'tsaritsa 无官方立绘\ntsaritsa 出图口径',
  };

  GrepTool buildTool() => GrepTool(
        listFiles: () async =>
            contents.keys.map(_file).toList(growable: false),
        readFile: (file) async => contents[file.name] ?? '',
      );

  test('grep 返回 文件:行号 并忽略大小写', () async {
    final result = await buildTool().execute('t', {'pattern': 'tsaritsa'});
    expect(result.isError, isFalse);
    expect(result.content, contains('a.md:1'));
    expect(result.content, contains('b.txt:1'));
    expect(result.content, contains('b.txt:2'));
  });

  test('include 过滤文件名', () async {
    final result = await buildTool().execute(
      't',
      {'pattern': 'tsaritsa', 'include': '*.md'},
    );
    expect(result.content, contains('a.md'));
    expect(result.content, isNot(contains('b.txt')));
  });

  test('无效正则会返回错误', () async {
    final result = await buildTool().execute('t', {'pattern': '['});
    expect(result.isError, isTrue);
  });

  test('max_results 限制条数', () async {
    final result = await buildTool().execute(
      't',
      {'pattern': 'tsaritsa', 'max_results': 1},
    );
    expect(RegExp('tsaritsa', caseSensitive: false).allMatches(result.content).length,
        1);
  });
}
