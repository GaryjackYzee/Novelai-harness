import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/source_favorite.dart';

class SourceFavoriteException implements Exception {
  const SourceFavoriteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// AITag / 法典的本地收藏库：图片落地到应用支持目录，索引原子写。
class SourceFavoriteStore {
  SourceFavoriteStore._() : _testRoot = null;

  SourceFavoriteStore.forTesting(Directory root) : _testRoot = root;

  static final SourceFavoriteStore instance = SourceFavoriteStore._();

  static const int _maxImageBytes = 32 * 1024 * 1024;

  final Directory? _testRoot;
  Directory? _resolvedRoot;
  bool _loaded = false;
  final Map<String, SourceFavorite> _favorites = <String, SourceFavorite>{};

  static String _key(String scope, String id) => '$scope:$id';

  List<SourceFavorite> forScope(String scope) {
    final list =
        _favorites.values
            .where((favorite) => favorite.scope == scope)
            .toList(growable: false)
          ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return list;
  }

  bool contains(String scope, String id) =>
      _favorites.containsKey(_key(scope, id));

  SourceFavorite? byId(String scope, String id) => _favorites[_key(scope, id)];

  Future<void> load() async {
    if (_loaded) return;
    final root = await _root();
    final index = File(p.join(root.path, 'favorites.json'));
    if (!await index.exists()) {
      _loaded = true;
      return;
    }
    try {
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is List) {
        for (final item in decoded) {
          if (item is! Map) continue;
          try {
            final favorite = SourceFavorite.fromJson(
              Map<String, dynamic>.from(item),
            );
            if (favorite.scope.isEmpty ||
                favorite.id.isEmpty ||
                favorite.localPath.isEmpty ||
                !await File(favorite.localPath).exists()) {
              continue;
            }
            _favorites[_key(favorite.scope, favorite.id)] = favorite;
          } on Object {
            // 单条损坏不影响其他收藏
          }
        }
      }
    } on Object {
      // 索引损坏时从空库开始
    }
    _loaded = true;
  }

  Future<SourceFavorite> save({
    required String scope,
    required String id,
    required String title,
    required Uint8List bytes,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    if (bytes.isEmpty) throw const SourceFavoriteException('图片内容为空');
    if (bytes.length > _maxImageBytes) {
      throw const SourceFavoriteException('图片超过 32MB，已拒绝收藏');
    }
    final root = await _root();
    await root.create(recursive: true);
    final stem = SourceFavorite.sanitizeFileStem('${scope}_$id');
    final target = File(p.join(root.path, '$stem${_extension(bytes)}'));
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    } catch (error) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // 保留原始错误
        }
      }
      throw SourceFavoriteException('收藏图片写入失败：$error');
    }
    final favorite = SourceFavorite(
      scope: scope,
      id: id,
      title: title,
      localPath: target.path,
      savedAt: DateTime.now(),
      metadata: metadata,
    );
    _favorites[_key(scope, id)] = favorite;
    await _persist();
    return favorite;
  }

  Future<void> remove(String scope, String id) async {
    final favorite = _favorites.remove(_key(scope, id));
    if (favorite == null) return;
    try {
      final file = File(favorite.localPath);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 索引先移除；孤儿文件不阻塞取消收藏
    }
    await _persist();
  }

  Future<Uint8List?> readBytes(String scope, String id) async {
    final favorite = byId(scope, id);
    if (favorite == null) return null;
    try {
      final file = File(favorite.localPath);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _persist() async {
    final root = await _root();
    await root.create(recursive: true);
    final target = File(p.join(root.path, 'favorites.json'));
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsString(
        jsonEncode(
          _favorites.values.map((favorite) => favorite.toJson()).toList(),
        ),
        flush: true,
      );
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    } on Object {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // 索引写失败不阻塞图片本身
        }
      }
    }
  }

  Future<Directory> _root() async {
    final existing = _resolvedRoot;
    if (existing != null) return existing;
    final root =
        _testRoot ??
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'NovelAI_Harness',
            'source_favorites',
          ),
        );
    _resolvedRoot = root;
    return root;
  }

  static String _extension(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return '.jpg';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return '.jpg';
  }
}
