import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/harness/types.dart';

/// 队列中的一条消息（文本 + 可选附图）。
class QueuedChatMessage {
  const QueuedChatMessage({required this.content, this.images = const []});

  final String content;
  final List<AgentMessageImage> images;

  Map<String, dynamic> toJson() => {
        'content': content,
        'images': [
          for (final image in images)
            {'base64': image.base64, 'mimeType': image.mimeType},
        ],
      };

  factory QueuedChatMessage.fromJson(Map<String, dynamic> json) {
    final rawImages = json['images'];
    final images = <AgentMessageImage>[];
    if (rawImages is List) {
      for (final item in rawImages) {
        if (item is! Map) continue;
        final base64 = '${item['base64'] ?? ''}';
        if (base64.isEmpty) continue;
        images.add(AgentMessageImage(
          base64: base64,
          mimeType: '${item['mimeType'] ?? 'image/png'}',
        ));
      }
    }
    return QueuedChatMessage(
      content: '${json['content'] ?? ''}',
      images: images,
    );
  }

  String encode() => jsonEncode(toJson());

  factory QueuedChatMessage.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('invalid queued message');
    return QueuedChatMessage.fromJson(Map<String, dynamic>.from(decoded));
  }
}

/// 对话消息队列的持久化存储（应用支持目录/chat_queue.db）。
class ChatQueueStore {
  ChatQueueStore._();

  static final ChatQueueStore instance = ChatQueueStore._();
  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    final db = sqlite3.open(p.join(dir.path, 'chat_queue.db'));
    db.execute('''
      CREATE TABLE IF NOT EXISTS chat_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content TEXT NOT NULL,
        images TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL
      )
    ''');
    try {
      db.execute("ALTER TABLE chat_queue ADD COLUMN images TEXT NOT NULL DEFAULT '[]'");
    } on Object {
      // 旧库已经迁移过
    }
    _db = db;
    return db;
  }

  Future<List<QueuedChatMessage>> load() async {
    try {
      final db = await _open();
      final rows = db.select(
        'SELECT content, images FROM chat_queue ORDER BY id ASC',
      );
      return rows.map((row) {
        final raw = '${row['images'] ?? '[]'}';
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            final images = <AgentMessageImage>[];
            for (final item in decoded) {
              if (item is! Map) continue;
              final base64 = '${item['base64'] ?? ''}';
              if (base64.isEmpty) continue;
              images.add(AgentMessageImage(
                base64: base64,
                mimeType: '${item['mimeType'] ?? 'image/png'}',
              ));
            }
            return QueuedChatMessage(
              content: '${row['content']}',
              images: images,
            );
          }
        } on Object {
          // 忽略损坏的图片列
        }
        return QueuedChatMessage(content: '${row['content']}');
      }).toList(growable: false);
    } on Object catch (error) {
      debugPrint('ChatQueueStore.load failed: $error');
      return const <QueuedChatMessage>[];
    }
  }

  Future<void> add(QueuedChatMessage message) async {
    try {
      final db = await _open();
      db.execute(
        'INSERT INTO chat_queue (content, images, created_at) VALUES (?, ?, ?)',
        <Object?>[
          message.content,
          jsonEncode([
            for (final image in message.images)
              {'base64': image.base64, 'mimeType': image.mimeType},
          ]),
          DateTime.now().toIso8601String(),
        ],
      );
    } on Object {
      // 存储不可用时保留内存队列
    }
  }

  Future<void> removeFirst() async {
    try {
      final db = await _open();
      db.execute(
        'DELETE FROM chat_queue WHERE id = (SELECT id FROM chat_queue ORDER BY id ASC LIMIT 1)',
      );
    } on Object {
      // 忽略
    }
  }

  /// 用给定顺序整体替换队列（编辑/删除/重排后调用）。
  Future<void> replaceAll(List<QueuedChatMessage> messages) async {
    try {
      final db = await _open();
      db.execute('DELETE FROM chat_queue');
      final now = DateTime.now().toIso8601String();
      for (final message in messages) {
        db.execute(
          'INSERT INTO chat_queue (content, images, created_at) VALUES (?, ?, ?)',
          <Object?>[
            message.content,
            jsonEncode([
              for (final image in message.images)
                {'base64': image.base64, 'mimeType': image.mimeType},
            ]),
            now,
          ],
        );
      }
    } on Object {
      // 忽略
    }
  }

  Future<void> clear() async {
    try {
      final db = await _open();
      db.execute('DELETE FROM chat_queue');
    } on Object {
      // 忽略
    }
  }

  /// 测试/调试用：关闭数据库连接。
  Future<void> close() async {
    _db?.dispose();
    _db = null;
  }

  Future<File?> debugFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File(p.join(dir.path, 'chat_queue.db'));
    } on Object {
      return null;
    }
  }
}
