import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';

import 'migration_test.dart' show VersionOneDatabase;

class VersionTwoDatabase extends VersionOneDatabase {
  VersionTwoDatabase(super.executor);
  @override
  int get schemaVersion => 2;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await super.migration.onCreate(m);
      await customStatement(
        '''CREATE TABLE budgets(id TEXT PRIMARY KEY,month TEXT NOT NULL,category TEXT NOT NULL,
      limit_minor INTEGER NOT NULL CHECK(limit_minor>0),version INTEGER NOT NULL,deleted_at TEXT,updated_at TEXT NOT NULL)''',
      );
    },
  );
}

void main() {
  test(
    'v0.2 budget file upgrades to schema 3 and can record first payment',
    () async {
      final dir = await Directory.systemTemp.createTemp('finance-v2-');
      final file = File('${dir.path}/old.sqlite');
      final old = VersionTwoDatabase(NativeDatabase(file));
      await old.customStatement(
        "INSERT INTO settings VALUES('currency','USD')",
      );
      await old.customStatement(
        "INSERT INTO budgets VALUES('b','2026-11','Дом',5000,1,NULL,'2026-11-14T00:00:00Z')",
      );
      await old.close();
      final db = LedgerDatabase(NativeDatabase(file));
      try {
        final repo = FinanceRepository(db);
        final snapshot = await repo.load();
        expect(snapshot.budgets.single.limitMinor, 5000);
        expect(snapshot.obligations, isEmpty);
        await repo.saveObligation(
          Obligation(
            id: 'o',
            name: 'Счёт',
            kind: EntryKind.expense,
            amountMinor: 1000,
            category: 'Дом',
            anchor: DateTime(2026, 11, 14),
            repeat: RepeatRule.once,
          ),
        );
        expect((await repo.load()).obligations.single.name, 'Счёт');
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle())
              .data
              .values
              .single,
          5,
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
