import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/budget_math.dart';
import 'package:personal_finance/domain/models.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  late String account;
  final month = DateTime(2026, 11);
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db);
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 100000);
    account = (await repo.load()).accounts.single.id;
  });
  tearDown(() => db.close());

  test(
    'budget counts expenses and refunds, excludes transfers and other months',
    () async {
      await repo.saveBudget(
        month: month,
        category: 'Продукты',
        limitMinor: 10000,
      );
      await repo.saveEntry(
        kind: EntryKind.expense,
        amountMinor: 8000,
        date: month,
        accountId: account,
        category: 'продукты',
      );
      var snapshot = await repo.load();
      final source = snapshot.entries.single.id;
      expect(budgetProgress(snapshot, month).single.nearLimit, isTrue);
      await repo.saveAccount(
        name: 'Наличные',
        kind: 'Наличные',
        openingMinor: 0,
      );
      await repo.saveEntry(
        kind: EntryKind.transfer,
        amountMinor: 2000,
        date: month,
        accountId: account,
        targetAccountId: (await repo.load()).accounts.last.id,
      );
      await repo.saveEntry(
        kind: EntryKind.expense,
        amountMinor: 9000,
        date: DateTime(2026, 10, 31),
        accountId: account,
        category: 'Продукты',
      );
      await repo.saveEntry(
        kind: EntryKind.refund,
        amountMinor: 1000,
        date: month,
        accountId: account,
        refundOf: source,
      );
      snapshot = await repo.load();
      var progress = budgetProgress(snapshot, month).single;
      expect(progress.spentMinor, 7000);
      expect(progress.remainingMinor, 3000);
      expect(progress.nearLimit, isFalse);
      await repo.saveEntry(
        kind: EntryKind.expense,
        amountMinor: 5000,
        date: month,
        accountId: account,
        category: 'Продукты',
      );
      progress = budgetProgress(await repo.load(), month).single;
      expect(progress.exceeded, isTrue);
      expect(progress.remainingMinor, -2000);
      expect(progress.fraction, 1.0);
      expect(budgetProgress(await repo.load(), DateTime(2026, 12)), isEmpty);
    },
  );

  test('duplicate and invalid limits fail atomically; edit checks revision and deletion retains tombstone', () async {
    await repo.saveBudget(month: month, category: 'Дом', limitMinor: 10000);
    final before = await repo.load();
    await expectLater(
      repo.saveBudget(month: month, category: 'дом', limitMinor: 20000),
      throwsA(isA<DomainError>()),
    );
    await expectLater(
      repo.saveBudget(month: month, category: 'Дом', limitMinor: 0),
      throwsA(isA<DomainError>()),
    );
    expect((await repo.load()).pendingChanges, before.pendingChanges);
    final budget = before.budgets.single;
    await repo.saveBudget(
      id: budget.id,
      expectedVersion: budget.version,
      month: month,
      category: 'Дом',
      limitMinor: 20000,
    );
    await expectLater(repo.deleteBudget(budget), throwsA(isA<DomainError>()));
    await repo.deleteBudget((await repo.load()).budgets.single);
    expect((await repo.load()).budgets, isEmpty);
    expect(
      (await db.customSelect('SELECT version FROM budgets').getSingle())
          .read<int>('version'),
      3,
    );
    await repo.saveBudget(month: month, category: 'Дом', limitMinor: 5000);
    expect((await repo.load()).budgets.single.limitMinor, 5000);
  });
}
