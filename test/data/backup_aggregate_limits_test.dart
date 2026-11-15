import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/money.dart';

void main() {
  test('oversized aggregate refunds in an imported snapshot cannot wrap and bypass validation', () async {
    final db = LedgerDatabase(NativeDatabase.memory());
    final repo = FinanceRepository(db);
    try {
      await repo.setCurrency('AZN');
      await repo.saveAccount(name: 'Тест', kind: 'Карта', openingMinor: 0);
      final a = (await repo.load()).accounts.single.id;
      final raw = jsonDecode(
        jsonEncode((await repo.exportData()).toJson()),
      ) as Map<String, dynamic>;
      Map<String, Object?> row(String id, EntryKind kind) => {
        'id': id,
        'body': jsonEncode(
          LedgerEntry(
            id: id,
            kind: kind,
            amountMinor: maxMoneyMinor,
            date: DateTime(2026, 11, 15),
            accountId: a,
            category: 'Дом',
            refundOf: kind == EntryKind.refund ? 'original' : null,
          ).toJson(),
        ),
        'account_id': a,
        'target_account_id': null,
        'refund_of': kind == EntryKind.refund ? 'original' : null,
        'version': 1,
        'deleted_at': null,
        'updated_at': '2026-11-15T00:00:00.000Z',
      };
      raw['tables']['entries'] = [
        row('original', EntryKind.expense),
        for (var n = 0; n < 11000; n++) row('refund-$n', EntryKind.refund),
      ];
      expect(() => BackupData.fromJson(raw), throwsA(isA<DomainError>()));
      expect((await repo.load()).entries, isEmpty);
    } finally {
      await db.close();
    }
  });
}
