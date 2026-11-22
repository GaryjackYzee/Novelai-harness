import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/models/nai_account_pool.dart';
import 'package:novelai_harness/data/services/account_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late AccountStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nai-account-store-');
    store = AccountStore(rootDirectory: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('missing accounts.json returns empty list', () async {
    expect(await store.loadAccounts(), isEmpty);
  });

  test('corrupt accounts.json throws instead of returning empty', () async {
    await File(
      p.join(dir.path, 'accounts.json'),
    ).writeAsString('{"accounts":[{"id":"keep"');
    await expectLater(
      store.loadAccounts(),
      throwsA(isA<AccountStoreException>()),
    );
  });

  test('corrupt file is preserved before a successful overwrite', () async {
    final file = File(p.join(dir.path, 'accounts.json'));
    await file.writeAsString('{"accounts":[{"id":"keep"');

    await store.save(
      accounts: [const NaiAccount(id: 'a', label: 'A', apiKey: 'secret-key')],
      activeId: 'a',
      mode: 'fixed',
    );

    final backups = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('.corrupt-'))
        .toList();
    expect(backups, isNotEmpty);
    expect(await backups.first.readAsString(), contains('"keep"'));

    final loaded = await store.loadAccounts();
    expect(loaded, hasLength(1));
    expect(loaded.single.apiKey, 'secret-key');

    await file.writeAsString('{"accounts":[{"id":"b"}');
    await store.save(
      accounts: const [NaiAccount(id: 'b', label: 'B', apiKey: 'new-key')],
      activeId: 'b',
      mode: 'fixed',
    );
    expect(await File(p.join(dir.path, 'accounts.json.bak')).exists(), isTrue);
  });
}
