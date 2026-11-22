import 'dart:convert';

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/nai_account_pool.dart';

/// 账号池文件无法读取/解析时抛出。
///
/// 调用方必须区分“文件不存在”和“文件损坏”：后者绝不能被当成空账号池，
/// 否则下一次落盘就会用单账号覆盖用户全部密钥。
class AccountStoreException implements Exception {
  const AccountStoreException(
    this.message, {
    this.path,
    this.unavailable = false,
  });

  final String message;
  final String? path;

  /// 存储后端不可用（无 path_provider / 权限），而不是文件内容损坏。
  final bool unavailable;

  @override
  String toString() => 'AccountStoreException($message)';
}

/// 账号池文件存储（应用支持目录/accounts.json）。
///
/// 不依赖 shared_preferences，避免键值后端异常导致账号丢失。
/// 写入采用 tmp + rename，并在覆写前保留 `.bak`；检测到损坏文件时额外
/// 保存一份 `.corrupt-<时间戳>.json`，确保不会静默丢掉用户的密钥。
class AccountStore {
  AccountStore({Future<Directory> Function()? rootDirectory})
    : _rootDirectory = rootDirectory ?? _defaultRoot;

  static final AccountStore instance = AccountStore();

  final Future<Directory> Function() _rootDirectory;

  static Future<Directory> _defaultRoot() async =>
      getApplicationSupportDirectory();

  Future<File> _file() async {
    final dir = await _rootDirectory();
    return File(p.join(dir.path, 'accounts.json'));
  }

  /// 账号池文件是否存在（用于区分“首次启动”和“读取失败”）。
  Future<bool> hasFile() async => (await _file()).exists();

  Future<List<NaiAccount>> loadAccounts() async {
    final File file;
    try {
      file = await _file();
    } on Object catch (error) {
      // 测试/无插件环境没有 path_provider：按“不可用”处理，调用方不得落盘。
      throw AccountStoreException('账号池存储不可用: $error', unavailable: true);
    }
    if (!await file.exists()) return const <NaiAccount>[];
    final String content;
    try {
      content = await file.readAsString();
    } on Object catch (error) {
      throw AccountStoreException('无法读取账号池文件: $error', path: file.path);
    }
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        throw const FormatException('账号池根节点不是对象');
      }
      final raw = decoded['accounts'];
      if (raw is! List) {
        throw const FormatException('accounts 不是数组');
      }
      final accounts = <NaiAccount>[];
      for (final item in raw) {
        if (item is! Map) {
          throw const FormatException('accounts 中存在非对象条目');
        }
        accounts.add(NaiAccount.fromJson(Map<String, dynamic>.from(item)));
      }
      return accounts;
    } on AccountStoreException {
      rethrow;
    } on Object catch (error) {
      throw AccountStoreException('账号池 JSON 损坏: $error', path: file.path);
    }
  }

  Future<String> loadActiveId() async => _read('activeId');

  Future<String> loadDefaultId() async => _read('defaultId');

  Future<String> loadMode() async {
    final mode = await _read('mode');
    return mode == 'rotate' ? 'rotate' : 'fixed';
  }

  Future<String> _read(String key) async {
    try {
      final file = await _file();
      if (!await file.exists()) return '';
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) return '${decoded[key] ?? ''}';
    } on Object {
      // 元信息读取失败只影响当前选择，账号主体由 loadAccounts 的严格校验兜底。
    }
    return '';
  }

  Future<void> save({
    required List<NaiAccount> accounts,
    required String activeId,
    required String mode,
    String defaultId = '',
  }) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final encoded = jsonEncode({
      'accounts': accounts.map((account) => _accountJson(account)).toList(),
      'activeId': activeId,
      'mode': mode,
      'defaultId': defaultId,
    });

    // 覆写前先保留原文件与损坏副本，避免一次异常写盘造成不可恢复丢失。
    if (await file.exists()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      try {
        await file.copy('${file.path}.bak');
      } on Object {
        // 备份失败不阻断本次写入，但下面的 corrupt 副本仍会尽力保留。
      }
      try {
        jsonDecode(await file.readAsString());
      } on Object {
        try {
          await file.copy('${file.path}.corrupt-$stamp.json');
        } on Object {
          // 无法复制损坏文件时继续写入，避免账号编辑功能整体不可用。
        }
      }
    }

    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encoded, flush: true);
    // Dart 的 rename 会在目标存在时替换目标文件，保证读取方不会看到半个 JSON。
    await tmp.rename(file.path);
  }

  Map<String, dynamic> _accountJson(NaiAccount account) => {
    'id': account.id,
    'label': account.label,
    'apiKey': account.apiKey,
    'tierName': account.tierName,
    'anlas': account.anlas,
    'v5Energy': account.v5Energy,
    if (account.updatedAt != null)
      'updatedAt': account.updatedAt!.toIso8601String(),
  };
}
