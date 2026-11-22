import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models/reflection_entry.dart';

/// 梳理串 SQLite 存储（应用支持目录/reflections.db）。
class ReflectionStore {
  ReflectionStore._();

  static final ReflectionStore instance = ReflectionStore._();
  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    final db = sqlite3.open(p.join(dir.path, 'reflections.db'));
    db.execute('''
      CREATE TABLE IF NOT EXISTS reflections (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        source TEXT NOT NULL,
        summary TEXT NOT NULL,
        lessons TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    _db = db;
    return db;
  }

  Future<List<ReflectionEntry>> list() async {
    final db = await _open();
    final rows = db.select(
      'SELECT id, title, source, summary, lessons, created_at FROM reflections ORDER BY created_at DESC',
    );
    return rows.map(_rowOf).toList(growable: false);
  }

  Future<void> upsert(ReflectionEntry entry) async {
    final db = await _open();
    db.execute(
      'INSERT OR REPLACE INTO reflections (id, title, source, summary, lessons, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      <Object?>[
        entry.id,
        entry.title,
        entry.source,
        entry.summary,
        jsonEncode(entry.lessons),
        entry.createdAt.toIso8601String(),
      ],
    );
  }

  Future<void> remove(String id) async {
    final db = await _open();
    db.execute('DELETE FROM reflections WHERE id = ?', <Object?>[id]);
  }

  ReflectionEntry _rowOf(Row row) {
    final rawLessons = row['lessons'] as String? ?? '[]';
    List<String> lessons;
    try {
      lessons = (jsonDecode(rawLessons) as List).whereType<String>().toList(
        growable: false,
      );
    } on Object {
      lessons = const <String>[];
    }
    return ReflectionEntry(
      id: '${row['id']}',
      title: '${row['title']}',
      source: '${row['source']}',
      summary: '${row['summary']}',
      lessons: lessons,
      createdAt: DateTime.tryParse('${row['created_at']}') ?? DateTime.now(),
    );
  }
}
