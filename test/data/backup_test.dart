import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/backup_codec.dart';
import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/domain/ledger_math.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/csv_export.dart';

void main() {
  late BackupData fixture;
  late Uint8List encrypted;
  const password = 'test-password-12345';

  setUpAll(() async {
    final db = LedgerDatabase(NativeDatabase.memory());
    final repo = FinanceRepository(db);
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    await repo.saveAccount(name: 'Наличные', kind: 'Наличные', openingMinor: 0);
    final accounts = (await repo.load()).accounts;
    await repo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 2000,
      date: DateTime(2026, 11, 14),
      accountId: accounts.first.id,
      category: 'Продукты',
      note: '=HYPERLINK("bad")',
    );
    final expense = (await repo.load()).entries.single;
    await repo.saveEntry(
      kind: EntryKind.refund,
      amountMinor: 500,
      date: DateTime(2026, 11, 15),
      accountId: accounts.first.id,
      refundOf: expense.id,
    );
    await repo.saveEntry(
      kind: EntryKind.transfer,
      amountMinor: 1000,
      date: DateTime(2026, 11, 16),
      accountId: accounts.first.id,
      targetAccountId: accounts.last.id,
    );
    await repo.saveBudget(
      month: DateTime(2026, 11),
      category: 'Продукты',
      limitMinor: 5000,
    );
    await repo.saveEntry(
      kind: EntryKind.income,
      amountMinor: 100,
      date: DateTime(2026, 11, 17),
      accountId: accounts.first.id,
      category: 'Удалённая операция',
    );
    await repo.deleteEntry(
      (await repo.load()).entries.singleWhere(
        (e) => e.category == 'Удалённая операция',
      ),
    );
    await repo.saveBudget(
      month: DateTime(2026, 11),
      category: 'Удалённый лимит',
      limitMinor: 100,
    );
    await repo.deleteBudget(
      (await repo.load()).budgets.singleWhere(
        (b) => b.category == 'Удалённый лимит',
      ),
    );
    fixture = await repo.exportData();
    encrypted = await BackupCodec.encrypt(fixture, password);
    await db.close();
  });

  test(
    'encrypted round trip preserves exact snapshot and hides plaintext',
    () async {
      expect(utf8.decode(encrypted).contains('Продукты'), isFalse);
      final restored = await BackupCodec.decrypt(encrypted, password);
      expect(restored.toJson(), fixture.toJson());
      expect(restored.accountCount, 2);
      expect(restored.entryCount, 3);
      expect(restored.budgetCount, 1);
    },
  );

  test('wrong password and ciphertext modification are rejected', () async {
    await expectLater(
      BackupCodec.decrypt(encrypted, 'wrong-password-123'),
      throwsA(isA<DomainError>()),
    );
    final envelope = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    final cipher = base64Decode(envelope['data'] as String);
    cipher[0] ^= 1;
    envelope['data'] = base64Encode(cipher);
    await expectLater(
      BackupCodec.decrypt(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        password,
      ),
      throwsA(isA<DomainError>()),
    );
  });

  test('unsupported KDF cost, malformed file and invalid relationships fail before restore', () async {
    final envelope = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    envelope['iterations'] = 999999999;
    await expectLater(
      BackupCodec.decrypt(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        password,
      ),
      throwsA(isA<DomainError>()),
    );
    await expectLater(
      BackupCodec.decrypt(Uint8List.fromList([1, 2, 3]), password),
      throwsA(isA<DomainError>()),
    );
    final data =
        jsonDecode(jsonEncode(fixture.toJson())) as Map<String, dynamic>;
    final tables = data['tables'] as Map<String, dynamic>;
    (tables['accounts'] as List).clear();
    expect(() => BackupData.fromJson(data), throwsA(isA<DomainError>()));
  });

  test('restore creates encrypted recovery first and survives reopening; failed safety save preserves data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'finance-backup-test-',
    );
    var db = LedgerDatabase(
      NativeDatabase(File('${directory.path}/ledger.sqlite')),
    );
    var repo = FinanceRepository(db);
    addTearDown(() async {
      if (await directory.exists()) {
        await db.close();
        await directory.delete(recursive: true);
      }
    });
    await repo.setCurrency('EUR');
    await repo.saveAccount(
      name: 'До восстановления',
      kind: 'Карта',
      openingMinor: 12345,
    );
    final previous = await repo.exportData();
    final blocker = File('${directory.path}/blocked');
    await blocker.writeAsString('not a directory');
    final broken = BackupService(repo, Directory(blocker.path));
    await expectLater(
      broken.restore(fixture, password),
      throwsA(isA<FileSystemException>()),
    );
    expect((await repo.exportData()).toJson(), previous.toJson());
    final service = BackupService(
      repo,
      Directory('${directory.path}/recovery'),
    );
    final recovery = await service.restore(fixture, password);
    final safety = await BackupCodec.decrypt(
      await recovery.readAsBytes(),
      password,
    );
    expect(safety.toJson(), previous.toJson());
    expect(await service.latestRecovery(), await recovery.readAsBytes());
    await db.close();
    db = LedgerDatabase(
      NativeDatabase(File('${directory.path}/ledger.sqlite')),
    );
    repo = FinanceRepository(db);
    try {
      final snapshot = await repo.load();
      expect(snapshot.currency, 'USD');
      expect(snapshot.budgets.single.limitMinor, 5000);
      expect(accountBalances(snapshot).values.reduce((a, b) => a + b), 8500);
      expect(
        (await repo.exportData()).tables['settings']!.any(
          (r) => r['key'] == 'sync_restore_required' && r['value'] == 'true',
        ),
        isTrue,
      );
      expect(exportOperationsCsv(snapshot), isNotEmpty);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test('replacement rolls back if safety callback fails; original raw data including outbox remains', () async {
    final db = LedgerDatabase(NativeDatabase.memory());
    final repo = FinanceRepository(db);
    try {
      final before = await repo.exportData();
      await expectLater(
        repo.replaceData(
          fixture,
          beforeReplace: (_) async => throw const DomainError('disk full'),
        ),
        throwsA(isA<DomainError>()),
      );
      expect((await repo.exportData()).toJson(), before.toJson());
    } finally {
      await db.close();
    }
  });

  test('CSV escapes quotes and spreadsheet formulas; export is separate from backup', () {
    final entry = LedgerEntry(
      id: 'e',
      kind: EntryKind.expense,
      amountMinor: 1234,
      date: DateTime(2026, 11, 14),
      accountId: 'a',
      category: 'Дом; "покупка"',
      note: '  =1+1',
    );
    final data = LedgerSnapshot(
      accounts: [
        const Account(id: 'a', name: '@evil', kind: 'Карта', openingMinor: 0),
      ],
      entries: [entry],
      currency: 'USD',
    );
    final csv = utf8.decode(exportOperationsCsv(data));
    expect(csv, contains('"Дом; ""покупка"""'));
    expect(csv, contains('"\'  =1+1"'));
    expect(csv, contains('"\'@evil"'));
    expect(csv, contains('"12,34"'));
  });
}
