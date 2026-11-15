import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';
import 'package:personal_finance/domain/reminder_plan.dart';
import 'package:personal_finance/domain/ledger_math.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  late String account;
  final today = DateTime(2026, 11, 14);
  final pdf = Uint8List.fromList(
    utf8.encode('%PDF-1.7\nfictional receipt\n%%EOF'),
  );
  Purchase purchase({String id = 'purchase', String? entryId}) => Purchase(
    id: id,
    name: 'Наушники',
    amountMinor: 3000,
    date: today,
    entryId: entryId,
    returnBy: DateTime(2026, 11, 21),
    warrantyUntil: DateTime(2027, 11, 14),
  );
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => today);
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    account = (await repo.load()).accounts.single.id;
  });
  tearDown(() => db.close());

  test('card does not spend; existing expense links once and guards edits until detached', () async {
    await repo.savePurchase(purchase());
    expect(accountBalances(await repo.load())[account], 10000);
    final entry = await repo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 3000,
      date: today,
      accountId: account,
      category: 'Покупки',
    );
    await repo.savePurchase(purchase(entryId: entry), expectedVersion: 1);
    var s = await repo.load();
    expect(s.entries.length, 1);
    expect(accountBalances(s)[account], 7000);
    await expectLater(
      repo.savePurchase(purchase(id: 'second', entryId: entry)),
      throwsA(isA<DomainError>()),
    );
    await expectLater(
      repo.deleteEntry(s.entries.single),
      throwsA(isA<DomainError>()),
    );
    await expectLater(
      repo.saveEntry(
        id: entry,
        expectedVersion: 1,
        kind: EntryKind.income,
        amountMinor: 3000,
        date: today,
        accountId: account,
        category: 'Другое',
      ),
      throwsA(isA<DomainError>()),
    );
    await repo.savePurchase(purchase(), expectedVersion: 2);
    await repo.deleteEntry(s.entries.single);
    s = await repo.load();
    expect(s.purchases.single.entryId, isNull);
    expect(accountBalances(s)[account], 10000);
  });

  test('new expense and outbox are atomic; stale edit and wrong amount are rejected', () async {
    await expectLater(
      repo.savePurchase(purchase(), newExpenseAccountId: 'missing'),
      throwsA(isA<DomainError>()),
    );
    expect((await repo.load()).purchases, isEmpty);
    expect((await repo.load()).entries, isEmpty);
    await repo.savePurchase(purchase(), newExpenseAccountId: account);
    final s = await repo.load();
    expect(s.entries.single.id, s.purchases.single.entryId);
    expect(accountBalances(s)[account], 7000);
    final before = s.pendingChanges;
    await expectLater(
      repo.savePurchase(purchase(), expectedVersion: 99),
      throwsA(isA<DomainError>()),
    );
    await expectLater(
      repo.savePurchase(
        Purchase.fromJson({...s.purchases.single.toJson(), 'amountMinor': 1}),
        expectedVersion: 1,
      ),
      throwsA(isA<DomainError>()),
    );
    expect((await repo.load()).pendingChanges, before);
    await repo.deletePurchase(s.purchases.single);
    expect((await repo.load()).entries.length, 1);
    await expectLater(
      repo.savePurchase(purchase()),
      throwsA(isA<DomainError>()),
    );
    expect((await repo.exportData()).purchaseCount, 0);
  });

  test('documents round trip encrypted with recovery and reject corrupt links or contents', () async {
    final directory = await Directory.systemTemp.createTemp('purchase-backup-');
    try {
      await repo.savePurchase(purchase(), newExpenseAccountId: account);
      await repo.addDocument('purchase', 'Чек.pdf', pdf);
      final document = (await repo.load()).documents.single;
      final backup = BackupService(repo, directory);
      const password = 'purchase-test-password';
      final encoded = await backup.create(password);
      final restored = await backup.inspect(encoded, password);
      expect(restored.purchaseCount, 1);
      expect(restored.documentCount, 1);
      await repo.deleteDocument(document);
      expect((await repo.load()).documents, isEmpty);
      await backup.restore(restored, password);
      expect(
        await repo.readDocument((await repo.load()).documents.single),
        pdf,
      );
      expect(accountBalances(await repo.load())[account], 7000);
      final data = (await repo.exportData()).toJson();
      Map<String, Object?> clone() =>
          (jsonDecode(jsonEncode(data)) as Map<String, dynamic>)
              .cast<String, Object?>();
      final broken = clone();
      (((broken['tables'] as Map)['documents'] as List).single as Map)['data'] =
          base64Encode([0, 1]);
      expect(() => BackupData.fromJson(broken), throwsA(isA<DomainError>()));
      final path = clone();
      (((path['tables'] as Map)['documents'] as List).single as Map)['name'] =
          '../receipt.pdf';
      expect(() => BackupData.fromJson(path), throwsA(isA<DomainError>()));
      final missing = clone();
      ((missing['tables'] as Map)['purchases'] as List).clear();
      expect(() => BackupData.fromJson(missing), throwsA(isA<DomainError>()));
      await repo.deletePurchase((await repo.load()).purchases.single);
      expect((await repo.exportData()).documentCount, 0);
      expect((await repo.load()).documents, isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('file type, file limit, total limit and invalid purchase dates are enforced', () async {
    await repo.savePurchase(purchase());
    await expectLater(
      repo.addDocument('purchase', 'run.pdf', Uint8List.fromList([77, 90])),
      throwsA(isA<DomainError>()),
    );
    await expectLater(
      repo.addDocument('purchase', 'big.pdf', Uint8List(maxDocumentBytes + 1)),
      throwsA(isA<DomainError>()),
    );
    final large = Uint8List(maxDocumentBytes)..setAll(0, [37, 80, 68, 70, 45]);
    for (var i = 0; i < 4; i++) {
      await repo.addDocument('purchase', '$i.pdf', large);
    }
    await expectLater(
      repo.addDocument('purchase', 'overflow.pdf', pdf),
      throwsA(isA<DomainError>()),
    );
    final first = (await repo.load()).documents.first;
    await repo.deleteDocument(first);
    await repo.addDocument('purchase', 'small.pdf', pdf);
    await expectLater(repo.readDocument(first), throwsA(isA<DomainError>()));
    expect((await repo.exportData()).documentCount, 4);
    await expectLater(
      repo.savePurchase(
        Purchase.fromJson({
          ...purchase(id: 'bad').toJson(),
          'returnBy': '2026-11-13',
        }),
      ),
      throwsA(isA<DomainError>()),
    );
  });

  test('purchase deadlines share scheduler, deduplicate, and archive stops reminders', () async {
    await repo.savePurchase(purchase());
    var plan = reminderPlan(await repo.load(), today);
    expect(plan.where((r) => r.purchase).length, 4);
    expect(plan.first.fireAt, DateTime(2026, 11, 14, 9));
    final p = (await repo.load()).purchases.single;
    await repo.savePurchase(
      Purchase.fromJson({...p.toJson(), 'warrantyUntil': '2026-11-21'}),
      expectedVersion: 1,
    );
    plan = reminderPlan(await repo.load(), today);
    expect(plan.length, 2);
    final updated = (await repo.load()).purchases.single;
    await repo.savePurchase(
      Purchase.fromJson({...updated.toJson(), 'archived': true}),
      expectedVersion: 2,
    );
    expect(reminderPlan(await repo.load(), today), isEmpty);
  });

  test('schema 3 backup upgrades with empty purchases and documents', () async {
    final data = (await repo.exportData()).toJson();
    final tables = Map<String, Object?>.from(data['tables']! as Map)
      ..remove('purchases')
      ..remove('documents');
    final upgraded = BackupData.fromJson({'schema': 3, 'tables': tables});
    expect(upgraded.purchaseCount, 0);
    expect(upgraded.documentCount, 0);
    expect(upgraded.toJson()['schema'], 4);
  });
}
