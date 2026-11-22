import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/danbooru_models.dart';

/// 本地收藏写入失败
class DanbooruFavoriteException implements Exception {
  const DanbooruFavoriteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Danbooru 本地收藏库：图片下载到应用支持目录，索引原子落盘。
///
/// 收藏与 Danbooru 账号无关，不写入工作台图库/生成历史，避免污染生图数据。
class DanbooruFavoriteStore {
  DanbooruFavoriteStore._() : _testRoot = null;

  DanbooruFavoriteStore.forTesting(Directory root) : _testRoot = root;

  static final DanbooruFavoriteStore instance = DanbooruFavoriteStore._();

  static const String _folderName = 'danbooru_favorites';
  static const String _indexFile = 'favorites.json';
  static const int _maxImageBytes = 32 * 1024 * 1024;

  final Directory? _testRoot;
  Directory? _resolvedRoot;
  bool _loaded = false;
  final Map<int, DanbooruFavorite> _favorites = <int, DanbooruFavorite>{};

  List<DanbooruFavorite> get favorites {
    final list = _favorites.values.toList(growable: false)
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return list;
  }

  bool contains(int postId) => _favorites.containsKey(postId);

  DanbooruFavorite? byId(int postId) => _favorites[postId];

  Future<void> load() async {
    if (_loaded) return;
    final root = await _root();
    final index = File(p.join(root.path, _indexFile));
    if (!await index.exists()) {
      _loaded = true;
      return;
    }
    try {
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is! List) {
        _loaded = true;
        return;
      }
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          final favorite = DanbooruFavorite.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (favorite.localPath.isEmpty ||
              !await File(favorite.localPath).exists()) {
            continue;
          }
          _favorites[favorite.post.id] = favorite;
        } on Object {
          // 单条记录损坏不拖垮整个收藏库
        }
      }
    } on Object {
      // 索引损坏时从空库开始；不删除用户可能仍可恢复的原图。
    }
    _loaded = true;
  }

  Future<DanbooruFavorite> save(DanbooruPost post, Uint8List bytes) async {
    if (bytes.isEmpty) throw const DanbooruFavoriteException('图片内容为空');
    if (bytes.length > _maxImageBytes) {
      throw const DanbooruFavoriteException('图片超过 32MB，已拒绝收藏');
    }
    final root = await _root();
    await root.create(recursive: true);
    final extension = _extensionFor(post, bytes);
    final target = File(p.join(root.path, '${post.id}$extension'));
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
    } catch (error) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // 保留原始错误
        }
      }
      throw DanbooruFavoriteException('收藏图片写入失败：$error');
    }
    final favorite = DanbooruFavorite(
      post: post,
      localPath: target.path,
      savedAt: DateTime.now(),
    );
    _favorites[post.id] = favorite;
    await _persist();
    return favorite;
  }

  Future<void> remove(int postId) async {
    final favorite = _favorites.remove(postId);
    if (favorite == null) return;
    try {
      final file = File(favorite.localPath);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 索引先移除；孤儿文件不应阻塞用户取消收藏
    }
    await _persist();
  }

  Future<Uint8List?> readBytes(int postId) async {
    final favorite = _favorites[postId];
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
    final target = File(p.join(root.path, _indexFile));
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsString(
        jsonEncode(favorites.map((f) => f.toJson()).toList()),
        flush: true,
      );
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
    } on Object {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // 索引写失败不阻塞收藏图片本身
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
            _folderName,
          ),
        );
    _resolvedRoot = root;
    return root;
  }

  static String _extensionFor(DanbooruPost post, Uint8List bytes) {
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
    final ext = post.fileExt.toLowerCase();
    return ext.isEmpty ? '.jpg' : '.$ext';
  }
}
