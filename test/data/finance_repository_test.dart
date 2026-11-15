import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/ledger_math.dart';
import 'package:personal_finance/domain/models.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  late Account cash;
  late Account card;
  final date = DateTime(2026, 11, 14);

  Future<void> add(
    EntryKind kind,
    int amount, {
    String? target,
    String? refundOf,
    DateTime? at,
  }) => repo.saveEntry(
    kind: kind,
    amountMinor: amount,
    date: at ?? date,
    accountId: cash.id,
    targetAccountId: target,
    category: 'Продукты',
    refundOf: refundOf,
  );

  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => date);
    await repo.setCurrency('USD');
    await repo.saveAccount(
      name: 'Наличные',
      kind: 'Наличные',
      openingMinor: 10000,
    );
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 0);
    final snapshot = await repo.load();
    cash = snapshot.accounts[0];
    card = snapshot.accounts[1];
  });
  tearDown(() async => db.close());

  test('control example and transfer conserve total and exclude opening balance from income', () async {
    await add(EntryKind.income, 100000);
    await add(EntryKind.expense, 25000);
    await add(EntryKind.transfer, 15000, target: card.id);
    final snapshot = await repo.load();
    expect(accountBalances(snapshot), {cash.id: 70000, card.id: 15000});
    final totals = monthTotals(snapshot.entries, date);
    expect(totals.income, 100000);
    expect(totals.expense, 25000);
    expect(totals.net, 75000);
  });

  test('failed transfer rolls back both ledger and outbox', () async {
    final pending = (await repo.load()).pendingChanges;
    await expectLater(
      add(EntryKind.transfer, 15000, target: cash.id),
      throwsA(isA<DomainError>()),
    );
    final snapshot = await repo.load();
    expect(snapshot.entries, isEmpty);
    expect(snapshot.pendingChanges, pending);
    expect(accountBalances(snapshot)[cash.id], 10000);
  });

  test(
    'edit and soft delete recalculate balances; stale writes fail',
    () async {
      await add(EntryKind.expense, 2500);
      final entry = (await repo.load()).entries.single;
      await repo.saveEntry(
        id: entry.id,
        expectedVersion: entry.version,
        kind: EntryKind.expense,
        amountMinor: 5000,
        date: date,
        accountId: cash.id,
        category: 'Дом',
      );
      expect(accountBalances(await repo.load())[cash.id], 5000);
      await expectLater(repo.deleteEntry(entry), throwsA(isA<DomainError>()));
      final edited = (await repo.load()).entries.single;
      await repo.deleteEntry(edited);
      expect((await repo.load()).entries, isEmpty);
      expect(accountBalances(await repo.load())[cash.id], 10000);
      final row = await db
          .customSelect('SELECT deleted_at, version FROM entries')
          .getSingle();
      expect(row.readNullable<String>('deleted_at'), isNotNull);
      expect(row.read<int>('version'), 3);
    },
  );

  test(
    'refund reduces expense, cannot exceed purchase or orphan linked refunds',
    () async {
      await add(EntryKind.expense, 8000);
      final original = (await repo.load()).entries.single;
      await add(EntryKind.refund, 3000, refundOf: original.id);
      final snapshot = await repo.load();
      expect(accountBalances(snapshot)[cash.id], 5000);
      expect(monthTotals(snapshot.entries, date).expense, 5000);
      expect(monthTotals(snapshot.entries, date).income, 0);
      await expectLater(
        add(EntryKind.refund, 6000, refundOf: original.id),
        throwsA(isA<DomainError>()),
      );
      await expectLater(
        repo.deleteEntry(original),
        throwsA(isA<DomainError>()),
      );
    },
  );

  test('reports use operation calendar date, not modification time', () async {
    await add(EntryKind.income, 5000, at: DateTime(2026, 10, 31));
    await add(EntryKind.expense, 2000, at: DateTime(2026, 11, 1));
    final entries = (await repo.load()).entries;
    expect(monthTotals(entries, DateTime(2026, 10)).income, 5000);
    expect(monthTotals(entries, date).income, 0);
    expect(monthTotals(entries, date).expense, 2000);
  });

  test(
    'currency locks after first account and archive requires zero balance',
    () async {
      await expectLater(repo.setCurrency('EUR'), throwsA(isA<DomainError>()));
      await expectLater(
        repo.saveAccount(
          id: cash.id,
          expectedVersion: 1,
          name: cash.name,
          kind: cash.kind,
          openingMinor: cash.openingMinor,
          archived: true,
        ),
        throwsA(isA<DomainError>()),
      );
      await repo.saveAccount(
        id: card.id,
        expectedVersion: 1,
        name: card.name,
        kind: card.kind,
        openingMinor: 0,
        archived: true,
      );
      await expectLater(
        add(EntryKind.transfer, 1000, target: card.id),
        throwsA(isA<DomainError>()),
      );
    },
  );

  test('rejects zero and negative operations without writes', () async {
    for (final amount in [0, -100]) {
      await expectLater(
        add(EntryKind.income, amount),
        throwsA(isA<DomainError>()),
      );
    }
    expect((await repo.load()).entries, isEmpty);
  });

  test('serialization keeps integer minor units and calendar dates', () {
    final entry = LedgerEntry(
      id: 'id',
      kind: EntryKind.expense,
      amountMinor: 101,
      date: date,
      accountId: 'cash',
      category: 'Дом',
    );
    final copy = LedgerEntry.fromJson(entry.toJson());
    expect(copy.toJson(), entry.toJson());
  });

  test('file database survives close and reopen including outbox', () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp('finance-test-');
    final file = File('${directory.path}/ledger.sqlite');
    final first = db = LedgerDatabase(NativeDatabase(file));
    final firstRepo = FinanceRepository(first);
    await firstRepo.setCurrency('EUR');
    await firstRepo.saveAccount(
      name: 'Карта',
      kind: 'Карта',
      openingMinor: 12345,
    );
    final account = (await firstRepo.load()).accounts.single;
    await firstRepo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 345,
      date: date,
      accountId: account.id,
      category: 'Продукты',
    );
    await first.close();
    final second = db = LedgerDatabase(NativeDatabase(file));
    try {
      final snapshot = await FinanceRepository(second).load();
      expect(snapshot.currency, 'EUR');
      expect(accountBalances(snapshot)[account.id], 12000);
      expect(snapshot.pendingChanges, 2);
      expect(snapshot.entries.single.amountMinor, 345);
    } finally {
      await second.close();
      await directory.delete(recursive: true);
    }
  });
}
