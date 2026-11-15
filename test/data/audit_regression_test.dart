import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/backup_codec.dart';
import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/domain/models.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  final today = DateTime(2026, 11, 14);
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db);
    await repo.setCurrency('USD');
  });
  tearDown(() => db.close());

  for (final kind in [
    EntryKind.expense,
    EntryKind.income,
    EntryKind.transfer,
  ]) {
    test(
      'backup survives deleted refund then source edited to ${kind.name}',
      () async {
        await repo.saveAccount(name: 'QA', kind: 'Карта', openingMinor: 10000);
        await repo.saveAccount(
          name: 'QA target',
          kind: 'Карта',
          openingMinor: 0,
        );
        final accounts = (await repo.load()).accounts;
        final id = await repo.saveEntry(
          kind: EntryKind.expense,
          amountMinor: 1000,
          date: today,
          accountId: accounts.first.id,
          category: 'Покупки',
        );
        final refundId = await repo.saveEntry(
          kind: EntryKind.refund,
          amountMinor: 500,
          date: today,
          accountId: accounts.first.id,
          refundOf: id,
        );
        await repo.deleteEntry(
          (await repo.load()).entries.singleWhere((e) => e.id == refundId),
        );
        await repo.saveEntry(
          id: id,
          expectedVersion: 1,
          kind: kind,
          amountMinor: 1000,
          date: today,
          accountId: accounts.first.id,
          targetAccountId: accounts.last.id,
          category: 'Другое',
        );
        final exported = await repo.exportData();
        expect(exported.entryCount, 1);
        await repo.replaceData(exported, beforeReplace: (_) async {});
        expect((await repo.load()).entries.single.kind, kind);
        expect((await repo.exportData()).entryCount, 1);
        // A live refund must still match a live expense and its category.
        final damaged =
            jsonDecode(jsonEncode(exported.toJson())) as Map<String, dynamic>;
        final entries = (damaged['tables'] as Map)['entries'] as List;
        final refund = entries.cast<Map<String, dynamic>>().singleWhere(
          (r) => r['id'] == refundId,
        );
        refund['deleted_at'] = null;
        final body = jsonDecode(refund['body'] as String) as Map;
        body['version'] = refund['version'];
        refund['body'] = jsonEncode(body);
        expect(() => BackupData.fromJson(damaged), throwsA(isA<DomainError>()));
      },
    );
  }

  for (final type in ['budget', 'obligation']) {
    test(
      'currency cannot reinterpret existing $type without accounts',
      () async {
        if (type == 'budget') {
          await repo.saveBudget(
            month: today,
            category: 'Дом',
            limitMinor: 5000,
          );
        } else {
          await repo.saveObligation(
            Obligation(
              id: 'qa-plan',
              name: 'QA plan',
              kind: EntryKind.expense,
              amountMinor: 5000,
              category: 'Дом',
              anchor: today,
              repeat: RepeatRule.monthly,
            ),
          );
        }
        final before = (await repo.exportData()).toJson();
        await expectLater(repo.setCurrency('EUR'), throwsA(isA<DomainError>()));
        expect((await repo.exportData()).toJson(), before);
        final damaged = jsonDecode(jsonEncode(before)) as Map<String, dynamic>;
        ((damaged['tables'] as Map)['settings'] as List).clear();
        expect(() => BackupData.fromJson(damaged), throwsA(isA<DomainError>()));
      },
    );
  }

  test('deleted budget still locks the currency of its history', () async {
    await repo.saveBudget(month: today, category: 'Дом', limitMinor: 5000);
    await repo.deleteBudget((await repo.load()).budgets.single);
    await expectLater(repo.setCurrency('EUR'), throwsA(isA<DomainError>()));
    expect((await repo.load()).currency, 'USD');
  });

  test('latest recovery enforces same size limit as history export', () async {
    final directory = await Directory.systemTemp.createTemp(
      'finance-audit-recovery-',
    );
    try {
      final file = File('${directory.path}/before-restore-qa.mfin');
      final handle = await file.open(mode: FileMode.write);
      try {
        await handle.truncate(BackupCodec.maxFileBytes + 1);
      } finally {
        await handle.close();
      }
      final service = BackupService(repo, directory);
      await expectLater(service.latestRecovery(), throwsA(isA<DomainError>()));
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
