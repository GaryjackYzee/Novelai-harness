import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Agent 本地文件工具的边界：只允许读取应用管理目录内的图片。
///
/// 这些工具由模型自主调用，不能信任模型给出的任意绝对路径；否则资料库/
/// 网页里的提示词注入就能让 Agent 读取本机文件并上传到第三方。
const int maxAgentImageBytes = 32 * 1024 * 1024;

bool looksLikeImageBytes(Uint8List bytes) {
  if (bytes.length < 12) return false;
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true; // PNG
  }
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return true; // JPEG
  }
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true; // WebP
  }
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true; // GIF
  }
  return false;
}

/// [path] 是否位于 [roots] 之一内部（词法 + realpath 双重校验）。
///
/// 解析符号链接失败时按拒绝处理，避免 junction/软链接指向目录外。
bool isPathInsideRoots(String path, Iterable<String> roots) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return false;
  final normalized = p.normalize(p.absolute(trimmed));
  for (final root in roots) {
    final trimmedRoot = root.trim();
    if (trimmedRoot.isEmpty) continue;
    final normalizedRoot = p.normalize(p.absolute(trimmedRoot));
    if (!p.isWithin(normalizedRoot, normalized)) continue;
    try {
      final realTarget = File(normalized).resolveSymbolicLinksSync();
      final realRoot = Directory(normalizedRoot).resolveSymbolicLinksSync();
      return p.isWithin(realRoot, realTarget);
    } on FileSystemException {
      return false;
    }
  }
  return false;
}

/// 读取 Agent 传入的图片路径；越界/为空/超限/非图片时返回错误文案。
Future<({Uint8List? bytes, String? error})> readAgentImagePath(
  String path,
  List<String> roots,
) async {
  if (roots.isEmpty) {
    return (bytes: null, error: '未配置可读目录，已拒绝读取本地文件。');
  }
  if (!isPathInsideRoots(path, roots)) {
    return (bytes: null, error: '路径不在允许读取的目录内（保存目录/资料库）：$path');
  }
  final file = File(path);
  try {
    final length = await file.length();
    if (length <= 0 || length > maxAgentImageBytes) {
      return (bytes: null, error: '图片为空或超过 32 MB 上限：$path');
    }
    final bytes = await file.readAsBytes();
    if (!looksLikeImageBytes(bytes)) {
      return (bytes: null, error: '该文件不是受支持的图片格式：$path');
    }
    return (bytes: bytes, error: null);
  } on FileSystemException catch (error) {
    return (bytes: null, error: '读取图片失败：${error.message}');
  }
}
