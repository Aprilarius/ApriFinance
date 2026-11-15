import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';

import 'migration_v2_test.dart' show VersionTwoDatabase;

class VersionThreeDatabase extends VersionTwoDatabase {
  VersionThreeDatabase(super.executor);
  @override
  int get schemaVersion => 3;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await super.migration.onCreate(m);
      await customStatement(
        '''CREATE TABLE obligations(id TEXT PRIMARY KEY,body TEXT NOT NULL,
      version INTEGER NOT NULL,deleted_at TEXT,updated_at TEXT NOT NULL)''',
      );
      await customStatement(
        '''CREATE TABLE settlements(id TEXT PRIMARY KEY,
      obligation_id TEXT NOT NULL REFERENCES obligations(id),period_index INTEGER NOT NULL,
      due_date TEXT NOT NULL,entry_id TEXT REFERENCES entries(id),status TEXT NOT NULL,
      version INTEGER NOT NULL,deleted_at TEXT,updated_at TEXT NOT NULL,UNIQUE(obligation_id,period_index))''',
      );
    },
  );
}

void main() {
  test(
    'schema 3 file upgrades preserving plan and gains purchase storage',
    () async {
      final directory = await Directory.systemTemp.createTemp('finance-v3-');
      final file = File('${directory.path}/old.sqlite');
      final old = VersionThreeDatabase(NativeDatabase(file));
      final plan = Obligation(
        id: 'o',
        name: 'Интернет',
        kind: EntryKind.expense,
        amountMinor: 1000,
        category: 'Дом',
        anchor: DateTime(2026, 11, 14),
        repeat: RepeatRule.monthly,
      );
      await old.customStatement(
        "INSERT INTO settings VALUES('currency','USD')",
      );
      await old.customStatement(
        'INSERT INTO obligations VALUES(?,?,1,NULL,?)',
        [plan.id, jsonEncode(plan.toJson()), '2026-11-14T00:00:00Z'],
      );
      await old.close();
      final db = LedgerDatabase(NativeDatabase(file));
      try {
        final repo = FinanceRepository(db);
        expect((await repo.load()).obligations.single.toJson(), plan.toJson());
        await repo.savePurchase(
          Purchase(
            id: 'p',
            name: 'Наушники',
            amountMinor: 3000,
            date: DateTime(2026, 11, 14),
          ),
        );
        expect((await repo.load()).purchases.single.name, 'Наушники');
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle())
              .data
              .values
              .single,
          5,
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
