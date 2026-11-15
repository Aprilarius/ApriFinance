import 'dart:io';

import 'package:drift/drift.dart' show MigrationStrategy;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';

import 'migration_v3_test.dart' show VersionThreeDatabase;

class VersionFourDatabase extends VersionThreeDatabase {
  VersionFourDatabase(super.executor);
  @override
  int get schemaVersion => 4;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await super.migration.onCreate(m);
      await customStatement(
        '''CREATE TABLE purchases(id TEXT PRIMARY KEY,body TEXT NOT NULL,
      entry_id TEXT REFERENCES entries(id),version INTEGER NOT NULL,deleted_at TEXT,updated_at TEXT NOT NULL)''',
      );
      await customStatement('''CREATE TABLE documents(id TEXT PRIMARY KEY,purchase_id TEXT NOT NULL REFERENCES purchases(id),
      name TEXT NOT NULL,mime TEXT NOT NULL,size INTEGER NOT NULL,data TEXT NOT NULL,
      version INTEGER NOT NULL,deleted_at TEXT,updated_at TEXT NOT NULL)''');
    },
  );
}

void main() {
  test('schema 4 file gains separate sync state without changing backup format or data', () async {
    final directory = await Directory.systemTemp.createTemp('finance-v4-');
    final file = File('${directory.path}/old.sqlite');
    final old = VersionFourDatabase(NativeDatabase(file));
    await old.customStatement("INSERT INTO settings VALUES('currency','USD')");
    await old.close();
    final db = LedgerDatabase(NativeDatabase(file));
    try {
      final repo = FinanceRepository(db);
      expect((await repo.load()).currency, 'USD');
      expect((await repo.captureSync()).scope, isNull);
      expect((await repo.exportData()).toJson()['schema'], 4);
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
  });
}
