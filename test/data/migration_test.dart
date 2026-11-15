import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/ledger_math.dart';
import 'package:personal_finance/domain/models.dart';

// Frozen v0.1 schema, intentionally independent of the current migration.
class VersionOneDatabase extends GeneratedDatabase {
  VersionOneDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in [
        'CREATE TABLE settings (key TEXT PRIMARY KEY,value TEXT NOT NULL)',
        'CREATE TABLE accounts (id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,opening_minor INTEGER NOT NULL,archived INTEGER NOT NULL DEFAULT 0,version INTEGER NOT NULL,updated_at TEXT NOT NULL)',
        'CREATE TABLE entries (id TEXT PRIMARY KEY,body TEXT NOT NULL,account_id TEXT NOT NULL REFERENCES accounts(id),target_account_id TEXT REFERENCES accounts(id),refund_of TEXT REFERENCES entries(id),version INTEGER NOT NULL,deleted_at TEXT,updated_at TEXT NOT NULL)',
        'CREATE TABLE outbox (id TEXT PRIMARY KEY,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,version INTEGER NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL)',
      ]) {
        await customStatement(sql);
      }
    },
  );
}

void main() {
  test('v0.1 file upgrades to v0.2 without resetting currency, balances, operations or outbox', () async {
    final dir = await Directory.systemTemp.createTemp('finance-migration-');
    final file = File('${dir.path}/old.sqlite');
    final old = VersionOneDatabase(NativeDatabase(file));
    const time = '2026-11-14T00:00:00.000Z';
    await old.customStatement("INSERT INTO settings VALUES ('currency','USD')");
    await old.customStatement('INSERT INTO accounts VALUES (?,?,?,?,?,?,?)', [
      'a',
      'Карта',
      'Карта',
      10000,
      0,
      1,
      time,
    ]);
    final entry = LedgerEntry(
      id: 'e',
      kind: EntryKind.expense,
      amountMinor: 2500,
      date: DateTime(2026, 11, 14),
      accountId: 'a',
      category: 'Дом',
    );
    await old.customStatement('INSERT INTO entries VALUES (?,?,?,?,?,?,?,?)', [
      'e',
      jsonEncode(entry.toJson()),
      'a',
      null,
      null,
      1,
      null,
      time,
    ]);
    await old.customStatement('INSERT INTO outbox VALUES (?,?,?,?,?,?)', [
      'change',
      'entry',
      'e',
      1,
      jsonEncode(entry.toJson()),
      time,
    ]);
    expect(
      (await old.customSelect('PRAGMA user_version').getSingle())
          .data
          .values
          .single,
      1,
    );
    await old.close();
    final current = LedgerDatabase(NativeDatabase(file));
    try {
      final repo = FinanceRepository(current);
      final snapshot = await repo.load();
      expect(snapshot.currency, 'USD');
      expect(accountBalances(snapshot)['a'], 7500);
      expect(snapshot.entries.single.toJson(), entry.toJson());
      expect(snapshot.pendingChanges, 1);
      expect(snapshot.budgets, isEmpty);
      await repo.saveBudget(
        month: DateTime(2026, 11),
        category: 'Дом',
        limitMinor: 5000,
      );
      expect((await repo.load()).budgets.single.limitMinor, 5000);
      expect(
        (await current.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        5,
      );
    } finally {
      await current.close();
      await dir.delete(recursive: true);
    }
  });
}
