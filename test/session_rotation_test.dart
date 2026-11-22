import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/services/session_log_service.dart';

void main() {
  test('会话轮转同时删除 sidecar，并保留最新会话', () async {
    final dir = await Directory.systemTemp.createTemp('session_rotation_');
    addTearDown(() => dir.delete(recursive: true));

    final oldSession = File('${dir.path}/old.jsonl');
    final oldContext = File('${oldSession.path}.context.json');
    await oldSession.writeAsString('');
    await oldContext.writeAsString('{}');
    final oldDate = DateTime.now().subtract(const Duration(days: 120));
    await oldSession.setLastModified(oldDate);
    await oldContext.setLastModified(oldDate);

    final latest = File('${dir.path}/latest.jsonl');
    final latestContext = File('${latest.path}.context.json');
    await latest.writeAsString('');
    await latestContext.writeAsString('{}');

    final orphanContext = File('${dir.path}/gone.jsonl.context.json');
    await orphanContext.writeAsString('{}');

    final service = SessionLogService();
    await service.init(baseDir: dir.path);
    // 轮转是 unawaited 的后台任务：轮询等待，避免固定延时在慢机器上抖动。
    for (var attempt = 0; attempt < 60; attempt += 1) {
      final done = !await oldSession.exists() &&
          !await oldContext.exists() &&
          !await orphanContext.exists();
      if (done) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(await oldSession.exists(), isFalse);
    expect(await oldContext.exists(), isFalse);
    expect(await latest.exists(), isTrue);
    expect(await latestContext.exists(), isTrue);
    expect(await orphanContext.exists(), isFalse);
  });

  test('轮转阈值可配置：数量与天数都按服务字段生效', () async {
    final dir = await Directory.systemTemp.createTemp('session_rotation_cfg_');
    addTearDown(() => dir.delete(recursive: true));

    final old = File('${dir.path}/old.jsonl');
    await old.writeAsString('');
    await old.setLastModified(
      DateTime.now().subtract(const Duration(days: 3)),
    );
    final fresh = File('${dir.path}/fresh.jsonl');
    await fresh.writeAsString('');

    final service = SessionLogService()
      ..maxSessions = 1
      ..retentionDays = 1;
    await service.init(baseDir: dir.path);
    for (var attempt = 0; attempt < 60; attempt += 1) {
      if (!await old.exists()) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await old.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
  });
}
